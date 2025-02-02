import 'dart:math';

import 'message_serializer.dart';

/// Options for the open Phoenix socket.
///
/// Provided durations are all in milliseconds.
class PhoenixSocketOptions {
  /// Create a PhoenixSocketOptions
  const PhoenixSocketOptions({
    /// The duration after which a connection attempt
    /// is considered failed
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
    MessageSerializer? serializer,
  })  : _timeout = timeout ?? const Duration(seconds: 10),
        serializer = serializer ?? const MessageSerializer(),
        _heartbeat = heartbeat ?? const Duration(seconds: 30),
        _heartbeatTimeout = heartbeatTimeout ?? const Duration(seconds: 10),
        assert(!(params != null && dynamicParams != null),
            "Can't set both params and dynamicParams");

  /// The serializer used to serialize and deserialize messages on
  /// applicable sockets.
  final MessageSerializer serializer;
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

  Duration? getReconnectionDelay(int numberOfAttempts) => reconnectDelays[max(
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
