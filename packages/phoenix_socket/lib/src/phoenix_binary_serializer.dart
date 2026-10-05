import 'dart:convert';
import 'dart:typed_data';

import 'events.dart';
import 'message.dart';

/// Phoenix v2 binary framing, independent of the application payload format.
///
/// Encoding produces client pushes. Decoding accepts server pushes, replies
/// and broadcasts. These directions have different push headers; they are not
/// symmetric encoders/decoders. See Phoenix's official JavaScript serializer.
class PhoenixBinarySerializer {
  const PhoenixBinarySerializer._();

  static Uint8List encode(Message message) {
    final payload = message.payloadBytes;
    if (payload == null) {
      throw ArgumentError(
          'Phoenix binary framing requires a Uint8List payload');
    }
    final fields = [
      utf8.encode(message.joinRef ?? ''),
      utf8.encode(message.ref ?? ''),
      utf8.encode(message.topic ?? ''),
      utf8.encode(message.event.value),
    ];
    var headerLength = 5;
    for (final field in fields) {
      if (field.length > 255) {
        throw ArgumentError('Phoenix binary metadata cannot exceed 255 bytes');
      }
      headerLength += field.length;
    }
    final frame = Uint8List(headerLength + payload.length);
    // Kind 0 is a client push; the zero-filled first byte already contains it.
    var offset = 5;
    for (var index = 0; index < fields.length; index++) {
      final field = fields[index];
      frame[index + 1] = field.length;
      frame.setAll(offset, field);
      offset += field.length;
    }
    frame.setAll(offset, payload);
    return frame;
  }

  static Message decode(Uint8List frame) {
    if (frame.isEmpty) {
      throw const FormatException('Empty Phoenix binary frame');
    }
    final kind = frame[0];
    final headerLength = switch (kind) {
      0 => 4,
      1 => 5,
      2 => 3,
      _ => throw FormatException('Unknown Phoenix binary frame kind: $kind'),
    };
    if (frame.length < headerLength) {
      throw const FormatException('Truncated Phoenix binary header');
    }
    final reader = _BinaryReader(frame, headerLength);
    String? joinRef;
    String? ref;
    if (kind != 2) {
      final value = reader.readString(frame[1]);
      joinRef = value.isEmpty ? null : value;
    }
    if (kind == 1) {
      final value = reader.readString(frame[2]);
      ref = value.isEmpty ? null : value;
    }
    final topicIndex = kind == 2
        ? 1
        : kind == 1
            ? 3
            : 2;
    final topic = reader.readString(frame[topicIndex]);
    final event = reader.readString(frame[topicIndex + 1]);
    // No payload copy: consumers must treat received bytes as immutable.
    final payload = Uint8List.sublistView(frame, reader.offset);
    return Message(
      joinRef: joinRef,
      ref: ref,
      topic: topic,
      event: kind == 1
          ? PhoenixChannelEvent.reply
          : PhoenixChannelEvent.custom(event),
      payload: kind == 1 ? {'status': event, 'response': payload} : payload,
    );
  }
}

class _BinaryReader {
  _BinaryReader(this.frame, this.offset);

  final Uint8List frame;
  int offset;

  String readString(int length) {
    final end = offset + length;
    if (end > frame.length) {
      throw const FormatException('Truncated Phoenix binary metadata');
    }
    final value = utf8.decode(Uint8List.sublistView(frame, offset, end));
    offset = end;
    return value;
  }
}
