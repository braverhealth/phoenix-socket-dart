import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket_msgpack/phoenix_socket_msgpack.dart';

import '../../phoenix_socket/tool/benchmark_utils.dart';

void main() {
  for (final size in [1024, 100 * 1024, 2 * 1024 * 1024]) {
    final message = Message(
        joinRef: '1',
        ref: '2',
        topic: 'room',
        event: PhoenixChannelEvent.custom('update'),
        payload: {'data': List.filled(size, 'x').join()});
    for (final base64 in [false, true]) {
      final codec = base64
          ? createBase64MessagePackSerializer()
          : createMessagePackSerializer();
      final frame = codec.encode(message);
      final length =
          frame is String ? frame.length : (frame as Uint8List).length;
      benchmark(base64 ? 'msgpack_base64' : 'msgpack_binary', size, length, () {
        final encoded = codec.encode(message);
        final bytes =
            encoded is String ? encoded.length : (encoded as Uint8List).length;
        return bytes +
            (codec.decode(frame).payloadMap!['data'] as String).length;
      });
    }
  }
}
