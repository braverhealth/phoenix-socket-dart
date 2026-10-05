import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

export 'mocks.mocks.dart';

@GenerateNiceMocks(
  [
    MockSpec<PhoenixChannel>(),
    MockSpec<PhoenixSocket>(),
    MockSpec<WebSocketChannel>(),
    MockSpec<WebSocketSink>(),
  ],
)
class MockTest extends Mock {
  void test();
}
