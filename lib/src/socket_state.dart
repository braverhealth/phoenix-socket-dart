part of 'socket_connection.dart';

sealed class PhoenixSocketState {
  const PhoenixSocketState._();

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  bool operator ==(Object other) {
    return runtimeType == other.runtimeType;
  }
}

final class PhoenixSocketInitializing extends PhoenixSocketState {
  const PhoenixSocketInitializing._() : super._();

  @override
  String toString() => 'PhoenixSocketInitializing';
}

final class PhoenixSocketReady extends PhoenixSocketState {
  const PhoenixSocketReady._() : super._();

  @override
  String toString() => 'PhoenixSocketReady';
}

final class PhoenixSocketClosing extends PhoenixSocketState {
  const PhoenixSocketClosing._() : super._();

  @override
  String toString() => 'PhoenixSocketClosing';
}

final class PhoenixSocketClosed extends PhoenixSocketState {
  PhoenixSocketClosed._(this.code, this.reason) : super._();

  final int code;
  final String? reason;

  @override
  String toString() => 'PhoenixSocketClosed($code, $reason)';

  @override
  int get hashCode => Object.hash(code, reason);

  @override
  bool operator ==(Object other) {
    return other is PhoenixSocketClosed &&
        other.code == code &&
        other.reason == reason &&
        other.runtimeType == runtimeType;
  }
}
