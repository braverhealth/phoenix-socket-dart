# Protobuf codec examples

Two working examples use generated classes from `protos/exchange.proto`:

- The optional `phoenix_socket_protobuf` package automatically encodes generated
  requests and decodes response bodies using `EchoReply.fromBuffer`. Standard
  Phoenix framing carries topic, event and references; control maps pass through.
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
  serializer: createProtobufSerializer(decoder: EchoReply.fromBuffer),
);
final reply = await channel.push(
  'echo', EchoRequest(text: 'hello'), expectingReply: true,
).future;
final body = reply.response as EchoReply;
```

For multiple response schemas, use `ProtobufPayloadCodec.select` with application
request context and the reply reference to choose a generated decoder. See the
[adapter package](../../packages/phoenix_socket_protobuf) for routing examples.
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
