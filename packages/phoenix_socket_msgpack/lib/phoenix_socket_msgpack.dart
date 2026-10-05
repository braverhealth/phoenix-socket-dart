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
    _validateFrame(frame);
    return _normalize(deserialize(frame));
  }
}

// Validate the complete view before the recursive third-party decoder allocates
// containers or reads its backing buffer. Each child requires at least one byte.
void _validateFrame(Uint8List frame) {
  final data = ByteData.sublistView(frame);
  var offset = 0;
  final remaining = <int>[1];

  void requireBytes(int count) {
    if (count > frame.length - offset) {
      throw const FormatException('Truncated MessagePack value');
    }
  }

  int length(int bytes) {
    requireBytes(bytes);
    final value = switch (bytes) {
      1 => frame[offset],
      2 => data.getUint16(offset),
      _ => data.getUint32(offset),
    };
    offset += bytes;
    return value;
  }

  void skip(int bytes) {
    requireBytes(bytes);
    offset += bytes;
  }

  while (remaining.isNotEmpty) {
    if (remaining.last == 0) {
      remaining.removeLast();
      continue;
    }
    remaining[remaining.length - 1]--;
    requireBytes(1);
    final tag = frame[offset++];
    var children = 0;
    var container = false;
    if (tag <= 0x7f ||
        tag >= 0xe0 ||
        tag == 0xc0 ||
        tag == 0xc2 ||
        tag == 0xc3) {
      continue;
    } else if (tag >= 0xa0 && tag <= 0xbf) {
      skip(tag & 0x1f);
    } else if (tag >= 0x90 && tag <= 0x9f) {
      container = true;
      children = tag & 0x0f;
    } else if (tag >= 0x80 && tag <= 0x8f) {
      container = true;
      children = (tag & 0x0f) * 2;
    } else {
      switch (tag) {
        case 0xcc || 0xd0:
          skip(1);
        case 0xcd || 0xd1:
          skip(2);
        case 0xce || 0xd2 || 0xca:
          skip(4);
        case 0xcf || 0xd3 || 0xcb:
          skip(8);
        case 0xc4 || 0xd9:
          skip(length(1));
        case 0xc5 || 0xda:
          skip(length(2));
        case 0xc6 || 0xdb:
          skip(length(4));
        case 0xdc:
          container = true;
          children = length(2);
        case 0xdd:
          container = true;
          children = length(4);
        case 0xde:
          container = true;
          children = length(2) * 2;
        case 0xdf:
          container = true;
          children = length(4) * 2;
        case 0xd4 || 0xd5 || 0xd6 || 0xd7 || 0xd8:
          skip(1 + (1 << (tag - 0xd4)));
        case 0xc7:
          skip(1 + length(1));
        case 0xc8:
          skip(1 + length(2));
        case 0xc9:
          skip(1 + length(4));
        default:
          throw const FormatException('Invalid MessagePack tag');
      }
    }
    if (container && remaining.length > 64) {
      throw const FormatException('MessagePack nesting exceeds 64 containers');
    }
    if (children > 0) {
      requireBytes(children);
      remaining.add(children);
    }
  }
  if (offset != frame.length) {
    throw const FormatException('Trailing bytes after MessagePack value');
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
