class PhoenixSocketEvent {}

class PhoenixSocketOpenEvent extends PhoenixSocketEvent {}

class PhoenixSocketCloseEvent extends PhoenixSocketEvent {
  final String reason;
  final int code;

  PhoenixSocketCloseEvent({this.reason, this.code});
}

class PhoenixSocketErrorEvent extends PhoenixSocketEvent {
  final dynamic error;
  final dynamic stacktrace;

  PhoenixSocketErrorEvent({
    this.error,
    this.stacktrace,
  });
}
