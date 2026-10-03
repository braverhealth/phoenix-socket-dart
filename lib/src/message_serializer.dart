import 'dart:convert';
import 'dart:typed_data';

import 'message.dart';
import 'message_codec.dart';
import 'phoenix_binary_serializer.dart';

typedef DecoderCallback = dynamic Function(String rawData);
typedef EncoderCallback = String Function(Object? data);

typedef BinaryDecoderCallback = dynamic Function(Uint8List rawData);
typedef BinaryEncoderCallback = Uint8List Function(Object? data);
typedef PayloadDecoderCallback = Object? Function(Uint8List payload);

/// Phoenix v2 JSON and binary framing, with optional application codecs.
class MessageSerializer implements MessageCodec {
  final DecoderCallback _decoder;
  final EncoderCallback _encoder;
  final BinaryDecoderCallback? _binaryDecoder;
  final BinaryEncoderCallback? _binaryEncoder;
  final PayloadDecoderCallback? _payloadDecoder;
  final PayloadCodec? _payloadCodec;

  /// Configure envelope callbacks and optional application payload conversion.
  ///
  /// Binary callbacks override complete binary envelopes. Without them, bytes
  /// use Phoenix framing. Choose either the decode-only [payloadDecoder] or a
  /// bidirectional [payloadCodec]; both also handle binary reply bodies.
  const MessageSerializer({
    DecoderCallback decoder = jsonDecode,
    EncoderCallback encoder = jsonEncode,
    BinaryDecoderCallback? binaryDecoder,
    BinaryEncoderCallback? binaryEncoder,
    PayloadDecoderCallback? payloadDecoder,
    PayloadCodec? payloadCodec,
  })  : _decoder = decoder,
        _encoder = encoder,
        _binaryDecoder = binaryDecoder,
        _binaryEncoder = binaryEncoder,
        _payloadDecoder = payloadDecoder,
        _payloadCodec = payloadCodec,
        assert(payloadDecoder == null || payloadCodec == null,
            'Choose payloadDecoder or payloadCodec');

  /// Decode text, Phoenix binary framing, or a configured binary envelope.
  @override
  Message decode(Object rawData) {
    final Message message;
    if (rawData is String) {
      message = _fromParts(_decoder(rawData));
    } else if (rawData is Uint8List) {
      message = _binaryDecoder == null
          ? PhoenixBinarySerializer.decode(rawData)
          : _fromParts(_binaryDecoder(rawData));
    } else {
      throw const FormatException('Expected a String or Uint8List frame');
    }
    return _mapPayload(message, encoding: false);
  }

  /// Encode bytes using Phoenix framing, other payloads using JSON, or the
  /// configured encoder for a complete binary envelope.
  @override
  Object encode(Message message) {
    final encoded = _mapPayload(message, encoding: true);
    if (_binaryEncoder != null) return _binaryEncoder(encoded.encode());
    if (encoded.payload is Uint8List) {
      return PhoenixBinarySerializer.encode(encoded);
    }
    return _encoder(encoded.encode());
  }

  Message _fromParts(Object? parts) {
    if (parts is! List) {
      throw const FormatException('Expected a Phoenix message array');
    }
    return Message.fromJson(parts);
  }

  Message _mapPayload(Message message, {required bool encoding}) {
    if (_payloadCodec == null && (encoding || _payloadDecoder == null)) {
      return message;
    }
    final envelope = message.isReply ? message.payloadMap : null;
    final status = envelope?['status'];
    if (message.isReply && (envelope == null || status is! String)) {
      throw const FormatException('Phoenix reply status must be a string');
    }
    final original = envelope == null ? message.payload : envelope['response'];
    Object? converted;
    if (_payloadCodec != null) {
      final context = PayloadContext(
        topic: message.topic,
        event: message.event.value,
        ref: message.ref,
        joinRef: message.joinRef,
        replyStatus: status as String?,
      );
      converted = encoding
          ? _payloadCodec.encode(original, context)
          : _payloadCodec.decode(original, context);
    } else {
      // Legacy callback: preserve canonical maps by identity, as in PR #115.
      converted = original is Uint8List
          ? _normalizeDecodedPayload(_payloadDecoder!(original))
          : original;
    }
    if (identical(original, converted)) return message;
    return Message(
      joinRef: message.joinRef,
      ref: message.ref,
      topic: message.topic,
      event: message.event,
      payload: envelope == null
          ? converted
          : <String, dynamic>{...envelope, 'response': converted},
    );
  }
}

Object? _normalizeDecodedPayload(Object? value) {
  if (value is Uint8List || value is Map<String, dynamic>) return value;
  if (value is Map) {
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key.toString();
      if (result.containsKey(key)) {
        throw const FormatException('Decoded map contains colliding keys');
      }
      result[key] = _normalizeDecodedPayload(entry.value);
    }
    return result;
  }
  if (value is List) return value.map(_normalizeDecodedPayload).toList();
  return value;
}
