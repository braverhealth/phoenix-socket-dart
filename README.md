# phoenix_socket

[![ci-test](https://github.com/braverhealth/phoenix-socket-dart/actions/workflows/test.yaml/badge.svg)](https://github.com/braverhealth/phoenix-socket-dart/actions/workflows/test.yaml)
[![pub-package](https://img.shields.io/pub/v/phoenix_socket.svg)](https://pub.dev/packages/phoenix_socket)
![Pub Points](https://img.shields.io/pub/points/phoenix_socket?color=blue&label=pub%20points)

Dart library to interact with [Phoenix][1] [Channels][2] ([Presence][3] support is currently _experimental_) over WebSockets.

This library uses [web_socket_channel][4] for WebSockets, making the API consistent across web and native
environments.

Requires Dart 3.4 or newer.

## Testing

Run the unit and regression tests with:

```sh
dart pub get
dart test
```

Run E2E tests against the Elixir backend included in this checkout with a
compatible Elixir/Erlang pair on `PATH` (CI uses Elixir 1.19.5 / OTP 27.3.4):

```sh
cd example/backend
MIX_ENV=test mix deps.get
cd ../..
dart run tool/run_e2e.dart
```

The runner compiles and starts its own backend on an OS-assigned loopback port,
disables the backend's control endpoint, runs the Dart E2E suite, and stops only
the process it started. Docker and Toxiproxy are not needed. It covers join and
request/reply behavior, recovery after join timeout and server disconnect,
close/leave cancellation, topic listener lifetimes, and buffered send modes.
Heartbeat-loss coverage uses a test-owned WebSocket proxy on another
OS-assigned loopback port.
Additional `dart test` options can be passed to the runner.

The historical fixed-port integration suites are opt-in via `dart test -P legacy`.
They require the original manually provisioned backend/Toxiproxy setup and
modify that proxy. CI uses the isolated embedded-backend suite instead.

## Getting Started

Look at the [example project][5] for an example on how to use this library. The API was designed to
look like javascript's as much as possible, but leveraging Dart's unique native advantages like Streams
and Futures.

[1]: https://www.phoenixframework.org/
[2]: https://hexdocs.pm/phoenix/Phoenix.Channel.html#content
[3]: https://hexdocs.pm/phoenix/Phoenix.Presence.html#content
[4]: https://pub.dev/packages/web_socket_channel
[5]: https://github.com/matehat/phoenix-socket-dart/tree/master/example
