import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

import 'helpers/binary_frames.dart';
import 'helpers/reproducible_random.dart';
import 'helpers/wire_vectors.dart';

void main() {
  const codec = MessageSerializer();

  test('seed corpus is identical across VM and JavaScript', () {
    final random = ReproducibleRandom(1);
    expect(List.generate(5, (_) => random.nextInt(0x100000000)),
        [270369, 67634689, 2647435461, 307599695, 2398689233]);
  });

  test('client bytes match the official Phoenix JavaScript serializer', () {
    for (final vector in independentVectors()['phoenix']['clients'] as List) {
      final expected = hexBytes(vector['frame'] as String);
      final message = Message.binary(
          joinRef: vector['join_ref'] == '' ? null : vector['join_ref'],
          ref: vector['ref'] == '' ? null : vector['ref'],
          topic: vector['topic'],
          event: PhoenixChannelEvent.custom(vector['event']),
          payload: Uint8List.fromList((vector['bytes'] as List).cast<int>()));
      expect(codec.encode(message), expected, reason: vector['name']);
    }
  });

  test('server vectors agree with the official JavaScript decoder', () {
    for (final vector in independentVectors()['phoenix']['servers'] as List) {
      final expected = vector['message'];
      final message = codec.decode(hexBytes(vector['frame'] as String));
      expect(message.joinRef, expected['join_ref'], reason: vector['name']);
      expect(message.ref, expected['ref']);
      expect(message.topic, expected['topic']);
      expect(message.event.value, expected['event']);
      expect(message.payload, wireValue(expected['payload']));
    }
  });

  for (final seed in [1, 0x51a7, 0x7fffffff]) {
    test('seed $seed preserves randomized binary framing and byte ownership',
        () {
      final random = ReproducibleRandom(seed);
      for (var index = 0; index < 1000; index++) {
        final joinRef = random.nextInt(4) == 0 ? null : '$index';
        final ref = random.nextInt(4) == 0 ? null : '${index + 1}';
        final topic = random.text(24);
        final event = random.text(24);
        final bytes = random.bytes(random.nextInt(1025));
        final message = Message.binary(
            joinRef: joinRef,
            ref: ref,
            topic: topic,
            event: PhoenixChannelEvent.custom(event),
            payload: bytes);
        final outbound = codec.encode(message) as Uint8List;
        final parts = clientFrameParts(outbound);
        final reason = 'seed=$seed case=$index';
        expect(parts, [joinRef, ref, topic, event, bytes], reason: reason);
        if (bytes.isNotEmpty) {
          final first = bytes.first;
          bytes[0] ^= 0xff;
          expect((clientFrameParts(outbound)[4] as Uint8List).first, first);
          bytes[0] = first;
        }
        final frames = [
          serverPush(joinRef, topic, event, bytes),
          serverReply(joinRef, ref, topic, 'ok', bytes),
          serverBroadcast(topic, event, bytes),
        ];
        for (var kind = 0; kind < frames.length; kind++) {
          final prefix = random.nextInt(32) + 1;
          final storage = Uint8List.fromList(
              [...random.bytes(prefix), ...frames[kind], ...random.bytes(17)]);
          final view = Uint8List.sublistView(
              storage, prefix, prefix + frames[kind].length);
          final decoded = codec.decode(view);
          final payload = kind == 1
              ? PushResponse.fromMessage(decoded).responseBytes!
              : decoded.payloadBytes!;
          expect(payload, bytes, reason: '$reason kind=$kind');
          expect(payload.offsetInBytes + payload.length,
              view.offsetInBytes + view.length);
          expect(decoded.topic, topic);
          if (bytes.isNotEmpty) {
            storage[view.offsetInBytes + view.length - 1] ^= 0xff;
            expect(payload.last, bytes.last ^ 0xff);
          }
        }
      }
    });

    test('seed $seed handles 2000 arbitrary bounded binary frames safely', () {
      final random = ReproducibleRandom(seed);
      for (var index = 0; index < 2000; index++) {
        final frame = random.bytes(random.nextInt(257));
        try {
          final decoded = codec.decode(frame);
          final payload = decoded.isReply
              ? PushResponse.fromMessage(decoded).responseBytes!
              : decoded.payloadBytes!;
          expect(payload.length, lessThanOrEqualTo(frame.length));
          expect(
              payload.offsetInBytes, greaterThanOrEqualTo(frame.offsetInBytes));
          expect(payload.offsetInBytes + payload.length,
              frame.offsetInBytes + frame.length);
        } on FormatException {
          // Rejection is valid; RangeError, StateError and other exceptions fail.
        } catch (error) {
          fail('seed=$seed case=$index bytes=${frame.toList()}: $error');
        }
      }
    });

    test('seed $seed rejects every truncation within metadata', () {
      final random = ReproducibleRandom(seed);
      for (var index = 0; index < 100; index++) {
        final frame = serverReply('join$index', 'ref$index',
            'topic${random.text(12)}', 'ok', random.bytes(20));
        final metadataEnd = frame.length - 20;
        for (var end = 0; end < metadataEnd; end++) {
          expect(() => codec.decode(Uint8List.sublistView(frame, 0, end)),
              throwsFormatException,
              reason: 'seed=$seed case=$index end=$end');
        }
      }
    });

    test('seed $seed round trips 1000 bounded JSON trees', () {
      final random = ReproducibleRandom(seed);
      for (var index = 0; index < 1000; index++) {
        final payload = random.value();
        final message = Message(
            topic: 'room',
            ref: '$index',
            event: PhoenixChannelEvent.custom('event'),
            payload: payload);
        final decoded = codec.decode(codec.encode(message));
        expect(decoded.payload, payload, reason: 'seed=$seed case=$index');
        expect(decoded.ref, '$index');
      }
    });
  }
}
