import 'dart:async';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

import 'helpers/logging.dart';
import 'helpers/proxy.dart';

Set<int> usedPorts = {};

void main() {
  group('PhoenixChannel', () {
    const addr = 'ws://localhost:4004/socket/websocket';

    setUpAll(() {
      maybeActivateAllLogLevels();
    });

    setUp(() async {
      await prepareProxy();
    });

    tearDown(() async {
      await destroyProxy();
    });

    test('can join a channel through a socket', () async {
      final socket = PhoenixSocket(addr);
      final completer = Completer<void>();

      await socket.connect();
      socket.addChannel(topic: 'channel1').join().onReply('ok', (reply) {
        expect(reply.status, equals('ok'));
        completer.complete();
      });

      await completer.future;
    });

    test('can join a channel through a socket that starts closed then connects',
        () async {
      await haltThenResumeProxy();

      final socket = PhoenixSocket(addr);
      final completer = Completer<void>();

      await socket.connect();

      socket.addChannel(topic: 'channel1').join().onReply('ok', (reply) {
        expect(reply.status, equals('ok'));
        completer.complete();
      });

      await completer.future;
    });

    test(
        'can join a channel through a socket that disconnects before join but reconnects',
        () async {
      final socket = PhoenixSocket(addr);
      final completer = Completer<void>();

      await socket.connect();

      await haltProxy();
      final joinFuture = socket.addChannel(topic: 'channel1').join();
      Future.delayed(const Duration(milliseconds: 300))
          .then((value) => resumeProxy());

      joinFuture.onReply('ok', (reply) {
        expect(reply.status, equals('ok'));
        completer.complete();
      });

      await completer.future;
    });

    test(
        'can join a channel through a socket that gets a "peer reset" before join but reconnects',
        () async {
      final socket = PhoenixSocket(addr);
      final completer = Completer<void>();

      await socket.connect();
      addTearDown(() {
        socket.close();
      });
      await resetPeer();

      runZonedGuarded(() {
        final joinFuture = socket.addChannel(topic: 'channel1').join();
        joinFuture.onReply('ok', (reply) {
          expect(reply.status, equals('ok'));
          completer.complete();
        });
      }, (error, stack) {});

      Future.delayed(const Duration(milliseconds: 1000))
          .then((value) => resetPeer(enable: false));

      await completer.future;
    });

    test('can join a channel through an unawaited socket', () async {
      final socket = PhoenixSocket(addr);
      final completer = Completer<void>();

      socket.connect();
      socket.addChannel(topic: 'channel1').join().onReply('ok', (reply) {
        expect(reply.status, equals('ok'));
        completer.complete();
      });

      await completer.future;
    });

    test('can join a channel requiring parameters', () async {
      final socket = PhoenixSocket(addr);

      await socket.connect();

      final channel1 = socket.addChannel(
          topic: 'channel1:hello', parameters: {'password': 'deadbeef'});

      expect(channel1.join().future, completes);
    });

    test('can handle channel join failures', () async {
      final socket = PhoenixSocket(addr);

      final completer = Completer<void>();

      await socket.connect();

      final channel1 = socket.addChannel(
          topic: 'channel1:hello', parameters: {'password': 'deadbee?'});

      channel1.join().onReply('error', (error) {
        expect(error.status, equals('error'));
        completer.complete();
      });

      await completer.future;
    });

    test('can handle channel crash on join', () async {
      final socket = PhoenixSocket(addr);
      final completer = Completer<void>();

      await socket.connect();

      final channel1 = socket
          .addChannel(topic: 'channel1:hello', parameters: {'crash!': '11'});

      channel1.join().onReply('error', (error) {
        expect(error.status, equals('error'));
        expect(error.response, equals({'reason': 'join crashed'}));
        completer.complete();
      });

      await completer.future;
    });

    test('can send messages to channels and receive a reply', () async {
      final socket = PhoenixSocket(addr);

      await socket.connect();

      final channel1 = socket.addChannel(topic: 'channel1');
      await channel1.join().future;

      final reply = await channel1.push('hello!', {'foo': 'bar'}).future;
      expect(reply.status, equals('ok'));
      expect(reply.response, equals({'name': 'bar'}));
    });

    test(
        'can send messages to channels that got transiently '
        'disconnected and receive a reply', () async {
      final socket = PhoenixSocket(addr);

      await socket.connect();

      final channel1 = socket.addChannel(topic: 'channel1');
      await channel1.join().future;

      await haltThenResumeProxy();
      await socket.openStream.first;

      final reply = await channel1.push('hello!', {'foo': 'bar'}).future;
      expect(reply.status, equals('ok'));
      expect(reply.response, equals({'name': 'bar'}));
    });

    test(
        'can send messages to channels that got "peer reset" '
        'and receive a reply', () async {
      final socket = PhoenixSocket(addr);

      await socket.connect();

      final channel1 = socket.addChannel(topic: 'channel1');
      await channel1.join().future;

      await resetPeerThenResumeProxy();

      final push = channel1.push('hello!', {'foo': 'bar'});
      final reply = await push.future;

      expect(reply.status, equals('ok'));
      expect(reply.response, equals({'name': 'bar'}));
    });

    test(
        'throws when sending messages to channels that got "peer reset" '
        'and that have not recovered yet', () async {
      final socket = PhoenixSocket(addr);

      await socket.connect();

      final channel1 = socket.addChannel(topic: 'channel1');
      await channel1.join().future;

      await resetPeer();

      final Completer<Object> errorCompleter = Completer();

      runZonedGuarded(() async {
        final push = channel1.push('hello!', {'foo': 'bar'});
        try {
          await push.future;
        } catch (err) {
          errorCompleter.complete(err);
        }
      }, (error, stack) {});

      final Object exception;
      expect(exception = await errorCompleter.future, isA<PhoenixException>());
      expect((exception as PhoenixException).socketClosed, isNotNull);
    });

    test(
      'throws when sending messages to channels that got disconnected '
      'and that have not recovered yet',
      () async {
        final socket = PhoenixSocket(addr);

        await socket.connect();

        final channel1 = socket.addChannel(topic: 'channel1');
        await channel1.join().future;

        await haltProxy();

        final Completer<Object> errorCompleter = Completer();
        runZonedGuarded(() async {
          try {
            final push = channel1.push('hello!', {'foo': 'bar'});
            await push.future;
          } catch (err) {
            errorCompleter.complete(err);
          }
        }, (error, stack) {});

        expect(await errorCompleter.future, isA<ChannelClosedError>());
      },
      timeout: Timeout(
        Duration(seconds: 5),
      ),
    );

    test('only emits reply messages that are channel replies', () async {
      final socket = PhoenixSocket(addr);

      socket.connect();

      final channel1 = socket.addChannel(topic: 'channel1');
      final channelMessages = [];
      channel1.messages.forEach((element) => channelMessages.add(element));

      await channel1.join().future;
      await channel1.push('hello!', {'foo': 'bar'}).future;

      expect(channelMessages, hasLength(2));
    });

    test('can receive messages from channels', () async {
      final socket = PhoenixSocket(addr);

      await socket.connect();

      final channel2 = socket.addChannel(topic: 'channel2');
      await channel2.join().future;

      var count = 0;
      await for (final msg in channel2.messages) {
        expect(msg.event.value, equals('ping'));
        expect(msg.payload, equals({}));
        if (++count == 5) break;
      }
    });

    test('can send and receive messages from multiple channels', () async {
      final socket1 = PhoenixSocket(addr);
      await socket1.connect();
      final channel1 = socket1.addChannel(topic: 'channel3');
      await channel1.join().future;

      final socket2 = PhoenixSocket(addr);
      await socket2.connect();
      final channel2 = socket2.addChannel(topic: 'channel3');
      await channel2.join().future;

      addTearDown(() {
        socket1.close();
        socket2.close();
      });

      expect(
        channel1.messages,
        emitsInOrder([
          predicate(
            (dynamic msg) => msg.payload['from'] == 'socket1',
            'was from socket1',
          ),
          predicate(
            (dynamic msg) => msg.payload['from'] == 'socket2',
            'was from socket2',
          ),
          predicate(
            (dynamic msg) => msg.payload['from'] == 'socket2',
            'was from socket2',
          ),
        ]),
      );

      expect(
        channel2.messages,
        emitsInOrder([
          predicate(
            (dynamic msg) => msg.payload['from'] == 'socket1',
            'was from socket1',
          ),
          predicate(
            (dynamic msg) => msg.payload['from'] == 'socket2',
            'was from socket2',
          ),
          predicate(
            (dynamic msg) => msg.payload['from'] == 'socket2',
            'was from socket2',
          ),
        ]),
      );

      channel1.push('ping', {'from': 'socket1'});
      await Future.delayed(Duration(milliseconds: 50));
      channel2.push('ping', {'from': 'socket2'});
      await Future.delayed(Duration(milliseconds: 50));
      channel2.push('ping', {'from': 'socket2'});
    });

    test('closes successfully', () async {
      final socket1 = PhoenixSocket(addr);
      await socket1.connect();
      final channel1 = socket1.addChannel(topic: 'channel3');
      await channel1.join().future;

      final socket2 = PhoenixSocket(addr);
      await socket2.connect();
      final channel2 = socket2.addChannel(topic: 'channel3');
      await channel2.join().future;

      addTearDown(() {
        socket1.close();
        socket2.close();
      });

      channel1.push('ping', {'from': 'socket1'});

      expect(
        channel2.messages,
        emits(
          predicate(
            (dynamic msg) => msg.payload['from'] == 'socket1',
            'was from socket1',
          ),
        ),
      );

      await channel1.leave().future;

      expect(channel1.state, equals(PhoenixChannelState.closed));
      expect(socket1.channels.length, equals(0));
    });

    test('can join another channel after closing a previous one', () async {
      final socket1 = PhoenixSocket(addr);
      await socket1.connect();
      final channel1 = socket1.addChannel(topic: 'channel3');
      await channel1.join().future;

      final socket2 = PhoenixSocket(addr);
      await socket2.connect();
      final channel2 = socket2.addChannel(topic: 'channel3');
      await channel2.join().future;

      addTearDown(() {
        socket1.close();
        socket2.close();
      });

      channel1.push('ping', {'from': 'socket1'});

      expect(
        channel2.messages,
        emits(
          predicate(
            (dynamic msg) => msg.payload['from'] == 'socket1',
            'was from socket1',
          ),
        ),
      );

      await channel1.leave().future;

      expect(channel1.state, equals(PhoenixChannelState.closed));
      expect(socket1.channels.length, equals(0));

      final channel3 = socket1.addChannel(topic: 'channel3');
      await channel3.join().future;

      channel3.push('ping', {'from': 'socket1'});

      expect(
        channel2.messages,
        emits(
          predicate(
            (dynamic msg) => msg.payload['from'] == 'socket1',
            'was from socket1',
          ),
        ),
      );
    });

    test('Pushing message on a closed channel throws exception', () async {
      final socket = PhoenixSocket(addr);
      await socket.connect();
      final channel = socket.addChannel(topic: 'channel3');

      await channel.join().future;
      await channel.leave().future;

      expect(
        () => channel.push('EventName', {}),
        throwsA(isA<ChannelClosedError>()),
      );
    });

    test('timeout on send message will throw', () async {
      final socket = PhoenixSocket(addr);
      await socket.connect();
      final channel = socket.addChannel(topic: 'channel1');
      await channel.join().future;

      final push = channel.push('hello!', {'foo': 'bar'}, Duration.zero);

      expect(
        push.future,
        throwsA(isA<ChannelTimeoutException>()),
      );
    });
  });
}
