import 'dart:async';

import 'package:test/test.dart';

import 'package:phoenix_socket/phoenix_socket.dart';

void main() {
  group('PhoenixSocket', () {
    test('can connect to a running Phoenix server', () async {
      final socket = PhoenixSocket("ws://localhost:4000/socket/websocket");

      await socket.connect().then((_) {
        expect(socket.isConnected, isTrue);
      });
    });

    test('can connect to a running Phoenix server with params', () async {
      final socket = PhoenixSocket(
        "ws://localhost:4000/socket/websocket",
        socketOptions: PhoenixSocketOptions(
          params: {'user_id': "this_is_a_userid"},
        ),
      );

      await socket.connect().then((_) {
        expect(socket.isConnected, isTrue);
      });
    });

    test('emits an "open" event', () async {
      final socket = PhoenixSocket("ws://localhost:4000/socket/websocket");

      socket.connect();

      await for (var event in socket.openStream) {
        expect(event, isA<OpenEvent>());
        socket.dispose();
      }
    });

    test('emits a "close" event after the connection was closed', () async {
      final completer = Completer();
      final socket = PhoenixSocket(
        "ws://localhost:4000/socket/websocket",
        socketOptions: PhoenixSocketOptions(
          params: {'user_id': "this_is_a_userid"},
        ),
      );

      await socket.connect().then((_) {
        Timer(Duration(milliseconds: 100), () {
          socket.dispose();
        });
      });

      socket.closeStream.listen((event) {
        expect(event, isA<CloseEvent>());
        completer.complete();
      });

      await completer.future;
    });
  });
}
