import 'dart:async';

import 'package:logging/logging.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket/src/delayed_callback.dart';
import 'package:rxdart/rxdart.dart';
import 'package:web_socket_channel/status.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

part 'socket_state.dart';

typedef WebSocketChannelFactory = Future<WebSocketChannel> Function();

final _logger = Logger('phoenix_socket.connection');

// Some custom close codes.
const heartbeatTimedOut = 4001;
const forcedReconnectionRequested = 4002;

/// Maintains connection to the underlying websocket, reconnecting to it if
/// necessary.
class SocketConnectionManager {
  SocketConnectionManager({
    required WebSocketChannelFactory factory,
    required List<Duration> reconnectDelays,
    required void Function(String) onMessage,
    required void Function(WebSocketConnectionState) onStateChange,
    required void Function(Object, [StackTrace?]) onError,
  })  : _factory = factory,
        _reconnectDelays = reconnectDelays,
        _onError = onError,
        _onStateChange = onStateChange,
        _onMessage = onMessage;

  final WebSocketChannelFactory _factory;
  final List<Duration> _reconnectDelays;
  final void Function(String message) _onMessage;
  final void Function(WebSocketConnectionState state) _onStateChange;
  final void Function(Object error, [StackTrace? stacktrace]) _onError;

  /// Currently attempted or live connection. Value is null only before
  /// any connection was attempted.
  final _connectionsStream = BehaviorSubject<_WebSocketConnection>();

  /// Count of consecutive attempts at establishing a connection without
  /// success.
  int _connectionAttempts = 0;

  /// References to the last initialized connection attempt.
  DelayedCallback<_WebSocketConnection>? _currentAttempt;

  bool _disposed = false;

  /// Requests to start connecting to the socket. Returns a future that
  /// completes when a WebSocket connection has been established.
  ///
  /// If [immediately] is false, and a connection is already established, then
  /// this method does not have any effect.
  ///
  /// If [immediately] is set to true, then an attempt to connect is made
  /// immediately. This might result in dropping the current connection and
  /// establishing a new one.
  Future<void> start({bool immediately = false}) async {
    if (_disposed) {
      throw StateError('Cannot start: WebSocket connection manager disposed');
    }

    if (immediately) {
      final currentAttempt = _currentAttempt;
      if (_connectionsStream.hasValue &&
          currentAttempt != null &&
          !currentAttempt.delayDone) {
        currentAttempt.skipDelay();
        return;
      }

      await reconnect(
        forcedReconnectionRequested,
        reason: 'Immediate connection requested',
        immediately: true,
      );
      return;
    }
    await _maybeConnect();
  }

  /// Sends a message to the socket. Will start connecting to the socket if
  /// necessary.
  ///
  /// Returns a future that completes when the message is successfully passed to
  /// an established WebSocket.
  ///
  /// The future will complete with error if the message couldn't be added to
  /// a WebSocket, either because this connection manager was disposed, or the
  /// WebSocket could not accept messages.
  Future<void> addMessage(String message) async {
    final connection = await _maybeConnect();
    return connection.send(message);
  }

  /// Forces reconnection to the WebSocket. Returns a future that completes when
  /// a WebSocket connection has been established.
  ///
  /// If a connection was already established, it gets closed with the provided
  /// code and optional reason.
  ///
  /// If [immediately] is true, then the new connection attempt is executed
  /// immediately, irrespective of ordinary reconnection delays provided to the
  /// constructor.
  Future<void> reconnect(int code, {String? reason, bool immediately = false}) {
    final currentConnection = _connectionsStream.valueOrNull;
    final connectFuture = _connect();
    if (immediately) {
      _currentAttempt?.skipDelay();
    }
    if (currentConnection?.connected == true) {
      currentConnection?.close(code, reason);
    }
    return connectFuture;
  }

  /// Disposes of the connection manager. The current connection (or attempt
  /// at one) is cancelled, and attempt to establish a new one will fail.
  ///
  /// If this manager is already disposed, this is a no-op.
  void dispose(int code, [String? reason]) {
    if (_disposed) {
      _logger.info('WebSocket connection manager already disposed');
      return;
    }
    _logger.fine('Disposing connection manager');
    _disposed = true;
    _currentAttempt = null;
    final currentConnection = _connectionsStream.valueOrNull;
    _connectionsStream.close();
    if (currentConnection != null && currentConnection.connected) {
      currentConnection.close(code, reason);
      _onStateChange(WebSocketDisconnected._(code, reason));
    }
  }

  /// Establishes a new connection unless one is already available/in progress.
  Future<_WebSocketConnection> _maybeConnect() {
    if (_disposed) {
      throw StateError('Cannot connect: WebSocket connection manager disposed');
    }

    if (!_connectionsStream.hasValue && _currentAttempt == null) {
      _connect();
    }

    return _connectionsStream.firstWhere((connection) => connection.connected);
  }

  /// Starts attempt to connect, and returns when a WebSocket connection has
  /// been successfully established.
  ///
  /// Upon completing, the [_pendingConnection] field will be set to the newly
  /// established connection Future, and the same Future will be returned.
  ///
  /// Can throw/complete with an exception if during any asynchronous operation,
  /// this [SocketConnectionManager] is disposed.
  ///
  /// The [_onError] callback can be invoked with an instance of
  /// [ConnectionInitializationException] in case the initialization of
  /// connection fails. However, the reconnection will be triggered until it is
  /// established, or interrupted by call to [dispose].
  Future<_WebSocketConnection> _connect() async {
    if (_disposed) {
      throw StateError('Cannot connect: WebSocket connection manager disposed');
    }

    while (_connectionsStream.valueOrNull?.connected != true) {
      final delay = _reconnectDelay();
      late final DelayedCallback attempt;
      attempt = _currentAttempt = DelayedCallback<_WebSocketConnection>(
        delay: delay,
        callback: () => _runConnectionAttempt(attempt),
      );
      _connectionAttempts++;

      if (_logger.isLoggable(Level.FINE)) {
        _logger.fine(() {
          final durationString = delay == Duration.zero
              ? 'now'
              : 'in ${delay.inMilliseconds} milliseconds';
          return 'Triggering attempt #$_connectionAttempts (id: ${attempt.idAsString}) to connect $durationString';
        });
      }

      _WebSocketConnection? connection;
      try {
        connection = await attempt.callbackFuture;
      } catch (error, stackTrace) {
        _logger.warning('Failed to initialize connection', error, stackTrace);
        if (attempt == _currentAttempt) {
          _onError(error, stackTrace);
        }
      } finally {
        if (_disposed) {
          // Manager was disposed while running connection attempt.
          // Should be goingAway, but https://github.com/dart-lang/http/issues/1294
          connection?.close(normalClosure, 'Client disposed');
          throw StateError('Client disposed');
        } else if (attempt != _currentAttempt) {
          // Some other attempt was started, close and await for other attempt to
          // complete.
          connection?.close(normalClosure, 'Closing obsolete connection');
          await _connectionsStream
              .firstWhere((connection) => connection.connected);
        } else if (connection != null) {
          // Correctly established connection.
          _logger.fine('Established WebSocket connection');
          _connectionAttempts = 0;
          _connectionsStream.add(connection);
        }
      }
    }

    return _connectionsStream.value;
  }

  Future<_WebSocketConnection> _runConnectionAttempt(
    DelayedCallback attempt,
  ) async {
    if (attempt != _currentAttempt) {
      throw StateError('Current attempt obsoleted while delaying');
    }

    try {
      return await _WebSocketConnection.connect(
        _factory,
        callbacks: _ConnectionCallbacks(attempt: attempt, manager: this),
      );
    } on ConnectionInitializationException {
      rethrow;
    } catch (error, stackTrace) {
      throw ConnectionInitializationException(error, stackTrace);
    }
  }

  Duration _reconnectDelay() {
    final delayIndex =
        _connectionAttempts.clamp(0, _reconnectDelays.length - 1);
    return _reconnectDelays[delayIndex];
  }
}

/// Wraps upstream callbacks to filter out obsolete or invalid callbacks from
/// _WebSocketConnection.
final class _ConnectionCallbacks {
  _ConnectionCallbacks({
    required this.attempt,
    required this.manager,
  });

  final DelayedCallback attempt;
  String get attemptIdString => attempt.idAsString;
  final SocketConnectionManager manager;

  WebSocketConnectionState? lastState;

  void onMessage(String message) {
    if (attempt != manager._currentAttempt) {
      if (_logger.isLoggable(Level.FINER)) {
        _logger.finer(
          'Preventing message reporting for old connection attempt $attemptIdString',
        );
      }
      return;
    }

    manager._onMessage(message);
  }

  void onError(Object error, [StackTrace? stackTrace]) {
    if (attempt != manager._currentAttempt) {
      if (_logger.isLoggable(Level.FINER)) {
        _logger.finer(
          'Preventing error reporting for old connection attempt $attemptIdString',
        );
      }
      return;
    }

    manager._onError(error, stackTrace);
  }

  void onStateChange(WebSocketConnectionState newState) {
    if (attempt != manager._currentAttempt) {
      if (_logger.isLoggable(Level.FINER)) {
        _logger.finer(
          'Preventing connection state update for old connection attempt $attemptIdString',
        );
      }
      return;
    }

    if (!_isTransitionAllowed(lastState, newState)) {
      if (_logger.isLoggable(Level.FINE)) {
        _logger.fine(
          'Preventing connection state change for $attemptIdString from $lastState to $newState',
        );
      }
      return;
    }

    if (_logger.isLoggable(Level.FINE)) {
      _logger.fine(
        'Changing connection state for $attemptIdString from $lastState to $newState',
      );
    }
    lastState = newState;

    if (newState is WebSocketDisconnected) {
      _logger.fine('Socket closed, attempting to reconnect');
      manager._connect();
    }

    manager._onStateChange(newState);
  }

  bool _isTransitionAllowed(
    WebSocketConnectionState? lastState,
    WebSocketConnectionState newState,
  ) {
    switch ((lastState, newState)) {
      case (null, _):
        return true;
      case (final a, final b) when a == b:
      case (_, WebSocketConnecting()):
      case (WebSocketDisconnected(), _):
      case (WebSocketDisconnecting(), final b) when b is! WebSocketDisconnected:
        return false;
      case _:
        return true;
    }
  }
}

class _WebSocketConnection {
  static Future<_WebSocketConnection> connect(
    WebSocketChannelFactory factory, {
    required _ConnectionCallbacks callbacks,
  }) async {
    callbacks.onStateChange(const WebSocketConnecting._());
    final WebSocketChannel ws;
    try {
      ws = await factory();
      await ws.ready;
    } catch (error, stackTrace) {
      throw ConnectionInitializationException(error, stackTrace);
    }

    callbacks.onStateChange(const WebSocketConnected._());

    return _WebSocketConnection._(
      ws,
      onMessage: callbacks.onMessage,
      onError: callbacks.onError,
      onStateChange: callbacks.onStateChange,
    );
  }

  _WebSocketConnection._(
    this._ws, {
    required void Function(String message) onMessage,
    required void Function(Object error, [StackTrace? stackTrace]) onError,
    required void Function(WebSocketConnectionState state) onStateChange,
  }) {
    late final StreamSubscription subscription;
    subscription = _ws.stream.listen(
      (event) => event is String
          ? onMessage(event)
          : onError(PhoenixException(), StackTrace.current),
      onError: onError,
      onDone: () {
        onStateChange(
          WebSocketDisconnected._(
            _ws.closeCode ?? noStatusReceived,
            _ws.closeReason,
          ),
        );
        connected = false;
        subscription.cancel();
      },
    );

    _ws.sink.done.then(
      (_) {
        if (connected) {
          connected = false;
          onStateChange(const WebSocketDisconnecting._());
        }
      },
      onError: onError,
    );
  }

  final WebSocketChannel _ws;
  bool connected = true;

  void send(dynamic message) {
    if (!connected) {
      throw WebSocketChannelException(
        'Trying to send a message after WebSocket sink closed.',
      );
    }

    _ws.sink.add(message);
  }

  sendError(Object messageError, StackTrace? messageTrace) {
    if (!connected) {
      throw WebSocketChannelException(
        'Trying to send a message after WebSocket sink closed.',
      );
    }
    _ws.sink.addError(messageError, messageTrace);
  }

  /// Closes the underlying connection providing the code and reason to the
  /// WebSocket's Close frame. Has no effect if already closed.
  ///
  /// Note that no [WebSocketDisconnecting] event is going to be emitted during
  /// close initiated by the client.
  void close(int status, [String? reason]) {
    if (connected) {
      connected = false;
      _ws.sink.close(status, reason);
    }
  }
}

final class ConnectionInitializationException {
  ConnectionInitializationException(this.cause, this.stackTrace);

  final Object cause;
  final StackTrace stackTrace;

  @override
  String toString() {
    return 'WebSocket connection failed to initialize: $cause\n$stackTrace';
  }
}
