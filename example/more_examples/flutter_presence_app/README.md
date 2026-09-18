# Flutter presence example

Demonstrates `PhoenixPresence<UserMeta>`, immutable metadata decoding,
`StreamBuilder`, and distinct awaiting/stale/empty states.

The app expects an already-running example Phoenix backend at
`ws://localhost:4001/socket/websocket`, with topic `presence:lobby`.
Adjust the endpoint in `lib/main.dart` for your device or deployment.
The included backend's `online_at` field contains Unix seconds as a string.

Presence attaches before the initial join. Subsequent reconnects are handled
by the channel; the last known presence remains visible with a stale label
until a fresh full state is received.

Use `flutter pub get` and `flutter run` to run the app.
`flutter test` validates the example metadata decoder without a server.
