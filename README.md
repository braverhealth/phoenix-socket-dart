# Phoenix Socket Dart

Dart and Flutter clients for Phoenix Channels, with optional binary payload codecs.

| Package | Purpose |
|---|---|
| [phoenix_socket](packages/phoenix_socket) | Socket/channel lifecycle, Presence, JSON and Phoenix binary framing |
| [phoenix_socket_msgpack](packages/phoenix_socket_msgpack) | MessagePack binary and base64 message envelopes |
| [phoenix_socket_protobuf](packages/phoenix_socket_protobuf) | Automatic generated-message encoding and configurable protobuf decoding |

Each package has its own pubspec, library and tests. The packages retain Dart 3.4
support and resolve independently. Shared examples and the embedded Phoenix
backend are in [example/](example); benchmark reports are in [docs/](docs).

## Development

Run Dart commands from the package being changed:

```sh
cd packages/phoenix_socket
dart pub get
dart analyze --fatal-infos lib
dart analyze --fatal-infos test
dart analyze --fatal-infos tool
dart test
dart test --platform chrome test/message_codec_test.dart test/binary_transport_test.dart
```

For each optional adapter, run `dart pub get`, `dart analyze --fatal-infos`,
`dart test` and `dart test --platform chrome` from its package directory.
See the [core testing guide](packages/phoenix_socket/README.md#testing) for backend E2E.

## Git dependency migration

The core package now lives under `packages/phoenix_socket`. Git consumers moving
from an older revision at the repository root must add the package path:

```yaml
dependencies:
  phoenix_socket:
    git:
      url: https://github.com/braverhealth/phoenix-socket-dart.git
      ref: 1.0.0-alpha
      path: packages/phoenix_socket
```

Published package names and Dart imports such as
`package:phoenix_socket/phoenix_socket.dart` remain the same. Consumers pinned to
older revisions continue using those revisions' original layout.

See [binary APIs and migration](docs/binary-codecs.md), the
[release changelog](packages/phoenix_socket/CHANGELOG.md) and the
[headless Chrome comparison](docs/chrome-codec-comparison.md).
