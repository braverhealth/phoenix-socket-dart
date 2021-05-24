import 'package:meta/meta.dart';

import 'message_serializer.dart';

/// Options for the open Phoenix socket.
///
/// Provided durations are all in milliseconds.
@immutable
class PhoenixSocketOptions {
  /// Create a PhoenixSocketOptions
  PhoenixSocketOptions({
    /// The duration after which a connection attempt
    /// is considered failed
    Duration? timeout,

    /// The interval between heartbeat roundtrips
    Duration? heartbeat,

    /// The list of delays between reconnection attempts.
    ///
    /// The last duration will be repeated until it works.
    this.reconnectDelays = const [
      Duration(milliseconds: 0),
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
        serializer = serializer ?? MessageSerializer(),
        _heartbeat = heartbeat ?? const Duration(seconds: 30) {
    assert(!(params != null && dynamicParams != null),
        "Can't set both params and dynamicParams");
  }

  /// The serializer used to serialize and deserialize messages on
  /// applicable sockets.
  final MessageSerializer serializer;

  final Duration _timeout;
  final Duration _heartbeat;

  /// Duration after which a request is assumed to have timed out.
  Duration get timeout => _timeout;

  /// Duration between heartbeats
  Duration get heartbeat => _heartbeat;

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
    res['vsn'] = '2.0.0';
    return res;
  }
}
