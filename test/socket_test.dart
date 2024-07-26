import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:mockito/mockito.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:rxdart/rxdart.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'mocks.dart';

void main() {
  test('socket connect retries on unexpected error', () async {
    final sink = MockWebSocketSink();
    final websocket = MockWebSocketChannel();
    final phoenixSocket = PhoenixSocket(
      'endpoint',
      socketOptions: PhoenixSocketOptions(params: {'token': 'token'}),
      webSocketChannelFactory: (_) => websocket,
    );
    int invocations = 0;
    final exceptions = ['E', PhoenixException()];

    when(websocket.sink).thenReturn(sink);

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
    await phoenixSocket.connect();
    expect(phoenixSocket.isConnected, isTrue);

    // Expect the first two unexpected failures to be retried
    verify(sink.add(any)).called(3);
  });

  test('socket connect does not create new socket if one is already connected',
      () async {
    final optionsCompleter = Completer<Map<String, String>>();
    final mockPhoenixSocketOptions = MockPhoenixSocketOptions();
    when(mockPhoenixSocketOptions.getParams())
        .thenAnswer((_) => optionsCompleter.future);
    when(mockPhoenixSocketOptions.heartbeat).thenReturn(Duration(days: 1));

    final sentRefs = <String>[];
    when(mockPhoenixSocketOptions.serializer).thenReturn(MessageSerializer(
      encoder: (object) {
        if (object is List) {
          final message = Message.fromJson(object);
          sentRefs.add(message.ref!);
          return message.ref!;
        }
        return 'ignored';
      },
      decoder: (ref) => Message.heartbeat(ref).encode(),
    ));

    int factoryCalls = 0;
    WebSocketChannel stubWebSocketChannelFactory(Uri uri) {
      ++factoryCalls;
      final mockWebSocketChannel = MockWebSocketChannel();
      when(mockWebSocketChannel.stream).thenAnswer((_) => NeverStream());
      when(mockWebSocketChannel.ready)
          .thenAnswer((_) => Future.sync(() => null));
      when(mockWebSocketChannel.sink).thenReturn(MockWebSocketSink());
      return mockWebSocketChannel;
    }

    final phoenixSocket = PhoenixSocket(
      'ws://endpoint',
      webSocketChannelFactory: stubWebSocketChannelFactory,
      socketOptions: mockPhoenixSocketOptions,
    );

    // Connect to the socket
    final connectFutures = [
      phoenixSocket.connect(),
      phoenixSocket.connect(),
      phoenixSocket.connect(),
    ];

    expect(factoryCalls, 0);

    optionsCompleter.complete({'token': 'fakeUserToken'});

    await Future.delayed(Duration.zero);

    for (final ref in sentRefs) {
      phoenixSocket.onSocketDataCallback(ref);
    }

    await Future.wait(connectFutures);

    expect(factoryCalls, 1);
  });

  test(
    'socket connect keeps retrying if an exception is thrown while building the mount point',
    () {
      final mockPhoenixSocketOptions = MockPhoenixSocketOptions();
      when(mockPhoenixSocketOptions.reconnectDelays).thenReturn(const [
        Duration.zero,
        Duration(seconds: 10),
        Duration(seconds: 20),
        Duration(seconds: 30),
      ]);
      when(mockPhoenixSocketOptions.getParams()).thenThrow(Exception());

      final phoenixSocket = PhoenixSocket(
        'ws://endpoint',
        socketOptions: mockPhoenixSocketOptions,
      );

      fakeAsync(
        (async) {
          phoenixSocket.connect();

          verify(mockPhoenixSocketOptions.getParams()).called(1);
          expect(phoenixSocket.isConnected, isFalse);

          // first retry after ~10 seconds
          async.elapse(const Duration(seconds: 11));
          verify(mockPhoenixSocketOptions.getParams()).called(1);
          expect(phoenixSocket.isConnected, isFalse);

          // second retry after ~20 seconds
          async.elapse(const Duration(seconds: 21));
          verify(mockPhoenixSocketOptions.getParams()).called(1);
          expect(phoenixSocket.isConnected, isFalse);

          // third retry after ~30 seconds
          async.elapse(const Duration(seconds: 31));
          verify(mockPhoenixSocketOptions.getParams()).called(1);
          expect(phoenixSocket.isConnected, isFalse);

          // fourth retry after ~30 seconds (the last reconnect delay is repeated from now on)
          async.elapse(const Duration(seconds: 31));
          verify(mockPhoenixSocketOptions.getParams()).called(1);
          expect(phoenixSocket.isConnected, isFalse);
        },
      );
    },
  );
}
