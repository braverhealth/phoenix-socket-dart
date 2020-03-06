import 'dart:async';
import 'dart:core';
import 'dart:developer' as dev;

import 'package:pedantic/pedantic.dart';
import 'package:meta/meta.dart';
import 'package:web_socket_channel/status.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'channel.dart';
import 'message.dart';

/// Options for the open Phoenix socket.
///
/// Provided durations are all in milliseconds.
class PhoenixSocketOptions {
  PhoenixSocketOptions({
    Duration timeout,
    Duration heartbeat,
    this.reconnectDelays = const [],
    this.params,
  })  : _timeout = timeout ?? Duration(seconds: 10),
        _heartbeat = heartbeat ?? Duration(seconds: 30) {
    params ??= {};
    params['vsn'] = '2.0.0';
  }

  final Duration _timeout;
  final Duration _heartbeat;

  /// Duration after which a request is assumed to have timed out.
  Duration get timeout => _timeout;

  /// Duration between heartbeats
  Duration get heartbeat => _heartbeat;

  /// Optional list of Duration between reconnect attempts
  final List<Duration> reconnectDelays;

  /// Parameters sent to your Phoenix backend on connection.
  Map<String, String> params;
}

class PhoenixSubscription {
  PhoenixChannel channel;
  StreamSubscription subscription;

  PhoenixSubscription({
    this.channel,
    this.subscription,
  });

  void cancel() => subscription.cancel();
}

class SocketEvent {}

class OpenEvent extends SocketEvent {}

class CloseEvent extends SocketEvent {
  final String reason;
  final int code;

  CloseEvent({this.reason, this.code});
}

class SocketError extends SocketEvent {
  final dynamic error;
  final dynamic stacktrace;

  SocketError({
    this.error,
    this.stacktrace,
  });
}

enum SocketState {
  closed,
  closing,
  connecting,
  connected,
}

class PhoenixSocket {
  final Map<String, Completer<Message>> _pendingMessages = {};
  final Map<String, StreamController> _topicStreams = {};

  Uri _mountPoint;
  SocketState _socketState;

  WebSocketChannel _ws;

  Stream<OpenEvent> _openStream;
  Stream<CloseEvent> _closeStream;
  Stream<SocketError> _errorStream;
  Stream<Message> _messageStream;

  Stream<OpenEvent> get openStream => _openStream;
  Stream<CloseEvent> get closeStream => _closeStream;
  Stream<SocketError> get errorStream => _errorStream;
  Stream<Message> get messageStream => _messageStream;

  StreamController<SocketEvent> _stateStreamController;
  StreamController<String> _receiveStreamController;

  List<Duration> reconnects = [
    Duration(seconds: 1000),
    Duration(seconds: 2000),
    Duration(seconds: 5000),
    Duration(seconds: 10000),
    Duration(seconds: 15000),
  ];

  List<StreamSubscription> _subscriptions = [];

  int _ref = 0;
  String _nextHeartbeatRef;
  Timer _heartbeatTimeout;

  String get nextRef => '${_ref++}';
  int _reconnectAttempts = 0;

  Map<String, PhoenixChannel> channels = {};

  PhoenixSocketOptions _options;

  Duration get defaultTimeout => _options.timeout;

  /// Creates an instance of PhoenixSocket
  ///
  /// endpoint is the full url to which you wish to connect
  /// e.g. `ws://localhost:4000/websocket/socket`
  PhoenixSocket(
    String endpoint, {
    PhoenixSocketOptions socketOptions,
  }) {
    _options = socketOptions ?? PhoenixSocketOptions();
    _mountPoint = _buildMountPoint(endpoint, _options);

    _receiveStreamController = StreamController.broadcast();
    _stateStreamController = StreamController.broadcast();

    _messageStream =
        _receiveStreamController.stream.map(MessageSerializer.decode);

    _openStream = _stateStreamController.stream
        .where((event) => event is OpenEvent)
        .cast<OpenEvent>();

    _closeStream = _stateStreamController.stream
        .where((event) => event is CloseEvent)
        .cast<CloseEvent>();

    _errorStream = _stateStreamController.stream
        .where((event) => event is SocketError)
        .cast<SocketError>();

    _subscriptions = [
      _messageStream.listen(_onMessage),
      _openStream.listen((_) => _startHeartbeat()),
      _closeStream.listen((_) => _cancelHeartbeat())
    ];
  }

  Stream<Message> streamForTopic(String topic) {
    var controller =
        _topicStreams.putIfAbsent(topic, () => StreamController<Message>());
    return controller.stream;
  }

  StreamSink<Message> _sinkForTopic(String topic) {
    var controller =
        _topicStreams.putIfAbsent(topic, () => StreamController<Message>());
    return controller.sink;
  }

  Uri get mountPoint => _mountPoint;

  bool get isConnected => _socketState == SocketState.connected;

  /// Attempts to make a WebSocket connection to your backend
  ///
  /// If the attempt fails, retries will be triggered at intervals specified
  /// by retryAfterIntervalMS
  Future<PhoenixSocket> connect() async {
    if (_ws != null) {
      return this;
    }

    _ws = WebSocketChannel.connect(_mountPoint);
    _ws.stream.listen(_onSocketData, cancelOnError: true)
      ..onError(_onSocketError)
      ..onDone(_onSocketClosed);

    _socketState = SocketState.connecting;

    try {
      _socketState = SocketState.connected;
      _stateStreamController.add(OpenEvent());

      return this;
    } catch (err) {
      var durationIdx = _reconnectAttempts++;
      if (durationIdx >= reconnects.length) {
        rethrow;
      }
      _ws = null;
      var duration = reconnects[durationIdx];
      return Future.delayed(duration, () => connect());
    }
  }

  Future<PhoenixSocket> reconnect() async {
    await connect();
    return this;
  }

  void dispose([int code, String reason]) {
    _socketState = SocketState.closing;

    _subscriptions.forEach((sub) => sub.cancel());
    _subscriptions.clear();

    _pendingMessages.clear();

    channels.forEach((_, channel) => channel.dispose());
    channels.clear();

    _topicStreams.forEach((_, controller) => controller.close());
    _topicStreams.clear();

    _ws.sink.close(code, reason);
  }

  Future<Message> waitForMessage(Message message) {
    if (_pendingMessages.containsKey(message.ref)) {
      return _pendingMessages[message.ref].future;
    }
    return Future.error(
        ArgumentError("Message hasn't been sent using this socket."));
  }

  Future<Message> sendMessage(Message message) {
    _ws.sink.add(message.encode());
    _pendingMessages[message.ref] = Completer<Message>();
    return _pendingMessages[message.ref].future;
  }

  /// [topic] is the name of the channel you wish to join
  /// [parameters] are any options parameters you wish to send
  PhoenixChannel addChannel({
    @required String topic,
    Map<String, String> parameters,
    Duration timeout,
  }) {
    var channel = PhoenixChannel.fromSocket(
      this,
      topic: topic,
      parameters: parameters,
      timeout: timeout ?? defaultTimeout,
    );

    channels[channel.reference] = channel;
    return channel;
  }

  void removeChannel(PhoenixChannel channel) {
    channels.remove(channel.reference);
    channel.dispose();
  }

  static Uri _buildMountPoint(String endpoint, PhoenixSocketOptions options) {
    var decodedUri = Uri.parse(endpoint);
    if (options?.params != null) {
      var params = decodedUri.queryParameters.entries.toList();
      params.addAll(options.params.entries.toList());
      decodedUri = decodedUri.replace(queryParameters: Map.fromEntries(params));
    }
    return decodedUri;
  }

  void _startHeartbeat() {
    _reconnectAttempts = 0;
    _heartbeatTimeout ??= Timer.periodic(_options.heartbeat, _sendHeartbeat);
  }

  void _cancelHeartbeat() {
    _heartbeatTimeout.cancel();
    _heartbeatTimeout = null;
  }

  void _sendHeartbeat(Timer timer) async {
    if (!isConnected) return;
    if (_nextHeartbeatRef != null) {
      _nextHeartbeatRef = null;
      unawaited(_ws.sink.close(normalClosure, 'heartbeat timeout'));
      return;
    }
    try {
      await sendMessage(_heartbeatMessage());
    } catch (err, stacktrace) {
      dev.log(
        'Heartbeat message failed with error: $err',
        stackTrace: stacktrace,
      );
    }
  }

  void _triggerChannelErrors() {
    for (var channel in channels.values) {
      channel.triggerError();
    }
  }

  Message _heartbeatMessage() {
    _nextHeartbeatRef = nextRef;
    return Message.heartbeat(_nextHeartbeatRef);
  }

  void _onMessage(Message message) {
    if (_nextHeartbeatRef == message.ref) {
      _nextHeartbeatRef = null;
    }

    if (_pendingMessages.containsKey(message.ref)) {
      var completer = _pendingMessages[message.ref];
      _pendingMessages.remove(message.ref);
      completer.complete(message);
    }

    if (message.topic != null && message.topic.isNotEmpty) {
      _sinkForTopic(message.topic).add(message);
    }
  }

  void _onSocketData(message) {
    if (message is String) {
      _receiveStreamController?.add(message);
    } else {
      throw ArgumentError('Received a non-string');
    }
  }

  void _onSocketError(error, stacktrace) {
    if (_socketState == SocketState.closing ||
        _socketState == SocketState.closed) {
      return;
    }

    _stateStreamController
        ?.add(SocketError(error: error, stacktrace: stacktrace));

    for (var completer in _pendingMessages.values) {
      completer.completeError(error, stacktrace);
    }
    _triggerChannelErrors();
    _pendingMessages.clear();
  }

  void _onSocketClosed() {
    if (_socketState == SocketState.closed) {
      return;
    }

    var ev = CloseEvent(
      reason: _ws.closeReason,
      code: _ws.closeCode,
    );
    _ws = null;
    _stateStreamController?.add(ev);

    if (_socketState == SocketState.closing) {
      _receiveStreamController.close();
      _stateStreamController.close();
      _stateStreamController = null;
      _receiveStreamController = null;
      _socketState = SocketState.closed;
      return;
    } else {
      _triggerChannelErrors();
    }

    for (var completer in _pendingMessages.values) {
      completer.completeError(ev);
    }
    _pendingMessages.clear();
  }
}
