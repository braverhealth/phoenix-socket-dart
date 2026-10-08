import 'dart:math';

import 'message_serializer.dart';
import 'message_codec.dart';
import 'transport/session_store.dart';
import 'transport/transport.dart';
import 'transport/websocket_stability_policy.dart';

/// Options for the open Phoenix socket.
///
/// Timing options use Dart's [Duration] type.
class PhoenixSocketOptions {
  /// Create a PhoenixSocketOptions
  const PhoenixSocketOptions({
    /// The duration after which a connection attempt
    /// is considered failed when timed transport fallback is disabled.
    Duration? timeout,

    /// The interval between heartbeat roundtrips
    Duration? heartbeat,

    /// The duration after which a heartbeat request
    /// is considered timed out
    Duration? heartbeatTimeout,
    this.maxReconnectionAttempts,

    /// The list of delays between reconnection attempts.
    ///
    /// The last duration will be repeated until it works.
    /// An empty list retries without a delay.
    this.reconnectDelays = const [
      Duration.zero,
      Duration(milliseconds: 1000),
      Duration(milliseconds: 2000),
      Duration(milliseconds: 4000),
      Duration(milliseconds: 8000),
      Duration(milliseconds: 16000),
      Duration(milliseconds: 32000),
    ],

    /// Parameters passed to the connection string as query string.
    ///
    /// Either this or [dynamicParams] can to be provided, but not both.
    this.params,

    /// A function that will be used lazily to retrieve parameters
    /// to pass to the connection string as query string.
    ///
    /// Either this or [params] car to be provided, but not both.
    this.dynamicParams,
    MessageCodec? serializer,
    this.transport = PhoenixSocketTransport.webSocket,
    this.longPollTimeout = const Duration(seconds: 20),
    this.longPollFallbackAfter,
    this.webSocketStability,
    this.sessionStorage,
    this.authToken,
    this.dynamicAuthToken,
  })  : _timeout = timeout ?? const Duration(seconds: 10),
        serializer = serializer ?? const MessageSerializer(),
        _heartbeat = heartbeat ?? const Duration(seconds: 30),
        _heartbeatTimeout = heartbeatTimeout ?? const Duration(seconds: 10),
        assert(!(params != null && dynamicParams != null),
            "Can't set both params and dynamicParams"),
        assert(!(authToken != null && dynamicAuthToken != null),
            "Can't set both authToken and dynamicAuthToken");

  /// The serializer used to serialize and deserialize messages on
  /// applicable sockets. As in Phoenix JavaScript, explicitly selecting long
  /// polling uses the default serializer; automatic fallback retains this codec.
  final MessageCodec serializer;

  /// WebSocket by default; select HTTP long polling explicitly if needed.
  final PhoenixSocketTransport transport;

  /// Maximum duration of each long-poll GET or POST. Zero selects the default
  /// 20 seconds, matching the reference Socket constructor.
  final Duration longPollTimeout;

  /// Optional WebSocket opening and health-check deadline before switching to
  /// long polling. This replaces the opening timeout while fallback is enabled.
  /// Null or zero disables fallback, matching Phoenix JavaScript.
  final Duration? longPollFallbackAfter;

  /// Optional fallback after repeated short-lived WebSocket connections, even
  /// when they answer their health probes. Can be used with or without timed
  /// opening fallback. Null preserves the reference client's retry behavior.
  final WebSocketStabilityPolicy? webSocketStability;

  /// Optional fallback history. Defaults to browser sessionStorage on the web
  /// and no persistent history on native platforms.
  final PhoenixSocketSessionStore? sessionStorage;

  /// Phoenix's optional auth token. Sent through the WebSocket subprotocol or
  /// the X-Phoenix-AuthToken header on long-poll GETs, as in the reference client.
  final String? authToken;

  /// Lazily refresh the auth token for each transport connection.
  final String Function()? dynamicAuthToken;
  final int? maxReconnectionAttempts;

  final Duration _timeout;
  final Duration _heartbeat;
  final Duration _heartbeatTimeout;

  /// Duration after which a request is assumed to have timed out.
  Duration get timeout => _timeout;

  /// Duration between heartbeats
  Duration get heartbeat => _heartbeat;

  /// Duration after which a heartbeat request is considered timed out.
  /// If the server does not respond to a heartbeat request within this
  /// duration, the connection is considered lost.
  Duration get heartbeatTimeout => _heartbeatTimeout;

  /// Optional list of Duration between reconnect attempts
  final List<Duration> reconnectDelays;

  /// Parameters sent to your Phoenix backend on connection.
  /// Use [dynamicParams] if your params are dynamic.
  final Map<String, String>? params;

  /// Will be called to get fresh params before each connection attempt.
  final Future<Map<String, String>> Function()? dynamicParams;

  /// Get connection params.
  Future<Map<String, String>> getParams() async {
    final res = dynamicParams != null ? await dynamicParams!() : params ?? {};
    return {
      ...res,
      'vsn': '2.0.0',
    };
  }

  Duration? getReconnectionDelay(int numberOfAttempts) =>
      reconnectDelays.isEmpty
          ? Duration.zero
          : reconnectDelays[max(
              0,
              min(
                numberOfAttempts,
                reconnectDelays.length - 1,
              ),
            )];

  bool shouldAttemptReconnection(int numberOfAttempts) =>
      maxReconnectionAttempts == null ||
      maxReconnectionAttempts! > numberOfAttempts;
}
