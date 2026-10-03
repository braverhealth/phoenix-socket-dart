# Protobuf codec examples

Two working examples use generated classes from `protos/exchange.proto`:

- `EchoPayloadCodec` converts an echo request/reply body while standard Phoenix
  framing carries topic, event and references. Maps for control messages pass
  through unchanged. It assumes one response schema for this example channel.
- `ProtobufEnvelopeCodec` defines a complete protobuf envelope. Both peers must
  implement that schema, including control messages. Binary reply bodies retain
  their status and empty bytes remain distinguishable from a missing body.

```sh
dart pub get
dart run bin/main.dart
dart test
dart test --platform chrome
```

To use generated requests directly with a matching server:

```dart
final options = PhoenixSocketOptions(
  serializer: MessageSerializer(payloadCodec: EchoPayloadCodec()),
);
final reply = await channel.push(
  'echo', EchoRequest(text: 'hello'), expectingReply: true,
).future;
final body = reply.response as EchoReply;
```

For multiple response schemas, use application request context and the reply
reference to choose a decoder, or keep `responseBytes` and decode at the caller.
Actual Braver requests currently include a base64 JSON wrapper with payload-name
and metadata fields; these examples do not replace that production contract.

Generated source uses protoc_plugin 21.1.2 / protobuf 3.1.0 to retain Dart 3.4
compatibility. To regenerate with `protoc` installed, use a protoc-gen-dart
wrapper that executes `dart run protoc_plugin:protoc_plugin` in this directory:

```sh
protoc --plugin=protoc-gen-dart=/path/to/wrapper \
  --dart_out=lib/src/generated -I protos protos/exchange.proto
dart format lib/src/generated
```
