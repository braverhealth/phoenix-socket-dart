@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

import 'helpers/fake_transport.dart';
import 'helpers/long_poll_server.dart';

@JS('globalThis.WebSocket')
external JSAny? get browserWebSocket;
@JS('globalThis.WebSocket')
external set browserWebSocket(JSAny? value);

void main() {
  test('default browser sessionStorage shares fallback history between sockets',
      () async {
    const key = 'phx:fallback:LongPoll';
    final storage = web.window.sessionStorage;
    final original = storage.getItem(key);
    storage.removeItem(key);
    addTearDown(() {
      if (original == null) {
        storage.removeItem(key);
      } else {
        storage.setItem(key, original);
      }
    });
    final server = LongPollServer();
    final first = PhoenixSocket('ws://example.invalid/socket/websocket',
        webSocketChannelFactory: (_) => FakeTransport(),
        httpClientFactory: server.createClient,
        socketOptions: const PhoenixSocketOptions(
            longPollFallbackAfter: Duration(milliseconds: 10)));
    addTearDown(first.dispose);
    await first.connect();
    expect(storage.getItem(key), 'true');
    final second = PhoenixSocket('ws://example.invalid/socket/websocket',
        webSocketChannelFactory: (_) =>
            throw StateError('Stored history must skip WebSocket'),
        httpClientFactory: server.createClient,
        socketOptions: const PhoenixSocketOptions(
            longPollFallbackAfter: Duration(milliseconds: 10)));
    addTearDown(second.dispose);
    expect(await second.connect(), same(second));
    expect(second.transport, PhoenixSocketTransport.longPolling);
  });

  test('missing browser WebSocket automatically selects long polling',
      () async {
    final original = browserWebSocket;
    browserWebSocket = null;
    addTearDown(() => browserWebSocket = original);
    final server = LongPollServer();
    final socket = PhoenixSocket('https://example.invalid/socket/websocket',
        httpClientFactory: server.createClient);
    addTearDown(socket.dispose);
    await socket.connect();
    expect(socket.transport, PhoenixSocketTransport.longPolling);
    final channel = socket.addChannel(topic: 'audit:no-websocket');
    expect((await channel.join().future).isOk, isTrue);
  });
}
