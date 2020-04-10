import 'package:equatable/equatable.dart';

class PhoenixSocketEvent {}

class PhoenixSocketOpenEvent extends PhoenixSocketEvent {}

class PhoenixSocketCloseEvent extends PhoenixSocketEvent {
  final String reason;
  final int code;

  PhoenixSocketCloseEvent({
    this.reason,
    this.code,
  });
}

class PhoenixSocketErrorEvent extends PhoenixSocketEvent {
  final dynamic error;
  final dynamic stacktrace;

  PhoenixSocketErrorEvent({
    this.error,
    this.stacktrace,
  });
}

/// Encapsulates constants used in the protocol over [PhoenixChannel].
class PhoenixChannelEvent extends Equatable {
  static const String __closeEventName = 'phx_close';
  static const String __errorEventName = 'phx_error';
  static const String __joinEventName = 'phx_join';
  static const String __replyEventName = 'phx_reply';
  static const String __leaveEventName = 'phx_leave';
  static const String __chanReplyEventName = 'chan_reply';

  final String value;

  PhoenixChannelEvent._(this.value);

  factory PhoenixChannelEvent.replyFor(String ref) =>
      PhoenixChannelEvent._('${__chanReplyEventName}_$ref');

  factory PhoenixChannelEvent.custom(name) => PhoenixChannelEvent._(name);

  /// Instantiates a PhoenixChannelEvent from
  /// one of the values used in the wire protocol.
  factory PhoenixChannelEvent(String value) {
    switch (value) {
      case __closeEventName:
        return close;
      case __errorEventName:
        return error;
      case __joinEventName:
        return join;
      case __replyEventName:
        return reply;
      case __leaveEventName:
        return leave;
      default:
        throw ArgumentError.value(value);
    }
  }

  static PhoenixChannelEvent close = PhoenixChannelEvent._(__closeEventName);

  static PhoenixChannelEvent error = PhoenixChannelEvent._(__errorEventName);

  static PhoenixChannelEvent join = PhoenixChannelEvent._(__joinEventName);

  static PhoenixChannelEvent reply = PhoenixChannelEvent._(__replyEventName);

  static PhoenixChannelEvent leave = PhoenixChannelEvent._(__leaveEventName);

  static PhoenixChannelEvent heartbeat = PhoenixChannelEvent._('heartbeat');

  static Set<PhoenixChannelEvent> _statuses;
  static Set<PhoenixChannelEvent> get statuses =>
      _statuses ??= {close, error, join, reply, leave};

  bool get isReply => value.startsWith(__chanReplyEventName);

  @override
  List<Object> get props => [value];

  @override
  bool get stringify => true;
}
