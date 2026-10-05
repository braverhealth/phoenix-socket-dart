import 'events.dart';
import 'message.dart';
import 'push.dart';
import 'pheonix_socket.dart';

/// Exception yield when a [PhoenixSocket] closes for unexpected reasons.
class PhoenixException implements Exception {
  /// The default constructor for this exception.
  PhoenixException({
    required String? message,
    this.socketClosed,
    this.socketError,
    this.channelEvent,
  }) : _message = message;

  final String? _message;

  /// The associated error event.
  final PhoenixSocketErrorEvent? socketError;

  /// The associated close event.
  final PhoenixSocketCloseEvent? socketClosed;

  /// The associated channel event.
  final String? channelEvent;

  /// The error message for this exception.
  Message? get message {
    if (socketClosed != null) {
      return Message(event: PhoenixChannelEvent.error);
    } else if (socketError != null) {
      return Message(event: PhoenixChannelEvent.error);
    }
    return null;
  }

  @override
  String toString() {
    if (_message != null) {
      return 'PhoenixException: $_message';
    } else if (socketError != null) {
      return socketError!.error.toString();
    } else {
      return 'PhoenixException: socket closed';
    }
  }
}

/// Exception thrown when a [Push]'s reply was awaited for, and
/// the allowed delay has passed.
class ChannelTimeoutException implements Exception {
  /// Default constructor
  ChannelTimeoutException(this.response);

  /// The PushReponse containing the timeout event.
  PushResponse response;
}

class ChannelClosedError extends PhoenixException {
  ChannelClosedError({
    required super.message,
  });
}

class SocketClosedError extends PhoenixException {
  SocketClosedError({
    required super.message,
    required super.socketClosed,
  });
}

class ConnectionManagerClosedError extends PhoenixException {
  ConnectionManagerClosedError({
    required super.message,
    super.socketClosed,
  });
}
