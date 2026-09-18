@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

import 'websocket_proxy.dart';

Future<void> eventually(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition was not met within five seconds');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  final endpoint = Platform.environment['PHOENIX_E2E_URL'];
  var sequence = 0;
  group('embedded Elixir backend', () {
    late PhoenixSocket socket;
    late String topic;
    setUp(() async {
      topic = 'audit:${DateTime.now().microsecondsSinceEpoch}-${sequence++}';
      socket = PhoenixSocket(endpoint!,
          socketOptions: PhoenixSocketOptions(
            params: {'user_id': topic},
            timeout: const Duration(milliseconds: 300),
            heartbeat: const Duration(milliseconds: 100),
            heartbeatTimeout: const Duration(seconds: 2),
            reconnectDelays: const [Duration(milliseconds: 200)],
          ));
      addTearDown(socket.dispose);
      expect(await socket.connect(), same(socket));
    });

    test('join, request/reply, and leave use the Phoenix wire protocol',
        () async {
      final channel = socket.addChannel(topic: topic);
      expect((await channel.join().future).isOk, isTrue);
      final reply = await channel
          .push('echo', {'value': 42}, expectingReply: true)
          .future;
      expect(reply.response, {'value': 42});
      expect((await channel.leave().future).isOk, isTrue);
      expect(channel.state, PhoenixChannelState.closed);
      expect(socket.channels, isEmpty);
    });

    test('a timed-out join recovers when its next attempt succeeds', () async {
      final channel =
          socket.addChannel(topic: topic, parameters: {'join_delay_ms': 450});
      final join = channel.join();
      join.onReply('timeout', (_) => channel.parameters['join_delay_ms'] = 0);
      await expectLater(join.future, throwsA(isA<ChannelTimeoutException>()));
      await eventually(() => channel.canPush);
      expect(
          (await channel
                  .push('echo', {'recovered': true}, expectingReply: true)
                  .future)
              .response,
          {'recovered': true});
    });

    test('server phx_close settles the pending push and preserves the socket',
        () async {
      final channel = socket.addChannel(topic: topic);
      await channel.join().future;
      await expectLater(
          channel.push('close_pending', {}, expectingReply: true).future,
          throwsA(isA<ChannelClosedError>()));
      expect(channel.state, PhoenixChannelState.closed);
      expect(socket.isConnected, isTrue);
      expect(socket.channels, isEmpty);
    });

    test('leaving during join closes the delayed server channel', () async {
      final channel =
          socket.addChannel(topic: topic, parameters: {'join_delay_ms': 100});
      final pendingJoin = channel.join();
      final joinRef = pendingJoin.ref;
      final protocol = socket.streamForTopic(topic);
      final serverJoin = protocol.firstWhere((message) =>
          message.event == PhoenixChannelEvent.reply && message.ref == joinRef);
      final serverClose = protocol.firstWhere((message) =>
          message.event == PhoenixChannelEvent.close &&
          message.joinRef == joinRef);
      final joinFailure =
          expectLater(pendingJoin.future, throwsA(isA<ChannelClosedError>()));
      final leave = channel.leave();
      final serverLeave = protocol.firstWhere((message) =>
          message.event == PhoenixChannelEvent.reply &&
          message.ref == leave.ref);
      expect((await leave.future).isOk, isTrue);
      await joinFailure;
      expect((await serverJoin).payload?['status'], 'ok');
      final leaveReply = await serverLeave;
      expect(leaveReply.payload?['status'], 'ok');
      expect(leaveReply.joinRef, joinRef);
      await serverClose;
      expect(channel.state, PhoenixChannelState.closed);
      expect(socket.channels, isEmpty);
      expect(socket.isConnected, isTrue);
    });

    test('closing a rejected join prevents another join request', () async {
      final channel =
          socket.addChannel(topic: topic, parameters: {'reject': true});
      expect((await channel.join().future).isError, isTrue);
      final laterReplies = <Message>[];
      final subscription =
          socket.streamForTopic(topic).listen(laterReplies.add);
      addTearDown(subscription.cancel);
      channel.close();
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(channel.state, PhoenixChannelState.closed);
      expect(laterReplies, isEmpty);
    });

    test('a topic observer survives channel leave and replacement', () async {
      final observed = <Message>[];
      final subscription = socket.streamForTopic(topic).listen(observed.add);
      addTearDown(subscription.cancel);
      final first = socket.addChannel(topic: topic);
      await first.join().future;
      await first.leave().future;
      final second = socket.addChannel(topic: topic);
      expect((await second.join().future).isOk, isTrue);
      expect(
          (await second
                  .push('echo', {'replacement': true}, expectingReply: true)
                  .future)
              .response,
          {'replacement': true});
      expect(
          observed
              .where((message) => message.event == PhoenixChannelEvent.reply)
              .length,
          greaterThanOrEqualTo(4));
    });

    test('a canceled topic subscription does not disable later subscribers',
        () async {
      final stream = socket.streamForTopic(topic);
      await stream.listen((_) {}).cancel();
      final replySeen = stream.first;
      final channel = socket.addChannel(topic: topic);
      await channel.join().future;
      expect((await replySeen).event, PhoenixChannelEvent.reply);
    });

    test('buffered fire-and-forget messages do not acquire reply timeouts',
        () async {
      final channel =
          socket.addChannel(topic: topic, parameters: {'join_delay_ms': 50});
      final join = channel.join();
      final observed = channel.messages
          .firstWhere((message) => message.event.value == 'observed');
      final push = channel.push('no_reply', {'buffered': true},
          expectingReply: false, newTimeout: const Duration(milliseconds: 30));
      var timedOut = false;
      push.onReply('timeout', (_) => timedOut = true);
      await join.future;
      expect((await observed).payload, {'buffered': true});
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(timedOut, isFalse);
      expect(
          (await channel.push('stats', {}, expectingReply: true).future)
              .response,
          {'observed': 1});
    });

    test('custom events with a phx_reply prefix reach channel subscribers',
        () async {
      final channel = socket.addChannel(topic: topic);
      await channel.join().future;
      final event = channel.messages
          .firstWhere((message) => message.event.value == 'phx_reply_custom');
      await channel
          .push(
              'echo_event',
              {
                'event': 'phx_reply_custom',
                'payload': {'ok': true}
              },
              expectingReply: true)
          .future;
      expect((await event).payload, {'ok': true});
    });

    test('server disconnect reconnects and rejoins the channel', () async {
      final channel = socket.addChannel(topic: topic);
      await channel.join().future;
      final closed = socket.closeStream.first;
      channel.push('disconnect', {}, expectingReply: false);
      await closed;
      await eventually(() => channel.canPush);
      expect(
          (await channel
                  .push('echo', {'reconnected': true}, expectingReply: true)
                  .future)
              .response,
          {'reconnected': true});
    });

    test('authenticated joins accept valid parameters and reject invalid ones',
        () async {
      final accepted = socket.addChannel(
          topic: 'channel1:accepted', parameters: {'password': 'deadbeef'});
      expect((await accepted.join().future).isOk, isTrue);
      final rejected = socket.addChannel(
          topic: 'channel1:rejected', parameters: {'password': 'invalid'});
      expect((await rejected.join().future).isError, isTrue);
      rejected.close();
    });

    test('broadcast messages are delivered to two real socket connections',
        () async {
      final other = PhoenixSocket(endpoint!);
      addTearDown(other.dispose);
      await other.connect();
      final first = socket.addChannel(topic: 'channel3');
      final second = other.addChannel(topic: 'channel3');
      await Future.wait([first.join().future, second.join().future]);
      final firstPong =
          first.messages.firstWhere((message) => message.event.value == 'pong');
      final secondPong = second.messages
          .firstWhere((message) => message.event.value == 'pong');
      first.push('ping', {'source': topic}, expectingReply: false);
      expect((await firstPong).payload, {'source': topic});
      expect((await secondPong).payload, {'source': topic});
    });

    test('a request timeout settles while the connection remains usable',
        () async {
      final channel = socket.addChannel(topic: topic);
      await channel.join().future;
      final request = channel.push('no_reply', {},
          expectingReply: true, newTimeout: const Duration(milliseconds: 40));
      await expectLater(
          request.future, throwsA(isA<ChannelTimeoutException>()));
      expect(socket.isConnected, isTrue);
      expect(
          (await channel
                  .push('echo', {'after': 'timeout'}, expectingReply: true)
                  .future)
              .response,
          {'after': 'timeout'});
    });

    test('heartbeat loss through an isolated proxy reconnects and rejoins',
        () async {
      final proxy = await WebSocketProxy.start(Uri.parse(endpoint!));
      final proxied = PhoenixSocket(proxy.endpoint,
          socketOptions: const PhoenixSocketOptions(
            heartbeat: Duration(milliseconds: 40),
            heartbeatTimeout: Duration(milliseconds: 150),
            reconnectDelays: [Duration(milliseconds: 20)],
          ));
      addTearDown(() async {
        proxied.dispose();
        await proxy.close();
      });
      await proxied.connect();
      final channel = proxied.addChannel(topic: topic);
      await channel.join().future;
      final lost = proxied.closeStream.first;
      proxy.dropFirstConnectionReplies = true;
      await lost;
      await eventually(() => proxy.connections == 2 && channel.canPush);
      expect(
          (await channel
                  .push('echo', {'heartbeat': 'recovered'},
                      expectingReply: true)
                  .future)
              .response,
          {'heartbeat': 'recovered'});
    });

    test(
        'a real stalled WebSocket handshake completes at the configured timeout',
        () async {
      final stalledServer =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = stalledServer.listen((_) {});
      final stalled = PhoenixSocket(
          'ws://127.0.0.1:${stalledServer.port}/socket/websocket',
          socketOptions: const PhoenixSocketOptions(
              timeout: Duration(milliseconds: 50), maxReconnectionAttempts: 0));
      addTearDown(() async {
        stalled.dispose();
        await requests.cancel();
        await stalledServer.close(force: true);
      });
      expect(
          await stalled.connect().timeout(const Duration(seconds: 2)), isNull);
      expect(stalled.isConnected, isFalse);
    });

    test('explicit close during reconnection prevents a late connection',
        () async {
      final channel = socket.addChannel(topic: topic);
      await channel.join().future;
      var opened = 0;
      final subscription = socket.openStream.listen((_) => opened++);
      addTearDown(subscription.cancel);
      final closed = socket.closeStream.first;
      channel.push('disconnect', {}, expectingReply: false);
      await closed;
      socket.close();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(socket.isConnected, isFalse);
      expect(opened, 1);
    });
  },
      skip: endpoint == null
          ? 'Run dart run tool/run_e2e.dart to start the isolated backend.'
          : false,
      timeout: const Timeout(Duration(seconds: 15)));
}
