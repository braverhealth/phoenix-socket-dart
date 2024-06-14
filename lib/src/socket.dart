import 'dart:async';
import 'dart:core';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:phoenix_socket/src/utils/iterable_extensions.dart';
import 'package:rxdart/rxdart.dart';
import 'package:web_socket_channel/status.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'channel.dart';
import 'events.dart';
import 'exceptions.dart';
import 'message.dart';
import 'push.dart';
import 'socket_options.dart';

part '_stream_router.dart';

/// State of a [PhoenixSocket].
enum SocketState {
  /// The connection is closed
  closed,

  /// The connection is closing
  closing,

  /// The connection is opening
  connecting,

  /// The connection is established
  connected,

  /// Unknown state
  unknown,
}

final Logger _logger = Logger('phoenix_socket.socket');

final Random _random = Random();

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
      })  : _endpoint = endpoint,
        _socketState = SocketState.unknown,
        _webSocketChannelFactory = webSocketChannelFactory {
    _options = socketOptions ?? PhoenixSocketOptions();

    _reconnects = _options.reconnectDelays;

    _messageStream =
        _receiveStreamController.stream.map(_options.serializer.decode);

    _openStream =
        _stateStreamController.stream.whereType<PhoenixSocketOpenEvent>();

    _closeStream =
        _stateStreamController.stream.whereType<PhoenixSocketCloseEvent>();

    _errorStream =
        _stateStreamController.stream.whereType<PhoenixSocketErrorEvent>();

    _subscriptions = [
      _messageStream.listen(_onMessage),
      _openStream.listen((_) => _startHeartbeat()),
      _closeStream.listen((_) => _cancelHeartbeat())
    ];
  }

  final Map<String, Completer<Message>> _pendingMessages = {};
  final Map<String, Stream<Message>> _topicStreams = {};

  final BehaviorSubject<PhoenixSocketEvent> _stateStreamController =
  BehaviorSubject();
  final StreamController<String> _receiveStreamController =
  StreamController.broadcast();
  final String _endpoint;
  final StreamController<Message> _topicMessages = StreamController();
  final WebSocketChannel Function(Uri uri)? _webSocketChannelFactory;

  late Uri _mountPoint;

  late Stream<PhoenixSocketOpenEvent> _openStream;
  late Stream<PhoenixSocketCloseEvent> _closeStream;
  late Stream<PhoenixSocketErrorEvent> _errorStream;
  late Stream<Message> _messageStream;

  SocketState _socketState;

  WebSocketChannel? _ws;

  _StreamRouter<Message>? _router;

  /// Stream of [PhoenixSocketOpenEvent] being produced whenever
  /// the connection is open.
  Stream<PhoenixSocketOpenEvent> get openStream => _openStream;

  /// Stream of [PhoenixSocketCloseEvent] being produced whenever
  /// the connection closes.
  Stream<PhoenixSocketCloseEvent> get closeStream => _closeStream;

  /// Stream of [PhoenixSocketErrorEvent] being produced in
  /// the lifetime of the [PhoenixSocket].
  Stream<PhoenixSocketErrorEvent> get errorStream => _errorStream;

  /// Stream of all [Message] instances received.
  Stream<Message> get messageStream => _messageStream;

  /// Reconnection durations, increasing in length.
  late List<Duration> _reconnects;

  List<StreamSubscription> _subscriptions = [];

  int _ref = 0;
  String? _nextHeartbeatRef;
  Timer? _heartbeatTimeout;

  /// A property yielding unique message reference ids,
  /// monotonically increasing.
  String get nextRef => '${_ref++}';

  int _reconnectAttempts = 0;

  bool _shouldReconnect = true;
  bool _reconnecting = false;

  /// [Map] of topic names to [PhoenixChannel] instances being
  /// maintained and tracked by the socket.
  Map<String, PhoenixChannel> channels = {};

  late PhoenixSocketOptions _options;

  /// Default duration for a connection timeout.
  Duration get defaultTimeout => _options.timeout;

  bool _disposed = false;

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

  /// The [Uri] containing all the parameters and options for the
  /// remote connection to occue.
  Uri get mountPoint => _mountPoint;

  /// Whether the underlying socket is connected of not.
  bool get isConnected => _ws != null && _socketState == SocketState.connected;

  void _connect(Completer<PhoenixSocket?> completer) async {
    if (_ws != null &&
        (_socketState == SocketState.connected ||
            _socketState == SocketState.connecting)) {
      _logger.warning(
          'Calling connect() on already connected or connecting socket.');
      completer.complete(this);
      return;
    }

    _shouldReconnect = true;

    if (_disposed) {
      throw StateError('PhoenixSocket cannot connect after being disposed.');
    }

    _mountPoint = await _buildMountPoint(_endpoint, _options);

    // workaround to check the existing bearer token
    final token = _mountPoint.queryParameters["token"];

    if(token != null && token.length > 1) {
      _logger.finest(() => 'Attempting to connect to $_mountPoint');

      try {
        _ws = _webSocketChannelFactory != null
            ? _webSocketChannelFactory!(_mountPoint)
            : WebSocketChannel.connect(_mountPoint);

        _ws!.stream
            .where(_shouldPipeMessage)
            .listen(_onSocketData, cancelOnError: true)
          ..onError(_onSocketError)
          ..onDone(_onSocketClosed);
      } catch (error, stacktrace) {
        _onSocketError(error, stacktrace);
      }

      _reconnectAttempts++;
      _socketState = SocketState.connecting;

      try {
        // Wait for the WebSocket to be ready before continuing. In case of a
        // failure to connect, the future will complete with an error and will be
        // caught.
        await _ws!.ready;

        _socketState = SocketState.connected;

        _logger.finest('Waiting for initial heartbeat roundtrip');
        if (await _sendHeartbeat(ignorePreviousHeartbeat: true)) {
          _stateStreamController.add(PhoenixSocketOpenEvent());
          _logger.info('Socket open');
          completer.complete(this);
        } else {
          throw PhoenixException();
        } // else
      } catch (err, stackTrace) {
        _logger.severe('Raised Exception', err, stackTrace);

        _ws = null;
        _socketState = SocketState.closed;

        completer.complete(_delayedReconnect());
      } // catch
    } // if
    else {
      // without a bearer token we don't do anything and start the retry loop
      _logger.severe('Invalid bearer token: "$token"');
      _ws = null;
      _socketState = SocketState.closed;
      _reconnectAttempts++;
      completer.complete(_delayedReconnect());
    } // else
  }

  /// Attempts to make a WebSocket connection to the Phoenix backend.
  ///
  /// If the attempt fails, retries will be triggered at intervals specified
  /// by retryAfterIntervalMS
  Future<PhoenixSocket?> connect() async {
    final completer = Completer<PhoenixSocket?>();
    runZonedGuarded(
      () => _connect(completer),
      (error, stack) {},
    );
    return completer.future;
  }

  /// Close the underlying connection supporting the socket.
  void close([
    int? code,
    String? reason,
    reconnect = false,
  ]) {
    _shouldReconnect = reconnect;
    if (isConnected) {
      // _ws != null and state is connected
      _socketState = SocketState.closing;
      _closeSink(code, reason);
    } else if (!_shouldReconnect) {
      dispose();
    }
  }

  /// Dispose of the socket.
  ///
  /// Don't forget to call this at the end of the lifetime of
  /// a socket.
  void dispose() {
    _shouldReconnect = false;
    if (_disposed) return;

    _disposed = true;
    _ws?.sink.close();

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

  /// Send a channel on the socket.
  ///
  /// Used internall to send prepared message. If you need to send
  /// a message on a channel, you would usually use [PhoenixChannel.push]
  /// instead.
  Future<Message> sendMessage(Message message) {
    if (_ws?.sink == null) {
      return Future.error(PhoenixException(
        socketClosed: PhoenixSocketCloseEvent(),
      ));
    }
    if (message.ref == null) {
      throw ArgumentError.value(
        message,
        'message',
        'does not contain a ref',
      );
    }
    _addToSink(_options.serializer.encode(message));
    return (_pendingMessages[message.ref!] = Completer<Message>()).future;
  }

  void _addToSink(String data) {
    if (_disposed) {
      return;
    }
    _ws!.sink.add(data);
  }

  void _closeSink([int? code, String? reason]) {
    if (_disposed || _ws == null) {
      return;
    }
    _ws!.sink.close(code, reason);
  }

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

  /// Processing incoming data from the socket
  ///
  /// Used to define a custom message type for proper data decoding
  onSocketDataCallback(message) {
    if (message is String) {
      if (!_receiveStreamController.isClosed) {
        _receiveStreamController.add(message);
      }
    } else {
      throw ArgumentError('Received a non-string');
    }
  }

  bool _shouldPipeMessage(dynamic event) {
    if (event is WebSocketChannelException) {
      return true;
    } else if (_socketState != SocketState.closed) {
      return true;
    } else {
      _logger.warning(
        'Message from socket dropped because PhoenixSocket is closed',
        '  $event',
      );
      return false;
    }
  }

  static Future<Uri> _buildMountPoint(
      String endpoint, PhoenixSocketOptions options) async {
    var decodedUri = Uri.parse(endpoint);
    final params = await options.getParams();
    final queryParams = decodedUri.queryParameters.entries.toList()
      ..addAll(params.entries.toList());
    return decodedUri.replace(
      queryParameters: Map.fromEntries(queryParams),
    );
  }

  void _startHeartbeat() {
    _reconnectAttempts = 0;
    _heartbeatTimeout ??= Timer.periodic(
      _options.heartbeat,
      (_) => _sendHeartbeat(),
    );
  }

  void _cancelHeartbeat() {
    _heartbeatTimeout?.cancel();
    _heartbeatTimeout = null;
  }

  Future<bool> _sendHeartbeat({bool ignorePreviousHeartbeat = false}) async {
    if (!isConnected) return false;

    if (_nextHeartbeatRef != null && !ignorePreviousHeartbeat) {
      _nextHeartbeatRef = null;
      if (_ws != null) {
        _closeSink(normalClosure, 'heartbeat timeout');
      }
      return false;
    }

    try {
      await sendMessage(_heartbeatMessage());
      _logger.fine('[phoenix_socket] Heartbeat completed');
      return true;
    } on WebSocketChannelException catch (err, stacktrace) {
      _logger.severe(
        '[phoenix_socket] Heartbeat message failed: WebSocketChannelException',
        err,
        stacktrace,
      );
      _triggerChannelExceptions(PhoenixException(
        socketError: PhoenixSocketErrorEvent(
          error: err,
          stacktrace: stacktrace,
        ),
      ));

      return false;
    } catch (err, stacktrace) {
      _logger.severe(
        '[phoenix_socket] Heartbeat message failed',
        err,
        stacktrace,
      );

      return false;
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

  Message _heartbeatMessage() => Message.heartbeat(_nextHeartbeatRef = nextRef);

  void _onMessage(Message message) {
    if (message.ref != null) {
      if (_nextHeartbeatRef == message.ref) {
        _nextHeartbeatRef = null;
      }

      final completer = _pendingMessages[message.ref!];
      if (completer != null) {
        _pendingMessages.remove(message.ref);
        completer.complete(message);
      }
    }

    if (message.topic != null && message.topic!.isNotEmpty) {
      _topicMessages.add(message);
    }
  }

  void _onSocketData(message) => onSocketDataCallback(message);

  void _onSocketError(dynamic error, dynamic stacktrace) {
    final socketError = PhoenixSocketErrorEvent(
      error: error,
      stacktrace: stacktrace,
    );

    if (!_stateStreamController.isClosed) {
      _stateStreamController.add(socketError);
    }

    for (final completer in _pendingMessages.values) {
      completer.completeError(error, stacktrace);
    }

    _logger.severe('Error on socket', error, stacktrace);
    _triggerChannelExceptions(PhoenixException(socketError: socketError));
    _pendingMessages.clear();

    _onSocketClosed();
  }

  void _onSocketClosed() {
    if (_shouldReconnect) {
      _delayedReconnect();
    }

    if (_socketState == SocketState.closed) {
      return;
    }

    final ev = PhoenixSocketCloseEvent(
      reason: _ws?.closeReason ?? 'WebSocket could not establish a connection',
      code: _ws?.closeCode,
    );
    final exc = PhoenixException(socketClosed: ev);
    _ws = null;

    if (!_stateStreamController.isClosed) {
      _stateStreamController.add(ev);
    }

    if (_socketState == SocketState.closing) {
      if (!_shouldReconnect) {
        dispose();
      }
      return;
    } else {
      _logger.info(
            () => 'Socket closed with reason ${ev.reason} and code ${ev.code}',
      );
      _triggerChannelExceptions(exc);
    }
    _socketState = SocketState.closed;

    for (final completer in _pendingMessages.values) {
      completer.completeError(exc);
    }
    _pendingMessages.clear();
  }

  Future<PhoenixSocket?> _delayedReconnect() async {
    if (_reconnecting) return null;

    _reconnecting = true;
    await Future.delayed(_reconnectDelay());

    if (!_disposed) {
      _reconnecting = false;
      return connect();
    }

    return null;
  }

  Duration _reconnectDelay() {
    final durationIdx = _reconnectAttempts;
    Duration duration;
    if (durationIdx >= _reconnects.length) {
      duration = _reconnects.last;
    } else {
      duration = _reconnects[durationIdx];
    }

    print("Reconnection: ${duration}");
    // Some random number to prevent many clients from retrying to
    // connect at exactly the same time.
    return duration + Duration(milliseconds: _random.nextInt(1000));
  }
}
