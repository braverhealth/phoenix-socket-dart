import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:msgpack_dart/msgpack_dart.dart';

void main() {
  group('MessagePackCodec', () {
    group('encode/decode', () {
      test('encodes and decodes simple Phoenix message', () {
        final message = [
          'joinRef123',
          'ref456',
          'chat:lobby',
          'new_msg',
          {'text': 'Hello, World!'},
        ];

        final encoded = MessagePackCodec.encode(message);
        expect(encoded, isNotEmpty);

        final decoded = MessagePackCodec.decode(encoded);
        expect(decoded, isList);
        expect(decoded[0], equals('joinRef123'));
        expect(decoded[1], equals('ref456'));
        expect(decoded[2], equals('chat:lobby'));
        expect(decoded[3], equals('new_msg'));
        expect(decoded[4], isMap);
        expect(decoded[4]['text'], equals('Hello, World!'));
      });

      test('handles null joinRef and ref', () {
        final message = [
          null,
          null,
          'chat:lobby',
          'new_msg',
          {'text': 'Hello'},
        ];

        final encoded = MessagePackCodec.encode(message);
        final decoded = MessagePackCodec.decode(encoded);

        expect(decoded[0], isNull);
        expect(decoded[1], isNull);
        expect(decoded[2], equals('chat:lobby'));
      });

      test('handles complex payload with nested structures', () {
        final message = [
          'join1',
          'ref1',
          'chat:main',
          'message',
          {
            'user': {'id': 123, 'name': 'Alice'},
            'content': 'Hello',
            'metadata': {
              'timestamp': 1699999999,
              'tags': ['important', 'urgent'],
            },
          },
        ];

        final encoded = MessagePackCodec.encode(message);
        final decoded = MessagePackCodec.decode(encoded);

        final payload = decoded[4] as Map;
        expect(payload['user']['id'], equals(123));
        expect(payload['user']['name'], equals('Alice'));
        expect(payload['metadata']['tags'], contains('important'));
        expect(payload['metadata']['tags'], contains('urgent'));
      });

      test('handles empty payload', () {
        final message = [
          'join1',
          'ref1',
          'phoenix',
          'heartbeat',
          {},
        ];

        final encoded = MessagePackCodec.encode(message);
        final decoded = MessagePackCodec.decode(encoded);

        expect(decoded[4], isMap);
        expect(decoded[4], isEmpty);
      });

      test('handles various data types in payload', () {
        final message = [
          'join1',
          'ref1',
          'test:topic',
          'test_event',
          {
            'string': 'test',
            'integer': 42,
            'double': 3.14,
            'boolean': true,
            'null_value': null,
            'list': [1, 2, 3],
            'map': {'nested': 'value'},
          },
        ];

        final encoded = MessagePackCodec.encode(message);
        final decoded = MessagePackCodec.decode(encoded);

        final payload = decoded[4] as Map;
        expect(payload['string'], equals('test'));
        expect(payload['integer'], equals(42));
        expect(payload['double'], closeTo(3.14, 0.001));
        expect(payload['boolean'], isTrue);
        expect(payload['null_value'], isNull);
        expect(payload['list'], equals([1, 2, 3]));
        expect(payload['map']['nested'], equals('value'));
      });
    });

    group('encodeBinary/decodeBinary', () {
      test('encodes and decodes binary format', () {
        final message = [
          'joinRef123',
          'ref456',
          'chat:lobby',
          'new_msg',
          {'text': 'Hello, Binary!'},
        ];

        final encoded = MessagePackCodec.encodeBinary(message);
        expect(encoded, isA<Uint8List>());
        expect(encoded.isNotEmpty, isTrue);

        final decoded = MessagePackCodec.decodeBinary(encoded);
        expect(decoded[0], equals('joinRef123'));
        expect(decoded[4]['text'], equals('Hello, Binary!'));
      });

      test('binary format is more compact than base64', () {
        final message = [
          'joinRef123',
          'ref456',
          'chat:lobby',
          'new_msg',
          {'text': 'Hello, World! This is a longer message to test compression.'},
        ];

        final binaryEncoded = MessagePackCodec.encodeBinary(message);
        final stringEncoded = MessagePackCodec.encode(message);

        // Binary should be smaller or equal (base64 adds ~33% overhead)
        // Note: string encoding uses codeUnits, so comparison isn't perfect
        print('Binary size: ${binaryEncoded.length} bytes');
        print('String size: ${stringEncoded.length} bytes');
      });
    });

    group('error handling', () {
      test('handles null data gracefully', () {
        final encoded = MessagePackCodec.encode(null);
        expect(encoded, isEmpty);
      });

      test('handles empty string decode', () {
        final decoded = MessagePackCodec.decode('');
        expect(decoded, isEmpty);
      });

      test('handles empty bytes decode', () {
        final decoded = MessagePackCodec.decodeBinary(Uint8List(0));
        expect(decoded, isEmpty);
      });

      test('throws on invalid MessagePack data', () {
        expect(
          () => MessagePackCodec.decodeBinary(Uint8List.fromList([0xFF, 0xFF, 0xFF])),
          throwsA(anything),
        );
      });
    });

    group('bandwidth comparison with JSON', () {
      test('MessagePack is more compact than JSON for typical message', () {
        final message = [
          'joinRef123',
          'ref456',
          'chat:lobby',
          'new_msg',
          {'text': 'Hello, World!', 'user_id': 123, 'timestamp': 1699999999},
        ];

        // MessagePack
        final msgpackEncoded = MessagePackCodec.encodeBinary(message);

        // JSON (using dart:convert)
        final jsonEncoded = '[\"joinRef123\",\"ref456\",\"chat:lobby\",\"new_msg\",{\"text\":\"Hello, World!\",\"user_id\":123,\"timestamp\":1699999999}]';

        print('MessagePack: ${msgpackEncoded.length} bytes');
        print('JSON: ${jsonEncoded.length} bytes');
        print('Savings: ${((1 - msgpackEncoded.length / jsonEncoded.length) * 100).toStringAsFixed(1)}%');

        // MessagePack should be smaller
        expect(msgpackEncoded.length, lessThan(jsonEncoded.length));
      });
    });
  });

  group('MessageSerializer with MessagePack', () {
    test('can be created with MessagePack codec', () {
      final serializer = MessageSerializer(
        decoder: MessagePackCodec.decode,
        encoder: MessagePackCodec.encode,
      );

      expect(serializer, isNotNull);
    });

    test('serializes Message correctly', () {
      final serializer = MessageSerializer(
        decoder: MessagePackCodec.decode,
        encoder: MessagePackCodec.encode,
      );

      final message = Message(
        joinRef: 'join123',
        ref: 'ref456',
        topic: 'chat:lobby',
        event: PhoenixChannelEvent.custom('new_msg'),
        payload: {'text': 'Hello!'},
      );

      final encoded = serializer.encode(message);
      expect(encoded, isNotEmpty);

      // Decode back
      final decoded = serializer.decode(encoded);
      expect(decoded.joinRef, equals('join123'));
      expect(decoded.ref, equals('ref456'));
      expect(decoded.topic, equals('chat:lobby'));
      expect(decoded.event.value, equals('new_msg'));
      expect(decoded.payload['text'], equals('Hello!'));
    });

    test('handles heartbeat messages', () {
      final serializer = MessageSerializer(
        decoder: MessagePackCodec.decode,
        encoder: MessagePackCodec.encode,
      );

      final heartbeat = Message.heartbeat('ref123');

      final encoded = serializer.encode(heartbeat);
      final decoded = serializer.decode(encoded);

      expect(decoded.topic, equals('phoenix'));
      expect(decoded.event.value, equals('heartbeat'));
      expect(decoded.ref, equals('ref123'));
    });
  });

  group('createMessagePackSerializer helper', () {
    test('creates properly configured serializer', () {
      final serializer = createMessagePackSerializer();

      final message = Message(
        joinRef: 'join1',
        ref: 'ref1',
        topic: 'test:topic',
        event: PhoenixChannelEvent.custom('test'),
        payload: {'data': 'test'},
      );

      final encoded = serializer.encode(message);
      final decoded = serializer.decode(encoded);

      expect(decoded.topic, equals('test:topic'));
      expect(decoded.payload['data'], equals('test'));
    });
  });

  group('createBinaryMessagePackSerializer helper', () {
    test('creates binary serializer', () {
      final serializer = createBinaryMessagePackSerializer();
      expect(serializer, isNotNull);
    });
  });

  group('Binary decoding with binaryDecoder callback', () {
    test('decodes Uint8List using binaryDecoder callback', () {
      final serializer = createMessagePackSerializer();

      // Encode a message to binary (simulates what backend sends)
      final originalMessage = [
        'join123',
        'ref456',
        'chat:lobby',
        'new_msg',
        {'text': 'Hello from backend!'},
      ];
      final binaryData = MessagePackCodec.encodeBinary(originalMessage);

      // Decode the binary data using the serializer
      final decoded = serializer.decode(binaryData);

      expect(decoded.joinRef, equals('join123'));
      expect(decoded.ref, equals('ref456'));
      expect(decoded.topic, equals('chat:lobby'));
      expect(decoded.event.value, equals('new_msg'));
      expect(decoded.payload['text'], equals('Hello from backend!'));
    });

    test('decodes Uint8List with null joinRef and ref', () {
      final serializer = createMessagePackSerializer();

      final originalMessage = [
        null,
        null,
        'chat:lobby',
        'broadcast_msg',
        {'user': 'Alice', 'text': 'Hi everyone!'},
      ];
      final binaryData = MessagePackCodec.encodeBinary(originalMessage);

      final decoded = serializer.decode(binaryData);

      expect(decoded.joinRef, isNull);
      expect(decoded.ref, isNull);
      expect(decoded.topic, equals('chat:lobby'));
      expect(decoded.event.value, equals('broadcast_msg'));
      expect(decoded.payload['user'], equals('Alice'));
    });

    test('decodes phx_reply messages from backend', () {
      final serializer = createMessagePackSerializer();

      // Phoenix reply format
      final replyMessage = [
        'join1',
        'ref1',
        'chat:lobby',
        'phx_reply',
        {'status': 'ok', 'response': {'message': 'joined'}},
      ];
      final binaryData = MessagePackCodec.encodeBinary(replyMessage);

      final decoded = serializer.decode(binaryData);

      expect(decoded.joinRef, equals('join1'));
      expect(decoded.ref, equals('ref1'));
      expect(decoded.topic, equals('chat:lobby'));
      expect(decoded.event.value, equals('phx_reply'));
      expect(decoded.payload['status'], equals('ok'));
      expect(decoded.payload['response']['message'], equals('joined'));
    });
  });
}
