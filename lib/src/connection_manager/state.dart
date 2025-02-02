import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../message.dart';

sealed class ConnectionState {
  const ConnectionState();
}

class DisconnectedState extends ConnectionState {
  const DisconnectedState({
    this.reconnectionAttempts = 0,
  });

  final int reconnectionAttempts;

  @override
  String toString() => 'DisconnectedState()';
}

class ConnectingState extends ConnectionState {
  ConnectingState({
    required this.channel,
    required this.reconnectionAttempts,
    required this.completer,
    int startingRef = 0,
    List<(Message, Completer<Message>?)>? queuedMessages,
  })  : _ref = startingRef,
        queuedMessages = queuedMessages ?? [];

  final WebSocketChannel channel;
  final int reconnectionAttempts;
  final List<(Message, Completer<Message>?)> queuedMessages;
  final Completer<void> completer;

  int _ref = 0;

  /// A property yielding unique message reference ids,
  /// monotonically increasing.
  int get nextRef => _ref++;

  int get currentRef => _ref;

  @override
  String toString() => 'ConnectingState($reconnectionAttempts)';
}

class ReconnectingState extends ConnectingState {
  ReconnectingState({
    required super.channel,
    required super.completer,
    super.reconnectionAttempts = 0,
    super.startingRef,
    super.queuedMessages,
  });

  @override
  String toString() => 'ReconnectingState($reconnectionAttempts)';
}

class ConnectedState extends ConnectionState {
  ConnectedState({
    required this.channel,
    required int startingRef,
  }) : _ref = startingRef;

  final WebSocketChannel channel;
  final Map<String, Completer<Message>> pendingMessages = {};

  String? pendingHeartbeatRef;
  Timer? heartbeatTimeout;
  int _ref;

  Message heartbeatMessage() =>
      Message.heartbeat(pendingHeartbeatRef = '$nextRef');

  /// A property yielding unique message reference ids,
  /// monotonically increasing.
  int get nextRef => _ref++;

  @override
  String toString() => 'ConnectedState()';
}
