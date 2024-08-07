import 'dart:async';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:stack_trace/stack_trace.dart';
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
  final void Function(PhoenixSocketState state) onStateChange;
  final void Function(Object error, [StackTrace? stacktrace]) onError;

  Future<_WsConnection>? _pendingConnection;

  bool _disposed = false;
  int _connectionAttempts = 0;
  int _currentAttemptId = 0;

  void setNewAttemptId() {
    late int newId;
    do {
      newId = _random.nextInt(1 << 32);
    } while (newId == _currentAttemptId);
    _currentAttemptId = newId;
  }

  /// Requests to start connecting to the socket.
  ///
  /// Has no effect if the connection is already established.
  void start() => _connect();

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
    if (_disposed) {
      throw StateError('Cannot stop: WebSocket connection manager disposed');
    }
    _stopConnecting(code, reason);
  }

  void dispose(int code, [String? reason]) {
    if (_disposed) {
      _logger.info(
        'Cannot dispose: WebSocket connection manager already disposed',
      );
      return;
    }
    _disposed = true;
    _stopConnecting(code, reason);
  }

  void _stopConnecting(int code, String? reason) {
    final currentConnection = _pendingConnection;
    _pendingConnection = null;
    setNewAttemptId();
    currentConnection?.then((connection) {
      connection.close(code, reason);
    }).ignore();
  }

  Future<_WsConnection> _connect() async {
    if (_disposed) {
      throw StateError('Cannot connect: WebSocket connection manager disposed');
    }

    final pendingConnection =
        _pendingConnection ?? _attemptConnection(_reconnectDelay(exact: true));
    final connection = await pendingConnection;
    if (_disposed) {
      throw StateError(
        'Cannot connect: WebSocket connection manager disposed',
      );
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
      assert(_pendingConnection == completer.future);
      connectionCompleter = completer;
    }

    Future.delayed(
      delayDuration,
      () => _attemptConnectionWithCompleter(connectionCompleter),
    );

    return connectionCompleter.future;
  }

  void _attemptConnectionWithCompleter(
    Completer<_WsConnection> connectionCompleter,
  ) {
    if (_disposed) {
      connectionCompleter.completeError(StateError(
        'WebSocket connection manager disposed during connection delay',
      ));
      return;
    }

    if (_pendingConnection != connectionCompleter.future) {
      // This would be odd, but I don't trust myself that much.
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

    setNewAttemptId();
    _WsConnection.connect(
      factory,
      onMessage: onMessage,
      onError: onError,
      onStateChange: _onStateChange(_currentAttemptId),
    )
        .then(connectionCompleter.complete)
        // I just want a readable indentation
        .onError<Object>(
      (error, stackTrace) {
        _logger.warning('Failed to initialize connection', error, stackTrace);
        onError(error, stackTrace);

        // Checks just as above.
        if (_pendingConnection == connectionCompleter.future) {
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
      },
    );
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

  void Function(PhoenixSocketState) _onStateChange(int connectionAttemptId) {
    final connectionIdString =
        connectionAttemptId.toRadixString(16).padLeft(8, '0');
    return (PhoenixSocketState state) {
      _logger.info('State changed for connection $connectionIdString: $state');

      if (connectionAttemptId != _currentAttemptId) {
        // This is no longer the active connection attempt.
        return;
      }

      switch (state) {
        case PhoenixSocketClosed():
          if (!_disposed) {
            _attemptConnection(_reconnectDelay());
          }
        case PhoenixSocketReady():
          _connectionAttempts = 0;
        case PhoenixSocketClosing():
        case PhoenixSocketInitializing():
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
    required void Function(PhoenixSocketState state) onStateChange,
  }) async {
    onStateChange(const PhoenixSocketInitializing._());
    final WebSocketChannel ws = await Chain.capture(
      () async {
        final ws = await factory();
        await ws.ready;
        return ws;
      },
      onError: (error, chain) =>
          throw ConnectionInitializationException(error, chain.terse),
    );

    onStateChange(const PhoenixSocketReady._());

    PhoenixSocketState lastState = const PhoenixSocketReady._();

    void updateState(PhoenixSocketState newState) {
      switch ((lastState, newState)) {
        case (final a, final b) when a == b:
          _logger.info('Attempt to change socket state to identical $newState');
        case (_, PhoenixSocketInitializing()):
        case (PhoenixSocketClosed(), _):
        case (PhoenixSocketClosing(), final b) when b is! PhoenixSocketClosed:
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
    required void Function(PhoenixSocketState state) onStateChange,
  }) {
    late final StreamSubscription subscription;
    subscription = _ws.stream.listen(
      (event) =>
          event is String ? onMessage(event) : onError(PhoenixException()),
      onError: onError,
      onDone: () {
        onStateChange(
          PhoenixSocketClosed._(_ws.closeCode ?? 4000, _ws.closeReason),
        );
        acceptingMessages = false;
        subscription.cancel();
      },
    );

    _ws.sink.done.then(
      (_) {
        if (acceptingMessages) {
          acceptingMessages = false;
          onStateChange(const PhoenixSocketClosing._());
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
  ConnectionInitializationException(this.cause, this.chain);

  final Object cause;
  final Chain chain;

  @override
  String toString() {
    return 'WebSocket connection failed to initialize: $cause\n${chain.terse}';
  }
}
