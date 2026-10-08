import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket/src/connection_manager/connection_manager.dart';
import 'package:phoenix_socket/src/connection_manager/state.dart';
import 'package:test/test.dart';

import 'helpers/controlled_http_client.dart';
import 'helpers/fake_transport.dart';
import 'helpers/long_poll_server.dart';

const _historyKey = 'phx:fallback:LongPoll';
const _endpoint = 'ws://example.invalid/socket/websocket';

class _History implements PhoenixSocketSessionStore {
  final values = <String, String>{};
  bool unavailable = false;
  @override
  String? getItem(String key) {
    if (unavailable) throw StateError('storage unavailable');
    return values[key];
  }

  @override
  void setItem(String key, String value) => values[key] = value;
  @override
  void removeItem(String key) => values.remove(key);
}

void _pump(FakeAsync time) => time.elapse(Duration.zero);

void _dispose(ConnectionManager manager, FakeAsync time) {
  manager.dispose();
  _pump(time);
  expect(time.nonPeriodicTimerCount, 0,
      reason: time.pendingTimersDebugString.join('\n'));
}

void main() {
  test('first probe gates connect, open and queued request/reply', () {
    fakeAsync((time) {
      final ws =
          FakeTransport(readyImmediately: true, replyToHeartbeats: false);
      final manager = ConnectionManager(
          serverUri: _endpoint, webSocketChannelFactory: (_) => ws);
      var connected = false;
      var opens = 0;
      Message? reply;
      manager.openStream.listen((_) => opens++);
      manager
          .connect(PhoenixSocketOptions(
              sessionStorage: _History(),
              longPollFallbackAfter: const Duration(seconds: 1)))
          .then((_) => connected = true);
      _pump(time);
      expect(manager.currentState, isA<ValidatingState>());
      final request = Message.heartbeat(manager.nextRef);
      manager.sendMessage(request);
      manager.waitForMessage(request).then((value) => reply = value);
      _pump(time);
      expect(connected, isFalse);
      expect(opens, 0);
      expect(ws.sent, hasLength(1));
      final probe = ws.sent.single;
      ws.replyTo([null, 'wrong-ref', 'phoenix', 'heartbeat', {}]);
      _pump(time);
      expect(connected, isFalse);
      ws.replyTo(probe);
      _pump(time);
      expect(connected, isTrue);
      expect(opens, 1);
      expect(ws.sent, hasLength(2));
      expect(ws.sent.last[1], request.ref);
      ws.replyTo(ws.sent.last);
      _pump(time);
      expect(reply?.ref, request.ref);
      time.elapse(const Duration(seconds: 2));
      expect(manager.transport, PhoenixSocketTransport.webSocket);
      _dispose(manager, time);
    });
  });

  test('probe deadline exposes only long polling and sends queued join once',
      () {
    fakeAsync((time) {
      final ws =
          FakeTransport(readyImmediately: true, replyToHeartbeats: false);
      final server = LongPollServer();
      final socket = PhoenixSocket(_endpoint,
          webSocketChannelFactory: (_) => ws,
          httpClientFactory: server.createClient,
          socketOptions: PhoenixSocketOptions(
              longPollFallbackAfter: const Duration(seconds: 1),
              sessionStorage: _History()));
      var opens = 0;
      var joined = false;
      socket.openStream.listen((_) => opens++);
      socket.connect().ignore();
      _pump(time);
      socket
          .addChannel(topic: 'audit:once')
          .join()
          .future
          .then((_) => joined = true);
      _pump(time);
      expect(opens, 0);
      expect(ws.sent.map((frame) => frame[3]), ['heartbeat']);
      time.elapse(const Duration(seconds: 1));
      _pump(time);
      expect(socket.isConnected, isTrue);
      expect(socket.transport, PhoenixSocketTransport.longPolling);
      expect(opens, 1);
      expect(joined, isTrue);
      expect(server.joins, 1);
      expect(ws.sent.where((frame) => frame[3] == 'phx_join'), isEmpty);
      socket.dispose();
      _pump(time);
      expect(time.nonPeriodicTimerCount, 0);
    });
  });

  for (final dispose in [false, true]) {
    test('${dispose ? 'dispose' : 'close'} during probe settles queued futures',
        () {
      fakeAsync((time) {
        final ws =
            FakeTransport(readyImmediately: true, replyToHeartbeats: false);
        final server = LongPollServer();
        final manager = ConnectionManager(
            serverUri: _endpoint,
            webSocketChannelFactory: (_) => ws,
            httpClientFactory: server.createClient);
        Object? connectionError;
        Object? requestError;
        var opens = 0;
        manager.openStream.listen((_) => opens++);
        manager
            .connect(PhoenixSocketOptions(
                sessionStorage: _History(),
                longPollFallbackAfter: const Duration(seconds: 1)))
            .then<void>((_) {},
                onError: (Object error) => connectionError = error);
        _pump(time);
        final request = Message.heartbeat(manager.nextRef);
        manager.sendMessage(request);
        manager.waitForMessage(request).then<void>((_) {},
            onError: (Object error) => requestError = error);
        _pump(time);
        if (dispose) {
          manager.dispose();
        } else {
          manager.close();
        }
        _pump(time);
        time.elapse(const Duration(seconds: 2));
        expect(connectionError, isA<SocketClosedError>());
        expect(requestError, isA<SocketClosedError>());
        expect(opens, 0);
        expect(server.clients, isEmpty);
        _dispose(manager, time);
      });
    });
  }

  test('malformed first probe response falls back without opening WebSocket',
      () {
    fakeAsync((time) {
      final ws =
          FakeTransport(readyImmediately: true, replyToHeartbeats: false);
      final server = LongPollServer();
      final manager = ConnectionManager(
          serverUri: _endpoint,
          webSocketChannelFactory: (_) => ws,
          httpClientFactory: server.createClient);
      var opens = 0;
      manager.openStream.listen((_) => opens++);
      manager
          .connect(PhoenixSocketOptions(
              sessionStorage: _History(),
              longPollFallbackAfter: const Duration(seconds: 10)))
          .ignore();
      _pump(time);
      ws.incoming.add('invalid JSON');
      _pump(time);
      expect(manager.transport, PhoenixSocketTransport.longPolling);
      expect(opens, 1);
      expect(server.clients, hasLength(1));
      _dispose(manager, time);
    });
  });

  test('proven WebSocket reconnect uses normal timeout and backoff', () {
    fakeAsync((time) {
      final transports = <FakeTransport>[];
      final server = LongPollServer();
      final manager = ConnectionManager(
          serverUri: _endpoint,
          httpClientFactory: server.createClient,
          webSocketChannelFactory: (_) {
            final ws = FakeTransport(readyImmediately: transports.isEmpty);
            transports.add(ws);
            return ws;
          });
      manager
          .connect(PhoenixSocketOptions(
              sessionStorage: _History(),
              timeout: const Duration(seconds: 5),
              longPollFallbackAfter: const Duration(seconds: 1),
              reconnectDelays: const [Duration(milliseconds: 100)]))
          .ignore();
      _pump(time);
      unawaited(transports.first.incoming.close());
      _pump(time);
      time.elapse(const Duration(milliseconds: 100));
      expect(transports, hasLength(2));
      time.elapse(const Duration(seconds: 2));
      expect(manager.currentState, isA<ConnectingState>());
      expect(server.clients, isEmpty);
      time.elapse(const Duration(seconds: 3));
      time.elapse(const Duration(milliseconds: 100));
      expect(transports, hasLength(3));
      transports.last.readyCompleter.complete();
      _pump(time);
      expect(manager.currentState, isA<ConnectedState>());
      expect(manager.transport, PhoenixSocketTransport.webSocket);
      expect(server.clients, isEmpty);
      _dispose(manager, time);
    });
  });

  for (final failure in ['timeout', 'error', 'close', 'factory']) {
    test('consecutive opening $failure failures re-enable temporary fallback',
        () {
      fakeAsync((time) {
        final transports = <FakeTransport>[];
        var attempts = 0;
        final history = _History();
        final server = LongPollServer();
        final manager = ConnectionManager(
            serverUri: _endpoint,
            httpClientFactory: server.createClient,
            webSocketChannelFactory: (_) {
              if (attempts++ > 0 && failure == 'factory') {
                throw StateError('WebSocket is blocked');
              }
              final ws = FakeTransport(readyImmediately: transports.isEmpty);
              transports.add(ws);
              return ws;
            });
        manager
            .connect(PhoenixSocketOptions(
                sessionStorage: history,
                timeout: const Duration(seconds: 2),
                longPollFallbackAfter: const Duration(seconds: 1),
                reconnectDelays: const [Duration(milliseconds: 100)]))
            .ignore();
        _pump(time);
        unawaited(transports.first.incoming.close());
        _pump(time);
        time.elapse(const Duration(milliseconds: 100));
        if (failure == 'factory') {
          time.elapse(const Duration(seconds: 1));
        } else {
          for (var i = 0; i < 3; i++) {
            expect(manager.transport, PhoenixSocketTransport.webSocket);
            if (failure == 'timeout') {
              time.elapse(const Duration(seconds: 2));
            } else if (failure == 'error') {
              transports.last.readyCompleter
                  .completeError(StateError('blocked'));
              _pump(time);
            } else {
              unawaited(transports.last.incoming.close());
              _pump(time);
            }
            expect(server.clients, isEmpty);
            time.elapse(const Duration(milliseconds: 100));
          }
          // The next attempt gets the first-use deadline, not the normal timeout.
          time.elapse(const Duration(seconds: 1));
        }
        _pump(time);
        expect(manager.currentState, isA<ConnectedState>());
        expect(manager.transport, PhoenixSocketTransport.longPolling);
        expect(history.values, isEmpty,
            reason: 'outages must not pin later sockets');
        expect(server.clients, hasLength(1));
        _dispose(manager, time);
      });
    });
  }

  test('a successful opening resets consecutive failure count', () {
    fakeAsync((time) {
      final transports = <FakeTransport>[];
      final server = LongPollServer();
      final manager = ConnectionManager(
          serverUri: _endpoint,
          httpClientFactory: server.createClient,
          webSocketChannelFactory: (_) {
            final ws = FakeTransport(readyImmediately: transports.isEmpty);
            transports.add(ws);
            return ws;
          });
      manager
          .connect(PhoenixSocketOptions(
              sessionStorage: _History(),
              timeout: const Duration(seconds: 2),
              longPollFallbackAfter: const Duration(seconds: 1),
              reconnectDelays: const []))
          .ignore();
      _pump(time);
      for (var cycle = 0; cycle < 2; cycle++) {
        unawaited(transports.last.incoming.close());
        _pump(time);
        for (var failure = 0; failure < 2; failure++) {
          transports.last.readyCompleter.completeError(StateError('restart'));
          _pump(time);
        }
        // A slow opening remains allowed after two isolated failures.
        time.elapse(const Duration(milliseconds: 1500));
        expect(server.clients, isEmpty);
        transports.last.readyCompleter.complete();
        _pump(time);
        expect(manager.currentState, isA<ConnectedState>());
      }
      expect(manager.transport, PhoenixSocketTransport.webSocket);
      _dispose(manager, time);
    });
  });

  test('temporary opening-failure fallback retries WebSocket after HTTP loss',
      () {
    fakeAsync((time) {
      final transports = <FakeTransport>[];
      final server = LongPollServer();
      final manager = ConnectionManager(
          serverUri: _endpoint,
          httpClientFactory: server.createClient,
          webSocketChannelFactory: (_) {
            final ws = FakeTransport(
                readyImmediately: transports.isEmpty || transports.length >= 5);
            transports.add(ws);
            return ws;
          });
      manager
          .connect(PhoenixSocketOptions(
              sessionStorage: _History()..unavailable = true,
              timeout: const Duration(seconds: 2),
              longPollFallbackAfter: const Duration(seconds: 1),
              reconnectDelays: const []))
          .ignore();
      _pump(time);
      unawaited(transports.first.incoming.close());
      _pump(time);
      for (var i = 0; i < 3; i++) {
        transports.last.readyCompleter.completeError(StateError('blocked'));
        _pump(time);
      }
      time.elapse(const Duration(seconds: 1));
      expect(manager.transport, PhoenixSocketTransport.longPolling);
      server.clients.single.expire();
      _pump(time);
      expect(manager.transport, PhoenixSocketTransport.webSocket);
      expect(manager.currentState, isA<ConnectedState>());
      expect(transports.last.sent.single[3], 'heartbeat');
      _dispose(manager, time);
    });
  });

  test('opening failure recovery respects the configured retry limit', () {
    fakeAsync((time) {
      final transports = <FakeTransport>[];
      final server = LongPollServer();
      final manager = ConnectionManager(
          serverUri: _endpoint,
          httpClientFactory: server.createClient,
          webSocketChannelFactory: (_) {
            final ws = FakeTransport(readyImmediately: transports.isEmpty);
            transports.add(ws);
            return ws;
          });
      manager
          .connect(PhoenixSocketOptions(
              sessionStorage: _History(),
              maxReconnectionAttempts: 1,
              longPollFallbackAfter: const Duration(seconds: 1),
              reconnectDelays: const []))
          .ignore();
      _pump(time);
      unawaited(transports.first.incoming.close());
      _pump(time);
      for (var i = 0; i < 2; i++) {
        transports.last.readyCompleter.completeError(StateError('blocked'));
        _pump(time);
      }
      expect(manager.currentState, isA<DisconnectedState>());
      expect(server.clients, isEmpty);
      _dispose(manager, time);
    });
  });

  test('opening failures do not enable fallback when its option is disabled',
      () {
    fakeAsync((time) {
      final transports = <FakeTransport>[];
      final server = LongPollServer();
      final manager = ConnectionManager(
          serverUri: _endpoint,
          httpClientFactory: server.createClient,
          webSocketChannelFactory: (_) {
            final ws = FakeTransport(readyImmediately: transports.isEmpty);
            transports.add(ws);
            return ws;
          });
      manager
          .connect(const PhoenixSocketOptions(
              maxReconnectionAttempts: 3, reconnectDelays: []))
          .ignore();
      _pump(time);
      unawaited(transports.first.incoming.close());
      _pump(time);
      for (var i = 0; i < 4; i++) {
        transports.last.readyCompleter.completeError(StateError('blocked'));
        _pump(time);
      }
      expect(manager.currentState, isA<DisconnectedState>());
      expect(server.clients, isEmpty);
      _dispose(manager, time);
    });
  });

  for (final explicitConnect in [false, true]) {
    test(
        'cleared history retries WebSocket on ${explicitConnect ? 'explicit' : 'automatic'} reconnect',
        () {
      fakeAsync((time) {
        final history = _History()..setItem(_historyKey, 'true');
        final server = LongPollServer();
        final ws =
            FakeTransport(readyImmediately: true, replyToHeartbeats: false);
        final manager = ConnectionManager(
            serverUri: _endpoint,
            webSocketChannelFactory: (_) => ws,
            httpClientFactory: server.createClient);
        final options = PhoenixSocketOptions(
            longPollFallbackAfter: const Duration(seconds: 1),
            reconnectDelays: const [],
            sessionStorage: history);
        manager.connect(options).ignore();
        _pump(time);
        expect(manager.transport, PhoenixSocketTransport.longPolling);
        history.removeItem(_historyKey);
        time.elapse(const Duration(seconds: 2));
        expect(manager.transport, PhoenixSocketTransport.longPolling);
        if (explicitConnect) {
          manager.close();
          manager.connect(options).ignore();
        } else {
          server.clients.single.expire();
        }
        _pump(time);
        expect(manager.transport, PhoenixSocketTransport.webSocket);
        expect(manager.currentState, isA<ValidatingState>());
        ws.replyTo(ws.sent.single);
        _pump(time);
        expect(manager.currentState, isA<ConnectedState>());
        expect(server.clients, hasLength(1));
        _dispose(manager, time);
      });
    });
  }

  test('history is refreshed after asynchronous connection parameters', () {
    fakeAsync((time) {
      final history = _History()..setItem(_historyKey, 'true');
      final params = Completer<Map<String, String>>();
      final ws = FakeTransport(readyImmediately: true);
      final server = LongPollServer();
      final manager = ConnectionManager(
          serverUri: _endpoint,
          webSocketChannelFactory: (_) => ws,
          httpClientFactory: server.createClient);
      manager
          .connect(PhoenixSocketOptions(
              longPollFallbackAfter: const Duration(seconds: 1),
              sessionStorage: history,
              dynamicParams: () => params.future))
          .ignore();
      _pump(time);
      history.removeItem(_historyKey);
      params.complete({});
      _pump(time);
      expect(manager.transport, PhoenixSocketTransport.webSocket);
      expect(manager.currentState, isA<ConnectedState>());
      expect(server.clients, isEmpty);
      _dispose(manager, time);
    });
  });

  test(
      'unavailable history retains established fallback during automatic reconnect',
      () {
    fakeAsync((time) {
      final history = _History()..setItem(_historyKey, 'true');
      final server = LongPollServer();
      final manager = ConnectionManager(
          serverUri: _endpoint,
          webSocketChannelFactory: (_) => throw StateError('must stay on HTTP'),
          httpClientFactory: server.createClient);
      manager
          .connect(PhoenixSocketOptions(
              longPollFallbackAfter: const Duration(seconds: 1),
              sessionStorage: history,
              reconnectDelays: const []))
          .ignore();
      _pump(time);
      history.unavailable = true;
      server.clients.single.expire();
      _pump(time);
      expect(manager.transport, PhoenixSocketTransport.longPolling);
      expect(server.clients, hasLength(2));
      _dispose(manager, time);
    });
  });

  test('forced polling stays on HTTP after history is removed', () {
    fakeAsync((time) {
      final history = _History()..setItem(_historyKey, 'true');
      final server = LongPollServer();
      final manager = ConnectionManager(
          serverUri: _endpoint,
          webSocketChannelFactory: (_) => throw StateError('forced polling'),
          httpClientFactory: server.createClient);
      manager
          .connect(PhoenixSocketOptions(
              transport: PhoenixSocketTransport.longPolling,
              longPollFallbackAfter: const Duration(seconds: 1),
              sessionStorage: history,
              reconnectDelays: const []))
          .ignore();
      _pump(time);
      history.removeItem(_historyKey);
      server.clients.single.expire();
      _pump(time);
      expect(manager.transport, PhoenixSocketTransport.longPolling);
      expect(server.clients, hasLength(2));
      _dispose(manager, time);
    });
  });

  test('initial HTTP fallback failures retry HTTP before history is recorded',
      () {
    fakeAsync((time) {
      final firstHttp = ControlledHttpClient();
      final server = LongPollServer();
      final history = _History();
      var webSockets = 0;
      var httpClients = 0;
      final manager = ConnectionManager(
          serverUri: _endpoint,
          webSocketChannelFactory: (_) {
            webSockets++;
            return FakeTransport();
          },
          httpClientFactory: () =>
              httpClients++ == 0 ? firstHttp : server.createClient());
      manager
          .connect(PhoenixSocketOptions(
              longPollFallbackAfter: const Duration(seconds: 1),
              sessionStorage: history,
              reconnectDelays: const []))
          .ignore();
      _pump(time);
      time.elapse(const Duration(seconds: 1));
      _pump(time);
      expect(history.values, isEmpty);
      firstHttp.requests.single.reply({'status': 500});
      _pump(time);
      expect(manager.currentState, isA<ConnectedState>());
      expect(manager.transport, PhoenixSocketTransport.longPolling);
      expect(webSockets, 1);
      expect(httpClients, 2);
      expect(firstHttp.closed, isTrue);
      expect(history.getItem(_historyKey), 'true');
      _dispose(manager, time);
    });
  });

  test('clearing history after live fallback allows WebSocket recovery', () {
    fakeAsync((time) {
      final history = _History();
      final server = LongPollServer();
      final transports = <FakeTransport>[];
      final manager = ConnectionManager(
          serverUri: _endpoint,
          httpClientFactory: server.createClient,
          webSocketChannelFactory: (_) {
            final ws = FakeTransport(readyImmediately: transports.isNotEmpty);
            transports.add(ws);
            return ws;
          });
      manager
          .connect(PhoenixSocketOptions(
              longPollFallbackAfter: const Duration(seconds: 1),
              sessionStorage: history,
              reconnectDelays: const []))
          .ignore();
      _pump(time);
      time.elapse(const Duration(seconds: 1));
      expect(history.getItem(_historyKey), 'true');
      history.removeItem(_historyKey);
      server.clients.single.expire();
      _pump(time);
      expect(transports, hasLength(2));
      expect(manager.currentState, isA<ConnectedState>());
      expect(manager.transport, PhoenixSocketTransport.webSocket);
      expect(transports.last.sent.single[3], 'heartbeat');
      expect(history.values, isEmpty);
      _dispose(manager, time);
    });
  });

  test(
      'an incompatible default WebSocket auth subprotocol selects HTTP without history',
      () {
    fakeAsync((time) {
      final history = _History();
      final server = LongPollServer();
      final manager = ConnectionManager(
          serverUri: _endpoint, httpClientFactory: server.createClient);
      manager
          .connect(
              PhoenixSocketOptions(authToken: '00?', sessionStorage: history))
          .ignore();
      _pump(time);
      expect(manager.currentState, isA<ConnectedState>());
      expect(manager.transport, PhoenixSocketTransport.longPolling);
      expect(server.requests.first.headers['X-Phoenix-AuthToken'], '00?');
      expect(history.values, isEmpty);
      _dispose(manager, time);
    });
  });

  test(
      'custom WebSocket factory owns auth even for incompatible default tokens',
      () {
    fakeAsync((time) {
      final ws = FakeTransport(readyImmediately: true);
      final server = LongPollServer();
      final manager = ConnectionManager(
          serverUri: _endpoint,
          webSocketChannelFactory: (_) => ws,
          httpClientFactory: server.createClient);
      manager.connect(const PhoenixSocketOptions(authToken: '00?')).ignore();
      _pump(time);
      expect(manager.currentState, isA<ConnectedState>());
      expect(manager.transport, PhoenixSocketTransport.webSocket);
      expect(server.clients, isEmpty);
      _dispose(manager, time);
    });
  });

  test('connection parameters are sent only on the initial GET', () async {
    final client = ControlledHttpClient();
    final transport = PhoenixLongPoll(
        Uri.parse(
            'https://example.invalid/socket/longpoll?token=app-secret&auth_token=secret&user_id=42&vsn=2.0.0'),
        client: client);
    addTearDown(transport.close);
    transport.stream.listen((_) {});
    final initial = await client.take('GET');
    expect(initial.request.url.queryParameters, {
      'token': 'app-secret',
      'auth_token': 'secret',
      'user_id': '42',
      'vsn': '2.0.0'
    });
    initial.reply({'status': 410, 'token': 'session +/=&', 'messages': []});
    await transport.ready;
    final poll = await client.take('GET');
    expect(poll.request.url.queryParameters, {'token': 'session +/=&'});
    transport.send('[null,"0","audit","echo",{}]');
    final post = await client.take('POST');
    expect(post.request.url, poll.request.url);
    post.reply({'status': 200});
    poll.reply({'status': 204, 'token': 'replacement', 'messages': []});
    expect((await client.take('GET')).request.url.queryParameters,
        {'token': 'replacement'});
  });
}
