import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket/src/connection_manager/connection_manager.dart';
import 'package:phoenix_socket/src/connection_manager/state.dart';
import 'package:test/test.dart';

import 'helpers/binary_frames.dart';
import 'helpers/fake_transport.dart';
import 'helpers/reproducible_random.dart';

void main() {
  for (final seed in [0x51a7, 0xa11ce]) {
    test('seed $seed routes 1024 concurrent requests across 16 channels',
        () async {
      final random = ReproducibleRandom(seed);
      final transport =
          FakeTransport(readyImmediately: true, decodeFrame: clientFrameParts);
      final queued = <List<dynamic>>[];
      final sent = Completer<void>();
      transport.onSend = (parts) {
        if (parts[3] == 'phx_join') {
          transport.replyTo(parts);
        } else {
          queued.add(parts);
          if (queued.length == 1024) sent.complete();
        }
      };
      final socket = PhoenixSocket('ws://unused.invalid/socket',
          socketOptions: const PhoenixSocketOptions(
              heartbeat: Duration(days: 1), timeout: Duration(seconds: 20)),
          webSocketChannelFactory: (_) => transport);
      addTearDown(socket.dispose);
      await socket.connect();
      final channels = List.generate(
          16, (index) => socket.addChannel(topic: 'stress:$index'));
      await Future.wait(channels.map((channel) => channel.join().future));
      final callbacks = List.filled(1024, 0);
      final pushes = List.generate(1024, (index) {
        final Object payload = index.isEven
            ? Uint8List.fromList([index >>> 8, index & 255])
            : <String, dynamic>{'id': index};
        final push =
            channels[index % 16].push('echo', payload, expectingReply: true);
        push.onReply('ok', (_) => callbacks[index]++);
        return push;
      });
      final results = Future.wait(pushes.map((push) => push.future));
      await sent.future;
      random.shuffle(queued);
      for (var index = 0; index < queued.length; index++) {
        final parts = queued[index];
        final Object reply = parts[4] is Uint8List
            ? serverReply(parts[0], parts[1], parts[2], 'ok', parts[4])
            : jsonEncode([
                parts[0],
                parts[1],
                parts[2],
                'phx_reply',
                {'status': 'ok', 'response': parts[4]}
              ]);
        transport.incoming.add(reply);
        if (index % 7 == 0) transport.incoming.add(reply);
        if (index % 16 == 0) {
          transport.incoming.add(serverBroadcast(parts[2], 'update', [42]));
          await Future<void>.delayed(Duration.zero);
        }
      }
      final replies = await results;
      for (var index = 0; index < replies.length; index++) {
        expect(replies[index].isOk, isTrue,
            reason: 'seed=$seed request=$index');
        if (index.isEven) {
          expect(replies[index].responseBytes, [index >>> 8, index & 255]);
        } else {
          expect(replies[index].responseMap, {'id': index});
        }
      }
      await Future<void>.delayed(Duration.zero);
      expect(callbacks, everyElement(1));
      socket.dispose();
      expect(socket.channels, isEmpty);
      await transport.sink.done;
      expect(transport.sink.closeCalls, 1);
    }, timeout: const Timeout(Duration(seconds: 60)));
  }

  test('100 connect/close cycles settle and release 6400 transport waiters',
      () async {
    FakeTransport? active;
    final manager = ConnectionManager(
        serverUri: 'ws://unused.invalid/socket',
        webSocketChannelFactory: (_) => active = FakeTransport(
            readyImmediately: true, decodeFrame: clientFrameParts));
    addTearDown(manager.dispose);
    for (var cycle = 0; cycle < 100; cycle++) {
      await manager.connect(const PhoenixSocketOptions(
          heartbeat: Duration(days: 1), maxReconnectionAttempts: 0));
      final state = manager.currentState as ConnectedState;
      final results = List.generate(
          64,
          (index) => manager
                  .waitForMessage(Message(
                      topic: 'room',
                      ref: 'cycle$cycle:$index',
                      event: PhoenixChannelEvent.custom('pending'),
                      payload: {}))
                  .then((_) => false, onError: (Object error) {
                expect(error, isA<SocketClosedError>());
                return true;
              }));
      await Future<void>.delayed(Duration.zero);
      expect(state.pendingMessages.length, 64, reason: 'cycle=$cycle');
      manager.close();
      expect(await Future.wait(results), everyElement(true));
      expect(state.pendingMessages, isEmpty);
      expect(manager.currentState, isA<DisconnectedState>());
      await active!.sink.done;
      expect(active!.sink.closeCalls, 1);
    }
    manager.dispose();
    expect(manager.isDisposed(), isTrue);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
      '80 channel replacements ignore late replies and settle abandoned pushes',
      () async {
    final transport =
        FakeTransport(readyImmediately: true, decodeFrame: clientFrameParts);
    final pending = <List<dynamic>>[];
    transport.onSend = (parts) {
      if (parts[3] == 'phx_join') {
        transport.replyTo(parts);
      } else {
        pending.add(parts);
      }
    };
    final socket = PhoenixSocket('ws://unused.invalid/socket',
        socketOptions: const PhoenixSocketOptions(heartbeat: Duration(days: 1)),
        webSocketChannelFactory: (_) => transport);
    addTearDown(socket.dispose);
    await socket.connect();
    var lateCallbacks = 0;
    for (var cycle = 0; cycle < 80; cycle++) {
      final channel = socket.addChannel(topic: 'replace');
      await channel.join().future;
      final pushes = List.generate(12, (index) {
        final push = channel.push('pending', Uint8List.fromList([index]),
            expectingReply: true);
        push.onReply('ok', (_) => lateCallbacks++);
        return push.future.then((_) => false, onError: (Object error) {
          expect(error, isA<ChannelClosedError>());
          return true;
        });
      });
      await Future<void>.delayed(Duration.zero);
      final abandoned = List<List<dynamic>>.of(pending);
      pending.clear();
      channel.close();
      expect(await Future.wait(pushes), everyElement(true));
      final replacement = socket.addChannel(topic: 'replace');
      await replacement.join().future;
      for (final parts in abandoned) {
        transport.incoming
            .add(serverReply(parts[0], parts[1], parts[2], 'ok', [99]));
      }
      await Future<void>.delayed(Duration.zero);
      expect(lateCallbacks, 0, reason: 'cycle=$cycle');
      expect(socket.channels['replace'], same(replacement));
      replacement.close();
      expect(socket.channels, isEmpty);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
