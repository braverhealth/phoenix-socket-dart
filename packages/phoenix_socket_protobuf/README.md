# phoenix_socket_protobuf

Optional protobuf payload support for `phoenix_socket` 1.0.0-rc2. Supply your
generated response constructor; the package encodes generated requests and
decodes binary response bodies. The core socket package has no protobuf dependency.

## One response schema

```dart
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket_protobuf/phoenix_socket_protobuf.dart';
import 'messages.pb.dart'; // Your generated Request and Reply types.

final socket = PhoenixSocket(endpoint, socketOptions: PhoenixSocketOptions(
  serializer: createProtobufSerializer(decoder: Reply.fromBuffer),
));
await socket.connect();
final channel = socket.addChannel(topic: 'your:topic');
await channel.join().future;

final reply = await channel.push(
  'request', Request(text: 'hello'), expectingReply: true,
).future;
final body = reply.response as Reply;
```

No custom `PayloadCodec` implementation or manual `writeToBuffer` call is needed.
This decoder applies to all binary application payloads, including broadcasts;
use schema selection when different events have different message types.

## Multiple schemas

```dart
final serializer = MessageSerializer(
  payloadCodec: ProtobufPayloadCodec.select(decoderFor: (context) {
    if (context.isReply) return Reply.fromBuffer;
    return switch (context.event) {
      'update' => Update.fromBuffer,
      _ => null, // Keep unrecognized binary payloads as bytes.
    };
  }),
);
```

The selector also receives topic, join reference, request reference and reply
status. Replies carry `phx_reply`; use application request context indexed by
`context.ref` when a topic has multiple reply schemas. The adapter does not
track requests or infer schemas from protobuf bytes. Capture an extension
registry in your decoder callback when your generated schema needs one.

## Behavior and wire format

- `GeneratedMessage` values encode using their generated protobuf runtime.
- JSON control messages, existing maps, raw bytes and decoded values pass through.
- Only binary bodies invoke a decoder or selector. Reply status remains separate.
- A null selector result preserves the original bytes, including buffer views.
- Empty protobuf bodies are valid and decode to their schema's defaults.
- Decoder/selector exceptions follow the socket's codec error path.

The package uses standard Phoenix v2 binary payload framing. Both peers must
support that contract. It does not define a protobuf envelope or convert
Braver's existing base64 JSON wrappers. Custom complete envelopes still use
`MessageCodec`; see the [protobuf examples](../../example/protobuf).

The dependency allows protobuf runtimes from 3.1 through 6.x. Generate your
application's messages with a compiler matching its protobuf runtime. Runnable
examples using actual generated classes are in [example/protobuf](../../example/protobuf).

```sh
dart pub get
dart analyze --fatal-infos
dart test
dart test --platform chrome
```
