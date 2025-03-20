import 'dart:convert';
import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';

/// A utility class for handling binary message encoding and decoding in Phoenix channels.
class BinaryDecoder {
  static const headerLength = 1;
  static const metaLength = 4;

  static const Map<String, int> kinds = {
    'push': 0,
    'reply': 1,
    'broadcast': 2,
  };

  static const Map<String, String> channelEvents = {
    'reply': 'phx_reply',
  };

  /// Encodes a [Message] into a binary format for transmission over websocket.
  ///
  /// The message must have a [Uint8List] payload for binary encoding.
  /// Returns a [Uint8List] containing the encoded message with header and payload.
  ///
  /// Throws [ArgumentError] if the message payload is not a [Uint8List].
  static Uint8List binaryEncode(Message message) {
    if (message.payload is! Uint8List) {
      throw ArgumentError(
          'Message payload must be Uint8List for binary encoding');
    }

    final joinRefBytes =
        message.joinRef != null ? utf8.encode(message.joinRef!) : Uint8List(0);
    final refBytes =
        message.ref != null ? utf8.encode(message.ref!) : Uint8List(0);
    final topicBytes = utf8.encode(message.topic ?? '');
    final eventBytes = utf8.encode(message.event.value);
    final payload = message.payload as Uint8List;

    final metaLength = BinaryDecoder.metaLength +
        joinRefBytes.length +
        refBytes.length +
        topicBytes.length +
        eventBytes.length;

    final header = Uint8List(BinaryDecoder.headerLength + metaLength);
    final view = ByteData.view(header.buffer);
    var offset = 0;

    view.setUint8(offset++, kinds['push']!);
    view.setUint8(offset++, joinRefBytes.length);
    view.setUint8(offset++, refBytes.length);
    view.setUint8(offset++, topicBytes.length);
    view.setUint8(offset++, eventBytes.length);

    header.setAll(offset, joinRefBytes);
    offset += joinRefBytes.length;
    header.setAll(offset, refBytes);
    offset += refBytes.length;
    header.setAll(offset, topicBytes);
    offset += topicBytes.length;
    header.setAll(offset, eventBytes);
    offset += eventBytes.length;

    final combined = Uint8List(header.length + payload.length);
    combined.setAll(0, header);
    combined.setAll(header.length, payload);

    return combined;
  }

  /// Decodes a binary message received from a websocket into a map of message components.
  ///
  /// The [buffer] parameter should be a [Uint8List] containing the binary message data.
  /// Returns a [Map] containing the decoded message components.
  ///
  /// Throws [Exception] if the message kind is unknown.
  static Map<String, dynamic> binaryDecode(Uint8List buffer) {
    ByteData view = ByteData.view(buffer.buffer);
    int kind = view.getUint8(0);

    switch (kind) {
      case 0: // push
        return decodePush(buffer, view);
      case 1: // reply
        return decodeReply(buffer, view);
      case 2: // broadcast
        return decodeBroadcast(buffer, view);
      default:
        throw Exception('Unknown message kind: $kind');
    }
  }

  /// Decodes a push message from the binary buffer.
  ///
  /// [buffer] contains the raw binary data.
  /// [view] is a [ByteData] view of the buffer for reading header information.
  /// Returns a [Map] containing the decoded push message components.
  static Map<String, dynamic> decodePush(Uint8List buffer, ByteData view) {
    int joinRefSize = view.getUint8(1);
    int topicSize = view.getUint8(2);
    int eventSize = view.getUint8(3);
    int offset = headerLength + metaLength - 1; // pushes have no ref

    String joinRef = utf8.decode(buffer.sublist(offset, offset + joinRefSize));
    offset += joinRefSize;

    String topic = utf8.decode(buffer.sublist(offset, offset + topicSize));
    offset += topicSize;

    String event = utf8.decode(buffer.sublist(offset, offset + eventSize));
    offset += eventSize;

    Uint8List data = buffer.sublist(offset);

    return {
      'join_ref': joinRef,
      'ref': null,
      'topic': topic,
      'event': event,
      'payload': data
    };
  }

  /// Decodes a reply message from the binary buffer.
  ///
  /// [buffer] contains the raw binary data.
  /// [view] is a [ByteData] view of the buffer for reading header information.
  /// Returns a [Map] containing the decoded reply message components.
  static Map<String, dynamic> decodeReply(Uint8List buffer, ByteData view) {
    int joinRefSize = view.getUint8(1);
    int refSize = view.getUint8(2);
    int topicSize = view.getUint8(3);
    int eventSize = view.getUint8(4);
    int offset = headerLength + metaLength;

    String joinRef = utf8.decode(buffer.sublist(offset, offset + joinRefSize));
    offset += joinRefSize;

    String ref = utf8.decode(buffer.sublist(offset, offset + refSize));
    offset += refSize;

    String topic = utf8.decode(buffer.sublist(offset, offset + topicSize));
    offset += topicSize;

    String event = utf8.decode(buffer.sublist(offset, offset + eventSize));
    offset += eventSize;

    Uint8List data = buffer.sublist(offset);

    Map<String, dynamic> payload = {'status': event, 'response': data};

    return {
      'join_ref': joinRef,
      'ref': ref,
      'topic': topic,
      'event': channelEvents['reply'],
      'payload': payload
    };
  }

  /// Decodes a broadcast message from the binary buffer.
  ///
  /// [buffer] contains the raw binary data.
  /// [view] is a [ByteData] view of the buffer for reading header information.
  /// Returns a [Map] containing the decoded broadcast message components.
  static Map<String, dynamic> decodeBroadcast(Uint8List buffer, ByteData view) {
    int topicSize = view.getUint8(1);
    int eventSize = view.getUint8(2);
    int offset = headerLength + 2;

    String topic = utf8.decode(buffer.sublist(offset, offset + topicSize));
    offset += topicSize;

    String event = utf8.decode(buffer.sublist(offset, offset + eventSize));
    offset += eventSize;

    Uint8List data = buffer.sublist(offset);

    return {
      'join_ref': null,
      'ref': null,
      'topic': topic,
      'event': event,
      'payload': data
    };
  }
}
