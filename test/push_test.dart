import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

void main() {
  test('Push.future should complete properly even after trigger', () async {
    var phoenixSocket = PhoenixSocket('');
    final channel = PhoenixChannel.fromSocket(phoenixSocket, topic: 'oui');

    var push = Push(channel, event: PhoenixChannelEvent.leave);
    push.trigger(PushResponse(status: 'ok'));

    expect(push.future, completes);
  });
}
