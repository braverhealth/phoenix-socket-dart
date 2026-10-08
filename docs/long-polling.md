# Phoenix HTTP long polling

The implementation follows Phoenix JavaScript **v1.8.15**, commit
`bd1801833b4fd7ceb02497cc7ba2d05e9bd391c8`:

- [LongPoll transport](https://github.com/phoenixframework/phoenix/blob/v1.8.15/assets/js/phoenix/longpoll.js)
- [Socket fallback and heartbeat behavior](https://github.com/phoenixframework/phoenix/blob/v1.8.15/assets/js/phoenix/socket.js)
- [Server HTTP protocol](https://github.com/phoenixframework/phoenix/blob/v1.8.15/lib/phoenix/transports/long_poll.ex)

## Usage

Pass the same full endpoint used for WebSockets. The transport changes
`ws`/`wss` to `http`/`https` and `/websocket` to `/longpoll`.

```dart
final socket = PhoenixSocket(
  'wss://example.com/socket/websocket',
  socketOptions: const PhoenixSocketOptions(
    transport: PhoenixSocketTransport.longPolling,
    longPollTimeout: Duration(seconds: 20),
    params: {'user_id': '123'},
  ),
);
await socket.connect();
final channel = socket.addChannel(topic: 'room:123');
await channel.join().future;
```

Or opt into automatic fallback:

```dart
final socket = PhoenixSocket(
  'wss://example.com/socket/websocket',
  socketOptions: const PhoenixSocketOptions(
    longPollFallbackAfter: Duration(milliseconds: 2500),
  ),
);
```

Timed fallback is disabled by default. Browsers without a WebSocket constructor
select long polling automatically. Timed fallback switches immediately on a WebSocket error
before opening, or after the opening deadline. Opening WebSocket starts a fresh
deadline for a heartbeat round trip; a valid reply cancels fallback. Replacing
an already open transport fails its pending replies and makes channels rejoin.
Once selected, long polling remains selected for that socket's lifetime.

Fallback history uses the same `phx:fallback:LongPoll` key as Phoenix JavaScript.
Browser `sessionStorage` is the default; native applications can supply a
`PhoenixSocketSessionStore` through `sessionStorage`. History is recorded only
after fallback opens and only if WebSocket has never passed its health check.
Stored history is consulted only when fallback is enabled.

## Protocol behavior

- One outstanding GET polls the session while at most one POST sends messages.
- The initial JSON-body `410` response opens the session. A later `410` closes
  with `3410 / session_gone` and reconnects with fresh connection parameters;
  channels rejoin rather than assuming the replacement session has their state.
- Body `200` delivers messages, `204` polls again, `403` closes with
  `1008 / forbidden`, and missing responses or `500` close with
  `1011 / internal server error`. HTTP status alone does not select this behavior.
- Each incoming frame is delivered in its own event-loop task so Future
  continuations can run before the next frame, as with WebSocket events.
- Same-tick sends coalesce into NDJSON POSTs. Batches contain at most 100 frames.
  Further writes wait for acknowledgement, preserving order. A POST ack confirms
  transport dispatch; channel replies arrive through polling.
- Failed or timed-out POSTs are not replayed automatically: delivery may already
  have occurred. Reconnection and application retry rules still apply.
- GET and POST use `longPollTimeout` (20 seconds by default). As in the reference
  Socket constructor, zero selects the default. The lower-level `PhoenixLongPoll`
  transport accepts zero to disable its timeout.
  The existing `timeout` controls channel pushes and WebSocket opening when timed
  fallback is disabled. With fallback enabled, its deadline controls opening.
- Long polling skips Phoenix socket heartbeats; polling supplies liveness.
- Closing cancels pending requests, delivery/batch timers and buffered writes.
  Late responses cannot affect a replacement session.

The existing Dart connection retry delays, maximum attempt setting, endpoint
API, Streams and Futures remain in use. This is protocol and transport
compatibility, not a replacement of the Dart public API with JavaScript callbacks.
Malformed server responses produce a transport error instead of escaping an
asynchronous callback. Requests and queued deliveries are cancelled on close.

## Authentication and HTTP clients

`authToken` or `dynamicAuthToken` supplies Phoenix's optional transport auth token.
The default WebSocket factory sends it using the Phoenix bearer subprotocol.
Long-poll GETs send `X-Phoenix-AuthToken`; POSTs send only their content type,
matching the reference. Existing `params`/`dynamicParams` are also supported.
A custom WebSocket factory remains responsible for its own subprotocols.

For custom networking, supply `httpClientFactory:` to `PhoenixSocket`. Return a
fresh, dedicated `package:http` client for each session. The socket owns and
closes that client. The client must support `AbortableRequest` for cancellation
and must not transparently retry POSTs; the default IO and browser clients work.
`PhoenixLongPoll` is also available as a lower-level frame transport.

## Binary behavior and codecs

The behavior matches the reference LongPoll transport:

- Outgoing `Uint8List` Phoenix frames become base64 lines in the POST batch.
- Incoming messages remain the text strings supplied by Phoenix's poll response.
  The stock server provides no corresponding binary-frame download wrapper.

Binary uploads therefore work with channels that return compatible JSON replies.
Full binary replies or broadcasts require a separately coordinated server/client
text envelope. No additional protobuf/base64 response convention is introduced.

Like the JavaScript Socket constructor, explicitly selecting long polling uses
the default `MessageSerializer`, ignoring a custom `serializer`. Automatic
fallback retains the original WebSocket codec. Applications using a custom codec
must ensure their server produces compatible long-poll responses before enabling
fallback. Application parameters are retained; negotiation is not silently changed.

## Server configuration

The server must enable long polling, for example:

```elixir
socket "/socket", MyAppWeb.UserSocket,
  websocket: true,
  longpoll: true
```

Proxies must pass GET, POST and OPTIONS on `/socket/longpoll`. Cross-origin
browser clients need the endpoint's origin/CORS settings to permit their origin
and headers. Use a server supporting the reference NDJSON/binary POST protocol;
the test fixture is pinned to Phoenix 1.8.15. Phoenix 1.6's single-frame POST
protocol is not compatible with the current reference client's batches.

## Verification

From `packages/phoenix_socket`:

```sh
node tool/long_poll_reference.mjs --check
dart test test/long_poll_test.dart test/long_poll_reference_test.dart test/long_poll_socket_test.dart
dart test --platform chrome test/long_poll_test.dart test/long_poll_reference_test.dart test/long_poll_socket_test.dart
dart run tool/run_e2e.dart --long-poll --platform vm
dart run tool/run_e2e.dart --long-poll --platform chrome
```

The Node harness executes an unchanged, licensed copy of the upstream LongPoll
implementation to generate portable expectations. VM and Chrome compare session
requests, status/close behavior, batching, endpoint conversion and binary uploads
to those expectations. Lifecycle tests cover fallback health, history, late
callbacks, reconnect/rejoin, pending replies and repeated client cleanup.

E2E runs start only a test-owned Phoenix process on an OS-assigned loopback port
and stop that exact process. Chrome uses real cross-origin HTTP requests and
preflight handling, not an in-memory HTTP client. CI runs the long-poll E2E suite
as four independent jobs: VM/Chrome on Dart 3.4.4/stable. Core, backend and workflow
changes trigger these jobs through the existing path filters.
