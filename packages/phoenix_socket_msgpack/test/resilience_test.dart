import 'dart:convert';
import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket_msgpack/phoenix_socket_msgpack.dart';
import 'package:test/test.dart';

import '../../phoenix_socket/test/helpers/reproducible_random.dart';
import '../../phoenix_socket/test/helpers/wire_vectors.dart';

void main() {
  test('Python MessagePack vectors decode independently of Dart encoding', () {
    final codec = createMessagePackSerializer();
    for (final vector in independentVectors()['messagepack'] as List) {
      final wire = hexBytes(vector['frame'] as String);
      final expected = wireValue(vector['message']) as List;
      final decoded = codec.decode(wire);
      expect(decoded.encode(), expected, reason: vector['name']);
      expect(codec.encode(Message.fromJson(expected)), wire,
          reason: 'canonical encoding ${vector['name']}');
      expect(
          createBase64MessagePackSerializer()
              .decode(base64.encode(wire))
              .encode(),
          expected);
    }
  });

  test('declared lengths cannot allocate beyond the available frame', () {
    for (final tag in [0xdd, 0xdf, 0xdb, 0xc6]) {
      expect(
          () => MessagePackCodec.decodeBinary(
              Uint8List.fromList([tag, 255, 255, 255, 255])),
          throwsFormatException,
          reason: 'tag=$tag');
    }
  });

  test('numeric and binary reads cannot escape a sliced frame', () {
    for (final bytes in [
      <int>[0xcb, 0],
      <int>[0xc4, 4, 1],
      <int>[0xd9, 4, 65]
    ]) {
      final storage = Uint8List.fromList([...bytes, ...List.filled(32, 0)]);
      final view = Uint8List.sublistView(storage, 0, bytes.length);
      expect(() => MessagePackCodec.decodeBinary(view), throwsFormatException);
    }
  });

  test('nesting is bounded and trailing values are rejected', () {
    expect(
        MessagePackCodec.decodeBinary(Uint8List.fromList([
          ...List.filled(64, 0x91),
          0xc0,
        ])),
        isA<List>());
    for (final leaf in [0xc0, 0x90, 0x80]) {
      expect(
          () => MessagePackCodec.decodeBinary(Uint8List.fromList([
                ...List.filled(65, 0x91),
                leaf,
              ])),
          throwsFormatException);
    }
    expect(
        () => MessagePackCodec.decodeBinary(Uint8List.fromList([0xc0, 0xc0])),
        throwsFormatException);
  });

  for (final seed in [1, 0x51a7, 0x7fffffff]) {
    for (final base64Mode in [false, true]) {
      test('seed $seed round trips 1000 nested trees (base64: $base64Mode)',
          () {
        final random = ReproducibleRandom(seed);
        final codec = base64Mode
            ? createBase64MessagePackSerializer()
            : createMessagePackSerializer();
        for (var index = 0; index < 1000; index++) {
          final payload = random.value(binary: true);
          final message = Message(
              joinRef: index % 3 == 0 ? null : '$index',
              ref: '$index',
              topic: 'room${random.text(6)}',
              event: PhoenixChannelEvent.custom('event'),
              payload: payload);
          final decoded = codec.decode(codec.encode(message));
          expect(decoded.encode(), message.encode(),
              reason: 'seed=$seed case=$index base64=$base64Mode');
        }
      });
    }

    test('seed $seed rejects 2000 truncated or arbitrary bounded frames safely',
        () {
      final random = ReproducibleRandom(seed);
      final codec = createMessagePackSerializer();
      for (var index = 0; index < 2000; index++) {
        final frame = random.bytes(random.nextInt(257));
        try {
          final decoded = codec.decode(frame);
          expect(
              codec.decode(codec.encode(decoded)).encode(), decoded.encode());
        } on FormatException {
          // A structurally invalid or non-envelope value must be rejected.
        } catch (error) {
          fail('seed=$seed case=$index bytes=${frame.toList()}: $error');
        }
      }
      final valid = codec.encode(Message(
          topic: 'room',
          event: PhoenixChannelEvent.custom('event'),
          payload: {'bytes': random.bytes(256)})) as Uint8List;
      for (var end = 0; end < valid.length; end++) {
        final storage = Uint8List.fromList([...valid, ...random.bytes(16)]);
        expect(() => codec.decode(Uint8List.sublistView(storage, 0, end)),
            throwsFormatException,
            reason: 'seed=$seed truncated=$end');
      }
    });
  }
}
