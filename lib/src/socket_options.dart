/// Options for the open Phoenix socket.
///
/// Provided durations are all in milliseconds.
class PhoenixSocketOptions {
  PhoenixSocketOptions({
    Duration timeout,
    Duration heartbeat,
    this.reconnectDelays = const [],
    this.params,
    this.dynamicParams,
  })  : _timeout = timeout ?? Duration(seconds: 10),
        _heartbeat = heartbeat ?? Duration(seconds: 30) {
    assert(!(params != null && dynamicParams != null),
        "Can't set both params and dynamicParams");
    params ??= {};
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
  /// Use [dynamicParams] if your params are dynamic.
  Map<String, String> params;

  /// Will be called to get fresh params before each connection attempt.
  Future<Map<String, String>> Function() dynamicParams;

  /// Get connection params.
  Future<Map<String, String>> getParams() async {
    var res = dynamicParams != null ? await dynamicParams() : params;
    res['vsn'] = '2.0.0';
    return res;
  }
}
