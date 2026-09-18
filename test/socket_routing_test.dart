import 'dart:async';
import 'dart:convert';

import 'package:mockito/mockito.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

import 'mocks.dart';

class _SocketHarness {
  final incoming = StreamController<String>();
  final network = MockWebSocketChannel();
  final sink = MockWebSocketSink();
  late final PhoenixSocket socket;

  _SocketHarness() {
    when(network.stream).thenAnswer((_) => incoming.stream);
    when(network.ready).thenAnswer((_) async {});
    when(network.sink).thenReturn(sink);
    when(network.closeCode).thenReturn(null);
    when(sink.close(any, any)).thenAnswer((_) async {});
    when(sink.add(any)).thenAnswer((invocation) {
      final parts = jsonDecode(invocation.positionalArguments.first as String)
          as List<dynamic>;
      incoming.add(jsonEncode([
        parts[0],
        parts[1],
        parts[2],
        'phx_reply',
        {'status': 'ok', 'response': <String, dynamic>{}},
      ]));
    });
    socket = PhoenixSocket(
      'ws://unused.invalid/socket/websocket',
      socketOptions: PhoenixSocketOptions(timeout: const Duration(seconds: 1)),
      webSocketChannelFactory: (_) => network,
    );
  }

  Future<void> cleanup() async {
    socket.dispose();
    await incoming.close();
  }
}

void main() {
  late _SocketHarness harness;

  setUp(() async {
    harness = _SocketHarness();
    await harness.socket.connect();
  });

  tearDown(() => harness.cleanup());

  test('canceling the last topic listener allows relistening and channel join',
      () async {
    final topicStream = harness.socket.streamForTopic('room');
    await topicStream.listen((_) {}).cancel();
    final observedReply = topicStream.first;

    final channel = harness.socket.addChannel(topic: 'room');
    expect((await channel.join().future).isOk, isTrue);
    expect((await observedReply).event, PhoenixChannelEvent.reply);
    expect(channel.state, PhoenixChannelState.joined);

    final laterReply = topicStream.first;
    final request = channel.push('request', {}, expectingReply: true);
    expect((await request.future).isOk, isTrue);
    expect((await laterReply).ref, request.ref);
  });

  test('external topic observer receives replies through channel replacement',
      () async {
    final observed = <Message>[];
    final observer = harness.socket.streamForTopic('room').listen(observed.add);
    addTearDown(observer.cancel);

    final original = harness.socket.addChannel(topic: 'room');
    expect((await original.join().future).isOk, isTrue);
    original.close();

    final replacement = harness.socket.addChannel(topic: 'room');
    expect(identical(original, replacement), isFalse);
    expect((await replacement.join().future).isOk, isTrue);
    expect(replacement.state, PhoenixChannelState.joined);
    expect(observed.map((message) => message.ref),
        [original.joinRef, replacement.joinRef]);

    final request = replacement.push('request', {}, expectingReply: true);
    expect((await request.future).isOk, isTrue);
    expect(observed.last.ref, request.ref);
  });

  test('removing a stale channel does not remove its replacement', () async {
    final original = harness.socket.addChannel(topic: 'room');
    await original.join().future;
    original.close();

    final replacement = harness.socket.addChannel(topic: 'room');
    harness.socket.removeChannel(original);
    expect(harness.socket.channels['room'], same(replacement));
    expect(harness.socket.addChannel(topic: 'room'), same(replacement));
    expect((await replacement.join().future).isOk, isTrue);
    expect(replacement.state, PhoenixChannelState.joined);

    original.close();
    expect(harness.socket.channels['room'], same(replacement));
  });

  test('socket disposal completes external topic streams', () async {
    final streamDone = harness.socket.streamForTopic('room').drain<void>();
    final channel = harness.socket.addChannel(topic: 'room');
    await channel.join().future;
    harness.socket.dispose();
    await streamDone;
    expect(channel.state, PhoenixChannelState.closed);
    expect(harness.socket.channels, isEmpty);
  });

  test('void reconnect reports setup failure without an unhandled future',
      () async {
    final socket = PhoenixSocket('ws://example.invalid/socket',
        socketOptions: const PhoenixSocketOptions(maxReconnectionAttempts: 0),
        webSocketChannelFactory: (_) => throw StateError('factory failed'));
    addTearDown(socket.dispose);
    final error = socket.errorStream.first;
    socket.close(null, null, true);
    expect((await error).error, isA<StateError>());
    await Future<void>.delayed(Duration.zero);
    expect(socket.isConnected, isFalse);
  });
}
