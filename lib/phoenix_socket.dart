/// Dart library to interact with Phoenix Channels and Presence over WebSockets.
///
/// This library uses web_socket_channel for WebSockets, making the API
/// consistent across web and native environments.
///
/// Like other implementation of clients for Phoenix Sockets, this library
/// provides a [PhoenixSocket] class that can be used to manage connections
/// with remote Phoenix servers. [PhoenixChannel]s can be joined through that
/// [PhoenixSocket] class, through which [Message]s can be sent and received.
/// To send a message on a channel, possibly expecting a reply, the [Push]
/// class can be used.
library phoenix_socket;

import 'src/channel.dart';
import 'src/message.dart';
import 'src/push.dart';
import 'src/socket.dart';

export 'src/channel.dart';
export 'src/events.dart';
export 'src/exceptions.dart';
export 'src/message.dart';
export 'src/presence.dart';
export 'src/push.dart';
export 'src/raw_socket.dart';
export 'src/socket.dart';
export 'src/socket_options.dart';
