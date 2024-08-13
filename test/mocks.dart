// ignore_for_file: camel_case_types

import 'package:mockito/annotations.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket/src/socket_connection.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

export 'mocks.mocks.dart';

@GenerateNiceMocks(
  [
    MockSpec<PhoenixChannel>(),
    MockSpec<PhoenixSocket>(),
    MockSpec<WebSocketChannel>(),
    MockSpec<WebSocketSink>(),
    MockSpec<PhoenixSocketOptions>(),
    MockSpec<OnMessage_MockBase>(as: #MockOnMessage),
    MockSpec<OnError_MockBase>(as: #MockOnError),
    MockSpec<OnStateChange_MockBase>(as: #MockOnStateChange),
  ],
)
abstract class OnMessage_MockBase {
  void call(String message);
}

abstract class OnError_MockBase {
  void call(Object error, [StackTrace stackTrace]);
}

abstract class OnStateChange_MockBase {
  void call(WebSocketConnectionState state);
}
