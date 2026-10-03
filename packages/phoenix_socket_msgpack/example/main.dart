import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket_msgpack/phoenix_socket_msgpack.dart';

void main() {
  final codec = createMessagePackSerializer();
  final frame = codec.encode(Message(
      joinRef: '1',
      ref: '2',
      topic: 'room',
      event: PhoenixChannelEvent.custom('echo'),
      payload: {'text': 'Hello, MessagePack'})) as Uint8List;
  print('MessagePack envelope: ${frame.length} bytes');
  print(codec.decode(frame).payloadMap!['text']);
}
