import 'dart:typed_data';

import 'package:msgpack_dart/msgpack_dart.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket_msgpack/phoenix_socket_msgpack.dart';
import 'package:test/test.dart';

import '../../phoenix_socket/test/helpers/fake_transport.dart';

void main() {
  for (final base64 in [false, true]) {
    final codec = base64
        ? createBase64MessagePackSerializer()
        : createMessagePackSerializer();
    group(base64 ? 'base64 envelopes' : 'binary envelopes', () {
      test('round trips nested maps, references and raw bytes', () {
        final message = Message(
            joinRef: '1',
            ref: '2',
            topic: 'room',
            event: PhoenixChannelEvent.custom('echo'),
            payload: {
              'nested': {'answer': 42},
              'bytes': Uint8List.fromList([0, 128, 255])
            });
        final frame = codec.encode(message);
        expect(frame, base64 ? isA<String>() : isA<Uint8List>());
        final result = codec.decode(frame);
        expect(result.joinRef, '1');
        expect(result.ref, '2');
        expect(result.payloadMap!['nested'], isA<Map<String, dynamic>>());
        expect(result.payloadMap!['bytes'], isA<Uint8List>());
        expect(result.payloadMap!['bytes'], [0, 128, 255]);
        final bytes = codec.encode(Message(
            topic: 'room',
            event: PhoenixChannelEvent.custom('bytes'),
            payload: Uint8List(0)));
        expect(bytes, base64 ? isA<String>() : isA<Uint8List>());
        expect(codec.decode(bytes).payloadBytes, isEmpty);
      });

      test('normalizes Presence maps through an actual listener', () async {
        final transport = FakeTransport(
            readyImmediately: true,
            decodeFrame: (frame) =>
                codec.decode(frame).encode() as List<dynamic>,
            encodeFrame: (parts) => codec.encode(Message.fromJson(parts)));
        transport.onSend = transport.replyTo;
        final socket = PhoenixSocket('ws://unused.invalid/socket',
            socketOptions: PhoenixSocketOptions(
                serializer: codec, heartbeat: const Duration(days: 1)),
            webSocketChannelFactory: (_) => transport);
        addTearDown(socket.dispose);
        await socket.connect();
        final channel = socket.addChannel(topic: 'presence:room');
        final presence =
            PhoenixPresence<Map<String, Object?>>(channel: channel);
        addTearDown(presence.dispose);
        await channel.join().future;
        final state = presence.snapshots.firstWhere((s) => s.isSynchronized);
        transport.incoming.add(codec.encode(Message(
            joinRef: channel.joinRef,
            topic: channel.topic,
            event: PhoenixChannelEvent.custom('presence_state'),
            payload: {
              'a': {
                'metas': [
                  {'phx_ref': 'a1', 'name': 'Ada'}
                ]
              }
            })));
        expect((await state).presences['a']!.metas.single.value['name'], 'Ada');
        final diff =
            presence.snapshots.firstWhere((s) => s.presences.containsKey('b'));
        transport.incoming.add(codec.encode(Message(
            joinRef: channel.joinRef,
            topic: channel.topic,
            event: PhoenixChannelEvent.custom('presence_diff'),
            payload: {
              'joins': {
                'b': {
                  'metas': [
                    {'phx_ref': 'b1'}
                  ]
                }
              },
              'leaves': {
                'a': {
                  'metas': [
                    {'phx_ref': 'a1'}
                  ]
                }
              }
            })));
        expect((await diff).presences.keys, ['b']);
      });

      test('supports socket join and binary reply bodies', () async {
        final transport = FakeTransport(
            readyImmediately: true,
            decodeFrame: (frame) =>
                codec.decode(frame).encode() as List<dynamic>,
            encodeFrame: (parts) => codec.encode(Message.fromJson(parts)));
        transport.onSend = (parts) => transport.incoming.add(codec.encode(
                Message(
                    joinRef: parts[0],
                    ref: parts[1],
                    topic: parts[2],
                    event: PhoenixChannelEvent.reply,
                    payload: {
                  'status': 'ok',
                  'response': parts[3] == 'phx_join' ? {} : parts[4],
                })));
        final socket = PhoenixSocket('ws://unused.invalid/socket',
            socketOptions: PhoenixSocketOptions(
                serializer: codec, heartbeat: const Duration(days: 1)),
            webSocketChannelFactory: (_) => transport);
        addTearDown(socket.dispose);
        await socket.connect();
        final channel = socket.addChannel(topic: 'room');
        await channel.join().future;
        final reply = await channel
            .push('echo', Uint8List.fromList([0, 128, 255]),
                expectingReply: true)
            .future;
        expect(reply.responseBytes, [0, 128, 255]);
      });
    });
  }

  test('binary adapter accepts base64 compatibility messages', () {
    final frame = MessagePackCodec.encode([null, '2', 'room', 'echo', {}]);
    expect(createBinaryMessagePackSerializer().decode(frame).ref, '2');
  });

  test('normalization rejects colliding keys', () {
    final frame = serialize([
      null,
      null,
      'room',
      'event',
      <dynamic, dynamic>{1: 'a', '1': 'b'}
    ]);
    expect(() => createMessagePackSerializer().decode(frame),
        throwsFormatException);
  });

  test('malformed binary and base64 envelopes fail decoding', () {
    final codec = createMessagePackSerializer();
    expect(() => codec.decode(Uint8List(0)), throwsFormatException);
    expect(() => codec.decode(Uint8List.fromList([0xd9])), throwsA(anything));
    expect(() => codec.decode('!invalid!'), throwsFormatException);
    expect(
        () => codec.decode(MessagePackCodec.encode([])), throwsFormatException);
  });
}
