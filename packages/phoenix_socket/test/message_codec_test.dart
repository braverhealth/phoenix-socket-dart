import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

import 'helpers/binary_frames.dart';

void main() {
  const serializer = MessageSerializer();

  for (final enabled in [false, true]) {
    test('payload logging only formats values when enabled ($enabled)', () {
      final oldLevel = Logger.root.level;
      Logger.root.level = enabled ? Level.FINEST : Level.INFO;
      addTearDown(() => Logger.root.level = oldLevel);
      final records = <LogRecord>[];
      final subscription = Logger.root.onRecord.listen(records.add);
      addTearDown(subscription.cancel);
      final probe = _PayloadStringificationProbe();
      final message = Message(
          topic: 'room',
          event: PhoenixChannelEvent.custom('echo'),
          payload: {'value': probe});

      final parts = message.encode() as List<dynamic>;
      final decoded = Message.fromJson(parts);

      expect(identical(decoded.payload, message.payload), isTrue);
      expect(probe.stringifications, enabled ? 2 : 0);
      final messageLogs = records
          .where((record) => record.loggerName == 'phoenix_socket.message')
          .map((record) => record.message);
      if (enabled) {
        expect(messageLogs, [
          allOf(startsWith('Message encoded'), contains('payload probe')),
          allOf(startsWith('Message decoded'), contains('payload probe')),
        ]);
      } else {
        expect(messageLogs, isEmpty);
      }
    });
  }

  test('JSON configuration and round trips remain compatible', () {
    final message = Message(
        joinRef: '1',
        ref: '2',
        topic: 'room',
        event: PhoenixChannelEvent.custom('hello'),
        payload: {'text': 'héllo'});
    expect(serializer.encode(message),
        '["1","2","room","hello",{"text":"héllo"}]');
    expect(serializer.decode(serializer.encode(message)).payloadMap,
        {'text': 'héllo'});
    expect(
        serializer.decode(serializer.encode(Message.heartbeat('3'))).payloadMap,
        {});
  });

  test('client push uses Phoenix framing and UTF-8 byte lengths', () {
    final payload = Uint8List.fromList([0, 128, 255]);
    final message = Message(
        joinRef: '1',
        ref: '2',
        topic: 'røom',
        event: PhoenixChannelEvent.custom('écho'),
        payload: payload);
    expect(
        serializer.encode(message),
        Uint8List.fromList([
          0,
          1,
          1,
          5,
          5,
          49,
          50,
          ...utf8.encode('røom'),
          ...utf8.encode('écho'),
          0,
          128,
          255,
        ]));
    expect(clientFrameParts(serializer.encode(message))[4], payload);
  });

  test('server push has no request reference', () {
    final decoded = serializer.decode(serverPush('1', 'room', 'echo', [1, 2]));
    expect(decoded.joinRef, '1');
    expect(decoded.ref, isNull);
    expect(decoded.topic, 'room');
    expect(decoded.event.value, 'echo');
    expect(decoded.payloadBytes, [1, 2]);
  });

  test('binary replies preserve status and response bytes', () {
    final decoded =
        serializer.decode(serverReply('1', '2', 'room', 'ok', [3, 4]));
    expect(decoded.event, PhoenixChannelEvent.reply);
    expect(decoded.ref, '2');
    final reply = PushResponse.fromMessage(decoded);
    expect(reply.isOk, isTrue);
    expect(reply.responseBytes, [3, 4]);
  });

  test('broadcast supports empty bytes and null references', () {
    final decoded = serializer.decode(serverBroadcast('room', 'empty', []));
    expect(decoded.joinRef, isNull);
    expect(decoded.ref, isNull);
    expect(decoded.payloadBytes, isEmpty);
  });

  test('frame subviews respect offsets and share payload storage', () {
    final fixture = serverReply('1', '2', 'røom', 'ok', [128, 255]);
    final storage = Uint8List.fromList([99, 98, ...fixture, 97, 96]);
    final frame = Uint8List.sublistView(storage, 2, storage.length - 2);
    final reply = PushResponse.fromMessage(serializer.decode(frame));
    expect(reply.responseBytes, [128, 255]);
    storage[storage.length - 3] = 42;
    expect(reply.responseBytes!.last, 42);
  });

  for (final frame in [
    <int>[],
    [9],
    [0],
    [1, 0, 0, 0],
    [2, 5, 0, 65],
    [0, 1, 1, 1, 255, 65, 66]
  ]) {
    test('rejects malformed binary frame $frame', () {
      expect(() => serializer.decode(Uint8List.fromList(frame)),
          throwsFormatException);
    });
  }

  test('binary metadata limits count UTF-8 bytes', () {
    final event = List.filled(128, 'é').join();
    expect(
        () => serializer.encode(Message(
            event: PhoenixChannelEvent.custom(event), payload: Uint8List(0))),
        throwsArgumentError);
    final valid = List.filled(255, 'x').join();
    expect(
        serializer.encode(Message(
            event: PhoenixChannelEvent.custom(valid), payload: Uint8List(0))),
        isA<Uint8List>());
  });

  for (final frame in [
    '{}',
    '[]',
    '[null,null,"room",5,{}]',
    '[1,null,"room","event",{}]'
  ]) {
    test('rejects malformed message array $frame', () {
      expect(() => serializer.decode(frame), throwsFormatException);
    });
  }

  test('custom envelope callbacks handle heartbeat messages', () {
    final codec = MessageSerializer(
      binaryEncoder: (parts) =>
          Uint8List.fromList(utf8.encode(jsonEncode(parts))),
      binaryDecoder: (bytes) => jsonDecode(utf8.decode(bytes)),
    );
    final frame = codec.encode(Message.heartbeat('1'));
    expect(frame, isA<Uint8List>());
    expect(codec.decode(frame).event, PhoenixChannelEvent.heartbeat);
  });

  test('payload codec encodes selected values using routing context', () {
    PayloadContext? context;
    final codec = MessageSerializer(payloadCodec: CallbackPayloadCodec(
      encoder: (value, ctx) {
        context = ctx;
        return ctx.event == 'echo' ? Uint8List.fromList([value as int]) : value;
      },
    ));
    final message = Message(
        joinRef: '1',
        ref: '2',
        topic: 'room',
        event: PhoenixChannelEvent.custom('echo'),
        payload: 42);
    expect(clientFrameParts(codec.encode(message))[4], [42]);
    expect(context!.topic, 'room');
    expect(context!.ref, '2');
    expect(codec.encode(Message.heartbeat('3')), isA<String>());
  });

  test('payload codec decodes binary reply bodies without changing status', () {
    PayloadContext? context;
    final codec = MessageSerializer(payloadCodec: CallbackPayloadCodec(
      decoder: (value, ctx) {
        context = ctx;
        return value is Uint8List ? value.single : value;
      },
    ));
    final reply = PushResponse.fromMessage(
        codec.decode(serverReply('1', '2', 'room', 'error', [42])));
    expect(reply.status, 'error');
    expect(reply.response, 42);
    expect(context!.event, 'phx_reply');
    expect(context!.isReply, isTrue);
    expect(context!.replyStatus, 'error');
  });

  test('canonical payload decoder maps retain identity, including reply bodies',
      () {
    final canonical = <String, dynamic>{
      'nested': <String, dynamic>{'answer': 42}
    };
    final codec = MessageSerializer(payloadDecoder: (_) => canonical);
    expect(
        identical(codec.decode(serverBroadcast('room', 'event', [1])).payload,
            canonical),
        isTrue);
    final reply = PushResponse.fromMessage(
        codec.decode(serverReply('1', '2', 'room', 'ok', [1])));
    expect(identical(reply.response, canonical), isTrue);
  });

  test('dynamic maps normalize recursively while retaining byte buffers', () {
    final bytes = Uint8List.fromList([7, 8]);
    final codec = MessageSerializer(
        payloadDecoder: (_) => <dynamic, dynamic>{
              'nested': <dynamic, dynamic>{'bytes': bytes},
            });
    final payload =
        codec.decode(serverBroadcast('room', 'event', [1])).payloadMap!;
    expect(payload['nested'], isA<Map<String, dynamic>>());
    expect(identical(payload['nested']['bytes'], bytes), isTrue);
  });

  test('normalization rejects keys that collide after conversion', () {
    final codec = MessageSerializer(
        payloadDecoder: (_) => <dynamic, dynamic>{1: 'a', '1': 'b'});
    expect(() => codec.decode(serverBroadcast('room', 'event', [1])),
        throwsFormatException);
  });

  test('typed payload and reply accessors reject mismatched types', () {
    final bytes = Message(
        event: PhoenixChannelEvent.custom('event'), payload: Uint8List(0));
    expect(() => bytes.payloadMap, throwsStateError);
    expect(() => Message.heartbeat('1').payloadBytes, throwsStateError);
    expect(
        () => const PushResponse(response: {}).responseBytes, throwsStateError);
    expect(() => PushResponse(response: Uint8List(0)).responseMap,
        throwsStateError);
  });
}

class _PayloadStringificationProbe {
  int stringifications = 0;

  @override
  String toString() {
    stringifications++;
    return 'payload probe';
  }
}
