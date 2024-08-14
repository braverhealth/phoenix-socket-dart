import 'dart:async';
import 'dart:core';

import 'package:logging/logging.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket/src/socket_connection.dart';
import 'package:phoenix_socket/src/utils/iterable_extensions.dart';
import 'package:rxdart/rxdart.dart';
import 'package:web_socket_channel/status.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

part '_stream_router.dart';

final Logger _logger = Logger('phoenix_socket.socket');

/// Main class to use when wishing to establish a persistent connection
/// with a Phoenix backend using WebSockets.
class PhoenixSocket {
  /// Creates an instance of PhoenixSocket
  ///
  /// endpoint is the full url to which you wish to connect
  /// e.g. `ws://localhost:4000/websocket/socket`
  PhoenixSocket(
    /// The URL of the Phoenix server.
    String endpoint, {
    /// The options used when initiating and maintaining the
    /// websocket connection.
    PhoenixSocketOptions? socketOptions,

    /// The factory to use to create the WebSocketChannel.
    WebSocketChannel Function(Uri uri)? webSocketChannelFactory,
  }) {
    _options = socketOptions ?? PhoenixSocketOptions();

    _messageStream =
        _receiveStreamController.stream.map(_options.serializer.decode);
    _openStream =
        _stateEventStreamController.stream.whereType<PhoenixSocketOpenEvent>();
    _closeStream =
        _stateEventStreamController.stream.whereType<PhoenixSocketCloseEvent>();
    _errorStream =
        _stateEventStreamController.stream.whereType<PhoenixSocketErrorEvent>();

    _connectionManager = SocketConnectionManager(
      factory: () async {
        final mountPoint = await _buildMountPoint(endpoint, _options);
        return (webSocketChannelFactory ?? WebSocketChannel.connect)
            .call(mountPoint);
      },
      reconnectDelays: _options.reconnectDelays,
      onMessage: onSocketDataCallback,
      onError: (error, [stackTrace]) => _stateEventStreamController.add(
        PhoenixSocketErrorEvent(error: error, stacktrace: stackTrace),
      ),
      onStateChange: _socketStateStream.add,
    );

    _subscriptions = [
      _messageStream.listen(_onMessage),
      _openStream.listen((_) => _isOpen = true),
      _closeStream.listen(_onSocketClosed),
      _errorStream.listen(_onSocketError),
      _socketStateStream.distinct().listen(_onSocketStateChanged),
    ];
  }

  static Future<Uri> _buildMountPoint(
    String endpoint,
    PhoenixSocketOptions options,
  ) async {
    var decodedUri = Uri.parse(endpoint);
    final params = await options.getParams();
    final queryParams = decodedUri.queryParameters.entries.toList()
      ..addAll(params.entries.toList());
    return decodedUri.replace(
      queryParameters: Map.fromEntries(queryParams),
    );
  }

  final Map<String, Completer<Message>> _pendingMessages = {};
  final Map<String, Stream<Message>> _topicStreams = {};

  final BehaviorSubject<PhoenixSocketEvent> _stateEventStreamController =
      BehaviorSubject();
  final StreamController<String> _receiveStreamController =
      StreamController.broadcast();
  final StreamController<Message> _topicMessages = StreamController();
  final BehaviorSubject<WebSocketConnectionState> _socketStateStream =
      BehaviorSubject();

  late Stream<PhoenixSocketOpenEvent> _openStream;
  late Stream<PhoenixSocketCloseEvent> _closeStream;
  late Stream<PhoenixSocketErrorEvent> _errorStream;
  late Stream<Message> _messageStream;
  late SocketConnectionManager _connectionManager;

  late PhoenixSocketOptions _options;

  /// Default duration for a connection timeout.
  Duration get defaultTimeout => _options.timeout;

  _StreamRouter<Message>? _router;

  /// Stream of [PhoenixSocketOpenEvent] being produced whenever
  /// the connection is open, that is when the initial heartbeat
  /// completes successfully.
  Stream<PhoenixSocketOpenEvent> get openStream => _openStream;

  /// Stream of [PhoenixSocketCloseEvent] being produced whenever
  /// the connection closes.
  Stream<PhoenixSocketCloseEvent> get closeStream => _closeStream;

  /// Stream of [PhoenixSocketErrorEvent] being produced in
  /// the lifetime of the [PhoenixSocket].
  Stream<PhoenixSocketErrorEvent> get errorStream => _errorStream;

  /// Stream of all [Message] instances received.
  Stream<Message> get messageStream => _messageStream;

  List<StreamSubscription> _subscriptions = [];

  int _ref = 0;

  /// A property yielding unique message reference ids,
  /// monotonically increasing.
  String get nextRef => '${_ref++}';

  Timer? _heartbeatTimeout;

  String? _latestHeartbeatRef;

  /// [Map] of topic names to [PhoenixChannel] instances being
  /// maintained and tracked by the socket.
  Map<String, PhoenixChannel> channels = {};

  bool _disposed = false;

  bool _isOpen = false;

  /// Whether the phoenix socket is ready to join channels. Note that this is
  /// not the same as the WebSocketReady state, but rather is set to true when
  /// both web socket is ready, and the first heartbeat reply has been received.
  bool get isConnected => _isOpen;

  bool get _isConnectingOrConnected => switch (_socketStateStream.valueOrNull) {
        WebSocketInitializing() || WebSocketReady() => true,
        _ => false,
      };

  _StreamRouter<Message> get _streamRouter =>
      _router ??= _StreamRouter<Message>(_topicMessages.stream);

  /// A stream yielding [Message] instances for a given topic.
  ///
  /// The [PhoenixChannel] for this topic may not be open yet, it'll still
  /// eventually yield messages when the channel is open and it receives
  /// messages.
  Stream<Message> streamForTopic(String topic) => _topicStreams.putIfAbsent(
      topic, () => _streamRouter.route((event) => event.topic == topic));

  // CONNECTION

  /// Connects to the underlying WebSocket and prepares this PhoenixSocket for
  /// connecting to channels.
  ///
  /// The returned future will complete as soon as the attempt to connect to a
  /// WebSocket is scheduled. If a WebSocket is connected or connecting, then
  /// it returns without any action.
  ///
  /// If [immediately] is set to `true`, then if a
  /// connection is not established, it will attempt to connect to a socket
  /// without delay.
  Future<void> connect({bool immediately = false}) async {
    if (_disposed) {
      throw StateError('PhoenixSocket cannot connect after being disposed.');
    }

    if (_isConnectingOrConnected) {
      _logger.warning(
        'Calling connect() on already connected or connecting socket.',
      );
    }

    if (isConnected) {
      return;
    } else if (!_socketStateStream.hasValue || _isConnectingOrConnected) {
      return _connectionManager.start(immediately: immediately);
    } else {
      return _reconnect(
        normalClosure, // Any code is a good code.
        immediately: immediately,
      );
    }
  }

  /// Close the underlying connection supporting the socket.
  void close([
    int? code,
    String? reason,
    reconnect = false,
  ]) {
    if (reconnect) {
      _reconnect(code ?? normalClosure, reason: reason);
    } else {
      _closeConnection(code ?? goingAway, reason: reason);
    }
  }

  /// Dispose of the socket.
  ///
  /// Don't forget to call this at the end of the lifetime of
  /// a socket.
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();

    _pendingMessages.clear();

    final disposedChannels = channels.values.toList();
    channels.clear();

    for (final channel in disposedChannels) {
      channel.leavePush?.trigger(PushResponse(status: 'ok'));
      channel.close();
    }

    _topicMessages.close();
    _topicStreams.clear();

    _stateEventStreamController.close();
    _receiveStreamController.close();
    _logger.info('Disposed of PhoenixSocket');
  }

  Future<void> _reconnect(
    int code, {
    String? reason,
    bool immediately = false,
  }) async {
    if (_disposed) {
      throw StateError('Cannot reconnect a disposed socket');
    }

    if (_socketStateStream.hasValue) {
      await _closeConnection(code, reason: reason);
    }
    _connectionManager.start(immediately: immediately);
  }

  Future<void> _closeConnection(int code, {String? reason}) async {
    if (_disposed) {
      _logger.warning('Cannot close a disposed socket');
    }
    if (_isConnectingOrConnected) {
      _connectionManager.stop(code, reason);
    } else if (_socketStateStream.valueOrNull is! WebSocketClosed) {
      await _socketStateStream.firstWhere((state) => state is WebSocketClosed);
    }
  }

  /// MESSAGING

  /// Send a channel on the socket.
  ///
  /// Used internally to send prepared message. If you need to send a message on
  /// a channel, you would usually use [PhoenixChannel.push] instead.
  ///
  /// Returns a future that completes when the reply for the sent message is
  /// received. If your flow awaits for the result of this future, add a timout
  /// to it so that you are not stuck in case that the reply is never received.
  Future<Message> sendMessage(Message message) {
    if (message.ref == null) {
      throw ArgumentError.value(
        message,
        'message',
        'does not contain a ref',
      );
    }
    _addToSink(_options.serializer.encode(message));
    if (message.event != PhoenixChannelEvent.heartbeat) {
      _cancelHeartbeat();
      _scheduleHeartbeat();
    }
    return (_pendingMessages[message.ref!] = Completer<Message>()).future;
  }

  void _addToSink(String data) {
    if (_disposed) {
      return;
    }
    _connectionManager.addMessage(data);
  }

  /// CHANNELS

  /// [topic] is the name of the channel you wish to join
  /// [parameters] are any options parameters you wish to send
  PhoenixChannel addChannel({
    required String topic,
    Map<String, dynamic>? parameters,
    Duration? timeout,
  }) {
    PhoenixChannel? channel = channels[topic];

    if (channel == null) {
      channel = PhoenixChannel.fromSocket(
        this,
        topic: topic,
        parameters: parameters,
        timeout: timeout ?? defaultTimeout,
      );

      channels[channel.topic] = channel;
      _logger.finer(() => 'Adding channel ${channel!.topic}');
    } else {
      _logger.finer(() => 'Reusing existing channel ${channel!.topic}');
    }
    return channel;
  }

  /// Stop managing and tracking a channel on this phoenix
  /// socket.
  ///
  /// Used internally by PhoenixChannel to remove itself after
  /// leaving the channel.
  void removeChannel(PhoenixChannel channel) {
    _logger.finer(() => 'Removing channel ${channel.topic}');
    if (channels.remove(channel.topic) is PhoenixChannel) {
      _topicStreams.remove(channel.topic);
    }
  }

  void _triggerChannelExceptions(PhoenixException exception) {
    _logger.fine(
      () => 'Trigger channel exceptions on ${channels.length} channels',
    );
    for (final channel in channels.values) {
      _logger.finer(
        () => 'Trigger channel exceptions on ${channel.topic}',
      );
      channel.triggerError(exception);
    }
  }

  /// HEARTBEAT

  Future<void> _startHeartbeat() async {
    if (_socketStateStream.valueOrNull is! WebSocketReady) {
      throw StateError('Cannot start heartbeat while disconnected');
    }

    _cancelHeartbeat(successfully: false);

    _logger.info('Waiting for initial heartbeat round trip');
    final initialHeartbeatSucceeded = await _sendHeartbeat(force: true);
    if (initialHeartbeatSucceeded) {
      _logger.info('Socket open');
      _stateEventStreamController.add(PhoenixSocketOpenEvent());
    }
    // The "else" case is handled - if needed - by the catch clauses in
    // [_sendHeartbeat].
  }

  /// Returns a Future completing with true if the heartbeat message was sent,
  /// and the reply to it was received.
  Future<bool> _sendHeartbeat({bool force = false}) async {
    if (!force && !isConnected) return false;

    if (_heartbeatTimeout != null) {
      if (_heartbeatTimeout!.isActive) {
        // Previous timeout is active, let it finish and schedule a heartbeat
        // itself, if successful.
        return false;
      }

      _cancelHeartbeat();
    }

    try {
      final heartbeatMessage = Message.heartbeat(nextRef);
      sendMessage(heartbeatMessage);
      _logger.fine('Heartbeat ${heartbeatMessage.ref} sent');
      final heartbeatRef = _latestHeartbeatRef = heartbeatMessage.ref!;

      _heartbeatTimeout = _scheduleHeartbeat(heartbeatRef);

      await _pendingMessages[heartbeatRef]!.future;
      _logger.fine('Heartbeat $heartbeatRef completed');
      return true;
    } on WebSocketChannelException catch (error, stackTrace) {
      _logger.warning(
        'Heartbeat message failed: WebSocketChannelException',
        error,
        stackTrace,
      );
      _stateEventStreamController.add(
        PhoenixSocketErrorEvent(
          error: error,
          stacktrace: stackTrace,
        ),
      );

      return false;
    } catch (error, stackTrace) {
      _logger.warning('Heartbeat message failed', error, stackTrace);
      _reconnect(4001, reason: 'Heartbeat timeout');
      return false;
    }
  }

  Timer _scheduleHeartbeat([String? previousHeartbeat]) {
    return Timer(_options.heartbeat, () {
      if (previousHeartbeat != null) {
        final completer = _pendingMessages.remove(previousHeartbeat);
        if (completer != null && !completer.isCompleted) {
          completer.completeError(
            TimeoutException(
              'Heartbeat $previousHeartbeat not completed before sending new one',
            ),
            StackTrace.current,
          );
          return;
        }
      }

      _sendHeartbeat();
    });
  }

  void _cancelHeartbeat({bool successfully = true}) {
    if (_heartbeatTimeout != null) {
      _heartbeatTimeout?.cancel();
      _heartbeatTimeout = null;
    }
    if (_latestHeartbeatRef != null) {
      final heartbeatCompleter = _pendingMessages.remove(_latestHeartbeatRef);
      if (successfully) {
        heartbeatCompleter?.complete(
          Message.heartbeat(_latestHeartbeatRef!), // doesn't matter
        );
      } else {
        heartbeatCompleter?.completeError('Heartbeat cancelled');
      }
      _latestHeartbeatRef = null;
    }
  }

  bool _shouldPipeMessage(String message) {
    final currentSocketState = _socketStateStream.valueOrNull;
    if (currentSocketState is WebSocketReady) {
      return true;
    } else {
      _logger.warning(
        'Message from socket dropped because PhoenixSocket is not ready (is $currentSocketState)'
        '\n$message',
      );

      return false;
    }
  }

  /// EVENT HANDLERS

  // Exists for testing only
  void onSocketDataCallback(String message) {
    if (_shouldPipeMessage(message)) {
      if (!_receiveStreamController.isClosed) {
        _receiveStreamController.add(message);
      }
    }
  }

  void _onMessage(Message message) {
    if (message.ref != null) {
      _logger.finer('Received message with ref ${message.ref}');
      final completer = _pendingMessages.remove(message.ref!);
      if (completer != null) {
        if (_logger.isLoggable(Level.FINEST)) {
          _logger.finest('Completed ref ${message.ref} with $message');
        }
        completer.complete(message);
      }

      if (message.ref != _latestHeartbeatRef) {
        // The connection is alive, prevent heartbeat timeout from closing
        // connection.
        _latestHeartbeatRef = null;
      }
    }

    if (message.topic != null && message.topic!.isNotEmpty) {
      _topicMessages.add(message);
    }
  }

  void _onSocketStateChanged(WebSocketConnectionState state) {
    if (state is! WebSocketReady) {
      _isOpen = false;
    }

    switch (state) {
      case WebSocketReady():
        _startHeartbeat();
      case WebSocketClosing():
        _cancelHeartbeat(successfully: false);

      case WebSocketClosed(:final code, :final reason):
        // Just in case we skipped the closing event.
        _cancelHeartbeat(successfully: false);

        _stateEventStreamController.add(
          PhoenixSocketCloseEvent(code: code, reason: reason),
        );
      case WebSocketInitializing():
    }
  }

  void _onSocketError(PhoenixSocketErrorEvent errorEvent) {
    for (final completer in _pendingMessages.values) {
      completer.completeError(
        errorEvent.error ?? 'Unknown error',
        errorEvent.stacktrace,
      );
    }
    _pendingMessages.clear();

    _logger.severe('Error on socket', errorEvent.error, errorEvent.stacktrace);

    if (_isOpen) {
      _triggerChannelExceptions(PhoenixException(socketError: errorEvent));
    }
  }

  void _onSocketClosed(PhoenixSocketCloseEvent closeEvent) {
    if (_disposed) {
      return;
    }

    final exception = PhoenixException(socketClosed: closeEvent);
    for (final completer in _pendingMessages.values) {
      completer.completeError(exception);
    }
    _pendingMessages.clear();

    _logger.fine(
      () =>
          'Socket closed with reason ${closeEvent.reason} and code ${closeEvent.code}',
    );
    _triggerChannelExceptions(exception);
  }
}
