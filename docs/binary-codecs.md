# Binary messages on the 1.0.0 track

## Boundaries

`MessageCodec` translates complete WebSocket messages into Phoenix `Message`
objects. The transport normalizes byte lists/buffers to `Uint8List`, invokes the
configured codec once, and retains generation/cancellation and channel routing
checks. Invalid input/output or codec failures follow the socket error path.

`MessageSerializer` is the default codec. Its text decoder/encoder callbacks
remain supported. It also implements Phoenix v2 binary client pushes and server
push/reply/broadcast decoding. Client and server push headers differ, so its
binary encode/decode operations are intentionally directional. Metadata fields
are limited to 255 UTF-8 bytes. Truncated headers/metadata and unknown kinds are
rejected before routing.

`PayloadCodec` converts application values independently of framing. It sees a
`PayloadContext` with topic, event, join/request references and optional reply
status. For replies only the body is converted. Application adapters can select
schemas or leave values unchanged. A custom complete-envelope codec implements
`MessageCodec` directly; neither layer assumes protobuf or MessagePack.

The legacy `payloadDecoder:` callback is also supported, now including binary
reply bodies. Canonical `Map<String, dynamic>` decoder output passes through by
identity, as in #115. Such maps must have canonical nested maps as well. Dynamic
maps are normalized recursively; bytes remain bytes, and colliding stringified
keys are rejected. Other decoded application values are preserved rather than
wrapped in a synthetic map. New payload codecs own their normalization.

## Payload ownership and performance

The Phoenix encoder allocates one final frame buffer and copies application
bytes into it. The decoder returns a view of the received buffer instead of
copying its body. Treat both received bytes and submitted payloads as immutable;
do not mutate queued payloads while the socket is using them. A small retained
view also retains its original frame, so copy a slice explicitly when that is
appropriate for a long-lived cache. Browser, WebSocket, masking, TLS and protobuf
implementations may still allocate or copy independently of this library.

Default JSON traffic uses the existing JSON callbacks, with no payload-codec
context objects or transformations when no payload codec is configured. Payload
logging is lazy so disabled logging does not stringify large messages.

The tools in `tool/codec_benchmark.dart` and `tool/allocation_benchmark.dart`
measure codec cost separately from network/server latency. See
[performance notes](codec-performance.md) for measurements and limitations.

## Protobuf and Braver compatibility

The checked-in protobuf example demonstrates both generated application messages
inside standard Phoenix framing and an application-defined protobuf envelope.
Its schemas are examples, not Braver's production schema.

Braver's current socket library uses `SocketOperationRequest.toJson()` to wrap
protobuf payloads in base64 under a payload-name key, with optional metadata.
`SocketQueryDecoder.responseFromJson()` reads the matching base64 response.
Changing those exchanges to raw binary also requires a server contract that
preserves the payload name and metadata. The new client support does not change
that production protocol automatically. Keep the existing JSON wrapper until a
matching server/client migration is made.

## Validation

Native and Chrome tests exercise binary framing, views, malformed input, mixed
control/application traffic, buffered sends, replies, reconnection, disposal and
Presence through fake transports. Both optional examples test actual generated
protobuf/MessagePack data through the socket, not only isolated codecs.

CI additionally runs the embedded backend E2E suite. Its new cases exercise
binary requests/replies, server pushes and broadcasts against the repository's
Phoenix serializer. Local unit/browser tests do not require that backend.

## Upstream contributions

This implementation adapts the capabilities contributed in:

- [#102](https://github.com/braverhealth/phoenix-socket-dart/pull/102): rxdart 0.28.
- [#105](https://github.com/braverhealth/phoenix-socket-dart/pull/105): binary framing and payload decoding, by Neelansh Sethi.
- [#111](https://github.com/braverhealth/phoenix-socket-dart/pull/111): removing the example's socket-close hotfix, already covered by the typed Presence example rewrite on 1.0.0-alpha.
- [#112](https://github.com/braverhealth/phoenix-socket-dart/pull/112): configurable logging, by Rohan Dilip Sanap.
- [#113](https://github.com/braverhealth/phoenix-socket-dart/pull/113): unhandled-future protection, already covered by the 1.0.0 lifecycle design.
- [#114](https://github.com/braverhealth/phoenix-socket-dart/pull/114): MessagePack envelopes and binary callbacks.
- [#115](https://github.com/braverhealth/phoenix-socket-dart/pull/115): canonical map pass-through.

The other two master-only commits are package/changelog version bumps; the
1.0.0-rc2 metadata and changelog supersede those 0.x release entries. This is
behavioral coverage rather than identical source/history: MessagePack is an
optional package, payloads have explicit map/byte accessors, and the legacy
payload decoder is configured on MessageSerializer rather than as a convenience
argument on PhoenixSocketOptions.

Framing follows Phoenix's official
[JavaScript serializer](https://github.com/phoenixframework/phoenix/blob/v1.8.14/assets/js/phoenix/serializer.js)
and its corresponding server serializer. Existing 1.0.0 Presence and lifecycle
work remains the foundation.
