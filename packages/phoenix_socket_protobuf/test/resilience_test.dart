import 'dart:typed_data';

import 'package:phoenix_socket_protobuf/phoenix_socket_protobuf.dart';
import 'package:protobuf/protobuf.dart' show InvalidProtocolBufferException;
import 'package:test/test.dart';

import '../../phoenix_socket/test/helpers/reproducible_random.dart';
import '../../phoenix_socket/test/helpers/wire_vectors.dart';
import 'helpers/messages.dart';

const context = PayloadContext(topic: 'room', event: 'event');

void main() {
  test('Google Python protobuf vectors decode and retain unknown fields', () {
    for (final vector in independentVectors()['protobuf'] as List) {
      final codec = ProtobufPayloadCodec(
          decoder: vector['schema'] == 'Reply'
              ? Reply.fromBuffer
              : Update.fromBuffer);
      final wire = hexBytes(vector['frame'] as String);
      final decoded = codec.decode(wire, context) as GeneratedMessage;
      final value = decoded is Reply ? decoded.text : (decoded as Update).id;
      expect(value, vector['value'], reason: vector['name']);
      expect(decoded.writeToBuffer(), wire, reason: vector['name']);
    }
  });

  for (final seed in [1, 0x51a7, 0x7fffffff]) {
    test('seed $seed decodes 2000 mutated bounded protobuf bodies safely', () {
      final random = ReproducibleRandom(seed);
      const codec = ProtobufPayloadCodec(decoder: Reply.fromBuffer);
      for (var index = 0; index < 2000; index++) {
        final Uint8List wire;
        if (index.isEven) {
          wire = random.bytes(random.nextInt(257));
        } else {
          wire = Reply(text: random.text(40)).writeToBuffer();
          if (wire.isNotEmpty) wire[random.nextInt(wire.length)] ^= 0xff;
        }
        try {
          final decoded = codec.decode(wire, context) as Reply;
          final encoded = codec.encode(decoded, context) as Uint8List;
          expect((codec.decode(encoded, context) as Reply).text, decoded.text,
              reason: 'seed=$seed case=$index');
        } on InvalidProtocolBufferException {
          // Wire rejection is valid; other errors fail and report the corpus.
        } on FormatException {
          // Invalid UTF-8 is rejected by the protobuf runtime.
        } on ArgumentError {
          // Malformed lengths yield RangeError on VM or ArgumentError in JS.
        } catch (error) {
          fail('seed=$seed case=$index bytes=${wire.toList()}: $error');
        }
      }
    });

    test('seed $seed preserves 1000 routed unicode messages and byte views',
        () {
      final random = ReproducibleRandom(seed);
      final codec = ProtobufPayloadCodec.select(
          decoderFor: (incoming) =>
              incoming.event == 'reply' ? Reply.fromBuffer : Update.fromBuffer);
      for (var index = 0; index < 1000; index++) {
        final text = random.text(80);
        final GeneratedMessage value =
            index.isEven ? Reply(text: text) : Update(id: text);
        final incoming = PayloadContext(
            topic: 'room', event: index.isEven ? 'reply' : 'update');
        final wire = codec.encode(value, incoming) as Uint8List;
        final prefix = random.nextInt(20) + 1;
        final storage = Uint8List.fromList(
            [...random.bytes(prefix), ...wire, ...random.bytes(20)]);
        final view =
            Uint8List.sublistView(storage, prefix, prefix + wire.length);
        final decoded = codec.decode(view, incoming);
        expect(decoded is Reply ? decoded.text : (decoded as Update).id, text,
            reason: 'seed=$seed case=$index');
      }
    });
  }

  test('10000 control payloads bypass schema selection and encoding', () {
    var selections = 0;
    final codec = ProtobufPayloadCodec.select(decoderFor: (_) {
      selections++;
      return Reply.fromBuffer;
    });
    for (var index = 0; index < 10000; index++) {
      final control = <String, dynamic>{'counter': index};
      expect(identical(codec.encode(control, context), control), isTrue);
      expect(identical(codec.decode(control, context), control), isTrue);
    }
    expect(selections, 0);
  });
}
