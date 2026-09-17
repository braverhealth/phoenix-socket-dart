import 'dart:convert';
import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket/src/utils/serializer.dart';
import 'package:phoenix_socket/src/utils/map_utils.dart';

typedef DecoderCallback = dynamic Function(String rawData);
typedef EncoderCallback = String Function(Object? data);
typedef PayloadDecoderCallback = dynamic Function(Uint8List payload);
typedef BinaryDecoderCallback = dynamic Function(Uint8List rawData);
typedef BinaryEncoderCallback = Uint8List Function(Object? data);

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
  final BinaryDecoderCallback? _binaryDecoder;
  final BinaryEncoderCallback? _binaryEncoder;

  /// Default constructor returning the singleton instance of this class.
  ///
  /// [binaryDecoder] - Optional callback for decoding binary (Uint8List) data
  /// directly. If provided, this will be used instead of Phoenix's binary
  /// framing format. Useful for pure MessagePack or other binary protocols.
  ///
  /// [binaryEncoder] - Optional callback for encoding messages to binary
  /// (Uint8List) directly. If provided, this will be used instead of the
  /// string encoder. Useful for pure MessagePack or other binary protocols.
  const MessageSerializer({
    DecoderCallback decoder = jsonDecode,
    EncoderCallback encoder = jsonEncode,
    PayloadDecoderCallback? payloadDecoder,
    BinaryDecoderCallback? binaryDecoder,
    BinaryEncoderCallback? binaryEncoder,
  })  : _decoder = decoder,
        _encoder = encoder,
        _payloadDecoder = payloadDecoder,
        _binaryDecoder = binaryDecoder,
        _binaryEncoder = binaryEncoder;

  /// Encode a [Message] into a raw string or a Uint8List.
  ///
  /// If [binaryEncoder] is provided, it will be used for all messages.
  /// If the message has a binary payload, it will be encoded using the
  /// [BinaryDecoder.binaryEncode] method. Otherwise, the message will be
  /// encoded using the [encoder] callback.
  /// Given a [Message], return the raw string that would be sent through
  /// a websocket.
  dynamic encode(Message message) {
    // Use binary encoder for pure binary protocols like MessagePack
    if (_binaryEncoder != null) {
      return _binaryEncoder!(message.encode());
    }
    if (message.payload is Uint8List) {
      return BinaryDecoder.binaryEncode(message);
    }
    return _encoder(message.encode());
  }

  /// Decode a [Message] from a raw string or a Uint8List.
  ///
  /// If [binaryDecoder] was provided, binary data will be decoded using that
  /// callback. Otherwise, binary data will be decoded using Phoenix's binary
  /// framing format via [BinaryDecoder.binaryDecode].
  /// String data is always decoded using the [decoder] callback.
  Message decode(dynamic rawData) {
    if (rawData is String) {
      return Message.fromJson(_decoder(rawData));
    } else if (rawData is Uint8List) {
      // If a custom binary decoder is provided, use it for pure binary formats
      // (like MessagePack). Otherwise, use Phoenix's binary framing format.
      if (_binaryDecoder != null) {
        return Message.fromJson(_binaryDecoder!(rawData));
      }
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
      if (deserializedPayload is Map<String, dynamic>) {
        // Already string-keyed at every level (e.g. jsonDecode output) — the
        // deep rebuild below would recursively copy the entire payload tree
        // for nothing. On multi-MB payloads that rebuild can dominate
        // main-thread time in consuming apps.
        return deserializedPayload;
      } else if (deserializedPayload is Map) {
        // Dynamic-keyed maps (e.g. msgpack output) genuinely need conversion.
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
