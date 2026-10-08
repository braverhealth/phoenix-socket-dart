/// Fall back to long polling when WebSocket repeatedly loses its connection.
///
/// A successful opening or heartbeat does not reset the failure count. The
/// connection must remain open for [minimumUptime] and have answered at least
/// one heartbeat or health probe on that connection.
/// Explicit client close/dispose starts a fresh failure budget.
class WebSocketStabilityPolicy {
  const WebSocketStabilityPolicy({
    this.maxUnstableConnections = 3,
    this.minimumUptime = const Duration(seconds: 30),
  }) : assert(maxUnstableConnections > 0);

  /// Number of consecutive unstable connection losses before selecting HTTP.
  final int maxUnstableConnections;

  /// Positive duration for which an opened WebSocket must remain connected
  /// before its successful heartbeat can reset the failure budget.
  final Duration minimumUptime;
}
