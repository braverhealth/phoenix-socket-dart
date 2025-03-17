import 'dart:convert';
import 'dart:typed_data';

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
