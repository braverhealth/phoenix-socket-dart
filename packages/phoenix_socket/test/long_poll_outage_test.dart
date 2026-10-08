import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket/src/connection_manager/connection_manager.dart';
import 'package:phoenix_socket/src/connection_manager/state.dart';
import 'package:test/test.dart';

import 'helpers/controlled_http_client.dart';
import 'helpers/fake_transport.dart';

class _History implements PhoenixSocketSessionStore {
  int writes = 0;
  @override
  String? getItem(String key) => null;
  @override
  void setItem(String key, String value) => writes++;
  @override
  void removeItem(String key) {}
}

void _pump(FakeAsync time) => time.elapse(Duration.zero);

class _Outage {
  _Outage({
    List<Duration> delays = const [],
    int? maxAttempts,
  }) {
    options = PhoenixSocketOptions(
        heartbeat: const Duration(days: 1),
        timeout: const Duration(seconds: 10),
        longPollTimeout: const Duration(seconds: 3),
        longPollFallbackAfter: const Duration(seconds: 1),
        reconnectDelays: delays,
        maxReconnectionAttempts: maxAttempts,
        sessionStorage: history);
    manager = ConnectionManager(
        serverUri: 'ws://example.invalid/socket/websocket',
        webSocketChannelFactory: (_) {
          final ws = FakeTransport(readyImmediately: sockets.isEmpty);
          ws.onSend = ws.replyTo;
          sockets.add(ws);
          return ws;
        },
        httpClientFactory: () {
          final client = ControlledHttpClient();
          clients.add(client);
          return client;
        });
  }

  late final ConnectionManager manager;
  late final PhoenixSocketOptions options;
  final history = _History();
  final sockets = <FakeTransport>[];
  final clients = <ControlledHttpClient>[];

  void enterFallback(FakeAsync time) {
    manager.connect(options).ignore();
    _pump(time);
    expect(manager.currentState, isA<ConnectedState>());
    unawaited(sockets.first.incoming.close());
    _pump(time);
    time.elapse(options.getReconnectionDelay(0)!);
    for (var i = 0; i < 3; i++) {
      failWebSocket(time);
      time.elapse(options.getReconnectionDelay(i)!);
    }
    failWebSocket(time);
    expect(manager.transport, PhoenixSocketTransport.longPolling);
    expect(clients, hasLength(1));
    expect(manager.currentState, isA<ConnectingState>());
  }

  void failWebSocket(FakeAsync time) {
    sockets.last.readyCompleter.completeError(StateError('server unavailable'));
    _pump(time);
  }

  void dispose(FakeAsync time) {
    manager.dispose();
    _pump(time);
    expect(clients.every((client) => client.closed), isTrue);
    expect(time.nonPeriodicTimerCount, 0,
        reason: time.pendingTimersDebugString.join('\n'));
  }
}

void main() {
  for (final failure in ['network', 'server', 'timeout']) {
    test('initial HTTP $failure failure recovers queued traffic over WebSocket',
        () {
      fakeAsync((time) {
        final outage = _Outage();
        var opens = 0;
        outage.manager.openStream.listen((_) => opens++);
        outage.enterFallback(time);
        var connected = false;
        Message? response;
        outage.manager.connect(outage.options).then((_) => connected = true);
        final request = Message.fromJson([
          null,
          outage.manager.nextRef,
          'audit:outage',
          'echo',
          {'value': 42}
        ]);
        outage.manager.sendMessage(request);
        outage.manager
            .waitForMessage(request)
            .then((message) => response = message);
        _pump(time);
        final initialPoll = outage.clients.single.requests.single;
        if (failure == 'network') {
          initialPoll.fail(StateError('HTTP connection refused'));
        } else if (failure == 'server') {
          initialPoll.reply({'status': 500});
        } else {
          time.elapse(outage.options.longPollTimeout);
        }
        _pump(time);
        expect(outage.manager.transport, PhoenixSocketTransport.webSocket);
        expect(outage.sockets, hasLength(6));
        expect(connected, isFalse);
        expect(opens, 1);
        expect(outage.clients.single.closed, isTrue);
        expect(outage.clients.single.requests.map((r) => r.request.method),
            ['GET']);
        outage.sockets.last.readyCompleter.complete();
        _pump(time);
        expect(connected, isTrue);
        expect(response?.ref, request.ref);
        expect(opens, 2);
        expect(
            outage.sockets
                .expand((ws) => ws.sent)
                .where((frame) => frame[3] == 'echo'),
            hasLength(1));
        expect(outage.history.writes, 0);
        outage.dispose(time);
      });
    });
  }

  test('working HTTP stays selected when WebSocket is blocked', () {
    fakeAsync((time) {
      final outage = _Outage();
      outage.enterFallback(time);
      outage.clients.single.requests.single
          .reply({'status': 410, 'token': 'session', 'messages': []});
      _pump(time);
      expect(outage.manager.currentState, isA<ConnectedState>());
      time.elapse(const Duration(seconds: 2));
      outage.clients.single.requests.last
          .reply({'status': 204, 'token': 'session', 'messages': []});
      _pump(time);
      time.elapse(const Duration(seconds: 2));
      expect(outage.manager.transport, PhoenixSocketTransport.longPolling);
      expect(outage.sockets, hasLength(5));
      expect(outage.history.writes, 0);
      outage.dispose(time);
    });
  });

  test('transport switches retain accumulated backoff', () {
    fakeAsync((time) {
      final outage = _Outage(delays: const [
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
        Duration(seconds: 8),
      ]);
      outage.enterFallback(time);
      outage.clients.single.requests.single.reply({'status': 500});
      _pump(time);
      time.elapse(const Duration(milliseconds: 7999));
      expect(outage.sockets, hasLength(5));
      time.elapse(const Duration(milliseconds: 1));
      expect(outage.sockets, hasLength(6));
      expect(outage.manager.transport, PhoenixSocketTransport.webSocket);
      outage.dispose(time);
    });
  });

  test('the retry limit spans failed WebSocket and HTTP openings', () {
    fakeAsync((time) {
      final outage = _Outage(maxAttempts: 3);
      outage.enterFallback(time);
      outage.clients.single.requests.single.reply({'status': 500});
      _pump(time);
      expect(outage.manager.currentState, isA<DisconnectedState>());
      expect(outage.sockets, hasLength(5));
      expect(outage.clients, hasLength(1));
      outage.dispose(time);
    });
  });

  test('both unavailable transports retry several WebSockets per HTTP probe',
      () {
    fakeAsync((time) {
      final outage = _Outage();
      outage.enterFallback(time);
      outage.clients.single.requests.single.reply({'status': 500});
      _pump(time);
      for (var i = 0; i < 3; i++) {
        outage.failWebSocket(time);
        expect(outage.clients, hasLength(1));
      }
      outage.failWebSocket(time);
      expect(outage.clients, hasLength(2));
      expect(outage.sockets, hasLength(9));
      outage.clients.last.requests.single.reply({'status': 500});
      _pump(time);
      outage.sockets.last.readyCompleter.complete();
      _pump(time);
      expect(outage.manager.currentState, isA<ConnectedState>());
      expect(outage.manager.transport, PhoenixSocketTransport.webSocket);
      expect(outage.history.writes, 0);
      outage.dispose(time);
    });
  });

  test('forbidden HTTP does not trigger outage recovery', () {
    fakeAsync((time) {
      final outage = _Outage();
      outage.enterFallback(time);
      outage.clients.single.requests.single.reply({'status': 403});
      _pump(time);
      expect(outage.manager.transport, PhoenixSocketTransport.longPolling);
      expect(outage.sockets, hasLength(5));
      expect(outage.clients, hasLength(2));
      outage.dispose(time);
    });
  });

  for (final authCompatibility in [false, true]) {
    test(
        '${authCompatibility ? 'auth compatibility' : 'forced polling'} retains HTTP on failure',
        () {
      fakeAsync((time) {
        final clients = <ControlledHttpClient>[];
        final manager = ConnectionManager(
            serverUri: 'ws://example.invalid/socket/websocket',
            httpClientFactory: () {
              final client = ControlledHttpClient();
              clients.add(client);
              return client;
            });
        manager
            .connect(PhoenixSocketOptions(
                transport: authCompatibility
                    ? PhoenixSocketTransport.webSocket
                    : PhoenixSocketTransport.longPolling,
                authToken: authCompatibility ? '00?' : null,
                sessionStorage: _History(),
                reconnectDelays: const []))
            .ignore();
        _pump(time);
        clients.single.requests.single.reply({'status': 500});
        _pump(time);
        expect(manager.transport, PhoenixSocketTransport.longPolling);
        expect(clients, hasLength(2));
        manager.dispose();
        _pump(time);
        expect(clients.every((client) => client.closed), isTrue);
        expect(time.nonPeriodicTimerCount, 0);
      });
    });
  }

  for (final dispose in [false, true]) {
    test(
        '${dispose ? 'dispose' : 'close'} during recovery backoff cancels queued work',
        () {
      fakeAsync((time) {
        final outage = _Outage(delays: const [Duration(seconds: 1)]);
        outage.enterFallback(time);
        Object? connectionError;
        Object? requestError;
        outage.manager.connect(outage.options).then<void>((_) {},
            onError: (Object error) => connectionError = error);
        final message = Message.heartbeat(outage.manager.nextRef);
        outage.manager.sendMessage(message);
        outage.manager.waitForMessage(message).then<void>((_) {},
            onError: (Object error) => requestError = error);
        _pump(time);
        outage.clients.single.requests.single.reply({'status': 500});
        _pump(time);
        if (dispose) {
          outage.manager.dispose();
        } else {
          outage.manager.close();
        }
        _pump(time);
        time.elapse(const Duration(seconds: 30));
        expect(connectionError, isA<SocketClosedError>());
        expect(requestError, isA<SocketClosedError>());
        expect(outage.sockets, hasLength(5));
        expect(outage.clients, hasLength(1));
        outage.dispose(time);
      });
    });
  }
}
