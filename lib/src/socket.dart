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
  }) : _endpoint = endpoint {
    _options = socketOptions ?? PhoenixSocketOptions();

    _messageStream =
        _receiveStreamController.stream.map(_options.serializer.decode);
    _openStream =
        _stateStreamController.stream.whereType<PhoenixSocketOpenEvent>();
    _closeStream =
        _stateStreamController.stream.whereType<PhoenixSocketCloseEvent>();
    _errorStream =
        _stateStreamController.stream.whereType<PhoenixSocketErrorEvent>();

    _connectionManager = SocketConnectionManager(
      endpoint: endpoint,
      factory: () async {
        final mountPoint = await _buildMountPoint(_endpoint, _options);
        return (webSocketChannelFactory ?? WebSocketChannel.connect)
            .call(mountPoint);
      },
      reconnectDelays: _options.reconnectDelays,
      onMessage: onSocketDataCallback,
      onError: (error, [stackTrace]) => _stateStreamController.add(
        PhoenixSocketErrorEvent(error: error, stacktrace: stackTrace),
      ),
      onStateChange: _socketStateStream.add,
    );

    _subscriptions = [
      _messageStream.listen(_onMessage),
      _openStream.listen((_) => _startHeartbeat()),
      _closeStream.listen(
        (event) => _onSocketClosed(code: event.code, reason: event.reason),
      ),
      _errorStream.listen(_onSocketError),
      _socketStateStream.listen(_onSocketStateChanged),
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

  final BehaviorSubject<PhoenixSocketEvent> _stateStreamController =
      BehaviorSubject();
  final StreamController<String> _receiveStreamController =
      StreamController.broadcast();
  final String _endpoint;
  final StreamController<Message> _topicMessages = StreamController();

  late Stream<PhoenixSocketOpenEvent> _openStream;
  late Stream<PhoenixSocketCloseEvent> _closeStream;
  late Stream<PhoenixSocketErrorEvent> _errorStream;
  late Stream<Message> _messageStream;

  final _socketStateStream = BehaviorSubject<PhoenixSocketState>();

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

  late PhoenixSocketOptions _options;

  /// Default duration for a connection timeout.
  Duration get defaultTimeout => _options.timeout;

  bool _disposed = false;

  late SocketConnectionManager _connectionManager;

  _StreamRouter<Message> get _streamRouter =>
      _router ??= _StreamRouter<Message>(_topicMessages.stream);

  /// A stream yielding [Message] instances for a given topic.
  ///
  /// The [PhoenixChannel] for this topic may not be open yet, it'll still
  /// eventually yield messages when the channel is open and it receives
  /// messages.
  Stream<Message> streamForTopic(String topic) => _topicStreams.putIfAbsent(
      topic, () => _streamRouter.route((event) => event.topic == topic));

  /// The string URL of the remote Phoenix server.
  String get endpoint => _endpoint;

  /// Whether the underlying socket is connected of not.
  bool get isConnected => _socketStateStream.valueOrNull is PhoenixSocketReady;

  bool get _isConnectingOrConnected => switch (_socketStateStream.valueOrNull) {
        PhoenixSocketInitializing() || PhoenixSocketReady() => true,
        _ => false,
      };

  /// CONNECTION

  Future<void> connect() async {
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
    } else if (_socketStateStream.valueOrNull is PhoenixSocketInitializing) {
      return _connectionManager.start();
    } else {
      return _reconnect(normalClosure); // Any code is a good code.
    }
  }

  /// Close the underlying connection supporting the socket.
  void close([
    int? code,
    String? reason,
    reconnect = false,
  ]) {
    if (reconnect) {
      _reconnect(code ?? normalClosure, reason);
    } else {
      _closeConnection(code ?? goingAway, reason);
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

    _stateStreamController.close();
    _receiveStreamController.close();
  }

  /// Wait for an expected message to arrive.
  ///
  /// Used internally when expecting a message like a heartbeat
  /// reply, a join reply, etc. If you need to wait for the
  /// reply of message you sent on a channel, you would usually
  /// use wait the returned [Push.future].
  Future<Message> waitForMessage(Message message) {
    if (message.ref == null) {
      throw ArgumentError.value(
        message,
        'message',
        'needs to contain a ref in order to be awaited for',
      );
    }
    final msg = _pendingMessages[message.ref!];
    if (msg != null) {
      return msg.future;
    }
    return Future.error(
      ArgumentError(
        "Message hasn't been sent using this socket.",
      ),
    );
  }

  Future<void> _reconnect(int code, [String? reason]) async {
    if (_disposed) {
      throw StateError('Cannot reconnect a disposed socket');
    }

    if (_socketStateStream.hasValue) {
      await _closeConnection(code, reason);
    }
    _connectionManager.start();
  }

  Future<void> _closeConnection(int code, [String? reason]) async {
    if (_disposed) {
      _logger.warning('Cannot close a disposed socket');
    }
    if (_isConnectingOrConnected) {
      _connectionManager.stop(code, reason);
    } else if (_socketStateStream.valueOrNull is! PhoenixSocketClosed) {
      await _socketStateStream
          .firstWhere((state) => state is PhoenixSocketClosed);
    }
  }

  /// MESSAGING

  /// Send a channel on the socket.
  ///
  /// Used internally to send prepared message. If you need to send
  /// a message on a channel, you would usually use [PhoenixChannel.push]
  /// instead.
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
    if (!isConnected) {
      throw StateError('Cannot start heartbeat while disconnected');
    }

    _cancelHeartbeat();
    _logger.fine('Cancelled heartbeat');

    _connectionManager.start();

    _logger.info('Socket connected, waiting for initial heartbeat round trip');
    final initialHearbeatSucceeded = await _sendHeartbeat();
    if (initialHearbeatSucceeded) {
      _logger.info('Socket open');
      _stateStreamController.add(PhoenixSocketOpenEvent());
    }
    // The "else" case is handled - if needed - by the catch clauses in
    // [_sendHeartbeat].
  }

  /// Returns a Future completing with true if the heartbeat message was sent,
  /// and the reply to it was received.
  Future<bool> _sendHeartbeat() async {
    if (!isConnected) return false;

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
      await sendMessage(heartbeatMessage);
      _logger.fine('Heartbeat ${heartbeatMessage.ref} sent');
      _latestHeartbeatRef = heartbeatMessage.ref;

      _heartbeatTimeout = _scheduleHeartbeat();

      await _pendingMessages[_latestHeartbeatRef]!.future;
      return true;
    } on WebSocketChannelException catch (error, stacktrace) {
      _logger.severe(
        'Heartbeat message failed: WebSocketChannelException',
        error,
        stacktrace,
      );
      _stateStreamController.add(
        PhoenixSocketErrorEvent(
          error: error,
          stacktrace: stacktrace,
        ),
      );

      return false;
    } catch (error, stacktrace) {
      _logger.severe('Heartbeat message failed', error, stacktrace);
      _onHeartbeatFailure();
      return false;
    }
  }

  Timer _scheduleHeartbeat() {
    return Timer(_options.heartbeat, () {
      if (_latestHeartbeatRef != null) {
        final completer = _pendingMessages.remove(_latestHeartbeatRef);
        if (completer != null && !completer.isCompleted) {
          completer.completeError(HeartbeatFailedException());
          _onHeartbeatFailure();
          return;
        }
      }

      _sendHeartbeat();
    });
  }

  void _onHeartbeatFailure() {
    _reconnect(4001, 'Heartbeat timeout');
  }

  void _cancelHeartbeat() {
    _heartbeatTimeout?.cancel();
    _heartbeatTimeout = null;
    if (_latestHeartbeatRef != null) {
      _pendingMessages.remove(_latestHeartbeatRef);
      _latestHeartbeatRef = null;
    }
  }

  bool _shouldPipeMessage(String message) {
    final currentSocketState = _socketStateStream.valueOrNull;
    if (currentSocketState is PhoenixSocketReady) {
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
      final completer = _pendingMessages.remove(message.ref!);
      if (completer != null) {
        completer.complete(message);
      }
      // The connection is alive, prevent hearbeat timeout from closing
      // connection.
      _latestHeartbeatRef = null;
    }

    if (message.topic != null && message.topic!.isNotEmpty) {
      _topicMessages.add(message);
    }
  }

  void _onSocketStateChanged(PhoenixSocketState state) {
    switch (state) {
      case PhoenixSocketReady():
        _stateStreamController.add(const PhoenixSocketOpenEvent());
      case PhoenixSocketClosing():
        _cancelHeartbeat();
      case PhoenixSocketClosed(:final code, :final reason):
        // Just in case we skipped the closing event.
        _cancelHeartbeat();
        _stateStreamController.add(
          PhoenixSocketCloseEvent(code: code, reason: reason),
        );
      case PhoenixSocketInitializing():
      // Good to know.
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
    _triggerChannelExceptions(PhoenixException(socketError: errorEvent));

    if (!_disposed) {
      _reconnect(protocolError, errorEvent.error?.toString());
    }
  }

  void _onSocketClosed({int? code, String? reason}) {
    if (_disposed) {
      return;
    }

    final closeEvent = PhoenixSocketCloseEvent(
      code: code,
      reason: reason ?? 'WebSocket closed without providing a reason',
    );

    if (!_stateStreamController.isClosed) {
      _stateStreamController.add(closeEvent);
    }

    final exception = PhoenixException(socketClosed: closeEvent);
    _logger.info(
      () =>
          'Socket closed with reason ${closeEvent.reason} and code ${closeEvent.code}',
    );
    _triggerChannelExceptions(exception);

    for (final completer in _pendingMessages.values) {
      completer.completeError(exception);
    }
    _pendingMessages.clear();
  }
}

final class HeartbeatFailedException implements Exception {}
