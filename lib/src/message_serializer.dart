import 'dart:convert';
import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket/src/utils/serializer.dart';
import 'package:phoenix_socket/src/utils/map_utils.dart';

typedef DecoderCallback = dynamic Function(String rawData);
typedef EncoderCallback = String Function(Object? data);
typedef PayloadDecoderCallback = dynamic Function(Uint8List payload);

/// Default class to serialize [Message] instances to JSON.
class MessageSerializer {
  static const int headerLength = 1;
  static const int metaLength = 4;

  static const Map<String, int> kinds = {
    'push': 0,
    'reply': 1,
    'broadcast': 2,
  };

  final DecoderCallback _decoder;
  final EncoderCallback _encoder;
  final PayloadDecoderCallback? _payloadDecoder;

  /// Default constructor returning the singleton instance of this class.
  const MessageSerializer({
    DecoderCallback decoder = jsonDecode,
    EncoderCallback encoder = jsonEncode,
    PayloadDecoderCallback? payloadDecoder,
  })  : _decoder = decoder,
        _encoder = encoder,
        _payloadDecoder = payloadDecoder;

  /// Encode a [Message] into a raw string or a Uint8List.
  ///
  /// If the message has a binary payload, it will be encoded using the
  /// [BinaryDecoder.binaryEncode] method. Otherwise, the message will be
  /// encoded using the [encoder] callback.
  /// Given a [Message], return the raw string that would be sent through
  /// a websocket.
  dynamic encode(Message message) {
    if (message.payload is Uint8List) {
      return BinaryDecoder.binaryEncode(message);
    }
    return _encoder(message.encode());
  }

  /// Decode a [Message] from a raw string or a Uint8List.
  ///
  /// If the message has a binary payload, it will be decoded using the
  /// [BinaryDecoder.binaryDecode] method. Otherwise, the message will be
  /// decoded using the [decoder] callback.
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

  dynamic _getPayload(dynamic payLoad) {
    if (_payloadDecoder != null && payLoad is Uint8List) {
      final deserializedPayload = _payloadDecoder!(payLoad);
      if (deserializedPayload is Map) {
        return MapUtils.deepConvertToStringDynamic(deserializedPayload);
      } else if (deserializedPayload is Uint8List) {
        return deserializedPayload;
      } else {
        return {'data': deserializedPayload};
      }
    } else {
      return payLoad;
    }
  }
}
