import 'dart:async';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

import 'helpers/fake_channel_socket.dart';

void main() {
  late FakeChannelSocket socket;
  late PhoenixChannel channel;

  setUp(() {
    socket = FakeChannelSocket();
    channel = PhoenixChannel.fromSocket(socket, topic: 'lifecycle');
  });

  tearDown(() async {
    channel.close();
    await socket.shutdown();
  });

  void acceptJoins() {
    socket.onSend = (message) {
      if (message.event == PhoenixChannelEvent.join) socket.reply(message);
    };
  }

  test(
      'join timeout recovers and preserves success callbacks and buffered work',
      () async {
    var joins = 0;
    socket.onSend = (message) {
      if (message.event == PhoenixChannelEvent.join && ++joins == 2) {
        socket.reply(message);
      } else if (message.event.value == 'request') {
        socket.reply(message);
      }
    };
    final joined = Completer<PushResponse>();
    final join = channel.join()..onReply('ok', joined.complete);
    final firstAttempt = join.future;
    final buffered = channel.push('request', {}, expectingReply: true);

    await expectLater(firstAttempt, throwsA(isA<ChannelTimeoutException>()));
    await joined.future.timeout(const Duration(seconds: 1));
    expect(await join.future, isA<PushResponse>());
    expect((await buffered.future).isOk, isTrue);
    expect(channel.state, PhoenixChannelState.joined);
    expect(joins, 2);
    expect(channel.pushBuffer, isEmpty);
  });

  test('join rejection retries without dropping callbacks', () async {
    var joins = 0;
    socket.onSend = (message) {
      if (message.event == PhoenixChannelEvent.join) {
        socket.reply(message, ++joins == 1 ? 'error' : 'ok');
      }
    };
    final joined = Completer<PushResponse>();
    final join = channel.join()..onReply('ok', joined.complete);
    expect((await join.future).isError, isTrue);
    await joined.future.timeout(const Duration(seconds: 1));
    expect(channel.state, PhoenixChannelState.joined);
    expect(joins, 2);
  });

  test('a pending join survives disconnect and ignores the old reply',
      () async {
    final join = channel.join();
    final originalJoin = socket.sentMessages.single;
    final result = join.future;
    socket.connected = false;
    channel.triggerError(ChannelClosedError(message: 'Expected disconnect'));
    socket.reply(originalJoin);
    await settleEvents();
    expect(channel.state, PhoenixChannelState.errored);

    acceptJoins();
    socket.connected = true;
    socket.opens.add(const PhoenixSocketOpenEvent());
    expect((await result.timeout(const Duration(seconds: 1))).isOk, isTrue);
    expect(channel.state, PhoenixChannelState.joined);
    expect(socket.sentMessages, hasLength(2));
    expect(socket.sentMessages.last.ref, isNot(originalJoin.ref));
  });

  test('close before join ends streams and removes the channel exactly once',
      () async {
    final streamDone = channel.messages.drain<void>();
    final statesDone = channel.stateStream.drain<void>();
    channel.close();
    channel.close();
    await Future.wait([streamDone, statesDone]);
    expect(socket.removals, 1);
    expect(socket.incoming.hasListener, isFalse);
    expect(socket.opens.hasListener, isFalse);
    expect(socket.errors.hasListener, isFalse);
    expect(() => channel.join(), throwsA(isA<ChannelClosedError>()));
  });

  test('lifecycle stream reports leave synchronously and closes with channel',
      () async {
    acceptJoins();
    await channel.join().future;
    final states = <PhoenixChannelState>[];
    final done = Completer<void>();
    final subscription =
        channel.stateStream.listen(states.add, onDone: done.complete);
    addTearDown(subscription.cancel);

    final leave = channel.leave();
    expect(states, [PhoenixChannelState.leaving]);
    socket.reply(socket.sentMessages.last);
    expect((await leave.future).isOk, isTrue);
    await done.future;
    expect(states, [PhoenixChannelState.leaving, PhoenixChannelState.closed]);
    expect(socket.removals, 1);
  });

  test('explicit close settles pending join and buffered requests', () async {
    final join = channel.join();
    final buffered = channel.push('request', {}, expectingReply: true);
    final joinResult =
        expectLater(join.future, throwsA(isA<ChannelClosedError>()));
    final pushResult =
        expectLater(buffered.future, throwsA(isA<ChannelClosedError>()));
    channel.close();
    await Future.wait([joinResult, pushResult]);
    expect(channel.pushBuffer, isEmpty);
  });

  for (final viaServer in [false, true]) {
    test('${viaServer ? 'server' : 'explicit'} close settles a sent request',
        () async {
      acceptJoins();
      await channel.join().future;
      final push = channel.push('request', {}, expectingReply: true);
      final result =
          expectLater(push.future, throwsA(isA<ChannelClosedError>()));
      if (viaServer) {
        channel.trigger(Message(event: PhoenixChannelEvent.close));
      } else {
        channel.close();
      }
      await result;
      expect(channel.state, PhoenixChannelState.closed);
    });
  }

  test('leave during join sends the original join ref and ignores its reply',
      () async {
    final join = channel.join();
    final originalJoin = socket.sentMessages.single;
    final buffered = channel.push('request', {}, expectingReply: true);
    final joinResult =
        expectLater(join.future, throwsA(isA<ChannelClosedError>()));
    final pushResult =
        expectLater(buffered.future, throwsA(isA<ChannelClosedError>()));

    final leave = channel.leave();
    final leaveMessage = socket.sentMessages.last;
    expect(leaveMessage.event, PhoenixChannelEvent.leave);
    expect(leaveMessage.joinRef, originalJoin.ref);
    expect(leaveMessage.ref, isNot(originalJoin.ref));
    await joinResult;
    socket.reply(originalJoin);
    await settleEvents();
    expect(channel.state, PhoenixChannelState.leaving);
    expect(socket.sentMessages, hasLength(2));

    socket.reply(leaveMessage);
    expect((await leave.future).isOk, isTrue);
    await Future.wait([joinResult, pushResult]);
    socket.reply(originalJoin);
    await settleEvents();

    expect(channel.state, PhoenixChannelState.closed);
    expect(socket.removals, 1);
    expect(socket.sentMessages, hasLength(2));
    expect((await channel.leave().future).isOk, isTrue);
    expect(channel.state, PhoenixChannelState.closed);
  });

  test('close settles a pending leave without restarting the canceled join',
      () async {
    final join = channel.join();
    final joinResult =
        expectLater(join.future, throwsA(isA<ChannelClosedError>()));
    final leave = channel.leave();
    final leaveResult =
        expectLater(leave.future, throwsA(isA<ChannelClosedError>()));
    channel.close();
    await Future.wait([joinResult, leaveResult]);
    expect(channel.state, PhoenixChannelState.closed);
    expect(socket.sentMessages, hasLength(2));
  });

  test('leave while disconnected still closes the channel', () async {
    socket.connected = false;
    final join = channel.join();
    final joinResult =
        expectLater(join.future, throwsA(isA<ChannelClosedError>()));
    expect((await channel.leave().future).isOk, isTrue);
    await joinResult;
    expect(channel.state, PhoenixChannelState.closed);
    expect(socket.removals, 1);
  });

  test('successful leave settles other outstanding requests', () async {
    socket.onSend = (message) {
      if (message.event == PhoenixChannelEvent.join ||
          message.event == PhoenixChannelEvent.leave) {
        socket.reply(message);
      }
    };
    await channel.join().future;
    final push = channel.push('request', {}, expectingReply: true);
    final result = expectLater(push.future, throwsA(isA<ChannelClosedError>()));
    expect((await channel.leave().future).isOk, isTrue);
    await result;
    expect(channel.state, PhoenixChannelState.closed);
    expect(socket.removals, 1);
  });

  test('closing a rejected join cancels automatic retries', () async {
    socket.onSend = (message) {
      if (message.event == PhoenixChannelEvent.join) {
        socket.reply(message, 'error');
      }
    };
    await channel.join().future;
    channel.close();
    await Future<void>.delayed(socket.defaultTimeout * 3);
    expect(socket.sentMessages, hasLength(1));
    expect(channel.state, PhoenixChannelState.closed);
  });

  test('buffering retains fire-and-forget mode', () async {
    acceptJoins();
    final join = channel.join();
    final push = channel.push('broadcast', {}, expectingReply: false);
    var timeouts = 0;
    push.onReply('timeout', (_) => timeouts++);
    await join.future;
    await Future<void>.delayed(socket.defaultTimeout * 3);
    expect(push.sent, isTrue);
    expect(timeouts, 0);
    expect(socket.transportWaiters, 0);
    expect(socket.sentMessages.map((message) => message.event.value),
        ['phx_join', 'broadcast']);
  });

  test('custom events beginning with phx_reply reach the message stream',
      () async {
    final messages = <Message>[];
    final subscription = channel.messages.listen(messages.add);
    addTearDown(subscription.cancel);
    channel.trigger(
        Message(event: PhoenixChannelEvent.custom('phx_reply_custom')));
    channel
        .trigger(Message(event: PhoenixChannelEvent.custom('ordinary_custom')));
    await settleEvents();
    expect(messages.map((message) => message.event.value),
        ['phx_reply_custom', 'ordinary_custom']);
  });
}
