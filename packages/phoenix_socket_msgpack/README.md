# phoenix_socket_msgpack

Optional complete-message MessagePack codecs for `phoenix_socket` 1.0.0-rc2.
The core socket package does not depend on MessagePack.

```dart
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket_msgpack/phoenix_socket_msgpack.dart';

final socket = PhoenixSocket(
  'wss://example.com/socket/websocket',
  socketOptions: PhoenixSocketOptions(serializer: createMessagePackSerializer()),
);
```

The server must encode/decode complete MessagePack arrays in the Phoenix order
`[join_ref, ref, topic, event, payload]`, including joins, heartbeats and replies.
This format differs from standard Phoenix binary framing with a MessagePack
payload inside it. `createMessagePackSerializer()` sends binary envelopes and
accepts both binary and base64 compatibility frames. The binary-named helper is
an alias. `createBase64MessagePackSerializer()` sends base64 text envelopes,
including when application payloads contain bytes.

Decoded maps are recursively normalized to string-keyed maps for replies and
Presence. Raw `Uint8List` values stay binary. Keys that collide after string
conversion fail decoding. Malformed/empty envelopes fail decoding as well.

For a checkout, the development override uses the root package. Publication
must ship the matching core release first. From this directory:

```sh
dart pub get
dart analyze --fatal-infos
dart test
dart test --platform chrome
dart run example/main.dart
```

Adapted from [PR #114](https://github.com/braverhealth/phoenix-socket-dart/pull/114).
The original MIT license is retained in LICENSE.
