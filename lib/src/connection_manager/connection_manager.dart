import 'dart:async';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:rxdart/rxdart.dart';
import 'package:web_socket_channel/status.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../events.dart';
import '../exceptions.dart';
import '../message.dart';
import '../socket_options.dart';
import 'event.dart';
import 'state.dart';

final Logger _logger = Logger('phoenix_socket.ConnectionManager');

Future<Uri> _buildMountPoint(
  Uri serverUri,
  PhoenixSocketOptions options,
) async {
  final params = await options.getParams();
  final queryParams = serverUri.queryParameters.entries.toList()
    ..addAll(params.entries.toList());
  return serverUri.replace(
    queryParameters: Map.fromEntries(queryParams),
  );
}

class ConnectionManager {
  ConnectionManager({
    required String serverUri,
    WebSocketChannel Function(Uri uri)? webSocketChannelFactory,
  })  : _uri = Uri.parse(serverUri),
        _webSocketChannelFactory =
            webSocketChannelFactory ?? WebSocketChannel.connect {
    _openStream =
        _stateStreamController.stream.whereType<PhoenixSocketOpenEvent>();

    _closeStream =
        _stateStreamController.stream.whereType<PhoenixSocketCloseEvent>();

    _errorStream =
        _stateStreamController.stream.whereType<PhoenixSocketErrorEvent>();

    _eventSubject.stream.asyncMap(_handleEvent).listen((result) {
      final (event, newState, generation) = result;
      if (newState == null || !_isActive(generation)) {
        _logger.fine('Ignored event $event');
        return;
      }

      final previousState = currentState;
      onState(event, previousState, newState);
    });
  }

  final Uri _uri;
  Uri? _lastConnectionUri;

  String get endpoint => _uri.toString();
  Uri get mountPoint => _lastConnectionUri ?? _uri;

  PhoenixSocketOptions? _options;
  int _generation = 0;
  bool _disposed = false;
  final Set<Completer<dynamic>> _cancellations = {};
  Completer<void>? _pendingConnection;
  WebSocketChannel? _activeTransport;
  final Map<WebSocketChannel, StreamSubscription<dynamic>> _subscriptions = {};
  final Map<WebSocketChannel, Timer> _readyTimeouts = {};

  bool _isActive(int generation) => !_disposed && generation == _generation;

  final WebSocketChannel Function(Uri uri) _webSocketChannelFactory;
  final StreamController<(ConnectionEvent, int)> _eventSubject =
      StreamController();

  final StreamController<Message> _receiveStreamController =
      StreamController.broadcast();

  final BehaviorSubject<ConnectionState> _state =
      BehaviorSubject.seeded(DisconnectedState());

  final BehaviorSubject<PhoenixSocketEvent> _stateStreamController =
      BehaviorSubject();

  ConnectionState get currentState => _state.value;

  ValueStream<ConnectionState> get stateStream => _state.stream;

  late Stream<PhoenixSocketOpenEvent> _openStream;
  late Stream<PhoenixSocketCloseEvent> _closeStream;
  late Stream<PhoenixSocketErrorEvent> _errorStream;

  Stream<Message> get messageStream => _receiveStreamController.stream;
  Stream<Message> get topicStream => _receiveStreamController.stream
      .where((m) => m.topic != null && m.topic!.isNotEmpty);

  /// Stream of [PhoenixSocketOpenEvent] being produced whenever
  /// the connection is open.
  Stream<PhoenixSocketOpenEvent> get openStream => _openStream;

  /// Stream of [PhoenixSocketCloseEvent] being produced whenever
  /// the connection closes.
  Stream<PhoenixSocketCloseEvent> get closeStream => _closeStream;

  /// Stream of [PhoenixSocketErrorEvent] being produced in
  /// the lifetime of the [PhoenixSocket].
  Stream<PhoenixSocketErrorEvent> get errorStream => _errorStream;

  String get nextRef => switch (currentState) {
        ConnectedState(:final nextRef) ||
        ConnectingState(:final nextRef) ||
        ReconnectingState(:final nextRef) =>
          '$nextRef',
        _ => '0',
      };

  Future<void> connect(PhoenixSocketOptions options) {
    if (_disposed) {
      return Future.error(ConnectionManagerClosedError(
        message: 'ConnectionManager was disposed',
      ));
    }
    if (_pendingConnection case final pending?) {
      return pending.future;
    }
    late Completer<void> returnedCompleter;

    switch (currentState) {
      case DisconnectedState():
        returnedCompleter = Completer<void>();
        _pendingConnection = returnedCompleter;
        _add(
          Connect(
            options: options,
            completer: returnedCompleter,
          ),
        );

      case ConnectingState(:final completer) ||
            ReconnectingState(:final completer):
        returnedCompleter = completer;

      case ConnectedState():
        return Future.value();
    }

    return returnedCompleter.future;
  }

  Future<Message> waitForMessage(Message message) {
    if (_disposed) {
      return Future.error(ConnectionManagerClosedError(
        message: 'ConnectionManager was disposed',
      ));
    }
    final completer = Completer<Message>();
    _add(
      WaitFor(
        messageRef: message.ref!,
        completer: completer,
      ),
    );
    return completer.future;
  }

  void sendMessage(Message message) {
    _add(Send(
      message: message,
    ));
  }

  Null _waitForMessage(
    String messageRef, {
    required Completer<Message> completer,
  }) {
    switch (currentState) {
      case ConnectedState(:final pendingMessages):
        final existingFuture = pendingMessages[messageRef];
        if (existingFuture == null) {
          pendingMessages[messageRef] = completer;
        } else {
          completer.complete(existingFuture.future);
        }
        break;

      case ConnectingState(:final queuedMessages) ||
            ReconnectingState(:final queuedMessages):
        for (final (i, (queuedMessage, existingCompleter))
            in queuedMessages.indexed) {
          if (queuedMessage.ref == messageRef) {
            if (existingCompleter != null) {
              completer.complete(existingCompleter.future);
            } else {
              queuedMessages
                  .replaceRange(i, i + 1, [(queuedMessage, completer)]);
            }
            return null;
          }
        }

        if (!completer.isCompleted) {
          completer.completeError(
            ArgumentError(
              "Message hasn't been sent using this socket.",
            ),
          );
        }
        break;

      default:
        completer.completeError(
          StateError(
            "Socket is closed so there is no message to wait for.",
          ),
        );
    }
    return null;
  }

  Null _sendMessage(
    Message message, {
    required Completer<Message>? completer,
    ConnectionState? state,
  }) {
    if (state != null && !identical(state, currentState)) {
      if (completer != null && !completer.isCompleted) {
        completer.completeError(SocketClosedError(
          message: 'Socket closed before its queued message was sent',
          socketClosed: PhoenixSocketCloseEvent(),
        ));
      }
      return null;
    }
    switch (state ?? currentState) {
      case ConnectedState(channel: final channel, :final pendingMessages):
        if (completer != null) {
          pendingMessages[message.ref!] = completer;
        }
        try {
          channel.sink.add(_options!.serializer.encode(message));
        } catch (error, stackTrace) {
          if (completer != null && !completer.isCompleted) {
            pendingMessages.remove(message.ref);
            completer.completeError(error, stackTrace);
          }
          _add(ChannelError(
              channel: channel, error: error, stackTrace: stackTrace));
        }
        break;

      case ConnectingState(:final queuedMessages) ||
            ReconnectingState(:final queuedMessages):
        queuedMessages.add((message, completer));
        break;

      default:
        completer?.completeError(
          PhoenixException(
            message: 'Cannot send message while disconnected',
            socketClosed: PhoenixSocketCloseEvent(),
          ),
        );
    }
    return null;
  }

  void close({
    int? code,
    String? reason,
  }) {
    if (_disposed) return;
    _generation++;
    for (final cancellation in _cancellations) {
      cancellation.complete();
    }
    _cancellations.clear();
    final oldState = currentState;
    final channel = _activeTransport;
    onState(
      ChannelClosed(code: code, reason: reason, channel: channel),
      oldState,
      DisconnectedState(),
    );
    if (oldState case ConnectedState(:final heartbeatTimeout)) {
      heartbeatTimeout?.cancel();
    }
    if (channel != null) _closeChannel(channel, code, reason);
    final error = SocketClosedError(
      message: 'ConnectionManager was closed',
      socketClosed: PhoenixSocketCloseEvent(reason: reason, code: code),
    );
    final pendingConnection = _pendingConnection;
    _pendingConnection = null;
    if (pendingConnection != null && !pendingConnection.isCompleted) {
      pendingConnection.completeError(error);
    }

    final pendingCompleters = switch (oldState) {
      ConnectedState(:final pendingMessages) =>
        pendingMessages.entries.map((pair) => pair.value),
      ConnectingState(:final queuedMessages) ||
      ReconnectingState(:final queuedMessages) =>
        queuedMessages.map((pair) => pair.$2),
      _ => Iterable<Completer>.empty(),
    };

    for (final completer in pendingCompleters) {
      if (completer?.isCompleted ?? true) {
        continue;
      }
      completer?.completeError(error);
    }
    switch (oldState) {
      case ConnectedState(:final pendingMessages):
        pendingMessages.clear();
      case ConnectingState(:final queuedMessages):
        queuedMessages.clear();
      case DisconnectedState():
    }
  }

  void dispose() {
    if (_disposed) return;
    close();
    _disposed = true;

    _receiveStreamController.close();
    _stateStreamController.close();
    _eventSubject.close();
    _state.close();
  }

  bool isDisposed() => _disposed;

  void onEvent(ConnectionEvent event) {
    _logger.fine(() => 'Handling event $event');
  }

  @mustCallSuper
  void onState(
    ConnectionEvent? event,
    ConnectionState previous,
    ConnectionState next,
  ) {
    _logger.fine(() => 'Moving to state $next');
    if (!_state.isClosed) _state.add(next);

    switch (next) {
      case ConnectedState():
        _addStateEvent(
          PhoenixSocketOpenEvent(),
        );

      case DisconnectedState():
        if (event case ChannelError(:final error)) {
          _addStateEvent(
            PhoenixSocketCloseEvent(
              reason: error.toString(),
            ),
          );
        } else if (event case ChannelClosed(:final code)) {
          _addStateEvent(
            PhoenixSocketCloseEvent(code: code),
          );
        }

      case _:
        if (event case ChannelError(:final error, :final stackTrace)) {
          _addStateEvent(
            PhoenixSocketErrorEvent(
              error: error,
              stacktrace: stackTrace,
            ),
          );
        }
    }
  }

  Future<(ConnectionEvent, ConnectionState?, int)> _handleEvent(
    (ConnectionEvent, int) queuedEvent,
  ) async {
    final (event, generation) = queuedEvent;
    if (!_isActive(generation)) {
      if (event case WaitFor(:final completer)) {
        completer.completeError(SocketClosedError(
          message:
              'ConnectionManager was closed before waiting for the message',
          socketClosed: PhoenixSocketCloseEvent(),
        ));
      }
      return (event, null, generation);
    }
    onEvent(event);

    return (
      event,
      switch (event) {
        Connect(options: final options, :final completer) =>
          await _connect(options, completer, generation),
        Disconnect(:final code, :final reason) => await _disconnect(
            PhoenixSocketCloseEvent(
              reason: reason,
              code: code,
            ),
          ),
        ChannelClosed(channel: final channel) => await _channelClosed(channel),
        ChannelError(:final channel, :final error, :final stackTrace) =>
          await _channelError(channel, error, stackTrace),
        ChannelReady(channel: final channel) => await _channelReady(channel),
        ReceiveMessage(:final payload, :final channel) =>
          _receiveMessage(channel, payload),
        Send(:final message) => _sendMessage(message, completer: null),
        WaitFor(:final messageRef, :final completer) =>
          _waitForMessage(messageRef, completer: completer),
      },
      generation,
    );
  }

  void _add(ConnectionEvent event) {
    if (!_eventSubject.isClosed) {
      _eventSubject.add((event, _generation));
    }
  }

  Future<WebSocketChannel?> _createChannel(int generation) async {
    final mountPoint = await _untilCancelled(
      _buildMountPoint(_uri, _options!),
      generation,
    );
    if (!_isActive(generation) || mountPoint == null) return null;
    _lastConnectionUri = mountPoint;

    final channel = _webSocketChannelFactory(mountPoint);
    _activeTransport = channel;
    if (!_isActive(generation)) {
      _closeChannel(channel);
      return null;
    }
    try {
      _subscriptions[channel] = channel.stream.listen(
        (message) {
          if (!_isActive(generation)) return;
          _add(
            ReceiveMessage(
              channel: channel,
              payload: message,
            ),
          );
        },
        cancelOnError: false,
        onError: (error, stackTrace) {
          if (!_isActive(generation)) return;
          _add(
            ChannelError(
              channel: channel,
              error: error,
              stackTrace: stackTrace,
            ),
          );
        },
        onDone: () {
          if (!_isActive(generation)) return;
          _add(
            ChannelClosed(
              channel: channel,
              code: channel.closeCode,
              reason: channel.closeReason,
            ),
          );
        },
      );
      final readyTimeout = Timer(_options!.timeout, () {
        if (!_isActive(generation)) return;
        _add(ChannelError(
          channel: channel,
          error: TimeoutException(
              'WebSocket handshake timed out', _options!.timeout),
          stackTrace: StackTrace.current,
        ));
      });
      _readyTimeouts[channel] = readyTimeout;
      channel.ready.then((_) {
        readyTimeout.cancel();
        if (_isActive(generation) && _readyTimeouts.remove(channel) != null) {
          _add(ChannelReady(channel: channel));
        }
      }, onError: (Object error, StackTrace stackTrace) {
        readyTimeout.cancel();
        if (_isActive(generation) && _readyTimeouts.remove(channel) != null) {
          _add(ChannelError(
              channel: channel, error: error, stackTrace: stackTrace));
        }
      });
    } catch (_) {
      _closeChannel(channel);
      rethrow;
    }

    return channel;
  }

  void _closeChannel(WebSocketChannel channel, [int? code, String? reason]) {
    if (identical(_activeTransport, channel)) _activeTransport = null;
    _readyTimeouts.remove(channel)?.cancel();
    _subscriptions.remove(channel)?.cancel();
    Future.sync(() => channel.sink.close(code, reason)).then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _addStateEvent(
            PhoenixSocketErrorEvent(error: error, stacktrace: stackTrace));
      },
    );
  }

  Future<bool> _waitForRetry(int attempt, int generation) async {
    final delay = Completer<void>();
    final timer = Timer(
      _options!.getReconnectionDelay(attempt) ?? Duration.zero,
      delay.complete,
    );
    await _untilCancelled(delay.future, generation);
    timer.cancel();
    return _isActive(generation);
  }

  Future<T?> _untilCancelled<T>(Future<T> future, int generation) async {
    final cancellation = Completer<T?>();
    if (_isActive(generation)) {
      _cancellations.add(cancellation);
    } else {
      cancellation.complete();
    }
    try {
      return await Future.any<T?>([future, cancellation.future]);
    } finally {
      _cancellations.remove(cancellation);
    }
  }

  Future<ConnectionState?> _startConnection({
    required int generation,
    required Completer<void> completer,
    int reconnectionAttempts = 0,
    int startingRef = 0,
    List<(Message, Completer<Message>?)>? queuedMessages,
    bool reconnecting = false,
  }) async {
    while (_isActive(generation)) {
      try {
        final channel = await _createChannel(generation);
        if (channel == null || !_isActive(generation)) return null;
        return reconnecting
            ? ReconnectingState(
                channel: channel,
                completer: completer,
                startingRef: startingRef,
                queuedMessages: queuedMessages,
                reconnectionAttempts: reconnectionAttempts,
              )
            : ConnectingState(
                channel: channel,
                completer: completer,
                startingRef: startingRef,
                queuedMessages: queuedMessages,
                reconnectionAttempts: reconnectionAttempts,
              );
      } catch (error, stackTrace) {
        if (!_isActive(generation)) return null;
        _addStateEvent(
            PhoenixSocketErrorEvent(error: error, stacktrace: stackTrace));
        if (!_options!.shouldAttemptReconnection(reconnectionAttempts)) {
          onState(null, currentState, DisconnectedState());
          _failConnection(completer, queuedMessages ?? [], error, stackTrace);
          return null;
        }
        if (!await _waitForRetry(reconnectionAttempts++, generation)) {
          return null;
        }
        reconnecting = true;
      }
    }
    return null;
  }

  void _failConnection(
    Completer<void> completer,
    List<(Message, Completer<Message>?)> queuedMessages,
    Object error, [
    StackTrace? stackTrace,
  ]) {
    if (identical(_pendingConnection, completer)) _pendingConnection = null;
    if (!completer.isCompleted) completer.completeError(error, stackTrace);
    for (final (_, pending) in queuedMessages) {
      if (pending != null && !pending.isCompleted) {
        pending.completeError(error, stackTrace);
      }
    }
    queuedMessages.clear();
  }

  Null _receiveMessage(WebSocketChannel channel, dynamic payload) {
    if (payload is String) {
      if (currentState case ConnectedState connectedState
          when connectedState.channel == channel) {
        final Message message;
        try {
          message = _options!.serializer.decode(payload);
        } catch (error, stackTrace) {
          _add(ChannelError(
              channel: channel, error: error, stackTrace: stackTrace));
          return null;
        }

        if (message.ref != null) {
          if (message.ref == connectedState.pendingHeartbeatRef) {
            connectedState.pendingHeartbeatRef = null;
          }

          final completer = connectedState.pendingMessages.remove(message.ref);
          if (completer != null && !completer.isCompleted) {
            completer.complete(message);
          }
        }

        if (!_receiveStreamController.isClosed) {
          _receiveStreamController.add(message);
        }
      }
    }
    return null;
  }

  Future<ConnectionState?> _connect(
    PhoenixSocketOptions options,
    Completer<void> completer,
    int generation,
  ) async {
    if (!_isActive(generation)) return null;
    switch (currentState) {
      case DisconnectedState():
        _options = options;
        return _startConnection(
          generation: generation,
          completer: completer,
        );

      case ConnectingState(completer: final existingCompleter) ||
            ReconnectingState(completer: final existingCompleter):
        if (!identical(existingCompleter, completer) &&
            !completer.isCompleted) {
          completer.complete(existingCompleter.future);
        }
        return null;

      case ConnectedState():
        if (!completer.isCompleted) completer.complete();
        _logger.warning(
          () => 'Tried to connect while not being in the DisconnectedState',
        );
        return null;
    }
  }

  Future<ConnectionState?> _channelReady(WebSocketChannel channel) async {
    switch (currentState) {
      case ConnectingState(
                channel: final currentChannel,
                :final currentRef,
                :final queuedMessages,
                :final completer,
              ) ||
              ReconnectingState(
                channel: final currentChannel,
                :final currentRef,
                :final queuedMessages,
                :final completer,
              )
          when currentChannel == channel:
        final state = ConnectedState(
          channel: channel,
          startingRef: currentRef,
        );

        onState(
          ChannelReady(channel: channel),
          currentState,
          state,
        );

        for (final (message, completer) in queuedMessages) {
          _sendMessage(
            message,
            state: state,
            completer: completer,
          );
        }

        if (identical(_pendingConnection, completer)) _pendingConnection = null;
        if (!completer.isCompleted) completer.complete();
        if (identical(currentState, state)) {
          _scheduleHeartbeat(state, immediately: true);
        }

        return null;

      case _:
        return null;
    }
  }

  Future<ConnectionState?> _disconnect(
    PhoenixSocketCloseEvent closeEvent, [
    WebSocketChannel? channel,
  ]) async {
    final generation = _generation;
    switch (currentState) {
      case ConnectedState(
            channel: final currentChannel,
            :final pendingMessages,
            :final heartbeatTimeout,
            :final currentRef,
          )
          when channel == null || channel == currentChannel:
        heartbeatTimeout?.cancel();
        _closeChannel(currentChannel);
        _addStateEvent(closeEvent);

        for (final completer in pendingMessages.values) {
          if (!completer.isCompleted) {
            completer.completeError(
              SocketClosedError(
                message: 'Socket was closed'
                    ' (${currentChannel.closeReason}, ${currentChannel.closeCode})',
                socketClosed: closeEvent,
              ),
            );
          }
        }
        pendingMessages.clear();

        if (_options!.shouldAttemptReconnection(0)) {
          final completer = Completer<void>();
          // Automatic reconnects do not necessarily have a public caller.
          // Keep their terminal failure handled even when nobody calls connect.
          completer.future
              .then<void>((_) {}, onError: (Object _, StackTrace __) {});
          _pendingConnection = completer;
          final reconnecting = ReconnectingState(
            channel: currentChannel,
            completer: completer,
            startingRef: currentRef,
          );
          onState(null, currentState, reconnecting);
          if (!await _waitForRetry(0, generation)) return null;
          return _startConnection(
            generation: generation,
            completer: completer,
            startingRef: reconnecting.currentRef,
            queuedMessages: reconnecting.queuedMessages,
            reconnecting: true,
          );
        }

        return DisconnectedState();

      case ConnectingState(
                channel: final currentChannel,
                :final currentRef,
                :final queuedMessages,
                :final reconnectionAttempts,
                :final completer,
              ) ||
              ReconnectingState(
                channel: final currentChannel,
                :final currentRef,
                :final queuedMessages,
                :final reconnectionAttempts,
                :final completer,
              )
          when channel == null || channel == currentChannel:
        _closeChannel(currentChannel);

        if (_options!.shouldAttemptReconnection(reconnectionAttempts)) {
          final reconnecting = ReconnectingState(
            channel: currentChannel,
            startingRef: currentRef,
            queuedMessages: queuedMessages,
            reconnectionAttempts: reconnectionAttempts + 1,
            completer: completer,
          );
          onState(null, currentState, reconnecting);
          if (!await _waitForRetry(reconnectionAttempts, generation)) {
            return null;
          }
          return _startConnection(
            generation: generation,
            completer: completer,
            startingRef: reconnecting.currentRef,
            queuedMessages: queuedMessages,
            reconnectionAttempts: reconnectionAttempts + 1,
            reconnecting: true,
          );
        }

        onState(null, currentState, DisconnectedState());
        _failConnection(
          completer,
          queuedMessages,
          SocketClosedError(
            message: 'Maximum connection attempt reached without a'
                ' successful connection',
            socketClosed: closeEvent,
          ),
        );
        return null;

      case DisconnectedState():
        _logger.info(
          () => 'Tried to disconnect while being in the DisconnectedState',
        );
        return null;

      case _:
        return null;
    }
  }

  Future<ConnectionState?> _channelClosed(
    WebSocketChannel? channel,
  ) async {
    return _disconnect(
      PhoenixSocketCloseEvent(
        reason: channel?.closeReason,
        code: channel?.closeCode,
      ),
      channel,
    );
  }

  Future<ConnectionState?> _channelError(
    WebSocketChannel affectedChannel,
    Object error,
    StackTrace stackTrace,
  ) async {
    switch (currentState) {
      case ConnectedState(:final channel) ||
              ConnectingState(:final channel) ||
              ReconnectingState(:final channel)
          when channel == affectedChannel:
        _addStateEvent(
          PhoenixSocketErrorEvent(
            error: error,
            stacktrace: stackTrace,
          ),
        );

        return _disconnect(
          PhoenixSocketCloseEvent(
            reason: channel.closeReason ?? error.toString(),
            code: channel.closeCode,
          ),
          channel,
        );
      case _:
    }
    return null;
  }

  void _addStateEvent(PhoenixSocketEvent event) {
    if (!_stateStreamController.isClosed) {
      _stateStreamController.add(event);
    }
  }

  void _scheduleHeartbeat(
    ConnectedState state, {
    bool immediately = false,
  }) {
    if (state.heartbeatTimeout != null) {
      return;
    }

    state.heartbeatTimeout = Timer(
      immediately ? Duration.zero : _options!.heartbeat,
      () {
        state.heartbeatTimeout = null;
        if (currentState == state) {
          _sendHeartbeat(state);
        }
      },
    );
  }

  Future<bool> _sendHeartbeat(ConnectedState state) async {
    try {
      final completer = Completer<Message>();
      _sendMessage(state.heartbeatMessage(), completer: completer);
      await completer.future.timeout(_options!.heartbeatTimeout);
      if (currentState == state) {
        _scheduleHeartbeat(state);
      }
      return true;
    } on TimeoutException catch (err, stackTrace) {
      _logger.severe(
        () => 'Heartbeat message timed out',
        err,
        stackTrace,
      );

      if (state == currentState) {
        _add(
          ChannelClosed(
            channel: state.channel,
            code: normalClosure,
            reason: 'heartbeat timeout',
          ),
        );
      }
      return false;
    } catch (err, stackTrace) {
      if (currentState == state && state.channel.closeCode != null) {
        _add(
          ChannelClosed(
            channel: state.channel,
            code: normalClosure,
            reason: 'heartbeat timeout',
          ),
        );

        _logger.severe(
          () => 'Heartbeat message failed and socket is closed,'
              ' thus issueing a disconnection',
          err,
          stackTrace,
        );

        return false;
      }

      _logger.severe(
        () => 'Heartbeat message failed',
        err,
        stackTrace,
      );
      return false;
    }
  }
}
