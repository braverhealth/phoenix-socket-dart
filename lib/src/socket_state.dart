part of 'socket_connection.dart';

/// Represents current logical state of the underlying WebSocket connection.
///
/// The flow of the states for a single connection attempt is:
/// Connecting → Connected → Disconnecting → Disconnected
///
/// However, the state can change to Disconnected from any state.
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
final class WebSocketConnecting extends WebSocketConnectionState {
  const WebSocketConnecting._() : super._();

  @override
  String toString() => 'WebSocketConnecting';
}

/// WebSocket connection was established and accepts sending messages through it.
final class WebSocketConnected extends WebSocketConnectionState {
  const WebSocketConnected._() : super._();

  @override
  String toString() => 'WebSocketConnected';
}

/// WebSocket connection has stopped accepting messages, and waits for final
/// server reply to the Close message.
final class WebSocketDisconnecting extends WebSocketConnectionState {
  const WebSocketDisconnecting._() : super._();

  @override
  String toString() => 'WebSocketDisconnecting';
}

/// WebSocket connection does not accept nor provide messages, nor will in the
/// future. This also encompasses situations where WebSocket connection was not
/// established at all.
final class WebSocketDisconnected extends WebSocketConnectionState {
  WebSocketDisconnected._(this.code, this.reason) : super._();

  final int code;
  final String? reason;

  @override
  String toString() => 'WebSocketDisconnected($code, $reason)';

  @override
  int get hashCode => Object.hash(code, reason);

  @override
  bool operator ==(Object other) {
    return other is WebSocketDisconnected &&
        other.code == code &&
        other.reason == reason &&
        other.runtimeType == runtimeType;
  }
}
