import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:phoenix_socket/phoenix_socket.dart';

void main() {
  late MessageSerializer serializer;
  final exampleMsg = Message(
    joinRef: '0',
    ref: '1',
    topic: 't',
    event: PhoenixChannelEvent.custom('e'),
    payload: {'foo': 1},
  );

  Uint8List binPayload() {
    return Uint8List.fromList([1]);
  }

  setUp(() {
    serializer = const MessageSerializer();
  });

  group('MessageSerializer', () {
    group('JSON', () {
      test('encodes general pushes', () {
        final encoded = serializer.encode(exampleMsg);
        expect(encoded, equals('["0","1","t","e",{"foo":1}]'));
      });

      test('decodes', () {
        final decoded = serializer.decode('["0","1","t","e",{"foo":1}]');
        expect(decoded.joinRef, equals('0'));
        expect(decoded.ref, equals('1'));
        expect(decoded.topic, equals('t'));
        expect(decoded.event.value, equals('e'));
        expect(decoded.payload, equals({'foo': 1}));
      });
    });

    group('Binary', () {
      test('encodes', () {
        final buffer = binPayload();
        final message = Message(
          joinRef: '0',
          ref: '1',
          topic: 't',
          event: PhoenixChannelEvent.custom('e'),
          payload: buffer,
        );

        final encoded = serializer.encode(message);
        final expected = Uint8List.fromList([
          0, // push type
          1, // joinRef length
          1, // ref length
          1, // topic length
          1, // event length
          ...utf8.encode('0'), // joinRef
          ...utf8.encode('1'), // ref
          ...utf8.encode('t'), // topic
          ...utf8.encode('e'), // event
          1, // payload
        ]);

        expect(encoded, equals(expected));
      });

      test('encodes variable length segments', () {
        final buffer = binPayload();
        final message = Message(
          joinRef: '10',
          ref: '1',
          topic: 'top',
          event: PhoenixChannelEvent.custom('ev'),
          payload: buffer,
        );

        final encoded = serializer.encode(message);
        final expected = Uint8List.fromList([
          0, // push type
          2, // joinRef length
          1, // ref length
          3, // topic length
          2, // event length
          ...utf8.encode('10'), // joinRef
          ...utf8.encode('1'), // ref
          ...utf8.encode('top'), // topic
          ...utf8.encode('ev'), // event
          1, // payload
        ]);

        expect(encoded, equals(expected));
      });

      test('decodes push', () {
        final List<int> message = [
          0, // push type
          3, // joinRef length
          3, // topic length
          10, // event length
          ...utf8.encode('123'), // joinRef
          ...utf8.encode('top'), // topic
          ...utf8.encode('some-event'), // event
          1, 1, // payload
        ];

        final decoded = serializer.decode(Uint8List.fromList(message));

        expect(decoded.joinRef, equals('123'));
        expect(decoded.ref, isNull);
        expect(decoded.topic, equals('top'));
        expect(decoded.event.value, equals('some-event'));
        expect(decoded.payload, equals(Uint8List.fromList([1, 1])));
      });

      test('decodes reply', () {
        final List<int> message = [
          1, // reply type
          3, // joinRef length
          2, // ref length
          3, // topic length
          2, // event length
          ...utf8.encode('100'), // joinRef
          ...utf8.encode('12'), // ref
          ...utf8.encode('top'), // topic
          ...utf8.encode('ok'), // event/status
          1, 1, // payload
        ];

        final decoded = serializer.decode(Uint8List.fromList(message));

        expect(decoded.joinRef, equals('100'));
        expect(decoded.ref, equals('12'));
        expect(decoded.topic, equals('top'));
        expect(decoded.event.value, equals('phx_reply'));
        expect(decoded.payload, isA<Map>());
        expect(decoded.payload?['status'], equals('ok'));
        expect(
            decoded.payload?['response'], equals(Uint8List.fromList([1, 1])));
      });

      test('decodes broadcast', () {
        final List<int> message = [
          2, // broadcast type
          3, // topic length
          10, // event length
          ...utf8.encode('top'),
          ...utf8.encode('some-event'),
          1, 1, // payload
        ];

        final decoded = serializer.decode(Uint8List.fromList(message));

        expect(decoded.joinRef, isNull);
        expect(decoded.ref, isNull);
        expect(decoded.topic, equals('top'));
        expect(decoded.event.value, equals('some-event'));
        expect(decoded.payload, equals(Uint8List.fromList([1, 1])));
      });
    });

    group('Error cases', () {
      test('throws on invalid message type', () {
        expect(
          () => serializer.decode(123),
          throwsA(isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            contains('non-string or a non-list of integers'),
          )),
        );
      });

      test('handles malformed JSON', () {
        expect(
          () => serializer.decode('{"bad json"}'),
          throwsA(isA<FormatException>()),
        );
      });
    });

    group('Edge cases', () {
      test('handles empty binary payload', () {
        final List<int> message = [
          2, // broadcast type
          3, // topic length
          5, // event length
          ...utf8.encode('top'),
          ...utf8.encode('event'),
          // empty payload
        ];

        final decoded = serializer.decode(Uint8List.fromList(message));

        expect(decoded.payload, isEmpty);
      });

      test('handles custom payload decoder', () {
        Map<String, dynamic> customDecoder(Uint8List payload) => {
              'nested': {'data': 42},
              'list': [
                {'item': 1},
                {'item': 2}
              ],
            };

        final serializer = MessageSerializer(
          payloadDecoder: customDecoder,
        );

        final List<int> message = [
          2, // broadcast type
          3, // topic length
          5, // event length
          ...utf8.encode('top'),
          ...utf8.encode('event'),
          1, // payload
        ];

        final decoded = serializer.decode(Uint8List.fromList(message));

        expect(decoded.payload?['nested']['data'], equals(42));
        expect(decoded.payload?['list'][0]['item'], equals(1));
        expect(decoded.payload?['list'][1]['item'], equals(2));
      });
    });
  });
}
