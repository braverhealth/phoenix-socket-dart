import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket_protobuf/phoenix_socket_protobuf.dart';
import 'package:phoenix_protobuf_example/protobuf_codecs.dart';

void main() {
  final request = EchoRequest(text: 'Hello, protobuf');
  final framed = createProtobufSerializer(decoder: EchoReply.fromBuffer);
  final phoenixFrame = framed.encode(Message(
      joinRef: '1',
      ref: '2',
      topic: 'echo:room',
      event: PhoenixChannelEvent.custom('echo'),
      payload: request)) as Uint8List;
  print('Phoenix framing plus protobuf payload: ${phoenixFrame.length} bytes');
  const envelopeCodec = ProtobufEnvelopeCodec();
  final frame = envelopeCodec.encode(Message(
      joinRef: '1',
      ref: '2',
      topic: 'echo:room',
      event: PhoenixChannelEvent.custom('echo'),
      payload: request.writeToBuffer()));
  print('Protobuf envelope: ${frame.length} bytes');
  print(EchoRequest.fromBuffer(envelopeCodec.decode(frame).payloadBytes!).text);
}
