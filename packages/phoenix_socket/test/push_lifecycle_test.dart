import 'dart:async';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

import 'helpers/fake_channel_socket.dart';

void main() {
  test('timeout settles sendExpectingReply without a transport waiter',
      () async {
    final socket = FakeChannelSocket();
    final channel = PhoenixChannel.fromSocket(socket, topic: 'timeout');
    final push = Push(channel,
        event: PhoenixChannelEvent.custom('request'),
        payload: () => {},
        timeout: socket.defaultTimeout);
    final result =
        expectLater(push.future, throwsA(isA<ChannelTimeoutException>()));
    await push.sendExpectingReply().timeout(const Duration(seconds: 1));
    await result;
    expect(socket.transportWaiters, 0);
    channel.close();
    await socket.shutdown();
  });

  test('handled channel failure does not emit a second unhandled error',
      () async {
    final errors = <Object>[];
    final done = Completer<void>();
    runZonedGuarded(() async {
      final socket = FakeChannelSocket();
      socket.onSend = (message) {
        if (message.event == PhoenixChannelEvent.join) socket.reply(message);
      };
      final channel = PhoenixChannel.fromSocket(socket, topic: 'disconnect');
      await channel.join().future;
      final push = channel.push('request', {}, expectingReply: true);
      final result =
          expectLater(push.future, throwsA(isA<ChannelClosedError>()));
      socket.connected = false;
      channel.triggerError(ChannelClosedError(message: 'Expected disconnect'));
      await result;
      await settleEvents();
      channel.close();
      await socket.shutdown();
      done.complete();
    }, (error, stack) {
      errors.add(error);
    });
    await done.future.timeout(const Duration(seconds: 1));
    expect(errors, isEmpty);
  });

  test('callback-only push can be canceled without an unhandled error',
      () async {
    final socket = FakeChannelSocket();
    final channel = PhoenixChannel.fromSocket(socket, topic: 'callback');
    final push = channel.join()..onReply('ok', (_) {});
    channel.close();
    await settleEvents();
    await expectLater(push.future, throwsA(isA<ChannelClosedError>()));
    await socket.shutdown();
  });
}
