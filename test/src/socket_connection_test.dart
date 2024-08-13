import 'dart:async';

import 'package:mockito/mockito.dart';
import 'package:phoenix_socket/src/socket_connection.dart';
import 'package:test/test.dart';

import '../mocks.mocks.dart';

void main() {
  group('$SocketConnectionManager', () {
    late MockOnMessage mockOnMessage;
    late MockOnError mockOnError;
    late MockOnStateChange mockOnStateChange;
    late MockWebSocketSink mockWebSocketSink;
    late MockWebSocketChannel mockChannel;
    late StreamController<String> channelController;
    late Completer<void> readyCompleter;

    setUp(() {
      mockOnMessage = MockOnMessage();
      mockOnError = MockOnError();
      mockOnStateChange = MockOnStateChange();
      mockWebSocketSink = MockWebSocketSink();
      mockChannel = MockWebSocketChannel();
      readyCompleter = Completer();
      channelController = StreamController<String>();

      when(mockChannel.ready).thenAnswer((_) => readyCompleter.future);
      when(mockChannel.sink).thenReturn(mockWebSocketSink);
      when(mockWebSocketSink.done).thenAnswer((_) => Completer().future);
      when(mockChannel.stream).thenAnswer((_) => channelController.stream);
    });

    test('start() - happy path', () async {
      SocketConnectionManager connectionManager = SocketConnectionManager(
        factory: () => Future.value(mockChannel),
        reconnectDelays: [Duration.zero],
        onMessage: mockOnMessage.call,
        onStateChange: mockOnStateChange.call,
        onError: mockOnError.call,
      );

      // No interactions in constructor.
      verifyZeroInteractions(mockChannel);

      connectionManager.start();
      await Future.delayed(Duration.zero);

      verify(mockChannel.ready).called(1);
      verify(
        mockOnStateChange.call(argThat(isA<WebSocketInitializing>())),
      ).called(1);
      verifyNoMoreInteractions(mockOnStateChange);

      readyCompleter.complete();
      await Future.delayed(Duration.zero);

      verify(
        mockOnStateChange.call(argThat(isA<WebSocketReady>())),
      ).called(1);
      verifyNoMoreInteractions(mockOnStateChange);

      // Clear expectations on these calls before proceeding.
      verify(mockChannel.sink);
      verify(mockChannel.stream);

      // Calling start again will not establish a new connection.
      connectionManager.start();
      await Future.delayed(Duration.zero);

      verifyNoMoreInteractions(mockChannel);
      verifyNoMoreInteractions(mockOnStateChange);
      verifyZeroInteractions(mockOnError);
      verifyZeroInteractions(mockOnMessage);
    });

    test('start() - reconnection after failure', () async {
      SocketConnectionManager connectionManager = SocketConnectionManager(
        factory: () => Future.value(mockChannel),
        reconnectDelays: [Duration.zero],
        onMessage: mockOnMessage.call,
        onStateChange: mockOnStateChange.call,
        onError: mockOnError.call,
      );

      verifyZeroInteractions(mockChannel);

      connectionManager.start();
      await Future.delayed(Duration.zero);

      verify(mockChannel.ready).called(1);
      verify(
        mockOnStateChange.call(argThat(isA<WebSocketInitializing>())),
      ).called(1);
      verifyNoMoreInteractions(mockOnStateChange);
      verifyZeroInteractions(mockOnError);
      verifyZeroInteractions(mockOnMessage);

      final cause = Object();
      final stackTrace = StackTrace.current;
      readyCompleter.completeError(cause, stackTrace);
      await Future.delayed(Duration.zero);

      verify(
        mockOnError(
            argThat(isA<ConnectionInitializationException>()
                .having((exception) => exception.cause, 'cause', cause)
                .having(
                  (exception) => exception.stackTrace,
                  'stackTrace',
                  stackTrace,
                )),
            any),
      ).called(1);
      verifyNoMoreInteractions(mockOnError);
      verifyNoMoreInteractions(mockOnStateChange);

      readyCompleter = Completer<void>();
      await Future.delayed(Duration.zero);
      verify(
        mockOnStateChange.call(argThat(isA<WebSocketInitializing>())),
      ).called(1);
      verifyNoMoreInteractions(mockOnStateChange);

      readyCompleter.complete();
      await Future.delayed(Duration.zero);
      verify(
        mockOnStateChange.call(argThat(isA<WebSocketReady>())),
      ).called(1);
      verifyNoMoreInteractions(mockOnError);
      verifyNoMoreInteractions(mockOnStateChange);
      verifyZeroInteractions(mockOnMessage);
    });

    test('start() - multiple attempts - happy path', () async {
      SocketConnectionManager connectionManager = SocketConnectionManager(
        factory: () => Future.value(mockChannel),
        reconnectDelays: [Duration.zero],
        onMessage: mockOnMessage.call,
        onStateChange: mockOnStateChange.call,
        onError: mockOnError.call,
      );

      verifyZeroInteractions(mockChannel);

      // .start() called twice synchronously.
      connectionManager.start();
      connectionManager.start();
      await Future.delayed(Duration.zero);

      verify(mockChannel.ready).called(1);
      verify(
        mockOnStateChange.call(argThat(isA<WebSocketInitializing>())),
      ).called(1);
      verifyNoMoreInteractions(mockOnStateChange);

      // .start() called during initialization.
      connectionManager.start();
      await Future.delayed(Duration.zero);
      verifyNoMoreInteractions(mockOnStateChange);
      verifyNever(mockChannel.ready);

      readyCompleter.complete();
      await Future.delayed(Duration.zero);
      verify(
        mockOnStateChange.call(argThat(isA<WebSocketReady>())),
      ).called(1);
      verifyNoMoreInteractions(mockOnStateChange);

      verifyZeroInteractions(mockOnError);
      verifyZeroInteractions(mockOnMessage);
    });

    test('start() - multiple attempts - connection problems', () async {
      SocketConnectionManager connectionManager = SocketConnectionManager(
        factory: () => Future.value(mockChannel),
        reconnectDelays: [Duration.zero],
        onMessage: mockOnMessage.call,
        onStateChange: mockOnStateChange.call,
        onError: mockOnError.call,
      );
      verifyZeroInteractions(mockChannel);

      // .start() called twice synchronously.
      connectionManager.start();
      connectionManager.start();
      await Future.delayed(Duration.zero);

      verify(mockChannel.ready).called(1);
      verify(
        mockOnStateChange.call(argThat(isA<WebSocketInitializing>())),
      ).called(1);
      verifyNoMoreInteractions(mockOnStateChange);

      // .start() called during initialization.
      connectionManager.start();
      await Future.delayed(Duration.zero);
      verifyNoMoreInteractions(mockOnStateChange);
      verifyNever(mockChannel.ready);

      readyCompleter.completeError(Object());
      await Future.delayed(Duration.zero);
      verifyNoMoreInteractions(mockOnStateChange);
      verify(mockOnError.call(any, any)).called(1);
      verifyNoMoreInteractions(mockOnError);

      readyCompleter = Completer()..complete();
      await Future.delayed(Duration.zero);
      verifyInOrder([
        mockOnStateChange.call(argThat(isA<WebSocketInitializing>())),
        mockOnStateChange.call(argThat(isA<WebSocketReady>())),
      ]);
      verifyNoMoreInteractions(mockOnStateChange);

      verifyNoMoreInteractions(mockOnError);
      verifyZeroInteractions(mockOnMessage);
    });

    test('emits WebSocketClosing state when WebSocketChannel\'s done completes',
        () async {
      final doneCompleter = Completer<void>();
      when(mockWebSocketSink.done).thenAnswer((_) => doneCompleter.future);

      SocketConnectionManager connectionManager = SocketConnectionManager(
        factory: () => Future.value(mockChannel),
        reconnectDelays: [Duration.zero],
        onMessage: mockOnMessage.call,
        onStateChange: mockOnStateChange.call,
        onError: mockOnError.call,
      );
      verifyZeroInteractions(mockChannel);

      // .start() called twice synchronously.
      connectionManager.start();
      readyCompleter.complete();
      await Future.delayed(Duration.zero);

      verify(mockChannel.ready).called(1);
      verifyInOrder([
        mockOnStateChange.call(argThat(isA<WebSocketInitializing>())),
        mockOnStateChange.call(argThat(isA<WebSocketReady>())),
      ]);
      verifyNoMoreInteractions(mockOnStateChange);

      doneCompleter.complete();
      await Future.delayed(Duration.zero);

      verify(
        mockOnStateChange.call(argThat(isA<WebSocketClosing>())),
      ).called(1);

      verifyNoMoreInteractions(mockOnStateChange);

      verifyZeroInteractions(mockOnError);
      verifyZeroInteractions(mockOnMessage);
    });

    test('emits WebSocketClosed state when WebSocketChannel\'s stream closes',
        () async {
      SocketConnectionManager connectionManager = SocketConnectionManager(
        factory: () => Future.value(mockChannel),
        reconnectDelays: [Duration.zero],
        onMessage: mockOnMessage.call,
        onStateChange: mockOnStateChange.call,
        onError: mockOnError.call,
      );
      verifyZeroInteractions(mockChannel);

      connectionManager.start();
      readyCompleter.complete();
      await Future.delayed(Duration.zero);

      verify(mockChannel.ready).called(1);
      verifyInOrder([
        mockOnStateChange.call(argThat(isA<WebSocketInitializing>())),
        mockOnStateChange.call(argThat(isA<WebSocketReady>())),
      ]);
      verifyNoMoreInteractions(mockOnStateChange);

      channelController.close();
      await Future.delayed(Duration.zero);

      verify(
        mockOnStateChange.call(argThat(isA<WebSocketClosed>())),
      ).called(1);

      verifyNoMoreInteractions(mockOnStateChange);

      verifyZeroInteractions(mockOnError);
      verifyZeroInteractions(mockOnMessage);
    });

    test('calls onError callback when WebSocketChannel\'s stream emits error',
        () async {
      SocketConnectionManager connectionManager = SocketConnectionManager(
        factory: () => Future.value(mockChannel),
        reconnectDelays: [Duration.zero],
        onMessage: mockOnMessage.call,
        onStateChange: mockOnStateChange.call,
        onError: mockOnError.call,
      );
      verifyZeroInteractions(mockChannel);

      connectionManager.start();
      readyCompleter.complete();
      await Future.delayed(Duration.zero);

      verify(mockChannel.ready).called(1);
      verifyInOrder([
        mockOnStateChange.call(argThat(isA<WebSocketInitializing>())),
        mockOnStateChange.call(argThat(isA<WebSocketReady>())),
      ]);
      verifyNoMoreInteractions(mockOnStateChange);
      verifyZeroInteractions(mockOnError);

      final error = Object();
      channelController.addError(error);
      await Future.delayed(Duration.zero);
      verify(mockOnError.call(error, any)).called(1);
      verifyNoMoreInteractions(mockOnError);

      verifyNoMoreInteractions(mockOnStateChange);
      verifyZeroInteractions(mockOnMessage);
    });

    test('start(immediatelly: true) executes connection attempt without delay',
        () async {
      SocketConnectionManager connectionManager = SocketConnectionManager(
        factory: () => Future.value(mockChannel),
        reconnectDelays: [const Duration(days: 1)],
        onMessage: mockOnMessage.call,
        onStateChange: mockOnStateChange.call,
        onError: mockOnError.call,
      );

      readyCompleter.complete(); // don't delay.
      connectionManager.start(immediately: false);
      await Future.delayed(Duration.zero);

      verifyZeroInteractions(mockChannel);
      verifyZeroInteractions(mockOnStateChange);

      connectionManager.start(immediately: true);
      await Future.delayed(Duration.zero);

      verify(mockChannel.ready).called(1);
      verifyInOrder([
        mockOnStateChange.call(argThat(isA<WebSocketInitializing>())),
        mockOnStateChange.call(argThat(isA<WebSocketReady>())),
      ]);
      verifyNoMoreInteractions(mockOnStateChange);

      verifyZeroInteractions(mockOnError);
      verifyZeroInteractions(mockOnMessage);
    });
  });
}
