import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket/src/connection_manager/connection_manager.dart';
import 'package:test/test.dart';

import 'helpers/binary_frames.dart';
import 'helpers/fake_transport.dart';

FakeTransport binaryTransport() => FakeTransport(
      readyImmediately: true,
      decodeFrame: clientFrameParts,
    );

PhoenixSocket socketFor(FakeTransport transport, {MessageCodec? codec}) {
  final socket = PhoenixSocket('ws://unused.invalid/socket',
      socketOptions: PhoenixSocketOptions(
          serializer: codec,
          maxReconnectionAttempts: 0,
          heartbeat: const Duration(days: 1)),
      webSocketChannelFactory: (_) => transport);
  transport.onSend = (parts) {
    if (parts[3] == 'phx_join' || parts[3] == 'phx_leave') {
      transport.replyTo(parts);
    }
  };
  addTearDown(socket.dispose);
  return socket;
}

void main() {
  test(
      'channel binary pushes and replies coexist with JSON joins and heartbeats',
      () async {
    final transport = binaryTransport();
    final heartbeat = Completer<void>();
    transport.onFrame = (frame) {
      if (frame is String &&
          jsonDecode(frame)[3] == 'heartbeat' &&
          !heartbeat.isCompleted) {
        heartbeat.complete();
      }
    };
    final socket = socketFor(transport);
    await socket.connect();
    await heartbeat.future;
    final channel = socket.addChannel(topic: 'room');
    await channel.join().future;
    transport.onSend = (parts) => transport.incoming.add(serverReply(
        parts[0] as String?,
        parts[1] as String?,
        'room',
        'ok',
        parts[4] as Uint8List));
    final push = channel.push('echo', Uint8List.fromList([0, 128, 255]),
        expectingReply: true);
    expect((await push.future).responseBytes, [0, 128, 255]);
    expect(transport.frames.whereType<String>(), isNotEmpty);
    expect(transport.frames.whereType<Uint8List>(), hasLength(1));
    expect(transport.sent.any((parts) => parts[3] == 'heartbeat'), isTrue);
  });

  test('binary broadcasts are delivered to both channel and topic listeners',
      () async {
    final transport = binaryTransport();
    final socket = socketFor(transport);
    await socket.connect();
    final channel = socket.addChannel(topic: 'room');
    await channel.join().future;
    final topic = socket.streamForTopic('room').first;
    final received = channel.messages.first;
    transport.incoming.add(serverBroadcast('room', 'update', [1, 2]));
    expect((await topic).payloadBytes, [1, 2]);
    expect((await received).payloadBytes, [1, 2]);
  });

  for (final asBuffer in [false, true]) {
    test('transport normalizes ${asBuffer ? 'ByteBuffer' : 'List<int>'} input',
        () async {
      final transport = binaryTransport();
      final socket = socketFor(transport);
      await socket.connect();
      final received = socket.messageStream.first;
      final frame = serverBroadcast('room', 'update', [5]);
      transport.incoming.add(asBuffer ? frame.buffer : frame.toList());
      expect((await received).payloadBytes, [5]);
    });
  }

  test('buffered binary requests are sent after channel join', () async {
    final transport = binaryTransport();
    final socket = socketFor(transport);
    await socket.connect();
    final channel = socket.addChannel(topic: 'room');
    final joining = channel.join();
    final request =
        channel.push('echo', Uint8List.fromList([42]), expectingReply: true);
    transport.onSend = (parts) {
      if (parts[3] == 'phx_join') {
        transport.replyTo(parts);
      } else {
        transport.incoming
            .add(serverReply(parts[0], parts[1], 'room', 'ok', [42]));
      }
    };
    await joining.future;
    expect((await request.future).responseBytes, [42]);
  });

  test('binary fire-and-forget pushes retain their send mode', () async {
    final transport = binaryTransport();
    final socket = socketFor(transport);
    await socket.connect();
    final channel = socket.addChannel(topic: 'room');
    await channel.join().future;
    final sent = Completer<List<dynamic>>();
    transport.onSend = (parts) => sent.complete(parts);
    final push =
        channel.push('notice', Uint8List.fromList([42]), expectingReply: false);
    final parts = await sent.future;
    expect(push.sent, isTrue);
    expect(parts[4], [42]);
    socket.dispose();
  });

  test('malformed binary frames report errors and settle pending pushes',
      () async {
    final transport = binaryTransport();
    final socket = socketFor(transport);
    await socket.connect();
    final channel = socket.addChannel(topic: 'room');
    await channel.join().future;
    transport.onSend = (_) {};
    final push =
        channel.push('echo', Uint8List.fromList([1]), expectingReply: true);
    final failure =
        expectLater(push.future, throwsA(isA<ChannelClosedError>()));
    final error = socket.errorStream.first;
    transport.incoming.add(Uint8List.fromList([9]));
    expect((await error).error, isA<FormatException>());
    await failure;
    expect(channel.state, PhoenixChannelState.errored);
  });

  test('callback-only pushes close without an unhandled completion future',
      () async {
    final transport = binaryTransport();
    final socket = socketFor(transport);
    await socket.connect();
    final channel = socket.addChannel(topic: 'room');
    await channel.join().future;
    transport.onSend = (_) {};
    final push =
        channel.push('echo', Uint8List.fromList([1]), expectingReply: true);
    push.onReply('ok', (_) {});
    channel.close();
    await Future<void>.delayed(Duration.zero);
    expect(channel.state, PhoenixChannelState.closed);
  });

  test('invalid custom codec output reports a socket error', () async {
    final transport = binaryTransport();
    final socket = socketFor(transport, codec: const _InvalidOutputCodec());
    final error = socket.errorStream.first;
    await socket.connect();
    socket.sendMessage(Message.heartbeat('request'));
    expect((await error).error, isA<FormatException>());
    expect(transport.frames, isEmpty);
  });

  for (final encoding in [true, false]) {
    test('payload ${encoding ? 'encoder' : 'decoder'} failures settle pushes',
        () async {
      final failure = StateError('application codec failed');
      final codec = MessageSerializer(
          payloadCodec: CallbackPayloadCodec(
        encoder: (value, context) {
          if (encoding && context.event == 'echo') throw failure;
          return value;
        },
        decoder: (value, context) {
          if (!encoding && context.isReply && value is Uint8List) {
            throw failure;
          }
          return value;
        },
      ));
      final transport = binaryTransport();
      final socket = socketFor(transport, codec: codec);
      await socket.connect();
      final channel = socket.addChannel(topic: 'room');
      await channel.join().future;
      transport.onSend = (parts) => transport.incoming.add(
          serverReply(parts[0], parts[1], 'room', 'ok', parts[4] as Uint8List));
      final error = socket.errorStream.first;
      final push =
          channel.push('echo', Uint8List.fromList([42]), expectingReply: true);
      final failedPush =
          expectLater(push.future, throwsA(isA<ChannelClosedError>()));

      expect((await error).error, same(failure));
      await failedPush;
      expect(channel.state, PhoenixChannelState.errored);
      expect(transport.sent.any((parts) => parts[3] == 'echo'), !encoding);
      await Future<void>.delayed(Duration.zero);
    });
  }

  test('malformed reply envelopes fail their push without an unhandled future',
      () async {
    final transport = binaryTransport();
    final socket = socketFor(transport);
    await socket.connect();
    final channel = socket.addChannel(topic: 'room');
    await channel.join().future;
    transport.onSend = (parts) => transport.incoming.add(jsonEncode([
          parts[0],
          parts[1],
          'room',
          'phx_reply',
          {'status': 42, 'response': {}},
        ]));
    final push = channel.push('echo', {}, expectingReply: true);
    await expectLater(push.future, throwsFormatException);
    await Future<void>.delayed(Duration.zero);
  });

  test('Presence receives decoded binary state and diffs', () async {
    final transport = binaryTransport();
    final codec = MessageSerializer(
        payloadCodec: CallbackPayloadCodec(
      decoder: (value, context) =>
          context.event.startsWith('presence_') && value is Uint8List
              ? jsonDecode(utf8.decode(value))
              : value,
    ));
    final socket = socketFor(transport, codec: codec);
    await socket.connect();
    final channel = socket.addChannel(topic: 'room');
    final presence = PhoenixPresence<Map<String, Object?>>(channel: channel);
    addTearDown(presence.dispose);
    await channel.join().future;
    final synchronized = presence.snapshots.firstWhere((s) => s.isSynchronized);
    transport.incoming.add(serverPush(
        channel.joinRef,
        'room',
        'presence_state',
        utf8.encode(jsonEncode({
          'a': {
            'metas': [
              {'phx_ref': 'a1'}
            ]
          },
        }))));
    expect((await synchronized).presences.keys, ['a']);
    final changed =
        presence.snapshots.firstWhere((s) => s.presences.containsKey('b'));
    transport.incoming.add(serverPush(
        channel.joinRef,
        'room',
        'presence_diff',
        utf8.encode(jsonEncode({
          'joins': {
            'b': {
              'metas': [
                {'phx_ref': 'b1'}
              ]
            }
          },
          'leaves': {
            'a': {
              'metas': [
                {'phx_ref': 'a1'}
              ]
            }
          },
        }))));
    expect((await changed).presences.keys, ['b']);
  });

  test('per-socket logger names reach the connection manager', () async {
    final oldLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    addTearDown(() => Logger.root.level = oldLevel);
    final records = <LogRecord>[];
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    final first = PhoenixSocket('ws://unused.invalid/socket',
        loggerName: 'client.one',
        webSocketChannelFactory: (_) => binaryTransport());
    final second = PhoenixSocket('ws://unused.invalid/socket',
        loggerName: 'client.two',
        webSocketChannelFactory: (_) => binaryTransport());
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.connect();
    await second.connect();
    first.addChannel(topic: 'room');
    second.addChannel(topic: 'room');
    final names = records.map((record) => record.loggerName).toSet();
    expect(
        names,
        containsAll([
          'client.one',
          'client.two',
          'client.one.connection_manager',
          'client.two.connection_manager'
        ]));
  });

  test('queued binary frames are ignored when their connection is closed',
      () async {
    var decoded = 0;
    final transport = binaryTransport();
    final codec = MessageSerializer(binaryDecoder: (_) {
      decoded++;
      return [null, null, 'room', 'late', {}];
    });
    final manager = ConnectionManager(
        serverUri: 'ws://unused.invalid/socket',
        webSocketChannelFactory: (_) => transport);
    addTearDown(manager.dispose);
    await manager.connect(PhoenixSocketOptions(
        serializer: codec, heartbeat: const Duration(days: 1)));
    transport.incoming.add(Uint8List.fromList([42]));
    manager.close();
    await Future<void>.delayed(Duration.zero);
    expect(decoded, 0);
  });

  test('reconnection retains binary request/reply support', () async {
    final first = binaryTransport();
    final second = binaryTransport();
    for (final transport in [first, second]) {
      transport.onSend = (parts) {
        if (parts[3] == 'phx_join') {
          transport.replyTo(parts);
        } else {
          transport.incoming
              .add(serverReply(parts[0], parts[1], 'room', 'ok', [7]));
        }
      };
    }
    var attempts = 0;
    final socket = PhoenixSocket('ws://unused.invalid/socket',
        socketOptions: const PhoenixSocketOptions(
            reconnectDelays: [], heartbeat: Duration(days: 1)),
        webSocketChannelFactory: (_) => attempts++ == 0 ? first : second);
    addTearDown(socket.dispose);
    await socket.connect();
    final channel = socket.addChannel(topic: 'room');
    await channel.join().future;
    expect(
        (await channel.push('echo', Uint8List(0), expectingReply: true).future)
            .responseBytes,
        [7]);
    final rejoined =
        channel.stateStream.firstWhere((s) => s == PhoenixChannelState.joined);
    await first.incoming.close();
    await rejoined;
    expect(
        (await channel.push('echo', Uint8List(0), expectingReply: true).future)
            .responseBytes,
        [7]);
    expect(attempts, 2);
  });
}

class _InvalidOutputCodec implements MessageCodec {
  const _InvalidOutputCodec();

  @override
  Object encode(Message message) => 42;

  @override
  Message decode(Object frame) => const MessageSerializer().decode(frame);
}
