import 'dart:async';

import 'package:mockito/mockito.dart';
import 'package:phoenix_socket/src/socket_connection.dart';
import 'package:test/test.dart';

import '../mocks.mocks.dart';

typedef MockWebSocketChannelConfig = ({
  MockWebSocketChannel channel,
  StreamController<String> streamController,
  Completer<void> sinkDoneCompleter,
  Completer<void> readyCompleter,
});

void main() {
  group('$SocketConnectionManager', () {
    late MockOnMessage mockOnMessage;
    late MockOnError mockOnError;
    late MockOnStateChange mockOnStateChange;

    setUp(() {
      mockOnMessage = MockOnMessage();
      mockOnError = MockOnError();
      mockOnStateChange = MockOnStateChange();
    });

    MockWebSocketChannelConfig setUpChannelMock() {
      final mockSink = MockWebSocketSink();
      final streamController = StreamController<String>();
      final readyCompleter = Completer();
      final doneCompleter = Completer();
      final mockChannel = MockWebSocketChannel();

      when(mockChannel.ready).thenAnswer((_) => readyCompleter.future);
      when(mockChannel.sink).thenReturn(mockSink);
      when(mockChannel.stream).thenAnswer((_) => streamController.stream);
      when(mockSink.done).thenAnswer((_) => doneCompleter.future);

      return (
        channel: mockChannel,
        streamController: streamController,
        sinkDoneCompleter: doneCompleter,
        readyCompleter: readyCompleter,
      );
    }

    test('start() - happy path', () async {
      MockWebSocketChannelConfig mockChannelConfig = setUpChannelMock();
      SocketConnectionManager connectionManager = SocketConnectionManager(
        factory: () => Future.value(mockChannelConfig.channel),
        reconnectDelays: [Duration.zero],
        onMessage: mockOnMessage.call,
        onStateChange: mockOnStateChange.call,
        onError: mockOnError.call,
      );

      // No interactions in constructor.
      verifyZeroInteractions(mockChannelConfig.channel);

      connectionManager.start();
      await Future.delayed(Duration.zero);

      verify(mockChannelConfig.channel.ready).called(1);
      verify(
        mockOnStateChange.call(argThat(isA<WebSocketInitializing>())),
      ).called(1);
      verifyNoMoreInteractions(mockOnStateChange);

      mockChannelConfig.readyCompleter.complete();
      await Future.delayed(Duration.zero);

      verify(
        mockOnStateChange.call(argThat(isA<WebSocketReady>())),
      ).called(1);
      verifyNoMoreInteractions(mockOnStateChange);

      // Clear expectations on these calls before proceeding.
      verify(mockChannelConfig.channel.sink);
      verify(mockChannelConfig.channel.stream);

      // Calling start again will not establish a new connection.
      connectionManager.start();
      await Future.delayed(Duration.zero);

      verifyNoMoreInteractions(mockChannelConfig.channel);
      verifyNoMoreInteractions(mockOnStateChange);
      verifyZeroInteractions(mockOnError);
      verifyZeroInteractions(mockOnMessage);
    });

    test('start() - reconnection after failure', () async {
      int invocationCount = 0;
      final channelMocks = [
        setUpChannelMock(),
        setUpChannelMock(),
      ];

      SocketConnectionManager connectionManager = SocketConnectionManager(
        factory: () => Future.value(channelMocks[invocationCount++].channel),
        reconnectDelays: [Duration.zero],
        onMessage: mockOnMessage.call,
        onStateChange: mockOnStateChange.call,
        onError: mockOnError.call,
      );

      connectionManager.start();

      expect(invocationCount, 0);
      await Future.delayed(Duration.zero);
      expect(invocationCount, 1);

      verify(channelMocks[0].channel.ready).called(1);
      verify(
        mockOnStateChange.call(argThat(isA<WebSocketInitializing>())),
      ).called(1);
      verifyNoMoreInteractions(mockOnStateChange);
      verifyZeroInteractions(mockOnError);
      verifyZeroInteractions(mockOnMessage);

      final cause = Object();
      final stackTrace = StackTrace.current;
      channelMocks[0].readyCompleter.completeError(cause, stackTrace);
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
      verifyNever(channelMocks[0].channel.sink);
      verifyNever(channelMocks[0].channel.stream);
      verifyNoMoreInteractions(mockOnError);
      verifyNoMoreInteractions(mockOnStateChange);

      await Future.delayed(Duration.zero);
      expect(invocationCount, 2);

      verify(
        mockOnStateChange.call(argThat(isA<WebSocketInitializing>())),
      ).called(1);
      verifyNoMoreInteractions(mockOnStateChange);

      channelMocks[1].readyCompleter.complete();
      await Future.delayed(Duration.zero);
      verify(
        mockOnStateChange.call(argThat(isA<WebSocketReady>())),
      ).called(1);
      verifyNoMoreInteractions(mockOnError);
      verifyNoMoreInteractions(mockOnStateChange);
      verifyZeroInteractions(mockOnMessage);
    });

    test('start() - multiple attempts - happy path', () async {
      var invocationCount = 0;
      final channelMocks = setUpChannelMock();
      SocketConnectionManager connectionManager = SocketConnectionManager(
        factory: () {
          invocationCount++;
          return Future.value(channelMocks.channel);
        },
        reconnectDelays: [Duration.zero],
        onMessage: mockOnMessage.call,
        onStateChange: mockOnStateChange.call,
        onError: mockOnError.call,
      );

      // .start() called twice synchronously.
      connectionManager.start();
      connectionManager.start();
      expect(invocationCount, 0);
      await Future.delayed(Duration.zero);
      expect(invocationCount, 1);

      verify(channelMocks.channel.ready).called(1);
      verify(
        mockOnStateChange.call(argThat(isA<WebSocketInitializing>())),
      ).called(1);
      verifyNoMoreInteractions(mockOnStateChange);

      // .start() called during initialization.
      connectionManager.start();
      await Future.delayed(Duration.zero);
      expect(invocationCount, 1);

      verifyNoMoreInteractions(mockOnStateChange);
      verifyNever(channelMocks.channel.ready);

      channelMocks.readyCompleter.complete();
      await Future.delayed(Duration.zero);
      verify(
        mockOnStateChange.call(argThat(isA<WebSocketReady>())),
      ).called(1);
      verifyNoMoreInteractions(mockOnStateChange);

      verifyZeroInteractions(mockOnError);
      verifyZeroInteractions(mockOnMessage);
    });

    test('start() - multiple attempts - connection problems', () async {
      var invocationCount = 0;
      final channelMocks = [
        setUpChannelMock(),
        setUpChannelMock(),
      ];

      SocketConnectionManager connectionManager = SocketConnectionManager(
        factory: () => Future.value(channelMocks[invocationCount++].channel),
        reconnectDelays: [Duration.zero],
        onMessage: mockOnMessage.call,
        onStateChange: mockOnStateChange.call,
        onError: mockOnError.call,
      );

      // .start() called twice synchronously.
      connectionManager.start();
      connectionManager.start();
      expect(invocationCount, 0);
      await Future.delayed(Duration.zero);
      expect(invocationCount, 1);

      verify(channelMocks[0].channel.ready).called(1);
      verify(
        mockOnStateChange.call(argThat(isA<WebSocketInitializing>())),
      ).called(1);
      verifyNoMoreInteractions(mockOnStateChange);

      // .start() called during initialization.
      connectionManager.start();
      await Future.delayed(Duration.zero);
      expect(invocationCount, 1);
      verifyNoMoreInteractions(mockOnStateChange);
      verifyNever(channelMocks[0].channel.ready);

      channelMocks[0].readyCompleter.completeError(Object());
      await Future.delayed(Duration.zero);
      verifyNoMoreInteractions(mockOnStateChange);
      verify(mockOnError.call(any, any)).called(1);
      verifyNoMoreInteractions(mockOnError);

      expect(invocationCount, 1);
      channelMocks[1].readyCompleter.complete();
      await Future.delayed(Duration.zero);
      expect(invocationCount, 2);
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
      final channelMocks = setUpChannelMock();

      SocketConnectionManager connectionManager = SocketConnectionManager(
        factory: () => Future.value(channelMocks.channel),
        reconnectDelays: [Duration.zero],
        onMessage: mockOnMessage.call,
        onStateChange: mockOnStateChange.call,
        onError: mockOnError.call,
      );

      connectionManager.start();
      channelMocks.readyCompleter.complete();
      await Future.delayed(Duration.zero);

      verify(channelMocks.channel.ready).called(1);
      verifyInOrder([
        mockOnStateChange.call(argThat(isA<WebSocketInitializing>())),
        mockOnStateChange.call(argThat(isA<WebSocketReady>())),
      ]);
      verifyNoMoreInteractions(mockOnStateChange);

      channelMocks.sinkDoneCompleter.complete();
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
      final channelMock = setUpChannelMock();

      SocketConnectionManager connectionManager = SocketConnectionManager(
        factory: () => Future.value(channelMock.channel),
        reconnectDelays: [Duration.zero],
        onMessage: mockOnMessage.call,
        onStateChange: mockOnStateChange.call,
        onError: mockOnError.call,
      );

      connectionManager.start();
      channelMock.readyCompleter.complete();
      await Future.delayed(Duration.zero);

      verify(channelMock.channel.ready).called(1);
      verifyInOrder([
        mockOnStateChange.call(argThat(isA<WebSocketInitializing>())),
        mockOnStateChange.call(argThat(isA<WebSocketReady>())),
      ]);
      verifyNoMoreInteractions(mockOnStateChange);

      channelMock.streamController.close();
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
      final channelMock = setUpChannelMock();

      SocketConnectionManager connectionManager = SocketConnectionManager(
        factory: () => Future.value(channelMock.channel),
        reconnectDelays: [Duration.zero],
        onMessage: mockOnMessage.call,
        onStateChange: mockOnStateChange.call,
        onError: mockOnError.call,
      );

      connectionManager.start();
      channelMock.readyCompleter.complete();
      await Future.delayed(Duration.zero);

      verify(channelMock.channel.ready).called(1);
      verifyInOrder([
        mockOnStateChange.call(argThat(isA<WebSocketInitializing>())),
        mockOnStateChange.call(argThat(isA<WebSocketReady>())),
      ]);
      verifyNoMoreInteractions(mockOnStateChange);
      verifyZeroInteractions(mockOnError);

      final error = Object();
      channelMock.streamController.addError(error);
      await Future.delayed(Duration.zero);
      verify(mockOnError.call(error, any)).called(1);
      verifyNoMoreInteractions(mockOnError);

      verifyNoMoreInteractions(mockOnStateChange);
      verifyZeroInteractions(mockOnMessage);
    });

    test('start(immediatelly: true) executes connection attempt without delay',
        () async {
      final channelMock = setUpChannelMock();
      SocketConnectionManager connectionManager = SocketConnectionManager(
        factory: () => Future.value(channelMock.channel),
        reconnectDelays: [const Duration(days: 1)],
        onMessage: mockOnMessage.call,
        onStateChange: mockOnStateChange.call,
        onError: mockOnError.call,
      );

      channelMock.readyCompleter.complete(); // don't delay.
      connectionManager.start(immediately: false);
      await Future.delayed(Duration.zero);

      verifyZeroInteractions(channelMock.channel);
      verifyZeroInteractions(mockOnStateChange);

      connectionManager.start(immediately: true);
      await Future.delayed(Duration.zero);

      verify(channelMock.channel.ready).called(1);
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
