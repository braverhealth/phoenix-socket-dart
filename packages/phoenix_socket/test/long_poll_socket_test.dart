import 'dart:async';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket/src/connection_manager/connection_manager.dart';
import 'package:phoenix_socket/src/connection_manager/state.dart';
import 'package:test/test.dart';

import 'helpers/controlled_http_client.dart';
import 'helpers/fake_transport.dart';
import 'helpers/long_poll_server.dart';

class MemorySessionStore implements PhoenixSocketSessionStore {
  final values = <String, String>{};
  @override
  String? getItem(String key) => values[key];
  @override
  void setItem(String key, String value) => values[key] = value;
  @override
  void removeItem(String key) => values.remove(key);
}

class ThrowingSessionStore implements PhoenixSocketSessionStore {
  @override
  String? getItem(String key) => throw StateError('storage unavailable');
  @override
  void setItem(String key, String value) =>
      throw StateError('storage unavailable');
  @override
  void removeItem(String key) => throw StateError('storage unavailable');
}

class CountingCodec implements MessageCodec {
  int encodes = 0;
  int decodes = 0;
  @override
  Object encode(Message message) {
    encodes++;
    return const MessageSerializer().encode(message);
  }

  @override
  Message decode(Object frame) {
    decodes++;
    return const MessageSerializer().decode(frame);
  }
}

Future<void> eventually(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('Condition never became true');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  const endpoint = 'ws://example.invalid/socket/websocket';
  const polling = PhoenixSocketOptions(
    transport: PhoenixSocketTransport.longPolling,
    reconnectDelays: [],
    heartbeat: Duration(milliseconds: 1),
    heartbeatTimeout: Duration(milliseconds: 1),
  );

  test(
      'a late WebSocket close failure cannot reset the replacement long-poll channel',
      () async {
    final close = Completer<void>();
    close.future.ignore();
    final ws = FakeTransport(afterClose: () => close.future);
    final server = LongPollServer();
    final socket = PhoenixSocket(endpoint,
        httpClientFactory: server.createClient,
        webSocketChannelFactory: (_) => ws,
        socketOptions: PhoenixSocketOptions(
            longPollFallbackAfter: const Duration(milliseconds: 10),
            sessionStorage: MemorySessionStore()));
    addTearDown(socket.dispose);
    final errors = <PhoenixSocketErrorEvent>[];
    socket.errorStream.listen(errors.add);
    await socket.connect();
    final channel = socket.addChannel(topic: 'audit:late-close');
    await channel.join().future;
    close.completeError(StateError('late close failure'));
    await Future<void>.delayed(Duration.zero);
    expect(errors, isEmpty);
    expect(channel.canPush, isTrue);
    expect(
        (await channel
                .push('echo', {'still': 'connected'}, expectingReply: true)
                .future)
            .responseMap,
        {'still': 'connected'});
  });

  test(
      'closing synchronously during the health probe leaves no active heartbeat timer',
      () async {
    final ws = FakeTransport(readyImmediately: true, replyToHeartbeats: false);
    late ConnectionManager manager;
    late ConnectedState opened;
    ws.onSend = (_) {
      opened = manager.currentState as ConnectedState;
      manager.close();
    };
    manager = ConnectionManager(
        serverUri: endpoint, webSocketChannelFactory: (_) => ws);
    addTearDown(manager.dispose);
    await manager.connect(PhoenixSocketOptions(
        longPollFallbackAfter: const Duration(seconds: 1),
        sessionStorage: MemorySessionStore()));
    expect(manager.currentState, isA<DisconnectedState>());
    expect(opened.heartbeatTimeout?.isActive ?? false, isFalse);
    expect(ws.sink.closeCalls, 1);
  });

  test('fallback opening deadline is independent of the channel push timeout',
      () async {
    final ws = FakeTransport();
    final server = LongPollServer();
    final socket = PhoenixSocket(endpoint,
        httpClientFactory: server.createClient,
        webSocketChannelFactory: (_) => ws,
        socketOptions: PhoenixSocketOptions(
            timeout: const Duration(milliseconds: 1),
            longPollFallbackAfter: const Duration(milliseconds: 50),
            sessionStorage: MemorySessionStore()));
    addTearDown(socket.dispose);
    final connection = socket.connect();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    ws.readyCompleter.complete();
    await connection;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(socket.transport, PhoenixSocketTransport.webSocket);
    expect(server.clients, isEmpty);
  });

  test('fallback health probe is independent of heartbeatTimeout', () async {
    final ws = FakeTransport(readyImmediately: true, replyToHeartbeats: false);
    final server = LongPollServer();
    final socket = PhoenixSocket(endpoint,
        httpClientFactory: server.createClient,
        webSocketChannelFactory: (_) => ws,
        socketOptions: PhoenixSocketOptions(
            heartbeatTimeout: const Duration(milliseconds: 1),
            longPollFallbackAfter: const Duration(milliseconds: 20),
            maxReconnectionAttempts: 0,
            sessionStorage: MemorySessionStore()));
    addTearDown(socket.dispose);
    await socket.connect();
    await eventually(() =>
        socket.transport == PhoenixSocketTransport.longPolling &&
        socket.isConnected);
    expect(server.clients, hasLength(1));
    expect(ws.sink.closeCalls, 1);
  });

  test(
      'a regular heartbeat reply does not satisfy a different fallback probe ref',
      () async {
    final ws = FakeTransport(readyImmediately: true, replyToHeartbeats: false);
    var heartbeats = 0;
    ws.onSend = (parts) {
      if (parts[3] == 'heartbeat' && ++heartbeats > 1) ws.replyTo(parts);
    };
    final server = LongPollServer();
    final socket = PhoenixSocket(endpoint,
        httpClientFactory: server.createClient,
        webSocketChannelFactory: (_) => ws,
        socketOptions: PhoenixSocketOptions(
            heartbeat: const Duration(milliseconds: 5),
            longPollFallbackAfter: const Duration(milliseconds: 30),
            sessionStorage: MemorySessionStore()));
    addTearDown(socket.dispose);
    await socket.connect();
    await eventually(() =>
        socket.transport == PhoenixSocketTransport.longPolling &&
        socket.isConnected);
    expect(heartbeats, greaterThan(1));
  });

  test('auth token callback can cancel before an HTTP client is created',
      () async {
    final server = LongPollServer();
    late PhoenixSocket socket;
    socket = PhoenixSocket(endpoint,
        httpClientFactory: server.createClient,
        socketOptions: PhoenixSocketOptions(
            transport: PhoenixSocketTransport.longPolling,
            dynamicAuthToken: () {
              socket.close();
              return 'stale';
            }));
    addTearDown(socket.dispose);
    expect(await socket.connect(), isNull);
    expect(server.clients, isEmpty);
  });

  test('a cancelling HTTP factory cannot leak the client it returns', () async {
    final client = ControlledHttpClient();
    late PhoenixSocket socket;
    socket =
        PhoenixSocket(endpoint, socketOptions: polling, httpClientFactory: () {
      socket.close();
      return client;
    });
    addTearDown(socket.dispose);
    expect(await socket.connect(), isNull);
    await Future<void>.delayed(Duration.zero);
    expect(client.closed, isTrue);
    expect(client.requests, isEmpty);
  });

  test('fallback after a previously healthy WebSocket is not memorized',
      () async {
    final first = FakeTransport(readyImmediately: true);
    final second = FakeTransport();
    var creations = 0;
    final server = LongPollServer();
    final store = MemorySessionStore();
    final socket = PhoenixSocket(endpoint,
        httpClientFactory: server.createClient,
        webSocketChannelFactory: (_) => creations++ == 0 ? first : second,
        socketOptions: PhoenixSocketOptions(
            longPollFallbackAfter: const Duration(milliseconds: 20),
            sessionStorage: store));
    addTearDown(socket.dispose);
    final health = socket.messageStream
        .firstWhere((message) => message.topic == 'phoenix');
    await socket.connect();
    await health;
    socket.close();
    await socket.connect();
    expect(socket.transport, PhoenixSocketTransport.longPolling);
    expect(store.values, isEmpty);
  });

  test(
      'forced long polling uses the default codec, matching the JS constructor',
      () async {
    final server = LongPollServer();
    final codec = CountingCodec();
    final socket = PhoenixSocket(endpoint,
        httpClientFactory: server.createClient,
        socketOptions: PhoenixSocketOptions(
            transport: PhoenixSocketTransport.longPolling, serializer: codec));
    addTearDown(socket.dispose);
    await socket.connect();
    final channel = socket.addChannel(topic: 'audit:default-codec');
    await channel.join().future;
    expect(
        (await channel.push('echo', {'value': 1}, expectingReply: true).future)
            .responseMap,
        {'value': 1});
    expect(codec.encodes, 0);
    expect(codec.decodes, 0);
  });

  test('automatic fallback retains the original codec', () async {
    final server = LongPollServer();
    final codec = CountingCodec();
    final ws = FakeTransport();
    final socket = PhoenixSocket(endpoint,
        httpClientFactory: server.createClient,
        webSocketChannelFactory: (_) => ws,
        socketOptions: PhoenixSocketOptions(
            serializer: codec,
            longPollFallbackAfter: const Duration(milliseconds: 10),
            sessionStorage: MemorySessionStore()));
    addTearDown(socket.dispose);
    await socket.connect();
    final channel = socket.addChannel(topic: 'audit:retained-codec');
    await channel.join().future;
    expect(codec.encodes, greaterThan(0));
    expect(codec.decodes, greaterThan(0));
  });

  test('unavailable optional storage does not block a fallback connection',
      () async {
    final server = LongPollServer();
    final socket = PhoenixSocket(endpoint,
        httpClientFactory: server.createClient,
        webSocketChannelFactory: (_) => FakeTransport(),
        socketOptions: PhoenixSocketOptions(
            longPollFallbackAfter: const Duration(milliseconds: 10),
            sessionStorage: ThrowingSessionStore()));
    addTearDown(socket.dispose);
    expect(await socket.connect(), same(socket));
    expect(socket.transport, PhoenixSocketTransport.longPolling);
  });

  test('empty fallback history does not select long polling', () async {
    final store = MemorySessionStore()..setItem('phx:fallback:LongPoll', '');
    final server = LongPollServer();
    final socket = PhoenixSocket(endpoint,
        httpClientFactory: server.createClient,
        webSocketChannelFactory: (_) => FakeTransport(readyImmediately: true),
        socketOptions: PhoenixSocketOptions(
            longPollFallbackAfter: const Duration(milliseconds: 30),
            sessionStorage: store));
    addTearDown(socket.dispose);
    await socket.connect();
    expect(socket.transport, PhoenixSocketTransport.webSocket);
    expect(server.clients, isEmpty);
  });

  test('zero socket poll timeout selects the reference default of 20 seconds',
      () async {
    final client = ControlledHttpClient();
    final manager =
        ConnectionManager(serverUri: endpoint, httpClientFactory: () => client);
    addTearDown(manager.dispose);
    final connection = manager.connect(const PhoenixSocketOptions(
        transport: PhoenixSocketTransport.longPolling,
        longPollTimeout: Duration.zero));
    (await client.take('GET'))
        .reply({'status': 410, 'token': 't', 'messages': []});
    await connection;
    final transport =
        (manager.currentState as ConnectedState).channel as PhoenixLongPoll;
    expect(transport.timeout, const Duration(seconds: 20));
  });

  test(
      'forced polling supports join, request/reply, events and leave with no heartbeat',
      () async {
    final server = LongPollServer();
    final socket = PhoenixSocket(endpoint,
        socketOptions: polling,
        httpClientFactory: server.createClient,
        webSocketChannelFactory: (_) =>
            throw StateError('WebSocket must not be used'));
    addTearDown(socket.dispose);
    expect(await socket.connect(), same(socket));
    expect(socket.transport, PhoenixSocketTransport.longPolling);
    expect(socket.mountPoint.path, '/socket/longpoll');
    final channel = socket.addChannel(topic: 'audit:longpoll');
    expect((await channel.join().future).isOk, isTrue);
    final reply = await channel
        .push('echo', {'value': 'é🐦'}, expectingReply: true)
        .future;
    expect(reply.responseMap, {'value': 'é🐦'});
    final event = channel.messages
        .firstWhere((message) => message.event.value == 'observed');
    channel.push('no_reply', {'value': 42}, expectingReply: false);
    expect((await event).payloadMap, {'value': 42});
    expect((await channel.leave().future).isOk, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(
        server.requests
            .where((r) => r.method == 'POST')
            .any((r) => r.body.contains('heartbeat')),
        isFalse);
    expect(socket.channels, isEmpty);
  });

  test(
      'expired session closes, refreshes parameters, and rejoins with new refs',
      () async {
    final server = LongPollServer();
    var params = 0;
    final socket = PhoenixSocket(endpoint,
        httpClientFactory: server.createClient,
        socketOptions: PhoenixSocketOptions(
          transport: PhoenixSocketTransport.longPolling,
          reconnectDelays: const [],
          dynamicParams: () async => {'credential': '${++params}'},
        ));
    addTearDown(socket.dispose);
    await socket.connect();
    final channel = socket.addChannel(topic: 'audit:recover');
    await channel.join().future;
    final originalRef = channel.joinRef;
    final close = socket.closeStream.first;
    final firstClient = server.clients.single;
    firstClient.expire();
    expect((await close).code, 3410);
    await eventually(() => server.joins == 2 && channel.canPush);
    expect(server.sessions, 2);
    expect(params, 2);
    expect(firstClient.closed, isTrue);
    expect(channel.joinRef, isNot(originalRef));
    expect(
        (await channel
                .push('echo', {'restored': true}, expectingReply: true)
                .future)
            .responseMap,
        {'restored': true});
  });

  test('a pending reply fails when its session disappears', () async {
    final server = LongPollServer();
    final socket = PhoenixSocket(endpoint,
        socketOptions: polling, httpClientFactory: server.createClient);
    addTearDown(socket.dispose);
    await socket.connect();
    final channel = socket.addChannel(topic: 'audit:pending');
    await channel.join().future;
    final request = channel.push('no_reply', {}, expectingReply: true);
    final failed =
        expectLater(request.future, throwsA(isA<ChannelClosedError>()));
    server.clients.single.expire();
    await failed;
  });

  test(
      'WebSocket opening deadline falls back and ignores late WebSocket readiness',
      () async {
    final ws = FakeTransport();
    final server = LongPollServer();
    final store = MemorySessionStore();
    final socket = PhoenixSocket(endpoint,
        webSocketChannelFactory: (_) => ws,
        httpClientFactory: server.createClient,
        socketOptions: PhoenixSocketOptions(
          longPollFallbackAfter: const Duration(milliseconds: 15),
          maxReconnectionAttempts: 0,
          sessionStorage: store,
        ));
    addTearDown(socket.dispose);
    await socket.connect();
    expect(socket.transport, PhoenixSocketTransport.longPolling);
    expect(ws.sink.closeCalls, 1);
    expect(store.getItem('phx:fallback:LongPoll'), 'true');
    ws.readyCompleter.complete();
    await Future<void>.delayed(Duration.zero);
    expect(socket.transport, PhoenixSocketTransport.longPolling);
    final channel = socket.addChannel(topic: 'audit:fallback');
    expect((await channel.join().future).isOk, isTrue);
  });

  test('WebSocket handshake error falls back before the deadline', () async {
    final ws = FakeTransport();
    final server = LongPollServer();
    final socket = PhoenixSocket(endpoint,
        webSocketChannelFactory: (_) => ws,
        httpClientFactory: server.createClient,
        socketOptions: PhoenixSocketOptions(
          longPollFallbackAfter: const Duration(seconds: 10),
          sessionStorage: MemorySessionStore(),
          maxReconnectionAttempts: 0,
        ));
    addTearDown(socket.dispose);
    final connection = socket.connect();
    await Future<void>.delayed(Duration.zero);
    ws.readyCompleter.completeError(StateError('blocked'));
    await connection.timeout(const Duration(seconds: 2));
    expect(socket.transport, PhoenixSocketTransport.longPolling);
  });

  test('healthy WebSocket cancels fallback and does not memorize long polling',
      () async {
    final ws = FakeTransport(readyImmediately: true);
    final server = LongPollServer();
    final store = MemorySessionStore();
    final socket = PhoenixSocket(endpoint,
        webSocketChannelFactory: (_) => ws,
        httpClientFactory: server.createClient,
        socketOptions: PhoenixSocketOptions(
          longPollFallbackAfter: const Duration(milliseconds: 20),
          sessionStorage: store,
        ));
    addTearDown(socket.dispose);
    await socket.connect();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(socket.transport, PhoenixSocketTransport.webSocket);
    expect(server.clients, isEmpty);
    expect(store.values, isEmpty);
  });

  test(
      'opened WebSocket without a health reply falls back and rejoins its channel',
      () async {
    final server = LongPollServer();
    final store = MemorySessionStore();
    final unhealthy =
        FakeTransport(readyImmediately: true, replyToHeartbeats: false);
    unhealthy.onSend = (parts) {
      if (parts[3] == 'phx_join') unhealthy.replyTo(parts);
    };
    final socket = PhoenixSocket(endpoint,
        webSocketChannelFactory: (_) => unhealthy,
        httpClientFactory: server.createClient,
        socketOptions: PhoenixSocketOptions(
          longPollFallbackAfter: const Duration(milliseconds: 40),
          sessionStorage: store,
          reconnectDelays: const [],
        ));
    addTearDown(socket.dispose);
    await socket.connect();
    final channel = socket.addChannel(topic: 'audit:health');
    await channel.join().future;
    await eventually(() =>
        socket.transport == PhoenixSocketTransport.longPolling &&
        server.joins == 1 &&
        channel.canPush);
    expect(unhealthy.sink.closeCalls, 1);
    expect(store.getItem('phx:fallback:LongPoll'), 'true');
  });

  test(
      'memorized fallback skips WebSocket and persists across explicit reconnect',
      () async {
    final server = LongPollServer();
    final store = MemorySessionStore()
      ..setItem('phx:fallback:LongPoll', 'true');
    var webSockets = 0;
    final socket = PhoenixSocket(endpoint, webSocketChannelFactory: (_) {
      webSockets++;
      return FakeTransport(readyImmediately: true);
    },
        httpClientFactory: server.createClient,
        socketOptions: PhoenixSocketOptions(
          longPollFallbackAfter: const Duration(milliseconds: 20),
          sessionStorage: store,
        ));
    addTearDown(socket.dispose);
    await socket.connect();
    socket.close();
    await socket.connect();
    expect(webSockets, 0);
    expect(server.clients, hasLength(2));
    expect(server.clients.first.closed, isTrue);
  });

  test('fallback is disabled by default even with stored history', () async {
    final ws = FakeTransport(readyImmediately: true);
    final server = LongPollServer();
    final store = MemorySessionStore()
      ..setItem('phx:fallback:LongPoll', 'true');
    final socket = PhoenixSocket(endpoint,
        webSocketChannelFactory: (_) => ws,
        httpClientFactory: server.createClient,
        socketOptions: PhoenixSocketOptions(sessionStorage: store));
    addTearDown(socket.dispose);
    await socket.connect();
    expect(socket.transport, PhoenixSocketTransport.webSocket);
    expect(server.clients, isEmpty);
  });

  test('close while fallback is scheduled prevents a late HTTP session',
      () async {
    final ws = FakeTransport();
    final server = LongPollServer();
    final socket = PhoenixSocket(endpoint,
        webSocketChannelFactory: (_) => ws,
        httpClientFactory: server.createClient,
        socketOptions: PhoenixSocketOptions(
          longPollFallbackAfter: const Duration(milliseconds: 20),
          sessionStorage: MemorySessionStore(),
        ));
    addTearDown(socket.dispose);
    final connection = socket.connect();
    await Future<void>.delayed(Duration.zero);
    socket.close();
    expect(await connection, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(server.clients, isEmpty);
  });

  test(
      'long-poll request timeout is independent of the WebSocket handshake timeout',
      () async {
    final client = ControlledHttpClient();
    final socket = PhoenixSocket(endpoint,
        httpClientFactory: () => client,
        socketOptions: const PhoenixSocketOptions(
          transport: PhoenixSocketTransport.longPolling,
          timeout: Duration(milliseconds: 1),
          longPollTimeout: Duration(seconds: 1),
        ));
    addTearDown(socket.dispose);
    final connection = socket.connect();
    final initial = await client.take('GET');
    await Future<void>.delayed(const Duration(milliseconds: 15));
    initial.reply({'status': 410, 'token': 't', 'messages': []});
    expect(await connection, same(socket));
  });

  test('repeated polling sessions close every owned HTTP client', () async {
    final server = LongPollServer();
    final socket = PhoenixSocket(endpoint,
        socketOptions: polling, httpClientFactory: server.createClient);
    addTearDown(socket.dispose);
    for (var i = 0; i < 50; i++) {
      await socket.connect();
      socket.close();
    }
    await Future<void>.delayed(Duration.zero);
    expect(server.clients, hasLength(50));
    expect(server.clients.every((client) => client.closed), isTrue);
    expect(socket.isConnected, isFalse);
  });
}
