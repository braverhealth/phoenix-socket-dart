import 'dart:convert';

import 'package:equatable/equatable.dart';

import 'push.dart';

class Message implements Equatable {
  final String joinRef;
  final String ref;
  final String topic;
  final String event;
  final Map payload;

  factory Message.fromJson(List<dynamic> parts) {
    return Message(
      joinRef: parts[0],
      ref: parts[1],
      topic: parts[2],
      event: parts[3],
      payload: parts[4],
    );
  }

  factory Message.heartbeat(String ref) {
    return Message(
      topic: 'phoenix',
      event: 'heartbeat',
      payload: {},
    );
  }

  Message({
    this.joinRef,
    this.ref,
    this.topic,
    this.event,
    this.payload,
  });

  String encode() {
    return jsonEncode([
      joinRef,
      ref,
      topic,
      event,
      payload,
    ]);
  }

  @override
  List<Object> get props => [joinRef, ref, topic, event, payload];

  Message asReplyEvent() {
    return Message(
      ref: ref,
      payload: payload,
      event: Push.replyEventName(ref),
      topic: topic,
      joinRef: joinRef,
    );
  }
}

class MessageSerializer {
  static Message decode(String rawData) {
    return Message.fromJson(jsonDecode(rawData));
  }

  String encode(Message message) {
    return message.encode();
  }
}
