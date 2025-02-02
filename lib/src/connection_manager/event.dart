import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../message.dart';
import '../socket_options.dart';

sealed class ConnectionEvent {
  const ConnectionEvent();
}

class Connect extends ConnectionEvent {
  const Connect({
    required this.options,
    required this.completer,
  });

  final PhoenixSocketOptions options;
  final Completer<void> completer;

  @override
  String toString() => 'Connect()';
}

class Disconnect extends ConnectionEvent {
  Disconnect({required this.code, required this.reason});

  final int? code;
  final String? reason;

  @override
  String toString() => 'Disconnect()';
}

class Send extends ConnectionEvent {
  Send({
    required this.message,
  });

  final Message message;
}

class WaitFor extends ConnectionEvent {
  WaitFor({
    required this.messageRef,
    required this.completer,
  });

  final String messageRef;
  final Completer<Message> completer;
}

class ReceiveMessage extends ConnectionEvent {
  ReceiveMessage({
    required this.payload,
    required this.channel,
  });

  final dynamic payload;
  final WebSocketChannel channel;
}

class ChannelReady extends ConnectionEvent {
  ChannelReady({
    required this.channel,
  });

  final WebSocketChannel channel;

  @override
  String toString() => 'ChannelReady()';
}

class ChannelClosed extends ConnectionEvent {
  ChannelClosed({
    required this.channel,
    required this.code,
    required this.reason,
  });

  final WebSocketChannel? channel;
  final int? code;
  final String? reason;

  @override
  String toString() => 'ChannelClosed($code)';
}

class ChannelError extends ConnectionEvent {
  ChannelError({
    required this.channel,
    required this.error,
    required this.stackTrace,
  });

  final WebSocketChannel channel;
  final Object error;
  final StackTrace stackTrace;

  @override
  String toString() => 'ChannelError($error)';
}
