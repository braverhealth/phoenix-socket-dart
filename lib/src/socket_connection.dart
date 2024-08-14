import 'dart:async';

import 'package:logging/logging.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket/src/socket_connection_attempt.dart';
import 'package:web_socket_channel/status.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

part 'socket_state.dart';

typedef WebSocketChannelFactory = Future<WebSocketChannel> Function();

final _logger = Logger('phoenix_socket.connection');

/// Maintains connection to the underlying websocket, reconnecting to it if
/// necessary.
class SocketConnectionManager {
  SocketConnectionManager({
    required Future<WebSocketChannel> Function() factory,
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

  /// Currently attempted or live connection. When null, signifies that no
  /// new attempts are being made.
  Future<_WebSocketConnection>? _pendingConnection;

  /// Count of consecutive attempts at establishing a connection without
  /// success.
  int _connectionAttempts = 0;

  SocketConnectionAttempt _currentAttempt = SocketConnectionAttempt.aborted();

  bool _disposed = false;
  bool get _shouldAttemptReconnection =>
      !_disposed && _pendingConnection != null;

  /// Requests to start connecting to the socket.
  ///
  /// Has no effect if the connection is already established.
  ///
  /// If [immediately] is set to true, then an attempt to connect is made
  /// immediately. This might result in dropping the current connection and
  /// establishing a new one.
  void start({bool immediately = false}) {
    if (_disposed) {
      throw StateError('Cannot start: WebSocket connection manager disposed');
    }

    if (immediately) {
      if (_pendingConnection != null && !_currentAttempt.delayDone) {
        _currentAttempt.skipDelay();
        return;
      }

      _stopConnecting(4002, 'Immediate connection requested');
      _connectionAttempts = 0;
    }
    _maybeConnect();
  }

  /// Sends a message to the socket. Will start connecting to the socket if
  /// necessary.
  ///
  /// Returns a future that completes when the message is successfully added to
  /// the socket.
  ///
  /// If after call to [addMessage] a call to [dispose] or [stop] is made, then
  /// this future will complete with an error instead.
  Future<void> addMessage(String message) {
    return _maybeConnect().then((connection) => connection.send(message));
  }

  /// Stops the attempts to connect, and closes the current connection if one is
  /// established.
  void stop(int code, [String? reason]) {
    _logger.fine('Stopping connecting attempts');
    if (_disposed) {
      throw StateError('Cannot stop: WebSocket connection manager disposed');
    }
    _stopConnecting(code, reason);
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
    _stopConnecting(code, reason);
  }

  void _stopConnecting(int code, String? reason) {
    final currentConnection = _pendingConnection;
    _pendingConnection = null;

    // Make sure that no old attempt will begin emitting messages.
    if (!_currentAttempt.delayDone) {
      _currentAttempt.abort();
    }
    _currentAttempt = SocketConnectionAttempt.aborted();

    currentConnection?.then((connection) {
      connection.close(code, reason);
    }).ignore();
  }

  /// Establishes a new connection unless one is already available/in progress.
  Future<_WebSocketConnection> _maybeConnect() {
    if (_disposed) {
      throw StateError('Cannot connect: WebSocket connection manager disposed');
    }

    return _pendingConnection ?? _connect();
  }

  /// Starts connection attempts.
  ///
  /// Upon completiong, the [_pendingConnection] field will be set to the newly
  /// established connection Future, and the same Future will be returned.
  ///
  /// Can throw/complete with an exception if:
  /// - during any asynchronous operation, this [SocketConnectionManager] is
  ///   disposed.
  /// - during any asynchronous operation, the [_pendingConnection] is set to
  ///   null, which is interpreted as a prompt to abort connecting.
  ///
  /// The [_onError] callback can be invoked with an instance of
  /// [ConnectionInitializationException] in case the initialization of
  /// connection fails. However, the reconnection will be triggered until it is
  /// established, or interrupted by call to [stop] or [dispose].
  Future<_WebSocketConnection> _connect() async {
    if (_disposed) {
      throw StateError('Cannot connect: WebSocket connection manager disposed');
    }

    final connectionCompleter = Completer<_WebSocketConnection>();
    final connectionFuture = _pendingConnection = connectionCompleter.future;

    while (!connectionCompleter.isCompleted) {
      final delay = _reconnectDelay();
      _connectionAttempts++;

      _WebSocketConnection? connection;
      try {
        connection = await _runConnectionAttempt(delay);
      } catch (error, stackTrace) {
        _logger.warning('Failed to initialize connection', error, stackTrace);
      } finally {
        if (_disposed) {
          // Manager was disposed while running connection attempt.
          connection?.close(goingAway, 'Client disposed');
          connectionCompleter.completeError(StateError('Client disposed'));
        } else if (connectionFuture != _pendingConnection) {
          connection?.close(normalClosure, 'Closing obsolete connection');
          if (_pendingConnection == null) {
            // stop() was called during connection attempt.
            connectionCompleter
                .completeError(StateError('Connection attempt aborted'));
          } else {
            // _startConnecting() was called during connection attempt, return the
            // new Future instead.
            connectionCompleter.complete(_pendingConnection);
          }
        } else if (connection != null) {
          // Correctly established connection.
          _logger.fine('Established WebSocket connection');
          _connectionAttempts = 0;
          connectionCompleter.complete(connection);
        }
      }
    }

    return connectionCompleter.future;
  }

  Future<_WebSocketConnection> _runConnectionAttempt(
    Duration delay,
  ) async {
    final attempt = _currentAttempt = SocketConnectionAttempt(delay: delay);
    if (_logger.isLoggable(Level.FINE)) {
      _logger.fine(() {
        final durationString = delay == Duration.zero
            ? 'now'
            : 'in ${delay.inMilliseconds} milliseconds';
        return 'Triggering attempt #$_connectionAttempts (id: ${attempt.idAsString}) to connect $durationString';
      });
    }

    await attempt.delayFuture;

    if (attempt != _currentAttempt) {
      throw StateError('Current attempt obsoleted while delaying');
    }

    try {
      final connection = await _WebSocketConnection.connect(
        _factory,
        callbacks: _ConnectionCallbacks(attempt: attempt, manager: this),
      );
      if (attempt == _currentAttempt) {
        return connection;
      } else {
        connection.close(normalClosure, 'Closing unnecessary connection');
        throw ConnectionInitializationException(
          'Current attempt obsoleted while delaying',
          StackTrace.current,
        );
      }
    } catch (error, stackTrace) {
      if (attempt == _currentAttempt) {
        _onError(error, stackTrace);
      }

      rethrow;
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

  final SocketConnectionAttempt attempt;
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

    switch (newState) {
      case WebSocketDisconnected():
        if (_logger.isLoggable(Level.FINE)) {
          _logger.fine(
            'Socket closed, ${!manager._shouldAttemptReconnection ? ' not ' : ''}attempting to reconnect',
          );
        }
        if (manager._shouldAttemptReconnection) {
          manager._connect();
        }
      case WebSocketConnected():
        manager._connectionAttempts = 0;
      case WebSocketDisconnecting():
      case WebSocketConnecting():
      // Do nothing.
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
          WebSocketDisconnected._(_ws.closeCode ?? 4000, _ws.closeReason),
        );
        acceptingMessages = false;
        subscription.cancel();
      },
    );

    _ws.sink.done.then(
      (_) {
        if (acceptingMessages) {
          acceptingMessages = false;
          onStateChange(const WebSocketDisconnecting._());
        }
      },
      onError: onError,
    );
  }

  final WebSocketChannel _ws;
  bool acceptingMessages = true;

  void send(dynamic message) {
    if (!acceptingMessages) {
      throw WebSocketChannelException(
        'Trying to send a message after WebSocket sink closed.',
      );
    }

    _ws.sink.add(message);
  }

  sendError(Object messageError, StackTrace? messageTrace) {
    if (!acceptingMessages) {
      throw WebSocketChannelException(
        'Trying to send a message after WebSocket sink closed.',
      );
    }
    _ws.sink.addError(messageError, messageTrace);
  }

  void close(int status, [String? reason]) {
    if (acceptingMessages) {
      acceptingMessages = false;
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
