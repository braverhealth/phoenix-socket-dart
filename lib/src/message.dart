import 'dart:typed_data';
import 'package:logging/logging.dart';
import 'channel.dart';
import 'events.dart';
import 'socket.dart';

final Logger _logger = Logger('phoenix_socket.message');

/// Class that encapsulate a message being sent or received on a
/// [PhoenixSocket].
class Message {
  /// Given a parsed JSON coming from the backend, yield
  /// a [Message] instance.
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

  /// Given a unique reference, generate a heartbeat message.
  factory Message.heartbeat(String ref) {
    return Message(
      topic: 'phoenix',
      event: PhoenixChannelEvent.heartbeat,
      payload: const {},
      ref: ref,
    );
  }

  /// Given a unique reference, generate a timeout message that
  /// will be used to error out a push.
  factory Message.timeoutFor(String ref) {
    return Message(
      event: PhoenixChannelEvent.replyFor(ref),
      payload: const {
        'status': 'timeout',
        'response': {},
      },
    );
  }

  /// Build a [Message] from its constituents.
  Message({
    this.joinRef,
    this.ref,
    this.topic,
    required this.event,
    this.payload,
  });

  /// Build a [Message] with binary payload.
  factory Message.binary({
    String? joinRef,
    String? ref,
    String? topic,
    required PhoenixChannelEvent event,
    required Uint8List payload,
  }) {
    return Message(
      joinRef: joinRef,
      ref: ref,
      topic: topic,
      event: event,
      payload: payload,
    );
  }

  /// Reference of the channel on which the message is received.
  ///
  /// Used by the [PhoenixSocket] to route the message on the proper
  /// [PhoenixChannel].
  final String? joinRef;

  /// The unique identifier for this message.
  ///
  /// This identifier is used in the reply event name, allowing us
  /// to consider a message as a reply to a previous message.
  final String? ref;

  /// The topic of the channel on which this message is sent.
  final String? topic;

  /// The event name of this message.
  final PhoenixChannelEvent event;

  /// The payload of this message.
  ///
  /// This can be either a JSON-encodable Map or a Uint8List for binary data.
  final dynamic payload;

  /// Encode a message to a JSON-encodable list of values.
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
  bool operator ==(Object other) =>
      other is Message &&
      other.joinRef == joinRef &&
      other.ref == ref &&
      other.topic == topic &&
      other.event == event &&
      other.payload == payload;

  @override
  int get hashCode =>
      Object.hash(runtimeType, joinRef, ref, topic, event, payload);

  @override
  String toString() =>
      'Message(joinRef: $joinRef, ref: $ref, topic: $topic, event: $event, payload: $payload)';

  /// Whether the message is a reply message.
  bool get isReply => event.isReply;

  /// Return a new [Message] with the event name being that of
  /// a proper reply message.
  Message asReplyEvent() {
    return Message(
      ref: ref,
      payload: payload,
      event: PhoenixChannelEvent.replyFor(ref!),
      topic: topic,
      joinRef: joinRef,
    );
  }
}
