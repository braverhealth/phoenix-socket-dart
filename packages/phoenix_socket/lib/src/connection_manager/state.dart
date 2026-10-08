import 'dart:async';

import '../transport/transport.dart';

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

  final PhoenixTransport channel;
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

/// WebSocket is open at the transport layer; application traffic stays queued
/// until the first health probe proves that the connection can exchange frames.
class ValidatingState extends ConnectingState {
  ValidatingState({
    required super.channel,
    required super.completer,
    required super.reconnectionAttempts,
    required this.healthCheckRef,
    required super.startingRef,
    super.queuedMessages,
  });

  final String healthCheckRef;

  @override
  String toString() => 'ValidatingState()';
}

class ConnectedState extends ConnectionState {
  ConnectedState({
    required this.channel,
    required int startingRef,
  }) : _ref = startingRef;

  final PhoenixTransport channel;
  final Map<String, Completer<Message>> pendingMessages = {};

  String? pendingHeartbeatRef;
  Timer? heartbeatTimeout;
  int _ref;

  Message heartbeatMessage() =>
      Message.heartbeat(pendingHeartbeatRef = '$nextRef');

  /// A property yielding unique message reference ids,
  /// monotonically increasing.
  int get nextRef => _ref++;

  int get currentRef => _ref;

  @override
  String toString() => 'ConnectedState()';
}
