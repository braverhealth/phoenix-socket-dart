# Phoenix HTTP long polling

The wire protocol follows Phoenix JavaScript **v1.8.15**, commit
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
before its first health check, or after the initial opening deadline. Opening
WebSocket starts a fresh deadline for a heartbeat round trip. Until its reply,
`connect()` remains pending, no socket open event is emitted, and application
messages and channel joins stay queued. A failed probe therefore sends them only
through the selected HTTP session. After WebSocket has passed its first probe,
later reconnects use normal WebSocket timeout/backoff without timed fallback.
Three consecutive failures to open make WebSocket unproven again, so the next
attempt receives the opening deadline and probe. A successful opening or explicit
close resets the failure count. HTTP reached through these repeated failures is
not memorized, and a new attempt after its session closes retries WebSocket even
without readable history. The configured maximum retry count still applies.
If this temporary HTTP fallback fails with a network/request timeout or server
error before opening, the next attempt returns to the previously proven
WebSocket for another normal retry window. Backoff and retry counts continue
across transport changes. HTTP that opens successfully remains selected until
that session ends. Forbidden responses, forced polling, auth-token compatibility
selection and other fallback reasons do not trigger this outage recovery.
The optional stability policy still applies to repeated short-lived connections.
Replacing an app-visible open transport fails its pending replies and makes
channels rejoin.

### Repeated short-lived connections

Enable the optional stability policy to handle a WebSocket that successfully
opens and answers heartbeats but repeatedly disconnects a few seconds later:

```dart
final options = PhoenixSocketOptions(
  longPollFallbackAfter: const Duration(milliseconds: 2500),
  webSocketStability: const WebSocketStabilityPolicy(
    maxUnstableConnections: 3,
    minimumUptime: Duration(seconds: 30),
  ),
);
```

This policy is an opt-in extension to the reference client's opening/probe
fallback. Its default budget is three unstable connection losses, and its
default healthy-uptime window is 30 seconds. Both values must be positive.
Opening and a single successful heartbeat leave the failure count intact until
the connection has sustained the configured uptime. Uptime without a successful
heartbeat also leaves the count intact. The existing reconnect-delay sequence
progresses across unstable connections; sustained healthy uptime resets it.

The policy counts remote transport errors/closes, including a normal server
close, and excludes explicit client close/dispose. Explicit client close also
resets the budget. The existing limit on failed opening/reconnection attempts
still applies. The stability policy can be used independently of timed opening
fallback. A policy-triggered switch selects long polling and records browser
fallback history only after the HTTP session opens successfully.

With timed fallback enabled, an error or close before the opening/health probe
completes selects HTTP immediately. This also handles proxies that accept the
WebSocket handshake and terminate traffic before the probe can finish.

Fallback history uses the same `phx:fallback:LongPoll` key as Phoenix JavaScript.
Browser `sessionStorage` is the default; native applications can supply a
`PhoenixSocketSessionStore` through `sessionStorage`. History is recorded only
after fallback opens and only if WebSocket has never passed its health check, or
the stability budget selected HTTP despite successful probes. Stored history is
consulted when timed fallback or a stability policy is enabled.
It is re-read before each new connection attempt. Clearing or expiring the key
allows the same socket to retry WebSocket on its next attempt, with a fresh
initial health check. An active HTTP session is not interrupted. The first HTTP
fallback must open before a missing key can trigger automatic recovery; forced
long polling always stays on HTTP. Without readable session storage, automatic
reconnects retain HTTP; explicit close/connect without remembered history can
retry WebSocket.

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
  fallback is disabled or WebSocket has already passed its initial health check.
  For an unproven WebSocket, the fallback deadline controls opening.
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
Phoenix 1.8.15 uses standard Base64 despite the `base64url.bearer.phx.` prefix.
If that encoding contains `/` (for example, token `00?`), it cannot be a valid
WebSocket subprotocol. The default factory selects HTTP automatically and sends
the original token in `X-Phoenix-AuthToken`, requiring long polling on the server.
This selection does not write fallback history. Token refresh can restore
WebSocket on a later attempt. `+` is a valid subprotocol character and stays
unchanged; changing it or `/` to the URL-safe alphabet would break the pinned
server decoder. A custom WebSocket factory owns its authentication mechanism.
Long-poll GETs send `X-Phoenix-AuthToken`; POSTs send only their content type,
matching the reference. Existing `params`/`dynamicParams` are also supported.
Only the initial GET includes connection query parameters, including any
application auth token. Once Phoenix supplies a session token, resumed GETs and
POSTs contain only that transport token. Session expiry reconnects with freshly
evaluated connection parameters and authentication. This omission of original
parameters, the first-open health gate, and history recovery are deliberate
client extensions to the reference implementation.
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
fallback. Each new session uses the application's connection parameters for
codec negotiation; resumed requests use only the session token.

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
dart test test/long_poll_test.dart test/long_poll_reference_test.dart test/long_poll_socket_test.dart test/websocket_stability_test.dart test/long_poll_review_test.dart test/long_poll_outage_test.dart
dart test --platform chrome test/long_poll_test.dart test/long_poll_reference_test.dart test/long_poll_socket_test.dart test/long_poll_browser_test.dart test/websocket_stability_test.dart test/long_poll_review_test.dart test/long_poll_outage_test.dart
dart run tool/run_e2e.dart --long-poll --platform vm
dart run tool/run_e2e.dart --long-poll --platform chrome
```

The Node harness executes an unchanged, licensed copy of the upstream LongPoll
implementation to generate portable expectations. VM and Chrome compare session
requests, status/close behavior, batching, endpoint conversion and binary uploads
to those expectations, with explicit assertions for the intentional resumed-query
omission. Lifecycle tests cover fallback health, history, late
callbacks, reconnect/rejoin, pending replies and repeated client cleanup.
Stability tests use a controlled clock on VM and Chrome for retry progression,
healthy-uptime boundaries, failure budgets and timer cleanup. Real-server E2E
also repeatedly opens, joins, receives heartbeat replies, disconnects and
verifies the eventual HTTP session and channel recovery. Authenticated query-token
tests check resumed request privacy and refreshed credentials after session expiry.
Outage tests check recovery through the original WebSocket after both transports
fail to open, accumulated backoff/retry limits, queued sends, and cancellation.

E2E runs start only a test-owned Phoenix process on an OS-assigned loopback port
and stop that exact process. Chrome uses real cross-origin HTTP requests and
preflight handling, not an in-memory HTTP client. CI runs the long-poll E2E suite
as four independent jobs: VM/Chrome on Dart 3.4.4/stable. Core, backend and workflow
changes trigger these jobs through the existing path filters.
