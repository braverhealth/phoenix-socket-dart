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
    int invocations = 0;
    final exceptions = ['E', PhoenixException()];
    final sinkCompleters = [
      Completer<void>(),
      Completer<void>(),
      Completer<void>(),
    ];
    final streamControllers = [
      StreamController<String>(),
      StreamController<String>(),
      StreamController<String>(),
    ];

    // This code might throw asynchronous errors, prevent the test from failing
    // if these are expected ones (as defined in `exceptions`).
    await runZonedGuarded(
      () async {
        final websocket = MockWebSocketChannel();
        final phoenixSocket = PhoenixSocket(
          'endpoint',
          socketOptions: PhoenixSocketOptions(
            params: {'token': 'token'},
            reconnectDelays: [Duration.zero],
          ),
          webSocketChannelFactory: (_) => websocket,
        );

        when(websocket.sink).thenAnswer((_) {
          final sink = MockWebSocketSink();
          final doneCompleter = sinkCompleters[invocations];
          when(sink.done).thenAnswer((_) => doneCompleter.future);
          when(sink.add(any)).thenAnswer((_) {
            // Throw an error adding data to the sink on the first two attempts.
            // On the third attempt, the sink add should work as expected.
            if (invocations < 2) {
              doneCompleter.complete();
              streamControllers[invocations].close();
              throw exceptions[invocations++];
            }
            streamControllers[invocations]
                .add(jsonEncode(Message.heartbeat('$invocations').encode()));
          });
          return sink;
        });
        when(websocket.ready).thenAnswer((_) => Future.value());

        when(websocket.stream)
            .thenAnswer((_) => streamControllers[invocations].stream);

        // Connect to the socket
        await phoenixSocket.connect();

        expect(phoenixSocket.isOpen, isTrue);
        expect(invocations, 2);
      },
      (error, stackTrace) {
        if (!exceptions.contains(error)) {
          throw Exception('Unexepcted exception: $error');
        }
      },
    );
  });

  test('socket connect does not create new socket if one is already connected',
      () async {
    final optionsCompleter = Completer<Map<String, String>>();

    final sentRefs = <String>[];

    PhoenixSocketOptions socketOptions = PhoenixSocketOptions(
        dynamicParams: () => optionsCompleter.future,
        heartbeat: Duration(days: 1),
        reconnectDelays: [Duration.zero],
        serializer: MessageSerializer(
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
      final mockWebSocketSink = MockWebSocketSink();
      when(mockWebSocketChannel.stream).thenAnswer((_) => NeverStream());
      when(mockWebSocketChannel.ready).thenAnswer((_) => Future.value());
      when(mockWebSocketChannel.sink).thenReturn(mockWebSocketSink);
      when(mockWebSocketSink.done).thenAnswer((_) => Completer<void>().future);
      return mockWebSocketChannel;
    }

    final phoenixSocket = PhoenixSocket(
      'ws://endpoint',
      webSocketChannelFactory: stubWebSocketChannelFactory,
      socketOptions: socketOptions,
    );

    // Connect to the socket
    final connectFutures = [
      phoenixSocket.connect(),
      phoenixSocket.connect(),
      phoenixSocket.connect(),
    ];

    expect(factoryCalls, 0);

    optionsCompleter.complete({'token': 'fakeUserToken'});

    // First skip options retrieval
    await Future.delayed(Duration.zero);
    // Then skip initialization delay
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

          async.elapse(Duration.zero);

          verify(mockPhoenixSocketOptions.getParams()).called(1);
          expect(phoenixSocket.isOpen, isFalse);

          // first retry after ~10 seconds
          async.elapse(const Duration(seconds: 11));
          verify(mockPhoenixSocketOptions.getParams()).called(1);
          expect(phoenixSocket.isOpen, isFalse);

          // second retry after ~20 seconds
          async.elapse(const Duration(seconds: 21));
          verify(mockPhoenixSocketOptions.getParams()).called(1);
          expect(phoenixSocket.isOpen, isFalse);

          // third retry after ~30 seconds
          async.elapse(const Duration(seconds: 31));
          verify(mockPhoenixSocketOptions.getParams()).called(1);
          expect(phoenixSocket.isOpen, isFalse);

          // fourth retry after ~30 seconds (the last reconnect delay is repeated from now on)
          async.elapse(const Duration(seconds: 31));
          verify(mockPhoenixSocketOptions.getParams()).called(1);
          expect(phoenixSocket.isOpen, isFalse);
        },
      );
    },
  );
}
