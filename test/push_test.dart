import 'package:mockito/mockito.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

import 'mocks.dart';

void main() {
  test('Push.future should complete properly even after trigger', () async {
    var phoenixSocket = PhoenixSocket('');
    final channel = PhoenixChannel.fromSocket(phoenixSocket, topic: 'oui');

    var push = Push(channel, event: PhoenixChannelEvent.leave);
    push.trigger(PushResponse(status: 'ok'));

    expect(push.future, completes);
  });

  test(
    'Push.future should throw if Push.sendMessage throws an exception',
    () async {
      final mockPhoenixSocket = MockPhoenixSocket();
      when(mockPhoenixSocket.sendMessage(any)).thenThrow(Exception());
      final channel =
          PhoenixChannel.fromSocket(mockPhoenixSocket, topic: 'oui');

      var push = Push(
        channel,
        event: PhoenixChannelEvent.leave,
        payload: () => {},
        timeout: Duration.zero,
      );

      expectLater(() => push.future, throwsA(isA<Exception>()));
      await push.send();
    },
  );

  test(
    'Push.future should throw if PhoenixChannel.onPushReply throws an exception',
    () async {
      final mockPhoenixSocket = MockPhoenixSocket();
      final mockPhoenixChannel = MockPhoenixChannel();
      when(mockPhoenixSocket.addChannel(topic: anyNamed('topic')))
          .thenReturn(mockPhoenixChannel);
      when(mockPhoenixChannel.socket).thenReturn(mockPhoenixSocket);
      when(mockPhoenixChannel.loggerName).thenReturn('oui');
      when(mockPhoenixChannel.onPushReply(any))
          .thenAnswer((_) async => throw Exception());

      var push = Push(
        mockPhoenixChannel,
        event: PhoenixChannelEvent.leave,
        payload: () => {},
        timeout: Duration.zero,
      );

      expectLater(() => push.future, throwsA(isA<Exception>()));
      await push.send();
    },
  );
}
