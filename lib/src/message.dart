import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:equatable/equatable.dart';

import 'events.dart';

final Logger _logger = Logger('phoenix_socket.message');

class Message implements Equatable {
  final String joinRef;
  final String ref;
  final String topic;
  final PhoenixChannelEvent event;
  final Map<String, dynamic> payload;

  factory Message.fromJson(List<dynamic> parts) {
    _logger.finest('Message decoded from $parts');
    return Message(
      joinRef: parts[0],
      ref: parts[1],
      topic: parts[2],
      event: PhoenixChannelEvent.custom(parts[3]),
      payload: parts[4],
    );
  }

  factory Message.heartbeat(String ref) {
    return Message(
      topic: 'phoenix',
      event: PhoenixChannelEvent.heartbeat,
      payload: {},
      ref: ref,
    );
  }

  factory Message.timeoutFor(String ref) {
    return Message(
      event: PhoenixChannelEvent.replyFor(ref),
      payload: {
        'status': 'timeout',
        'response': {},
      },
    );
  }

  Message({
    this.joinRef,
    this.ref,
    this.topic,
    this.event,
    this.payload,
  }) : assert(event is PhoenixChannelEvent);

  Object encode() {
    final parts = [
      joinRef,
      ref,
      topic,
      event.value,
      payload,
    ];
    _logger.finest('Message encoded to $parts');
    return parts;
  }

  @override
  List<Object> get props => [joinRef, ref, topic, event, payload];

  bool get isReply => event.isReply;

  @override
  bool get stringify => true;

  Message asReplyEvent() {
    return Message(
      ref: ref,
      payload: payload,
      event: PhoenixChannelEvent.replyFor(ref),
      topic: topic,
      joinRef: joinRef,
    );
  }
}

class MessageSerializer {
  static Message decode(String rawData) {
    return Message.fromJson(jsonDecode(rawData));
  }

  static String encode(Message message) {
    return jsonEncode(message.encode());
  }
}
