import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket_protobuf/phoenix_socket_protobuf.dart';
import 'package:phoenix_protobuf_example/protobuf_codecs.dart';

import '../../../test/helpers/binary_frames.dart';
import '../../../tool/benchmark_utils.dart';

void main() {
  for (final size in [1024, 100 * 1024, 2 * 1024 * 1024]) {
    final text = List.filled(size, 'x').join();
    final request = EchoRequest(text: text);
    final response = EchoReply(text: text).writeToBuffer();
    final payloadCodec =
        createProtobufSerializer(decoder: EchoReply.fromBuffer);
    final message = Message(
        joinRef: '1',
        ref: '2',
        topic: 'echo:room',
        event: PhoenixChannelEvent.custom('echo'),
        payload: request);
    final inbound = serverReply('1', '2', 'echo:room', 'ok', response);
    benchmark('protobuf_payload', size,
        (payloadCodec.encode(message) as Uint8List).length, () {
      final encoded = payloadCodec.encode(message) as Uint8List;
      final decoded = payloadCodec.decode(inbound);
      return encoded.length +
          (decoded.payloadMap!['response'] as EchoReply).text.length;
    });
    const envelopeCodec = ProtobufEnvelopeCodec();
    final enveloped = Message(
        joinRef: '1',
        ref: '2',
        topic: 'echo:room',
        event: PhoenixChannelEvent.custom('echo'),
        payload: response);
    final frame = envelopeCodec.encode(enveloped);
    benchmark('protobuf_envelope', size, frame.length, () {
      final outgoing = Message(
          joinRef: '1',
          ref: '2',
          topic: 'echo:room',
          event: PhoenixChannelEvent.custom('echo'),
          payload: request.writeToBuffer());
      final encoded = envelopeCodec.encode(outgoing);
      final decoded = envelopeCodec.decode(frame);
      return encoded.length +
          EchoReply.fromBuffer(decoded.payloadBytes!).text.length;
    });
  }
}
