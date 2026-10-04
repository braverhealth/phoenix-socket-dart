import 'package:phoenix_socket/src/socket_options.dart';
import 'package:test/test.dart';

void main() {
  test('empty reconnect delay list means immediate retry', () {
    const options = PhoenixSocketOptions(reconnectDelays: []);
    expect(options.getReconnectionDelay(0), Duration.zero);
    expect(options.getReconnectionDelay(100), Duration.zero);
    expect(options.shouldAttemptReconnection(100), isTrue);
  });

  test('retry delays clamp to the first and last supplied delays', () {
    const options = PhoenixSocketOptions(reconnectDelays: [
      Duration(milliseconds: 10),
      Duration(milliseconds: 20),
    ]);
    expect(options.getReconnectionDelay(-1), const Duration(milliseconds: 10));
    expect(options.getReconnectionDelay(0), const Duration(milliseconds: 10));
    expect(options.getReconnectionDelay(1), const Duration(milliseconds: 20));
    expect(options.getReconnectionDelay(20), const Duration(milliseconds: 20));
  });
}
