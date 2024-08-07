part of 'socket_connection.dart';

/// Represents current logical state of the underlying WebSocket connection.
///
/// The flow of the states for a single connection attempt is:
/// Initializing → Ready → Closing → Closed
///
/// However, the state can change to Closed from any state.
///
/// A single WebSocket connection does not get re-initialized.
sealed class WebSocketConnectionState {
  const WebSocketConnectionState._();

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  bool operator ==(Object other) {
    return runtimeType == other.runtimeType;
  }
}

/// A connection attempt has started. This encompasses both local preparation of
/// initial connection, and waiting for connection to become ready.
final class WebSocketInitializing extends WebSocketConnectionState {
  const WebSocketInitializing._() : super._();

  @override
  String toString() => 'WebSocketInitializing';
}

/// WebSocket connection was established and accepts sending messages through it.
final class WebSocketReady extends WebSocketConnectionState {
  const WebSocketReady._() : super._();

  @override
  String toString() => 'WebSocketReady';
}

/// WebSocket connection has stopped accepting messages, and waits for final
/// server reply to the Close message.
final class WebSocketClosing extends WebSocketConnectionState {
  const WebSocketClosing._() : super._();

  @override
  String toString() => 'WebSocketClosing';
}

/// WebSocket connection does not accept nor provide messages, nor will in the
/// future. This also encompasses situations where WebSocket connection was not
/// established at all.
final class WebSocketClosed extends WebSocketConnectionState {
  WebSocketClosed._(this.code, this.reason) : super._();

  final int code;
  final String? reason;

  @override
  String toString() => 'WebSocketClosed($code, $reason)';

  @override
  int get hashCode => Object.hash(code, reason);

  @override
  bool operator ==(Object other) {
    return other is WebSocketClosed &&
        other.code == code &&
        other.reason == reason &&
        other.runtimeType == runtimeType;
  }
}
