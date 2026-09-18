import 'dart:async';

import 'package:phoenix_socket/phoenix_socket.dart';

/// A socket boundary for testing the channel's own timers and reply handling.
class FakeChannelSocket implements PhoenixSocket {
  bool connected = true;
  int _sequence = 0;
  int removals = 0;
  int transportWaiters = 0;
  final sentMessages = <Message>[];
  final incoming = StreamController<Message>.broadcast();
  final opens = StreamController<PhoenixSocketOpenEvent>.broadcast();
  final errors = StreamController<PhoenixSocketErrorEvent>.broadcast();
  void Function(Message)? onSend;

  @override
  bool get isConnected => connected;

  @override
  Duration get defaultTimeout => const Duration(milliseconds: 25);

  @override
  String get nextRef => '${++_sequence}';

  @override
  Stream<Message> streamForTopic(String topic) => incoming.stream;

  @override
  Stream<PhoenixSocketOpenEvent> get openStream => opens.stream;

  @override
  Stream<PhoenixSocketErrorEvent> get errorStream => errors.stream;

  @override
  void sendMessage(Message message) {
    sentMessages.add(message);
    onSend?.call(message);
  }

  @override
  Future<Message> waitForMessage(Message message) {
    transportWaiters++;
    return Completer<Message>().future;
  }

  @override
  void removeChannel(PhoenixChannel channel) => removals++;

  void reply(Message message, [String status = 'ok']) => incoming.add(Message(
        joinRef: message.joinRef,
        ref: message.ref,
        topic: message.topic,
        event: PhoenixChannelEvent.reply,
        payload: {'status': status, 'response': <String, dynamic>{}},
      ));

  Future<void> shutdown() async {
    await incoming.close();
    await opens.close();
    await errors.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> settleEvents() => Future<void>.delayed(Duration.zero);
