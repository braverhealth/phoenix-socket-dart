import 'dart:convert';
import 'dart:typed_data';

import 'package:msgpack_dart/msgpack_dart.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket/src/utils/serializer.dart';

typedef DecoderCallback = dynamic Function(String rawData);
typedef EncoderCallback = String Function(Object? data);

/// Default class to serialize [Message] instances to JSON.
class MessageSerializer {
  final DecoderCallback _decoder;
  final EncoderCallback _encoder;
  final bool useMessagePack;

  /// Default constructor returning the singleton instance of this class.
  const MessageSerializer({
    DecoderCallback decoder = jsonDecode,
    EncoderCallback encoder = jsonEncode,
    this.useMessagePack = true,
  })  : _decoder = decoder,
        _encoder = encoder;

  /// Yield a [Message] from some raw string arriving from a websocket.
  Message decode(dynamic rawData) {
    if (rawData is String) {
      return Message.fromJson(_decoder(rawData));
    } else if (rawData is Uint8List) {
      final rawMap = BinaryDecoder.binaryDecode(rawData);
      return Message(
        joinRef: rawMap['join_ref'],
        ref: rawMap['ref'],
        topic: rawMap['topic'],
        event: PhoenixChannelEvent.custom(rawMap['event']),
        payload: _getPayload(rawMap['payload']),
      );
    } else {
      throw ArgumentError('Received a non-string or a non-list of integers');
    }
  }

  /// Given a [Message], return the raw string that would be sent through
  /// a websocket.
  String encode(Message message) => _encoder(message.encode());

  Map<String, dynamic>? _getPayload(payLoad) {
    if (useMessagePack && payLoad is Uint8List) {
      final deserializedPayload = deserialize(payLoad);
      if (deserializedPayload is Map) {
        return deepConvertToStringDynamic(deserializedPayload);
      } else {
        return {'data': deserializedPayload};
      }
    } else {
      return payLoad;
    }
  }
}

Map<String, dynamic> deepConvertToStringDynamic(Map<dynamic, dynamic> input) {
  return input.map((key, value) {
    if (value is Map) {
      return MapEntry(key.toString(), deepConvertToStringDynamic(value));
    } else if (value is List) {
      return MapEntry(
          key.toString(),
          value.map((element) {
            if (element is Map) {
              return deepConvertToStringDynamic(element);
            } else {
              return element;
            }
          }).toList());
    } else {
      return MapEntry(key.toString(), value);
    }
  });
}
