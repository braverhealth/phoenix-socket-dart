# phoenix_socket

[![ci-test](https://github.com/braverhealth/phoenix-socket-dart/actions/workflows/test.yaml/badge.svg)](https://github.com/braverhealth/phoenix-socket-dart/actions/workflows/test.yaml)
[![pub-package](https://img.shields.io/pub/v/phoenix_socket.svg)](https://pub.dev/packages/phoenix_socket)
![Pub Points](https://img.shields.io/pub/points/phoenix_socket?color=blue&label=pub%20points)

Dart library to interact with [Phoenix][1] [Channels][2] ([Presence][3] support is currently _experimental_) over WebSockets.

This library uses [web_socket_channel][4] for WebSockets, making the API consistent across web and native
environments.

## Getting Started

Look at the [example project][5] for an example on how to use this library. The API was designed to
look like javascript's as much as possible, but leveraging Dart's unique native advantages like Streams
and Futures.

## Presence

Attach presence **before joining** the channel so it receives the initial
`presence_state`. A presence key identifies a resource (often a user); its
`metas` represent tracked processes or devices, not a history of events.

```dart
final channel = socket.addChannel(topic: 'presence:lobby');
final presence = PhoenixPresence<Map<String, Object?>>(
  channel: channel,
);

final snapshots = presence.snapshots.listen((snapshot) {
  if (!snapshot.isSynchronized) return; // Awaiting state, stale, or closed.
  for (final user in snapshot.presences.values) {
    print('${user.key}: ${user.metas.length} devices');
  }
});
final changes = presence.changes.listen((change) {
  if (change.becamePresent) print('${change.key} is now present');
  if (change.becameAbsent) print('${change.key} is no longer present');
});
final errors = presence.errors.listen((failure) {
  print('Presence error: ${failure.error}');
});

channel.join();
await socket.connect();

// When the consumer is finished:
await snapshots.cancel();
await changes.cancel();
await errors.cancel();
await presence.dispose(); // Does not leave the channel or close the socket.
```

For application types, provide a decoder and read `meta.value`:

```dart
class UserMeta {
  const UserMeta(this.onlineAt);

  factory UserMeta.fromJson(Map<String, Object?> json) => UserMeta(
    DateTime.fromMillisecondsSinceEpoch(
      int.parse(json['online_at'] as String) * 1000,
    ),
  );

  final DateTime onlineAt;
}

final presence = PhoenixPresence<UserMeta>(
  channel: channel,
  decodeMeta: UserMeta.fromJson,
);
final users = presence.snapshot.presences.values;
final times = users.expand((user) => user.metas.map((meta) => meta.value.onlineAt));
```

The protocol's `phxRef` and nullable `phxRefPrev` remain on each metadata wrapper.
`meta.data` contains the raw metadata, including these references. Additional
presence-level fields supplied by the server's `fetch/2` are in `user.data`.
Raw JSON maps/lists, metadata lists, and snapshot maps are deeply unmodifiable;
custom decoded values must also be immutable.

### State and notification semantics

- `snapshot` is the latest value. `snapshots` is a broadcast stream that replays
  the latest value to each subscriber, including an initial `awaitingState`
  snapshot. An empty synchronized map means nobody is present.
- A full state plus buffered diffs commits one synchronized snapshot. Full state
  payloads refresh enriched fields even when protocol references are unchanged.
- `changes` is a broadcast stream without replay. Each per-key change includes
  `before`, `after`, `joined`, `left`, and the committed `snapshot`. Join/leave
  metadata is computed by reference across the completed update. Metadata
  replacement does not create a false key departure; enrichment-only changes
  can have empty `joined` and `left` lists.
- Disconnects and channel errors retain the last known data with `stale` status;
  they do not claim that everyone left. Diffs wait for a full state after a
  rejoin. Explicitly outdated message join references and buffered diffs from
  older joins are discarded.
- Malformed payloads or decoder failures are reported on `errors` as
  `PresenceError` values, with no partial state commit. Data stays stale until a
  valid full state arrives. The client does not invent a resync wire command;
  recovery requires the server to send state, normally after rejoining.
- Disposing or closing the channel publishes `closed`, cancels input
  subscriptions, and closes output streams. Disposal is awaitable and
  idempotent; paused output listeners do not delay its cleanup future.

Custom event names use `stateEvent:` and `diffEvent:`; either can be supplied
independently. Phoenix `track`, `update`, and `untrack` are server operations.
Sending client commands for them requires an application-defined channel API.

### Migrating existing presence consumers

- Use `snapshots.listen(...)` instead of `onSync`, and `changes.listen(...)`
  instead of `onJoin`/`onLeave`. The old callbacks remain deprecated and now
  run after the entire state commits; callback failures are reported on
  `errors` without interrupting reconciliation.
- Replace `presence.list(presence.state, chooser)` with typed
  `presence.snapshot.presences.entries.map(...)` or `values.map(...)`.
- The `state` getter remains available, but assigning state or mutating it,
  metadata lists, or raw JSON is no longer supported. Pending diffs are private.
- Replace metadata subclasses with a decoder returning an immutable application
  object. Raw metadata maps now use `Object?` values, so reads need explicit
  type checks/casts. `clone()` returns the same immutable object.
- Replace `Presence.fromJson(key, {key: payload})` with
  `Presence.fromPayload(key, payload)`. The old constructor is deprecated.
- Replace the deprecated `eventNames` map with named event options. Legacy maps
  still work, with missing entries correctly defaulted.

See the [Flutter presence example](example/more_examples/flutter_presence_app)
for typed metadata and `StreamBuilder` usage.

[1]: https://www.phoenixframework.org/
[2]: https://hexdocs.pm/phoenix/Phoenix.Channel.html#content
[3]: https://hexdocs.pm/phoenix/Phoenix.Presence.html#content
[4]: https://pub.dev/packages/web_socket_channel
[5]: https://github.com/matehat/phoenix-socket-dart/tree/master/example
