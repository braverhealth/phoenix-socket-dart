import 'channel.dart';
import 'socket.dart';

/// Base socket event
abstract class PhoenixSocketEvent {
  const PhoenixSocketEvent();
}

/// Open event for a [PhoenixSocket].
class PhoenixSocketOpenEvent extends PhoenixSocketEvent {
  const PhoenixSocketOpenEvent();
}

/// Close event for a [PhoenixSocket].
class PhoenixSocketCloseEvent extends PhoenixSocketEvent {
  /// Default constructor for this close event.
  const PhoenixSocketCloseEvent({
    this.reason,
    this.code,
  });

  /// The reason the socket was closed.
  final String? reason;

  /// The code of the socket close.
  final int? code;

  @override
  bool operator ==(Object other) =>
      other is PhoenixSocketCloseEvent &&
      other.reason == reason &&
      other.code == code;

  @override
  int get hashCode => Object.hash(runtimeType, reason, code);

  @override
  String toString() => 'PhoenixSocketCloseEvent(reason: $reason, code: $code)';
}

/// Error event for a [PhoenixSocket].
class PhoenixSocketErrorEvent extends PhoenixSocketEvent {
  /// Default constructor for the error event.
  const PhoenixSocketErrorEvent({
    this.error,
    this.stacktrace,
  });

  /// The error that happened on the socket
  final Object? error;

  /// The stacktrace associated with the error.
  final dynamic stacktrace;

  @override
  bool operator ==(Object other) =>
      other is PhoenixSocketErrorEvent && other.error == error;

  @override
  int get hashCode => Object.hash(runtimeType, error);

  @override
  String toString() => 'PhoenixSocketErrorEvent(error: $error)';
}

/// Encapsulates constants used in the protocol over [PhoenixChannel].
class PhoenixChannelEvent {
  const PhoenixChannelEvent._(this.value);

  /// A reply event name for a given push ref value.
  factory PhoenixChannelEvent.replyFor(String ref) =>
      PhoenixChannelEvent._('${__chanReplyEventName}_$ref');

  /// A custom push event.
  ///
  /// This is the event name used when a user of the library sends a message
  /// on a channel.
  const PhoenixChannelEvent.custom(String name) : value = name;

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

  static const String __closeEventName = 'phx_close';
  static const String __errorEventName = 'phx_error';
  static const String __joinEventName = 'phx_join';
  static const String __replyEventName = 'phx_reply';
  static const String __leaveEventName = 'phx_leave';
  static const String __chanReplyEventName = 'chan_reply';

  /// The string value for a channel event.
  final String value;

  /// The constant close event
  static PhoenixChannelEvent close = PhoenixChannelEvent._(__closeEventName);

  /// The constant error event
  static PhoenixChannelEvent error = PhoenixChannelEvent._(__errorEventName);

  /// The constant join event
  static PhoenixChannelEvent join = PhoenixChannelEvent._(__joinEventName);

  /// The constant reply event
  static PhoenixChannelEvent reply = PhoenixChannelEvent._(__replyEventName);

  /// The constant leave event
  static PhoenixChannelEvent leave = PhoenixChannelEvent._(__leaveEventName);

  /// The constant heartbeat event
  static PhoenixChannelEvent heartbeat = PhoenixChannelEvent._('heartbeat');

  /// The constant set of possible internal channel event names.
  static Set<PhoenixChannelEvent> statuses = {close, error, join, reply, leave};

  /// Whether the event name is an 'reply' event
  bool get isReply =>
      value.startsWith(__chanReplyEventName) ||
      value.startsWith(__replyEventName);

  /// Whether the event name is a 'channel reply' event
  bool get isChannelReply => value.startsWith(__chanReplyEventName);

  @override
  bool operator ==(Object other) =>
      other is PhoenixChannelEvent && other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => 'PhoenixChannelEvent($value)';
}
