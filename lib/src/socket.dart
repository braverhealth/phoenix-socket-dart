import 'dart:async';
import 'dart:core';

import 'package:logging/logging.dart';

import 'package:rxdart/rxdart.dart';
import 'package:pedantic/pedantic.dart';
import 'package:meta/meta.dart';
import 'package:web_socket_channel/status.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'channel.dart';
import 'events.dart';
import 'exception.dart';
import 'message.dart';
import 'socket_options.dart';

enum SocketState {
  closed,
  closing,
  connecting,
  connected,
}

final Logger _logger = Logger('phoenix_socket.socket');

class PhoenixSocket {
  final Map<String, Completer<Message>> _pendingMessages = {};
  final Map<String, StreamController> _topicStreams = {};

  final BehaviorSubject<PhoenixSocketEvent> _stateStreamController =
      BehaviorSubject();
  final StreamController<String> _receiveStreamController =
      StreamController.broadcast();

  Uri _mountPoint;
  SocketState _socketState;

  WebSocketChannel _ws;

  Stream<PhoenixSocketOpenEvent> _openStream;
  Stream<PhoenixSocketCloseEvent> _closeStream;
  Stream<PhoenixSocketErrorEvent> _errorStream;
  Stream<Message> _messageStream;

  Stream<PhoenixSocketOpenEvent> get openStream => _openStream;
  Stream<PhoenixSocketCloseEvent> get closeStream => _closeStream;
  Stream<PhoenixSocketErrorEvent> get errorStream => _errorStream;
  Stream<Message> get messageStream => _messageStream;

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

  final Zone _zone;
  bool _disposed = false;

  /// Creates an instance of PhoenixSocket
  ///
  /// endpoint is the full url to which you wish to connect
  /// e.g. `ws://localhost:4000/websocket/socket`
  PhoenixSocket(
    String endpoint, {
    PhoenixSocketOptions socketOptions,
  }) : _zone = Zone.current.fork() {
    _options = socketOptions ?? PhoenixSocketOptions();
    _mountPoint = _buildMountPoint(endpoint, _options);

    _messageStream =
        _receiveStreamController.stream.map(MessageSerializer.decode);

    _openStream = _stateStreamController.stream
        .where((event) => event is PhoenixSocketOpenEvent)
        .cast<PhoenixSocketOpenEvent>();

    _closeStream = _stateStreamController.stream
        .where((event) => event is PhoenixSocketCloseEvent)
        .cast<PhoenixSocketCloseEvent>();

    _errorStream = _stateStreamController.stream
        .where((event) => event is PhoenixSocketErrorEvent)
        .cast<PhoenixSocketErrorEvent>();

    _subscriptions = [
      _messageStream.listen(_zone.bindUnaryCallback(_onMessage)),
      _openStream.listen(_zone.bindUnaryCallback((_) => _startHeartbeat())),
      _closeStream.listen(_zone.bindUnaryCallback((_) => _cancelHeartbeat()))
    ];
  }

  Stream<Message> streamForTopic(String topic) {
    final controller =
        _topicStreams.putIfAbsent(topic, () => StreamController<Message>());
    return controller.stream;
  }

  StreamSink<Message> _sinkForTopic(String topic) {
    final controller =
        _topicStreams.putIfAbsent(topic, () => StreamController<Message>());
    return controller.sink;
  }

  Uri get mountPoint => _mountPoint;

  bool get isConnected =>
      _ws is WebSocketChannel && _socketState == SocketState.connected;

  /// Attempts to make a WebSocket connection to your backend
  ///
  /// If the attempt fails, retries will be triggered at intervals specified
  /// by retryAfterIntervalMS
  Future<PhoenixSocket> connect() async {
    if (_ws != null) {
      return this;
    }

    if (_disposed) {
      throw StateError('PhoenixSocket cannot connect after being disposed.');
    }

    _logger.finest(() => 'Attempting to connect to $_mountPoint');

    var completer = Completer<PhoenixSocket>();

    // Run the heartbeat callback in our isolated zone.
    _zone.run(() {
      try {
        _ws = WebSocketChannel.connect(_mountPoint);
        _ws.stream
            .where(_zone.bindUnaryCallback(_shouldPipeMessage))
            .listen(_zone.bindUnaryCallback(_onSocketData), cancelOnError: true)
              ..onError(_zone.bindBinaryCallback(_onSocketError))
              ..onDone(_zone.bindCallback(_onSocketClosed));
      } catch (error, stacktrace) {
        _onSocketError(error, stacktrace);
      }

      _socketState = SocketState.connecting;

      try {
        _socketState = SocketState.connected;
        _logger.finest('Waiting for initial heartbeat roundtrip');
        _sendHeartbeat(_heartbeatTimeout).then(
          // Run the heartbeat callback in our isolated zone.
          _zone.bindUnaryCallback((_) {
            _stateStreamController.add(PhoenixSocketOpenEvent());
            _logger.info('Socket open');
            completer.complete(this);
          }),
        );
      } catch (err) {
        final durationIdx = _reconnectAttempts++;
        if (durationIdx >= reconnects.length) {
          rethrow;
        }
        _ws = null;
        _socketState = SocketState.closed;

        final duration = reconnects[durationIdx];

        completer.complete(Future.delayed(duration, connect));
      }
    });

    return completer.future;
  }

  void close([int code, String reason]) {
    _zone.run(() {
      if (isConnected) {
        _socketState = SocketState.closing;
        _ws.sink.close(code, reason);
      } else {
        dispose();
      }
    });
  }

  void dispose() {
    _zone.run(() {
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
        channel.close();
      }

      for (final stream in _topicStreams.values) {
        stream.close();
      }
      _topicStreams.clear();

      _stateStreamController.close();
      _receiveStreamController.close();
    });
  }

  Future<Message> waitForMessage(Message message) {
    if (_pendingMessages.containsKey(message.ref)) {
      return _pendingMessages[message.ref].future;
    }
    return Future.error(
      ArgumentError(
        "Message hasn't been sent using this socket.",
      ),
    );
  }

  Future<Message> sendMessage(Message message) {
    return _zone.run(() {
      if (_ws?.sink is! WebSocketSink) {
        return Future.error(PhoenixException(
          socketClosed: PhoenixSocketCloseEvent(),
        ));
      }
      _ws.sink.add(MessageSerializer.encode(message));
      _pendingMessages[message.ref] = Completer<Message>();
      return _pendingMessages[message.ref].future;
    });
  }

  /// [topic] is the name of the channel you wish to join
  /// [parameters] are any options parameters you wish to send
  PhoenixChannel addChannel({
    @required String topic,
    Map<String, String> parameters,
    Duration timeout,
  }) {
    return _zone.run(() {
      var channel;
      if (channels.isNotEmpty) {
        final foundChannels =
            channels.entries.where((element) => element.value.topic == topic);
        channel = foundChannels.isNotEmpty ? foundChannels.first : null;
      }

      if (channel is! PhoenixChannel) {
        channel = PhoenixChannel.fromSocket(
          this,
          topic: topic,
          parameters: parameters,
          timeout: timeout ?? defaultTimeout,
          zone: _zone,
        );

        channels[channel.reference] = channel;
        _logger.finer(() => 'Adding channel ${channel.topic}');
      } else {
        _logger.finer(() => 'Reusing existing channel ${channel.topic}');
      }
      return channel;
    });
  }

  void removeChannel(PhoenixChannel channel) {
    _zone.run(() {
      _logger.finer(() => 'Removing channel ${channel.topic}');
      if (channels.remove(channel.reference) is PhoenixChannel) {
        _topicStreams.remove(channel.topic);
      }
    });
  }

  bool _shouldPipeMessage(dynamic event) {
    if (event is WebSocketChannelException) {
      return true;
    } else if (_socketState != SocketState.closed) {
      return true;
    } else {
      _logger.warning(
        'Message from socket dropped because PhoenixSocket is closed',
      );
      _logger.warning('  $event');
      return false;
    }
  }

  static Uri _buildMountPoint(String endpoint, PhoenixSocketOptions options) {
    var decodedUri = Uri.parse(endpoint);
    if (options?.params != null) {
      final params = decodedUri.queryParameters.entries.toList();
      params.addAll(options.params.entries.toList());
      decodedUri = decodedUri.replace(queryParameters: Map.fromEntries(params));
    }
    return decodedUri;
  }

  void _startHeartbeat() {
    _reconnectAttempts = 0;
    _heartbeatTimeout ??= Timer.periodic(
      _options.heartbeat,
      _zone.bindUnaryCallback(_sendHeartbeat),
    );
  }

  void _cancelHeartbeat() {
    _heartbeatTimeout?.cancel();
    _heartbeatTimeout = null;
  }

  Future<void> _sendHeartbeat(Timer timer) async {
    if (!isConnected) return;
    if (_nextHeartbeatRef != null) {
      _nextHeartbeatRef = null;
      unawaited(_ws.sink.close(normalClosure, 'heartbeat timeout'));
      return;
    }
    try {
      await sendMessage(_heartbeatMessage());
      _logger.fine('[phoenix_socket] Heartbeat completed');
    } catch (err, stacktrace) {
      _logger.severe(
        '[phoenix_socket] Heartbeat message failed with error',
        err,
        stacktrace,
      );
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
    if (_nextHeartbeatRef == message.ref) {
      _nextHeartbeatRef = null;
    }

    if (_pendingMessages.containsKey(message.ref)) {
      final completer = _pendingMessages[message.ref];
      _pendingMessages.remove(message.ref);
      completer.complete(message);
    }

    if (message.topic != null && message.topic.isNotEmpty) {
      _sinkForTopic(message.topic).add(message);
    }
  }

  void _onSocketData(message) => (message is String)
      ? _receiveStreamController?.add(message)
      : throw ArgumentError('Received a non-string');

  void _onSocketError(dynamic error, dynamic stacktrace) {
    if (_socketState == SocketState.closing ||
        _socketState == SocketState.closed) {
      return;
    }
    final socketError =
        PhoenixSocketErrorEvent(error: error, stacktrace: stacktrace);
    _stateStreamController?.add(socketError);

    for (final completer in _pendingMessages.values) {
      completer.completeError(error, stacktrace);
    }
    _logger.severe('Error on socket', error, stacktrace);
    _triggerChannelExceptions(PhoenixException(socketError: socketError));
    _pendingMessages.clear();

    _onSocketClosed();
  }

  void _onSocketClosed() {
    if (_socketState == SocketState.closed) {
      return;
    }

    final ev = PhoenixSocketCloseEvent(
      reason: _ws.closeReason,
      code: _ws.closeCode,
    );
    _ws = null;
    _stateStreamController?.add(ev);

    if (_socketState == SocketState.closing) {
      dispose();
      return;
    } else {
      _logger.info(
        'Socket closed with reason ${ev.reason} and code ${ev.code}',
      );
      _triggerChannelExceptions(PhoenixException(socketClosed: ev));
    }
    _socketState = SocketState.closed;

    for (final completer in _pendingMessages.values) {
      completer.completeError(ev);
    }
    _pendingMessages.clear();
  }
}
