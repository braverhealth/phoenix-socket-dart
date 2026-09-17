import 'dart:convert';
import 'dart:typed_data';
import 'package:msgpack_dart/msgpack_dart.dart';
import 'package:logging/logging.dart';
import 'package:phoenix_socket/src/message_serializer.dart';

// Re-export MessageSerializer for convenience
export 'package:phoenix_socket/src/message_serializer.dart';

final Logger _logger = Logger('phoenix_socket.msgpack_serializer');

/// MessagePack encoder/decoder for Phoenix Socket messages.
///
/// This class provides MessagePack serialization for Phoenix Socket messages,
/// enabling 40-70% bandwidth savings compared to JSON serialization.
///
/// Usage:
/// ```dart
/// final socket = PhoenixSocket(
///   'wss://example.com/socket',
///   socketOptions: PhoenixSocketOptions(
///     serializer: MessageSerializer(
///       decoder: MessagePackCodec.decode,
///       encoder: MessagePackCodec.encode,
///     ),
///   ),
/// );
/// ```
class MessagePackCodec {
  MessagePackCodec._();

  /// Encode a Phoenix message (List format) to MessagePack binary.
  ///
  /// Phoenix messages are sent as: [joinRef, ref, topic, event, payload]
  ///
  /// This function serializes the list to MessagePack binary format.
  static String encode(Object? data) {
    try {
      if (data == null) {
        _logger.warning('Encoding null data');
        return '';
      }

      // Serialize to MessagePack binary
      final bytes = serialize(data);

      // Convert to base64 for WebSocket text frame compatibility.
      // base64 is required here because MessagePack bytes can contain values
      // >= 0x80 which are not valid UTF-8 single bytes and would be corrupted
      // by String.fromCharCodes through a text frame.
      final encoded = base64.encode(bytes);

      _logger.finest('Encoded MessagePack: ${bytes.length} bytes');
      return encoded;
    } catch (e, stackTrace) {
      _logger.severe('MessagePack encoding error', e, stackTrace);
      rethrow;
    }
  }

  /// Decode MessagePack binary to Phoenix message format (List).
  ///
  /// Takes MessagePack binary data and deserializes it back to the
  /// Phoenix message list format: [joinRef, ref, topic, event, payload]
  static dynamic decode(String rawData) {
    try {
      if (rawData.isEmpty) {
        _logger.warning('Decoding empty string');
        return [];
      }

      // Decode from base64 back to MessagePack bytes
      final bytes = base64.decode(rawData);

      // Deserialize from MessagePack
      final decoded = deserialize(bytes);

      _logger.finest('Decoded MessagePack: $decoded');
      return decoded;
    } catch (e, stackTrace) {
      _logger.severe('MessagePack decoding error', e, stackTrace);
      rethrow;
    }
  }

  /// Encode data directly to Uint8List (for binary WebSocket frames).
  ///
  /// This is more efficient than the string-based encode() method,
  /// as it sends raw binary without base64 encoding overhead.
  ///
  /// Use this when your WebSocket transport supports binary frames.
  static Uint8List encodeBinary(Object? data) {
    try {
      if (data == null) {
        _logger.warning('Encoding null data to binary');
        return Uint8List(0);
      }

      final bytes = serialize(data);
      _logger.finest('Encoded MessagePack binary: ${bytes.length} bytes');
      return bytes;
    } catch (e, stackTrace) {
      _logger.severe('MessagePack binary encoding error', e, stackTrace);
      rethrow;
    }
  }

  /// Decode from Uint8List (for binary WebSocket frames).
  ///
  /// This is more efficient than the string-based decode() method.
  static dynamic decodeBinary(Uint8List bytes) {
    try {
      if (bytes.isEmpty) {
        _logger.warning('Decoding empty bytes');
        return [];
      }

      final decoded = deserialize(bytes);
      _logger.finest('Decoded MessagePack binary: $decoded');
      return decoded;
    } catch (e, stackTrace) {
      _logger.severe('MessagePack binary decoding error', e, stackTrace);
      rethrow;
    }
  }
}

/// Helper function to create a MessageSerializer configured for MessagePack.
///
/// This serializer handles both sending and receiving MessagePack binary data.
/// - For outgoing messages: Encodes to MessagePack binary and sends as Uint8List
/// - For incoming messages: Decodes both string and binary MessagePack data
///
/// The backend should send pure MessagePack binary in Phoenix array format:
/// `[join_ref, ref, topic, event, payload]`
///
/// Example usage:
/// ```dart
/// final socket = PhoenixSocket(
///   'wss://example.com/socket',
///   socketOptions: PhoenixSocketOptions(
///     serializer: createMessagePackSerializer(),
///   ),
/// );
/// ```
MessageSerializer createMessagePackSerializer() {
  return MessageSerializer(
    decoder: MessagePackCodec.decode,
    encoder: MessagePackCodec.encode,
    binaryDecoder: MessagePackCodec.decodeBinary,
    binaryEncoder: MessagePackCodec.encodeBinary,
  );
}

/// Helper function to create a MessageSerializer with binary MessagePack.
///
/// This version uses binary WebSocket frames instead of base64-encoded strings,
/// resulting in even better bandwidth efficiency.
///
/// Note: Requires WebSocket server to support binary frames.
///
/// Example usage:
/// ```dart
/// final socket = PhoenixSocket(
///   'wss://example.com/socket',
///   socketOptions: PhoenixSocketOptions(
///     serializer: createBinaryMessagePackSerializer(),
///   ),
/// );
/// ```
MessageSerializer createBinaryMessagePackSerializer() {
  return MessageSerializer(
    binaryDecoder: MessagePackCodec.decodeBinary,
    binaryEncoder: MessagePackCodec.encodeBinary,
  );
}
