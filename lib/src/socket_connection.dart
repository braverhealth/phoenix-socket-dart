import 'dart:async';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket/src/socket_connection_attempt.dart';
import 'package:web_socket_channel/status.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

part 'socket_state.dart';

typedef WebSocketChannelFactory = Future<WebSocketChannel> Function();

final _logger = Logger('phoenix_socket.connection');

final _random = Random();

class SocketConnectionManager {
  SocketConnectionManager({
    required this.endpoint,
    required this.factory,
    required this.reconnectDelays,
    required this.onMessage,
    required this.onStateChange,
    required this.onError,
  });

  final String endpoint;
  final WebSocketChannelFactory factory;
  final List<Duration> reconnectDelays;
  final void Function(String message) onMessage;
  final void Function(WebSocketConnectionState state) onStateChange;
  final void Function(Object error, [StackTrace? stacktrace]) onError;

  Future<_WsConnection>? _pendingConnection;

  bool _disposed = false;
  int _connectionAttempts = 0;

  SocketConnectionAttempt _currentAttempt = SocketConnectionAttempt.aborted();

  SocketConnectionAttempt _setNewAttempt(Duration delay) {
    return _currentAttempt = SocketConnectionAttempt(delay: delay);
  }

  /// Requests to start connecting to the socket.
  ///
  /// Has no effect if the connection is already established.
  void start({bool immediately = false}) {
    if (_disposed) {
      throw StateError('Cannot start: WebSocket connection manager disposed');
    }

    if (immediately) {
      if (_pendingConnection != null && !_currentAttempt.done) {
        _currentAttempt.completeNow();
        return;
      }

      _stopConnecting(4002, 'Immediate connection requested');
      _connectionAttempts = 0;
    }
    _connect();
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
    return _connect().then((connection) => connection.send(message));
  }

  void stop(int code, [String? reason]) {
    _logger.fine('Stopping connecting attempts');
    if (_disposed) {
      throw StateError('Cannot stop: WebSocket connection manager disposed');
    }
    _stopConnecting(code, reason);
  }

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
    if (!_currentAttempt.done) {
      _currentAttempt.abort();
    }
    _currentAttempt = SocketConnectionAttempt.aborted();

    currentConnection?.then((connection) {
      connection.close(code, reason);
    }).ignore();
  }

  Future<_WsConnection> _connect() async {
    if (_disposed) {
      throw StateError('Cannot connect: WebSocket connection manager disposed');
    }

    final pendingConnection = _pendingConnection ??=
        _attemptConnection(_reconnectDelay(exact: _connectionAttempts == 0));
    final connection = await pendingConnection;
    if (_disposed) {
      throw StateError('Cannot connect: WebSocket connection manager disposed');
    } else if (_pendingConnection != pendingConnection) {
      // Something changed while waiting, try again from the start.
      _logger.warning('Connection changed while connecting');
      connection.close(normalClosure, 'New connection is being established');
      return _connect();
    } else {
      return connection;
    }
  }

  /// Returns a future that completes with a _WsConnection.
  ///
  /// If [completer] is null, then a new connection attempt will replace
  /// _pendingConnection.
  ///
  /// If [completer] is not null, then the returned future will be that
  /// completer's future.
  ///
  /// Can throw/complete with an exception if:
  /// - during any asynchronous operation, this [SocketConnectionManager] is
  ///   disposed.
  /// - during any asynchronous operation, the [_pendingConnection] is set to
  ///   null, which is interpreted as a prompt to abort connecting.
  ///
  /// The [onError] callback can be invoked with an instance of
  /// [ConnectionInitializationException] in case the initialization of
  /// connection fails. However, the reconnection will be triggered until it is
  /// established, or interrupted by call to [stop] or [dispose].
  Future<_WsConnection> _attemptConnection(Duration delayDuration,
      [Completer<_WsConnection>? completer]) async {
    _connectionAttempts++;

    final Completer<_WsConnection> connectionCompleter;
    if (completer == null) {
      connectionCompleter = Completer<_WsConnection>();
      _pendingConnection = connectionCompleter.future;
    } else {
      connectionCompleter = completer;
    }

    final attempt = _setNewAttempt(delayDuration);
    if (_logger.isLoggable(Level.FINE)) {
      _logger.fine(() {
        final durationString = delayDuration == Duration.zero
            ? 'now'
            : 'in ${delayDuration.inMilliseconds} milliseconds';
        return 'Triggering attempt #$_connectionAttempts (ID=${attempt.idToString}) to connect $durationString';
      });
    }

    attempt.completionFuture
        .then(
          (_) =>
              _attemptConnectionWithCompleter(connectionCompleter, attempt.id),
        )
        .catchError(
          (error) => _logger.info(
            'Pending connection attempt ${attempt.idToString} aborted',
          ),
        );

    return connectionCompleter.future;
  }

  void _attemptConnectionWithCompleter(
    Completer<_WsConnection> connectionCompleter,
    int attemptId,
  ) async {
    if (_disposed) {
      connectionCompleter.completeError(StateError(
        'WebSocket connection manager disposed during connection delay',
      ));
      return;
    }

    if (attemptId != _currentAttempt.id) {
      // This would be odd, but I've seen enough.
      if (_pendingConnection != null) {
        _logger.warning('Pending connection updated while delaying');
        connectionCompleter.complete(_pendingConnection!);
        return;
      } else {
        // We probably don't want to connect anymore.
        connectionCompleter.completeError(
          StateError('Connection aborted'),
          StackTrace.current,
        );
        return;
      }
    }

    try {
      final connection = await _WsConnection.connect(
        factory,
        onMessage: onMessage,
        onError: onError,
        onStateChange: _onStateChange(attemptId),
      );
      if (attemptId == _currentAttempt.id) {
        connectionCompleter.complete(connection);
      } else {
        connection.close(normalClosure, 'Closing unnecessary connection');
      }
    } catch (error, stackTrace) {
      _logger.warning('Failed to initialize connection', error, stackTrace);

      onError(error, stackTrace);

      // Checks just as above.
      if (attemptId == _currentAttempt.id) {
        _attemptConnection(_reconnectDelay(), connectionCompleter);
      } else if (_pendingConnection != null) {
        _logger.warning(
          'Pending connection updated while waiting for initialization',
        );
        connectionCompleter.complete(_pendingConnection);
      } else {
        connectionCompleter.completeError(
          StateError('Connection aborted'),
          StackTrace.current,
        );
      }
    }
  }

  Duration _reconnectDelay({bool exact = false}) {
    final duration = reconnectDelays[
        _connectionAttempts.clamp(0, reconnectDelays.length - 1)];

    if (exact) {
      return duration;
    } else {
      // Some random number to prevent many clients from retrying to
      // connect at exactly the same time.
      return duration + Duration(milliseconds: _random.nextInt(1000));
    }
  }

  void Function(WebSocketConnectionState) _onStateChange(
      int connectionAttemptId) {
    final connectionIdString =
        connectionAttemptId.toRadixString(16).padLeft(8, '0');
    return (WebSocketConnectionState state) {
      _logger.info('State changed for connection $connectionIdString: $state');

      if (connectionAttemptId != _currentAttempt.id) {
        // This is no longer the active connection attempt.
        return;
      }

      switch (state) {
        case WebSocketClosed():
          _logger.info('Socket closed, ($_disposed), attempting to reconnect');
          if (!_disposed) {
            _attemptConnection(_reconnectDelay());
          }
        case WebSocketReady():
          _connectionAttempts = 0;
        case WebSocketClosing():
        case WebSocketInitializing():
        // Do nothing.
      }

      onStateChange(state);
    };
  }
}

class _WsConnection {
  static Future<_WsConnection> connect(
    WebSocketChannelFactory factory, {
    required void Function(String message) onMessage,
    required void Function(Object error, [StackTrace? stackTrace]) onError,
    required void Function(WebSocketConnectionState state) onStateChange,
  }) async {
    onStateChange(const WebSocketInitializing._());
    final WebSocketChannel ws;
    try {
      ws = await factory();
      await ws.ready;
    } catch (error, stackTrace) {
      throw ConnectionInitializationException(error, stackTrace);
    }

    onStateChange(const WebSocketReady._());

    WebSocketConnectionState lastState = const WebSocketReady._();

    void updateState(WebSocketConnectionState newState) {
      switch ((lastState, newState)) {
        case (final a, final b) when a == b:
          _logger.info('Attempt to change socket state to identical $newState');
        case (_, WebSocketInitializing()):
        case (WebSocketClosed(), _):
        case (WebSocketClosing(), final b) when b is! WebSocketClosed:
          _logger.warning(
            'Attempt to change socket state from $lastState to $newState',
          );
        case _:
          _logger.info('Changing socket state from $lastState to $newState');
          lastState = newState;
          onStateChange(newState);
      }
    }

    return _WsConnection._(
      ws,
      onMessage: onMessage,
      onError: onError,
      onStateChange: updateState,
    );
  }

  _WsConnection._(
    this._ws, {
    required void Function(String message) onMessage,
    required void Function(Object error, [StackTrace? stackTrace]) onError,
    required void Function(WebSocketConnectionState state) onStateChange,
  }) {
    late final StreamSubscription subscription;
    subscription = _ws.stream.listen(
      (event) =>
          event is String ? onMessage(event) : onError(PhoenixException()),
      onError: onError,
      onDone: () {
        onStateChange(
          WebSocketClosed._(_ws.closeCode ?? 4000, _ws.closeReason),
        );
        acceptingMessages = false;
        subscription.cancel();
      },
    );

    _ws.sink.done.then(
      (_) {
        if (acceptingMessages) {
          acceptingMessages = false;
          onStateChange(const WebSocketClosing._());
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
