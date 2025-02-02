import 'dart:collection';
import 'dart:core';

import 'package:logging/logging.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'connection_manager/connection_manager.dart';
import 'connection_manager/state.dart' show ConnectedState, DisconnectedState;
import 'events.dart';
import 'exceptions.dart';
import 'message.dart';
import 'pheonix_channel.dart';
import 'push.dart';
import 'socket_options.dart';
import 'stream_router.dart';

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
  }) : _connectionManager = ConnectionManager(
          serverUri: endpoint,
          webSocketChannelFactory: webSocketChannelFactory,
        ) {
    _options = socketOptions ?? PhoenixSocketOptions();

    _streamRouter =
        PhoenixStreamRouter<Message>(_connectionManager.topicStream);

    _connectionManager
      ..closeStream.listen((closeEvent) {
        _triggerChannelExceptions(
          SocketClosedError(
            message: 'Socket closed',
            socketClosed: closeEvent,
          ),
        );
      })
      ..errorStream.listen((errorEvent) {
        _triggerChannelExceptions(
          PhoenixException(
            message: 'An error occurred on the websocket',
            socketError: errorEvent,
          ),
        );
      });
  }

  final ConnectionManager _connectionManager;
  late final PhoenixStreamRouter<Message> _streamRouter;
  final Map<String, Stream<Message>> _topicStreams = {};

  /// Stream of [PhoenixSocketOpenEvent] being produced whenever
  /// the connection is open.
  Stream<PhoenixSocketOpenEvent> get openStream =>
      _connectionManager.openStream;

  /// Stream of [PhoenixSocketCloseEvent] being produced whenever
  /// the connection closes.
  Stream<PhoenixSocketCloseEvent> get closeStream =>
      _connectionManager.closeStream;

  /// Stream of [PhoenixSocketErrorEvent] being produced in
  /// the lifetime of the [PhoenixSocket].
  Stream<PhoenixSocketErrorEvent> get errorStream =>
      _connectionManager.errorStream;

  /// Stream of all [Message] instances received.
  Stream<Message> get messageStream => _connectionManager.messageStream;

  final Map<String, PhoenixChannel> _channels = {};

  /// [Map] of topic names to [PhoenixChannel] instances being
  /// maintained and tracked by the socket.
  UnmodifiableMapView<String, PhoenixChannel> get channels =>
      UnmodifiableMapView(_channels);

  late PhoenixSocketOptions _options;

  /// Default duration for a connection timeout.
  Duration get defaultTimeout => _options.timeout;

  /// A stream yielding [Message] instances for a given topic.
  ///
  /// The [PhoenixChannel] for this topic may not be open yet, it'll still
  /// eventually yield messages when the channel is open and it receives
  /// messages.
  Stream<Message> streamForTopic(String topic) => _topicStreams.putIfAbsent(
      topic, () => _streamRouter.route((event) => event.topic == topic));

  /// The string URL of the remote Phoenix server.
  String get endpoint => _connectionManager.endpoint;

  /// The [Uri] containing all the parameters and options for the
  /// remote connection to occur.
  Uri get mountPoint => _connectionManager.mountPoint;

  /// Whether the underlying socket is connected of not.
  bool get isConnected => _connectionManager.currentState is ConnectedState;
  bool get isDisonnected =>
      _connectionManager.currentState is DisconnectedState;

  String get nextRef => _connectionManager.nextRef;

  /// Attempts to make a WebSocket connection to the Phoenix backend.
  ///
  /// If the attempt fails, retries will be triggered at intervals specified
  /// by retryAfterIntervalMS
  Future<PhoenixSocket?> connect([PhoenixSocketOptions? newOptions]) async {
    if (newOptions != null) {
      _options = newOptions;
    }
    try {
      await _connectionManager.connect(_options);
      return this;
    } on SocketClosedError {
      return null;
    }
  }

  /// Close the underlying connection supporting the socket.
  void close([
    int? code,
    String? reason,
    bool reconnect = false,
  ]) {
    _connectionManager.close(
      code: code,
      reason: reason,
    );

    if (reconnect) {
      _connectionManager.connect(
        _options,
      );
    }
  }

  /// Dispose of the socket.
  ///
  /// Don't forget to call this at the end of the lifetime of
  /// a socket.
  void dispose() {
    if (_connectionManager.isDisposed()) {
      return;
    }

    _connectionManager.dispose();

    final disposedChannels = _channels.values.toList();
    _channels.clear();

    for (final channel in disposedChannels) {
      channel.leavePush?.trigger(PushResponse(status: 'ok'));
      channel.close();
    }
    _streamRouter.close();
    _topicStreams.clear();
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
    return _connectionManager.waitForMessage(message);
  }

  /// Send a channel on the socket.
  ///
  /// Used internally to send prepared message. If you need to send
  /// a message on a channel, you would usually use [PhoenixChannel.push]
  /// instead.
  void sendMessage(Message message) async {
    if (message.ref == null) {
      throw ArgumentError.value(
        message,
        'message',
        'does not contain a ref',
      );
    }

    _connectionManager.sendMessage(message);
  }

  /// [topic] is the name of the channel you wish to join
  /// [parameters] are any options parameters you wish to send
  PhoenixChannel addChannel({
    required String topic,
    Map<String, dynamic>? parameters,
    Duration? timeout,
  }) {
    PhoenixChannel? channel = _channels[topic];

    if (channel == null) {
      channel = PhoenixChannel.fromSocket(
        this,
        topic: topic,
        parameters: parameters,
        timeout: timeout ?? defaultTimeout,
      );

      _channels[channel.topic] = channel;
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
    if (_channels.remove(channel.topic) is PhoenixChannel) {
      _topicStreams.remove(channel.topic);
    }
  }

  void _triggerChannelExceptions(PhoenixException exception) {
    _logger.fine(
      () => 'Trigger channel exceptions on ${_channels.length} channels',
    );
    for (final channel in _channels.values) {
      _logger.finer(
        () => 'Trigger channel exceptions on ${channel.topic}',
      );
      if (exception.socketClosed != null ||
          exception.socketError != null ||
          exception is SocketClosedError) {
        channel.triggerError(
          ChannelClosedError(message: exception.toString()),
        );
      } else {
        channel.triggerError(exception);
      }
    }
  }
}
