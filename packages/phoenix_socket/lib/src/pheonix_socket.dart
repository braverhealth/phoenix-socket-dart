import 'dart:collection';
import 'dart:core';

import 'package:http/http.dart' as http;
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
import 'transport/transport.dart';

/// Main class to use when wishing to establish a persistent connection
/// with a Phoenix backend using WebSockets or HTTP long polling.
class PhoenixSocket {
  /// Creates an instance of PhoenixSocket
  ///
  /// endpoint is the full url to which you wish to connect
  /// e.g. `ws://localhost:4000/socket/websocket`
  PhoenixSocket(
    /// The URL of the Phoenix server.
    String endpoint, {
    /// The options used when initiating and maintaining the
    /// connection.
    PhoenixSocketOptions? socketOptions,

    /// Logger name for this socket and its connection manager.
    String loggerName = 'phoenix_socket.socket',

    /// The factory to use to create the WebSocketChannel.
    WebSocketChannel Function(Uri uri)? webSocketChannelFactory,

    /// Creates a dedicated HTTP client for each long-poll session. The socket
    /// closes it when that session ends. Avoid clients that retry POSTs.
    http.Client Function()? httpClientFactory,
  })  : _logger = Logger(loggerName),
        _connectionManager = ConnectionManager(
          serverUri: endpoint,
          loggerName: '$loggerName.connection_manager',
          webSocketChannelFactory: webSocketChannelFactory,
          httpClientFactory: httpClientFactory,
        ) {
    _options = socketOptions ?? PhoenixSocketOptions();

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
            message: 'An error occurred on the connection',
            socketError: errorEvent,
          ),
        );
      });
  }

  final ConnectionManager _connectionManager;
  final Logger _logger;

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
  Stream<Message> streamForTopic(String topic) =>
      _connectionManager.topicStream.where((event) => event.topic == topic);

  /// The string URL of the remote Phoenix server.
  String get endpoint => _connectionManager.endpoint;

  /// The [Uri] containing all the parameters and options for the
  /// remote connection to occur.
  Uri get mountPoint => _connectionManager.mountPoint;

  /// The selected transport, including any automatic switch to long polling.
  PhoenixSocketTransport get transport => _connectionManager.transport;

  /// Whether the underlying socket is connected of not.
  bool get isConnected => _connectionManager.currentState is ConnectedState;
  bool get isDisonnected =>
      _connectionManager.currentState is DisconnectedState;

  String get nextRef => _connectionManager.nextRef;

  /// Attempts to connect to the Phoenix backend using the selected transport.
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
      // This void API has no caller to observe the reconnect future. Failures
      // are still reported by errorStream.
      _connectionManager.connect(_options).ignore();
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
  void sendMessage(Message message) {
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
    if (identical(_channels[channel.topic], channel)) {
      _channels.remove(channel.topic);
    }
  }

  void _triggerChannelExceptions(PhoenixException exception) {
    _logger.fine(
      () => 'Trigger channel exceptions on ${_channels.length} channels',
    );
    for (final channel in _channels.values.toList()) {
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
