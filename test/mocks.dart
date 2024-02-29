import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:phoenix_socket/phoenix_socket.dart';

export 'mocks.mocks.dart';

@GenerateNiceMocks(
  [
    MockSpec<PhoenixChannel>(),
    MockSpec<PhoenixSocket>(),
  ],
)
class MockTest extends Mock {
  void test();
}
