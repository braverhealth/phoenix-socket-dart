import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

void main() {
  test('only the protocol reply and synthetic reply namespace are replies', () {
    expect(PhoenixChannelEvent.reply.isReply, isTrue);
    expect(PhoenixChannelEvent.replyFor('123').isReply, isTrue);
    expect(PhoenixChannelEvent.replyFor('123').isChannelReply, isTrue);
    for (final name in [
      'phx_reply_custom',
      'phx_reply123',
      'chan_replycustom'
    ]) {
      expect(PhoenixChannelEvent.custom(name).isReply, isFalse, reason: name);
      expect(PhoenixChannelEvent.custom(name).isChannelReply, isFalse,
          reason: name);
    }
  });
}
