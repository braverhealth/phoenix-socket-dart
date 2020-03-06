# phoenix_socket

Dart library to interact with [Phoenix][1] [Channels][2] ([Presence][3] coming up next) over WebSockets.

This library uses [web_socket_channel][4] for WebSockets, making the API consistent across web and native
environments.

## Getting Started

Look at the [example project][5] for an example on how to use this library. The API was designed to
look like javascript's as much as possible, but leveraging Dart's unique native advantages like Streams 
and Futures.

> The documentation is in a poor state for now, but it will improve soon enough.


[1]: https://www.phoenixframework.org/
[2]: https://hexdocs.pm/phoenix/Phoenix.Channel.html#content
[3]: https://hexdocs.pm/phoenix/Phoenix.Presence.html#content
[4]: https://pub.dev/packages/web_socket_channel
[5]: https://github.com/matehat/phoenix-socket-dart/tree/master/example
