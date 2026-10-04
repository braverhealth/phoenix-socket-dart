import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket_protobuf/phoenix_socket_protobuf.dart';
import 'package:protobuf/protobuf.dart' show InvalidProtocolBufferException;
import 'package:test/test.dart';

import 'helpers/messages.dart';
import '../../../test/helpers/binary_frames.dart';
import '../../../test/helpers/fake_transport.dart';

const context = PayloadContext(topic: 'echo:room', event: 'echo');

void main() {
  test('fixed decoder produces a typed protobuf message', () {
    const codec = ProtobufPayloadCodec(decoder: Reply.fromBuffer);
    final decoded = codec.decode(Reply(text: 'héllo').writeToBuffer(), context);
    expect(decoded, isA<Reply>());
    expect((decoded as Reply).text, 'héllo');
  });

  test('empty bytes are a valid protobuf message', () {
    const codec = ProtobufPayloadCodec(decoder: Reply.fromBuffer);
    expect((codec.decode(Uint8List(0), context) as Reply).text, '');
  });

  test('GeneratedMessage requests encode automatically', () {
    const codec = ProtobufPayloadCodec(decoder: Reply.fromBuffer);
    final encoded = codec.encode(Request(text: 'héllo'), context);
    expect(encoded, isA<Uint8List>());
    expect(Request.fromBuffer(encoded as Uint8List).text, 'héllo');
  });

  test('encoding preserves non-protobuf values by identity', () {
    const codec = ProtobufPayloadCodec(decoder: Reply.fromBuffer);
    for (final value in [
      null,
      {'json': true},
      [1, 2],
      Uint8List(0)
    ]) {
      expect(identical(codec.encode(value, context), value), isTrue);
    }
  });

  test('non-binary values bypass the decoder', () {
    final codec = ProtobufPayloadCodec(decoder: (_) {
      fail('The decoder must only receive binary payloads');
    });
    for (final value in [
      null,
      {'json': true},
      [1, 2],
      Reply(text: 'decoded')
    ]) {
      expect(identical(codec.decode(value, context), value), isTrue);
    }
  });

  test('decoding keeps the incoming byte view', () {
    final bytes = Reply(text: 'view').writeToBuffer();
    final storage = Uint8List.fromList([99, ...bytes, 98]);
    final view = Uint8List.sublistView(storage, 1, storage.length - 1);
    final codec = ProtobufPayloadCodec(decoder: (incoming) {
      expect(identical(incoming, view), isTrue);
      return Reply.fromBuffer(incoming);
    });
    expect((codec.decode(view, context) as Reply).text, 'view');
  });

  test('selector receives routing and reply context and chooses a schema', () {
    const replyContext = PayloadContext(
        topic: 'echo:room',
        event: 'phx_reply',
        joinRef: '1',
        ref: '2',
        replyStatus: 'error');
    final codec = ProtobufPayloadCodec.select(decoderFor: (incoming) {
      expect(identical(incoming, replyContext), isTrue);
      expect(incoming.isReply, isTrue);
      expect(incoming.ref, '2');
      expect(incoming.joinRef, '1');
      expect(incoming.replyStatus, 'error');
      return Update.fromBuffer;
    });
    expect(
        (codec.decode(Update(id: 'update-42').writeToBuffer(), replyContext)
                as Update)
            .id,
        'update-42');
  });

  test('unknown schemas keep the original bytes', () {
    final bytes = Uint8List.fromList([0, 128, 255]);
    final codec = ProtobufPayloadCodec.select(decoderFor: (_) => null);
    expect(identical(codec.decode(bytes, context), bytes), isTrue);
  });

  test('non-binary control values bypass the selector', () {
    final codec = ProtobufPayloadCodec.select(decoderFor: (_) {
      fail('The selector must only receive binary payloads');
    });
    final control = <String, dynamic>{};
    expect(identical(codec.decode(control, context), control), isTrue);
  });

  test('malformed protobuf errors propagate', () {
    const codec = ProtobufPayloadCodec(decoder: Reply.fromBuffer);
    expect(() => codec.decode(Uint8List.fromList([10, 255]), context),
        throwsA(isA<InvalidProtocolBufferException>()));
  });

  for (final selecting in [false, true]) {
    test('decoder errors propagate unchanged (selector: $selecting)', () {
      final failure = StateError('application decoder failed');
      GeneratedMessage decode(List<int> _) => throw failure;
      final codec = selecting
          ? ProtobufPayloadCodec.select(decoderFor: (_) => decode)
          : ProtobufPayloadCodec(decoder: decode);
      expect(() => codec.decode(Uint8List(0), context), throwsA(same(failure)));
    });
  }

  test('selector errors propagate unchanged', () {
    final failure = StateError('schema selection failed');
    final codec = ProtobufPayloadCodec.select(decoderFor: (_) => throw failure);
    expect(() => codec.decode(Uint8List(0), context), throwsA(same(failure)));
  });

  test('serializer preserves JSON control frames and binary reply status', () {
    final codec = createProtobufSerializer(decoder: Reply.fromBuffer);
    final heartbeat = codec.encode(Message.heartbeat('3'));
    expect(heartbeat, isA<String>());
    expect(codec.decode(heartbeat).payloadMap, {});
    final decoded = codec.decode(serverReply(
        '1', '2', 'echo:room', 'error', Reply(text: 'denied').writeToBuffer()));
    final reply = PushResponse.fromMessage(decoded);
    expect(reply.status, 'error');
    expect((reply.response as Reply).text, 'denied');
  });

  test('protobuf messages traverse a socket with the convenience serializer',
      () async {
    final codec = createProtobufSerializer(decoder: Reply.fromBuffer);
    final transport =
        FakeTransport(readyImmediately: true, decodeFrame: clientFrameParts);
    transport.onSend = (parts) {
      if (parts[3] == 'phx_join') {
        transport.replyTo(parts);
      } else {
        final request = Request.fromBuffer(parts[4] as Uint8List);
        transport.incoming.add(serverReply(parts[0], parts[1], parts[2], 'ok',
            Reply(text: request.text).writeToBuffer()));
      }
    };
    final socket = PhoenixSocket('ws://unused.invalid/socket',
        socketOptions: PhoenixSocketOptions(
            serializer: codec, heartbeat: const Duration(days: 1)),
        webSocketChannelFactory: (_) => transport);
    addTearDown(socket.dispose);
    await socket.connect();
    final channel = socket.addChannel(topic: 'echo:room');
    await channel.join().future;
    final reply = await channel
        .push('echo', Request(text: 'héllo'), expectingReply: true)
        .future;
    expect(reply.isOk, isTrue);
    expect((reply.response as Reply).text, 'héllo');
  });

  test('selected schemas decode replies and broadcasts into different types',
      () {
    final codec = MessageSerializer(
        payloadCodec: ProtobufPayloadCodec.select(
      decoderFor: (incoming) => incoming.isReply
          ? Reply.fromBuffer
          : incoming.event == 'update'
              ? Update.fromBuffer
              : null,
    ));
    final reply = PushResponse.fromMessage(codec.decode(serverReply(
        '1', '2', 'echo:room', 'ok', Reply(text: 'reply').writeToBuffer())));
    expect((reply.response as Reply).text, 'reply');
    final update = codec.decode(serverBroadcast(
        'echo:room', 'update', Update(id: 'update-42').writeToBuffer()));
    expect((update.payload as Update).id, 'update-42');
    final unknown =
        codec.decode(serverBroadcast('echo:room', 'unknown', [255]));
    expect(unknown.payloadBytes, [255]);
  });
}
