import 'dart:convert';
import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';

import '../test/helpers/binary_frames.dart';
import '../test/helpers/fake_transport.dart';
import 'benchmark_utils.dart';

Future<void> main(List<String> args) async {
  const serializer = MessageSerializer();
  for (final size in [1024, 100 * 1024, 2 * 1024 * 1024]) {
    final message = Message(
      joinRef: '1',
      ref: '2',
      topic: 'room',
      event: PhoenixChannelEvent.custom('update'),
      payload: {'data': List.filled(size, 'x').join()},
    );
    final frame = serializer.encode(message);
    final iterations = size > 1024 * 1024 ? 20 : 200;
    for (var i = 0; i < 10; i++) {
      serializer.decode(serializer.encode(message));
    }
    final watch = Stopwatch()..start();
    var checksum = 0;
    for (var i = 0; i < iterations; i++) {
      checksum += serializer.encode(message).toString().length;
      checksum += serializer.decode(frame).topic!.length;
    }
    watch.stop();
    print(jsonEncode({
      'codec': 'json',
      'payload_bytes': size,
      'frame_bytes': frame.toString().length,
      'iterations': iterations,
      'microseconds_per_exchange': watch.elapsedMicroseconds / iterations,
      'checksum': checksum,
    }));
  }
  for (final size in [1024, 100 * 1024, 2 * 1024 * 1024]) {
    final bytes = Uint8List(size);
    final message = Message.binary(
        joinRef: '1',
        ref: '2',
        topic: 'room',
        event: PhoenixChannelEvent.custom('update'),
        payload: bytes);
    final inbound = serverBroadcast('room', 'update', bytes);
    benchmark('phoenix_binary', size,
        (serializer.encode(message) as Uint8List).length, () {
      final encoded = serializer.encode(message) as Uint8List;
      final decoded = serializer.decode(inbound);
      return encoded.length + decoded.payloadBytes!.length;
    });
  }
  for (final size in [1024, 100 * 1024, 2 * 1024 * 1024]) {
    for (final binary in [false, true]) {
      await _roundTrips(size, binary);
    }
  }
}

Future<void> _roundTrips(int size, bool binary) async {
  final transport =
      FakeTransport(readyImmediately: true, decodeFrame: clientFrameParts);
  transport.onSend = (parts) {
    if (parts[3] == 'phx_join') {
      transport.replyTo(parts);
    } else if (binary) {
      transport.incoming.add(
          serverReply(parts[0], parts[1], 'room', 'ok', parts[4] as Uint8List));
    } else {
      transport.incoming.add(jsonEncode([
        parts[0],
        parts[1],
        'room',
        'phx_reply',
        {'status': 'ok', 'response': parts[4]}
      ]));
    }
  };
  final socket = PhoenixSocket('ws://benchmark.invalid/socket',
      socketOptions: const PhoenixSocketOptions(heartbeat: Duration(days: 1)),
      webSocketChannelFactory: (_) => transport);
  try {
    await socket.connect();
    final channel = socket.addChannel(topic: 'room');
    await channel.join().future;
    final Object payload =
        binary ? Uint8List(size) : {'data': List.filled(size, 'x').join()};
    for (var i = 0; i < 5; i++) {
      await channel.push('echo', payload, expectingReply: true).future;
      transport.sent.clear();
      transport.frames.clear();
    }
    final samples = <int>[];
    var checksum = 0;
    final iterations = size > 1024 * 1024 ? 20 : 200;
    final total = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      final watch = Stopwatch()..start();
      final reply =
          await channel.push('echo', payload, expectingReply: true).future;
      samples.add(watch.elapsedMicroseconds);
      checksum += binary
          ? reply.responseBytes!.length
          : (reply.responseMap!['data'] as String).length;
      transport.sent.clear();
      transport.frames.clear();
    }
    total.stop();
    samples.sort();
    print(jsonEncode({
      'codec': binary ? 'binary_fake_transport' : 'json_fake_transport',
      'payload_bytes': size,
      'iterations': iterations,
      'p50_microseconds': samples[samples.length ~/ 2],
      'p95_microseconds': samples[(samples.length * .95).ceil() - 1],
      'exchanges_per_second': iterations * 1000000 / total.elapsedMicroseconds,
      'checksum': checksum
    }));
  } finally {
    socket.dispose();
  }
}
