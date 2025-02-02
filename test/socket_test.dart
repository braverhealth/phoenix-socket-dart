import 'dart:async';
import 'dart:convert';

import 'package:mockito/mockito.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:rxdart/rxdart.dart';
import 'package:test/test.dart';

import 'mocks.dart';

void main() {
  test('socket connect retries on unexpected error', () async {
    final sink = MockWebSocketSink();
    final websocket = MockWebSocketChannel();
    final phoenixSocket = PhoenixSocket(
      'endpoint',
      webSocketChannelFactory: (_) {
        return websocket;
      },
    );
    int invocations = 0;
    final exceptions = ['E', PhoenixException(message: '')];

    when(sink.close(any, any)).thenAnswer((_) async {});
    when(websocket.sink).thenReturn(sink);
    when(websocket.ready).thenAnswer((_) async {
      if (invocations < 2) {
        when(websocket.closeCode).thenReturn(1000);
        throw exceptions[invocations++];
      } else {
        when(websocket.closeCode).thenReturn(null);
      }
    });

    when(websocket.stream).thenAnswer((_) {
      if (invocations < 2) {
        // Return a never stream to keep the socket open on the first two
        // attempts. If it is an empty Stream the socket will close immediately.
        return NeverStream();
      } else {
        // Return a heartbeat on the third attempt which allows the socket
        // to connect.
        final controller = StreamController<String>()
          ..add(jsonEncode(Message.heartbeat('$invocations').encode()));
        return controller.stream;
      }
    });

    // Throw an error adding data to the sink on the first two attempts.
    // On the third attempt, the sink add should work as expected.
    when(sink.add(any)).thenAnswer((_) {
      if (invocations < 2) {
        throw exceptions[invocations++];
      }
    });

    // Connect to the socket
    final connectionFuture = phoenixSocket.connect();

    await connectionFuture;
    expect(phoenixSocket.isConnected, isTrue);

    // Expect the first two unexpected failures to be retried
    verify(websocket.ready).called(3);
  });
}
