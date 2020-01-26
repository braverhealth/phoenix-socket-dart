import 'package:test/test.dart';

import 'package:phoenix_socket/phoenix_socket.dart';

void main() {
  var addr = 'ws://localhost:4001/socket/websocket';

  group('PhoenixChannel', () {
    test('can join a channel through a socket', () async {
      final socket = PhoenixSocket(addr);

      await socket.connect();
      var reply =
          await socket.addChannel(topic: 'channel1').join().onReply('ok');
      expect(reply.status, equals('ok'));
    });

    test('can join a channel requiring parameters', () async {
      final socket = PhoenixSocket(addr);

      await socket.connect();

      var channel1 = socket.addChannel(
          topic: 'channel1:hello', parameters: {'password': 'deadbeef'});

      expect(channel1.join().future, completes);
    });

    test('can handle channel join failures', () async {
      final socket = PhoenixSocket(addr);

      await socket.connect();

      var channel1 = socket.addChannel(
          topic: 'channel1:hello', parameters: {'password': 'deadbee?'});

      final error = await channel1.join().onReply('error');
      expect(error.status, equals('error'));
    });

    test('can handle channel crash on join', () async {
      final socket = PhoenixSocket(addr);

      await socket.connect();

      var channel1 = socket
          .addChannel(topic: 'channel1:hello', parameters: {'crash!': '11'});

      final error = await channel1.join().onReply('error');
      expect(error.status, equals('error'));
      expect(error.response, equals({'reason': 'join crashed'}));
    });

    test('can send messages to channels and receive a reply', () async {
      final socket = PhoenixSocket(addr);

      await socket.connect();

      var channel1 = socket.addChannel(topic: 'channel1');
      await channel1.join().future;

      var reply = await channel1.push('hello!', {'foo': 'bar'}).future;
      expect(reply.status, equals('ok'));
      expect(reply.response, equals({'name': 'bar'}));
    });

    test('can receive messages from channels', () async {
      final socket = PhoenixSocket(addr);

      await socket.connect();

      var channel2 = socket.addChannel(topic: 'channel2');
      await channel2.join().future;

      var count = 0;
      await for (var msg in channel2.messages) {
        expect(msg.event, equals('ping'));
        expect(msg.payload, equals({}));
        if (++count == 5) break;
      }
    });

    test('can send and receive messages from multiple channels', () async {
      final socket1 = PhoenixSocket(addr);
      await socket1.connect();
      var channel1 = socket1.addChannel(topic: 'channel3');
      await channel1.join().future;

      final socket2 = PhoenixSocket(addr);
      await socket2.connect();
      var channel2 = socket2.addChannel(topic: 'channel3');
      await channel2.join().future;

      expect(
        channel1.messages,
        emitsInOrder([
          predicate(
            (Message msg) => msg.payload['from'] == 'socket1',
            'was from socket1',
          ),
          predicate(
            (Message msg) => msg.payload['from'] == 'socket2',
            'was from socket2',
          ),
          predicate(
            (Message msg) => msg.payload['from'] == 'socket2',
            'was from socket2',
          ),
        ]),
      );

      expect(
        channel2.messages,
        emitsInOrder([
          predicate(
            (Message msg) => msg.payload['from'] == 'socket1',
            'was from socket1',
          ),
          predicate(
            (Message msg) => msg.payload['from'] == 'socket2',
            'was from socket2',
          ),
          predicate(
            (Message msg) => msg.payload['from'] == 'socket2',
            'was from socket2',
          ),
        ]),
      );

      channel1.push('ping', {'from': 'socket1'});
      channel2.push('ping', {'from': 'socket2'});
      channel2.push('ping', {'from': 'socket2'});
    });
  });
}
