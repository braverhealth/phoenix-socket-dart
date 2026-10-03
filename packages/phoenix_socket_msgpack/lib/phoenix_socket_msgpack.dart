/// Optional MessagePack codecs for complete Phoenix message envelopes.
library phoenix_socket_msgpack;

import 'dart:convert';
import 'dart:typed_data';

import 'package:msgpack_dart/msgpack_dart.dart';
import 'package:phoenix_socket/phoenix_socket.dart';

export 'package:phoenix_socket/phoenix_socket.dart'
    show MessageCodec, MessageSerializer;

/// MessagePack encoding of `[join_ref, ref, topic, event, payload]`.
///
/// Text mode uses base64, preserving PR #114's compatibility format. Both
/// client and server must explicitly use the same envelope protocol.
class MessagePackCodec {
  const MessagePackCodec._();

  static String encode(Object? value) => base64.encode(encodeBinary(value));

  static Object? decode(String frame) => decodeBinary(base64.decode(frame));

  static Uint8List encodeBinary(Object? value) => serialize(value);

  static Object? decodeBinary(Uint8List frame) {
    if (frame.isEmpty) throw const FormatException('Empty MessagePack frame');
    return _normalize(deserialize(frame));
  }
}

/// Send binary envelopes; accept binary and base64 compatibility envelopes.
MessageSerializer createMessagePackSerializer() => MessageSerializer(
      decoder: MessagePackCodec.decode,
      encoder: MessagePackCodec.encode,
      binaryDecoder: MessagePackCodec.decodeBinary,
      binaryEncoder: MessagePackCodec.encodeBinary,
    );

MessageSerializer createBinaryMessagePackSerializer() =>
    createMessagePackSerializer();

/// Send and receive base64 envelopes in WebSocket text frames.
MessageCodec createBase64MessagePackSerializer() =>
    const _Base64MessagePackSerializer();

class _Base64MessagePackSerializer implements MessageCodec {
  const _Base64MessagePackSerializer();

  @override
  String encode(Message message) => MessagePackCodec.encode(message.encode());

  @override
  Message decode(Object frame) => const MessageSerializer(
        decoder: MessagePackCodec.decode,
        binaryDecoder: MessagePackCodec.decodeBinary,
      ).decode(frame);
}

Object? _normalize(Object? value) {
  if (value is Uint8List) return value;
  if (value is Map) {
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key.toString();
      if (result.containsKey(key)) {
        throw const FormatException('MessagePack map contains colliding keys');
      }
      result[key] = _normalize(entry.value);
    }
    return result;
  }
  if (value is List) return value.map(_normalize).toList();
  return value;
}
