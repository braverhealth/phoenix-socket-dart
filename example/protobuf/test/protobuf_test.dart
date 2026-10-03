import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_protobuf_example/protobuf_codecs.dart';
import 'package:test/test.dart';

import '../../../test/helpers/binary_frames.dart';
import '../../../test/helpers/fake_transport.dart';

void main() {
  test('protobuf payloads traverse channel pushes and binary replies',
      () async {
    const codec = MessageSerializer(payloadCodec: EchoPayloadCodec());
    final transport =
        FakeTransport(readyImmediately: true, decodeFrame: clientFrameParts);
    transport.onSend = (parts) {
      if (parts[3] == 'phx_join') {
        transport.replyTo(parts);
      } else {
        final request = EchoRequest.fromBuffer(parts[4] as Uint8List);
        transport.incoming.add(serverReply(parts[0], parts[1], parts[2], 'ok',
            EchoReply(text: request.text).writeToBuffer()));
      }
    };
    final socket = PhoenixSocket('ws://unused.invalid/socket',
        socketOptions: const PhoenixSocketOptions(
            serializer: codec, heartbeat: Duration(days: 1)),
        webSocketChannelFactory: (_) => transport);
    addTearDown(socket.dispose);
    await socket.connect();
    final channel = socket.addChannel(topic: 'echo:room');
    await channel.join().future;
    final reply = await channel
        .push('echo', EchoRequest(text: 'héllo'), expectingReply: true)
        .future;
    expect(reply.isOk, isTrue);
    expect((reply.response as EchoReply).text, 'héllo');
  });

  test('protobuf envelope preserves null references, maps and empty bytes', () {
    const codec = ProtobufEnvelopeCodec();
    final heartbeat = codec.decode(codec.encode(Message.heartbeat('2')));
    expect(heartbeat.joinRef, isNull);
    expect(heartbeat.ref, '2');
    expect(heartbeat.payloadMap, {});
    final bytes = codec.decode(codec.encode(Message(
        topic: 'room',
        event: PhoenixChannelEvent.custom('empty'),
        payload: Uint8List(0))));
    expect(bytes.payloadBytes, isEmpty);
  });

  test('protobuf envelope supports socket joins, heartbeats and replies',
      () async {
    const codec = ProtobufEnvelopeCodec();
    final transport = FakeTransport(
        readyImmediately: true,
        decodeFrame: (frame) => codec.decode(frame).encode() as List<dynamic>,
        encodeFrame: (parts) => codec.encode(Message.fromJson(parts)));
    transport.onSend = (parts) {
      final response = parts[3] == 'phx_join' ? <String, dynamic>{} : parts[4];
      transport.incoming.add(codec.encode(Message(
          joinRef: parts[0],
          ref: parts[1],
          topic: parts[2],
          event: PhoenixChannelEvent.reply,
          payload: {'status': 'ok', 'response': response})));
    };
    final socket = PhoenixSocket('ws://unused.invalid/socket',
        socketOptions: const PhoenixSocketOptions(
            serializer: codec, heartbeat: Duration(days: 1)),
        webSocketChannelFactory: (_) => transport);
    addTearDown(socket.dispose);
    await socket.connect();
    final channel = socket.addChannel(topic: 'echo:room');
    await channel.join().future;
    final reply = await channel
        .push('echo', EchoRequest(text: 'protobuf').writeToBuffer(),
            expectingReply: true)
        .future;
    expect(EchoRequest.fromBuffer(reply.responseBytes!).text, 'protobuf');
  });

  test('malformed protobuf frames fail decoding', () {
    const codec = ProtobufEnvelopeCodec();
    expect(() => codec.decode('text'), throwsFormatException);
    expect(() => codec.decode(Uint8List(0)), throwsFormatException);
    expect(
        () => codec.decode(
            Envelope(event: 'phx_reply', binaryResponse: [1]).writeToBuffer()),
        throwsFormatException);
    expect(() => codec.decode(Uint8List.fromList([10, 255])),
        throwsA(isA<Exception>()));
  });
}
