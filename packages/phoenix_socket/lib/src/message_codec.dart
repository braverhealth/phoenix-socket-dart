import 'dart:typed_data';

import 'message.dart';

/// Converts complete Phoenix messages to and from WebSocket frames.
///
/// Frames must be [String] or [Uint8List]. Implementations must preserve the
/// topic, event, join reference and request reference used by channel routing.
/// Reply payloads retain a string `status` and an arbitrary `response` body.
abstract interface class MessageCodec {
  Object encode(Message message);
  Message decode(Object frame);
}

/// Routing information available to an application payload codec.
class PayloadContext {
  const PayloadContext({
    required this.topic,
    required this.event,
    this.joinRef,
    this.ref,
    this.replyStatus,
  });

  final String? topic;
  final String event;
  final String? joinRef;
  final String? ref;
  final String? replyStatus;

  /// For replies, [event] is `phx_reply`, not the original request event.
  bool get isReply => replyStatus != null;
}

/// Converts application payloads independently of Phoenix wire framing.
///
/// Return unchanged values for control events or schemas this codec does not
/// handle. For replies, these methods receive the response body; the socket
/// retains the status envelope. Implementations returning JSON maps must use
/// string keys throughout. No map normalization is performed on this path.
abstract interface class PayloadCodec {
  Object? encode(Object? payload, PayloadContext context);
  Object? decode(Object? payload, PayloadContext context);
}

typedef PayloadConverter = Object? Function(
    Object? payload, PayloadContext context);

/// A payload codec backed by application callbacks, such as protobuf codecs.
class CallbackPayloadCodec implements PayloadCodec {
  const CallbackPayloadCodec({
    PayloadConverter? encoder,
    PayloadConverter? decoder,
  })  : _encoder = encoder,
        _decoder = decoder;

  final PayloadConverter? _encoder;
  final PayloadConverter? _decoder;

  @override
  Object? encode(Object? payload, PayloadContext context) =>
      _encoder == null ? payload : _encoder(payload, context);

  @override
  Object? decode(Object? payload, PayloadContext context) =>
      _decoder == null ? payload : _decoder(payload, context);
}
