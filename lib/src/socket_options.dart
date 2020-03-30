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
