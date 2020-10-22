import 'events.dart';
import 'message.dart';

/// Exception yield when a [PhoenixSocket] closes for unexpected reasons.
class PhoenixException {
  /// The default constructor for this exception.
  PhoenixException({
    this.socketClosed,
    this.socketError,
    this.channelEvent,
  });

  /// The associated error event.
  final PhoenixSocketErrorEvent socketError;

  /// The associated close event.
  final PhoenixSocketCloseEvent socketClosed;

  /// The associated channel event.
  final String channelEvent;

  /// The error message for this exception.
  Message get message {
    if (socketClosed is PhoenixSocketCloseEvent) {
      return Message(event: PhoenixChannelEvent.error);
    } else if (socketError is PhoenixSocketErrorEvent) {
      return Message(event: PhoenixChannelEvent.error);
    }
    return null;
  }
}
