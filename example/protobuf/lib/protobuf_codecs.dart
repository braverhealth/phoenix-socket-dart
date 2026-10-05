import 'dart:convert';
import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';

import 'src/generated/exchange.pb.dart';

export 'src/generated/exchange.pb.dart';

/// A complete protobuf envelope for a server implementing exchange.proto.
/// Control maps remain JSON inside the envelope. Binary application payloads
/// and reply bodies stay bytes, including empty bodies.
class ProtobufEnvelopeCodec implements MessageCodec {
  const ProtobufEnvelopeCodec();

  @override
  Uint8List encode(Message message) {
    final envelope = Envelope(
        joinRef: message.joinRef,
        ref: message.ref,
        topic: message.topic,
        event: message.event.value);
    final payload = message.payload;
    if (payload is Uint8List) {
      envelope.binaryPayload = payload;
    } else if (message.isReply &&
        message.payloadMap?['response'] is Uint8List) {
      envelope.binaryResponse = message.payloadMap!['response'] as Uint8List;
      envelope.replyStatus = message.payloadMap!['status'] as String;
    } else {
      envelope.jsonPayload = jsonEncode(payload);
    }
    return envelope.writeToBuffer();
  }

  @override
  Message decode(Object frame) {
    if (frame is! Uint8List) {
      throw const FormatException('Expected a protobuf binary envelope');
    }
    final envelope = Envelope.fromBuffer(frame);
    final event = PhoenixChannelEvent.custom(envelope.event);
    if (envelope.event.isEmpty ||
        envelope.whichPayload() == Envelope_Payload.binaryResponse &&
            (!envelope.hasReplyStatus() || !event.isReply)) {
      throw const FormatException('Invalid protobuf envelope metadata');
    }
    final Object? payload = switch (envelope.whichPayload()) {
      Envelope_Payload.jsonPayload => jsonDecode(envelope.jsonPayload),
      Envelope_Payload.binaryPayload => _bytes(envelope.binaryPayload),
      Envelope_Payload.binaryResponse => {
          'status': envelope.replyStatus,
          'response': _bytes(envelope.binaryResponse),
        },
      Envelope_Payload.notSet =>
        throw const FormatException('Missing envelope payload'),
    };
    return Message(
      joinRef: envelope.hasJoinRef() ? envelope.joinRef : null,
      ref: envelope.hasRef() ? envelope.ref : null,
      topic: envelope.hasTopic() ? envelope.topic : null,
      event: event,
      payload: payload,
    );
  }
}

Uint8List _bytes(List<int> value) =>
    value is Uint8List ? value : Uint8List.fromList(value);
