/// Optional generated protobuf payload codecs for Phoenix binary frames.
library phoenix_socket_protobuf;

import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:protobuf/protobuf.dart';

export 'package:phoenix_socket/phoenix_socket.dart'
    show MessageSerializer, PayloadCodec, PayloadContext;
export 'package:protobuf/protobuf.dart' show GeneratedMessage;

/// A generated `YourMessage.fromBuffer` constructor or an application decoder.
typedef ProtobufDecoder = GeneratedMessage Function(List<int> bytes);

/// Select a schema using routing metadata, or return null to retain raw bytes.
///
/// Reply events are `phx_reply`. Use [PayloadContext.ref] or application routing
/// information when a channel has more than one reply schema.
typedef ProtobufDecoderSelector = ProtobufDecoder? Function(
    PayloadContext context);

/// Encodes generated messages and decodes binary application payloads.
///
/// JSON control messages, non-protobuf values and already decoded messages pass
/// through unchanged. The surrounding [MessageSerializer] preserves reply
/// status and applies this codec to the reply body. Exceptions propagate to the
/// socket's codec error path. No additional payload copy is made before decode.
class ProtobufPayloadCodec implements PayloadCodec {
  /// Decode every binary application payload using the supplied schema.
  const ProtobufPayloadCodec({required ProtobufDecoder decoder})
      : _decoder = decoder,
        _decoderFor = null;

  /// Choose a decoder per binary payload; unrecognized schemas remain bytes.
  const ProtobufPayloadCodec.select(
      {required ProtobufDecoderSelector decoderFor})
      : _decoder = null,
        _decoderFor = decoderFor;

  final ProtobufDecoder? _decoder;
  final ProtobufDecoderSelector? _decoderFor;

  @override
  Object? encode(Object? payload, PayloadContext context) =>
      payload is GeneratedMessage ? payload.writeToBuffer() : payload;

  @override
  Object? decode(Object? payload, PayloadContext context) {
    if (payload is! Uint8List) return payload;
    final decoder = _decoder ?? _decoderFor!(context);
    return decoder == null ? payload : decoder(payload);
  }
}

/// Use generated messages with standard Phoenix framing and one response schema.
///
/// For multiple schemas, configure [ProtobufPayloadCodec.select] on a
/// [MessageSerializer]. Both peers must support binary protobuf payloads.
MessageSerializer createProtobufSerializer(
        {required ProtobufDecoder decoder}) =>
    MessageSerializer(payloadCodec: ProtobufPayloadCodec(decoder: decoder));
