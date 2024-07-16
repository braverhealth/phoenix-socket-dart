import 'package:mockito/mockito.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

import 'mocks.dart';

void main() {
  group('PhoenixChannel unit tests', () {
    test(
        'pushing an event into a channel with state PhoenixChannelState.closed does not throw',
        () {
      final mockSocket = MockPhoenixSocket();
      when(mockSocket.defaultTimeout).thenReturn(Duration.zero);
      when(mockSocket.isConnected).thenReturn(true);

      final channel = PhoenixChannel.fromSocket(mockSocket, topic: 'test');
      channel.join();
      channel.close();

      expect(channel.state, PhoenixChannelState.closed);
      expect(() => channel.push('test-event', {}), returnsNormally);
    });

    test(
        'pushing an event into a channel with state PhoenixChannelState.errored does not throw',
        () {
      final mockSocket = MockPhoenixSocket();
      when(mockSocket.defaultTimeout).thenReturn(Duration.zero);
      when(mockSocket.isConnected).thenReturn(false);

      final channel = PhoenixChannel.fromSocket(mockSocket, topic: 'test');
      channel.join();

      expect(channel.state, PhoenixChannelState.errored);
      expect(() => channel.push('test-event', {}), returnsNormally);
    });
  });
}
