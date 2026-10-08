import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

import 'helpers/fake_transport.dart';
import 'helpers/long_poll_server.dart';

const shortPolicy = WebSocketStabilityPolicy(
  minimumUptime: Duration(milliseconds: 100),
);

class _MemoryStore implements PhoenixSocketSessionStore {
  final values = <String, String>{};
  @override
  String? getItem(String key) => values[key];
  @override
  void setItem(String key, String value) => values[key] = value;
  @override
  void removeItem(String key) => values.remove(key);
}

class _Harness {
  _Harness({
    WebSocketStabilityPolicy? policy = shortPolicy,
    bool timedFallback = true,
    bool healthy = true,
    bool Function(int attempt)? heartbeatReplies,
    bool ready = true,
    int? maxReconnectionAttempts,
    List<Duration> reconnectDelays = const [],
  }) {
    socket = PhoenixSocket('ws://example.invalid/socket/websocket',
        socketOptions: PhoenixSocketOptions(
          webSocketStability: policy,
          longPollFallbackAfter:
              timedFallback ? const Duration(seconds: 1) : null,
          heartbeat: const Duration(days: 1),
          heartbeatTimeout: const Duration(seconds: 2),
          sessionStorage: store,
          maxReconnectionAttempts: maxReconnectionAttempts,
          reconnectDelays: reconnectDelays,
        ), webSocketChannelFactory: (_) {
      final replies = heartbeatReplies?.call(transports.length) ?? healthy;
      final ws =
          FakeTransport(readyImmediately: ready, replyToHeartbeats: replies);
      ws.onSend = ws.replyTo;
      if (!replies) {
        ws.onSend = (parts) {
          if (parts[3] != 'heartbeat') ws.replyTo(parts);
        };
      }
      transports.add(ws);
      return ws;
    }, httpClientFactory: server.createClient);
  }

  final server = LongPollServer();
  final store = _MemoryStore();
  final transports = <FakeTransport>[];
  late final PhoenixSocket socket;

  void connect(FakeAsync time) {
    socket.connect().ignore();
    pump(time);
  }

  void drop(FakeAsync time, {bool error = false}) {
    final ws = transports.last;
    if (error) {
      ws.incoming.addError(StateError('unexpected network loss'));
    } else {
      ws.closeCode = 1006;
      ws.closeReason = 'network lost';
      unawaited(ws.incoming.close());
    }
    pump(time);
  }

  void dispose(FakeAsync time) {
    socket.dispose();
    time.flushMicrotasks();
    expect(time.nonPeriodicTimerCount, 0,
        reason: time.pendingTimersDebugString.join('\n'));
  }
}

void pump(FakeAsync time) => time.elapse(Duration.zero);

void main() {
  test('default stability policy is opt-in with a three-loss, 30-second budget',
      () {
    expect(const PhoenixSocketOptions().webSocketStability, isNull);
    expect(const WebSocketStabilityPolicy().maxUnstableConnections, 3);
    expect(const WebSocketStabilityPolicy().minimumUptime,
        const Duration(seconds: 30));
  });

  for (final error in [false, true]) {
    test(
        'three healthy but short-lived WebSockets select long polling on ${error ? 'error' : 'close'}',
        () {
      fakeAsync((time) {
        final h = _Harness();
        try {
          h.connect(time);
          final channel = h.socket.addChannel(topic: 'audit:unstable');
          channel.join().future.ignore();
          pump(time);
          for (var loss = 0; loss < 3; loss++) {
            expect(
                h.transports.last.sent.any((m) => m[3] == 'heartbeat'), isTrue);
            expect(h.socket.transport, PhoenixSocketTransport.webSocket);
            time.elapse(const Duration(milliseconds: 10));
            h.drop(time, error: error);
          }
          expect(h.transports, hasLength(3));
          expect(h.server.clients, hasLength(1));
          expect(h.socket.transport, PhoenixSocketTransport.longPolling);
          time.elapse(const Duration(seconds: 1));
          expect(channel.canPush, isTrue);
          Object? echo;
          channel
              .push('echo', {'alive': true}, expectingReply: true)
              .future
              .then((reply) => echo = reply.responseMap);
          pump(time);
          expect(echo, {'alive': true});
          expect(h.store.getItem('phx:fallback:LongPoll'), 'true');
          expect(h.transports.every((ws) => ws.sink.closeCalls == 1), isTrue);
        } finally {
          h.dispose(time);
        }
      });
    });
  }

  test('sustained healthy uptime resets the budget across reconnects', () {
    fakeAsync((time) {
      final h = _Harness();
      try {
        h.connect(time);
        time.elapse(const Duration(milliseconds: 10));
        h.drop(time); // One unstable loss.
        time.elapse(const Duration(milliseconds: 100));
        h.drop(time); // This connection was stable; budget is reset.
        for (var loss = 0; loss < 2; loss++) {
          time.elapse(const Duration(milliseconds: 10));
          h.drop(time);
          expect(h.server.clients, isEmpty);
        }
        time.elapse(const Duration(milliseconds: 10));
        h.drop(time);
        expect(h.transports, hasLength(5));
        expect(h.socket.transport, PhoenixSocketTransport.longPolling);
      } finally {
        h.dispose(time);
      }
    });
  });

  test('uptime without a heartbeat response cannot reset the failure budget',
      () {
    fakeAsync((time) {
      final h = _Harness(
          timedFallback: false,
          heartbeatReplies: (attempt) => attempt == 0,
          policy: const WebSocketStabilityPolicy(
              maxUnstableConnections: 2,
              minimumUptime: Duration(milliseconds: 100)));
      try {
        h.connect(time);
        h.drop(time);
        time.elapse(const Duration(milliseconds: 100));
        h.drop(time);
        expect(h.transports, hasLength(2));
        expect(h.socket.transport, PhoenixSocketTransport.longPolling);
      } finally {
        h.dispose(time);
      }
    });
  });

  test('stability policy works independently of timed opening fallback', () {
    fakeAsync((time) {
      final h = _Harness(timedFallback: false);
      try {
        h.connect(time);
        for (var loss = 0; loss < 3; loss++) {
          time.elapse(const Duration(milliseconds: 10));
          h.drop(time);
        }
        expect(h.socket.transport, PhoenixSocketTransport.longPolling);
        expect(h.transports, hasLength(3));
      } finally {
        h.dispose(time);
      }
    });
  });

  test(
      'without the stability policy, successful probes preserve WebSocket retries',
      () {
    fakeAsync((time) {
      final h = _Harness(policy: null);
      try {
        h.connect(time);
        for (var loss = 0; loss < 5; loss++) {
          time.elapse(const Duration(milliseconds: 10));
          h.drop(time);
        }
        expect(h.transports, hasLength(6));
        expect(h.server.clients, isEmpty);
        expect(h.socket.transport, PhoenixSocketTransport.webSocket);
      } finally {
        h.dispose(time);
      }
    });
  });

  test('manual close resets the budget and its timer without selecting HTTP',
      () {
    fakeAsync((time) {
      final h = _Harness(
          policy: const WebSocketStabilityPolicy(
              maxUnstableConnections: 2,
              minimumUptime: Duration(milliseconds: 100)));
      try {
        h.connect(time);
        h.drop(time); // One unstable loss.
        h.socket.close();
        pump(time);
        time.elapse(const Duration(milliseconds: 200));
        expect(h.server.clients, isEmpty);
        h.connect(time);
        h.drop(time); // One loss in a fresh budget, not two.
        expect(h.server.clients, isEmpty);
        h.drop(time);
        expect(h.socket.transport, PhoenixSocketTransport.longPolling);
      } finally {
        h.dispose(time);
      }
    });
  });

  test(
      'reconnect delays progress until a connection has sustained healthy uptime',
      () {
    fakeAsync((time) {
      final h = _Harness(reconnectDelays: const [
        Duration(milliseconds: 10),
        Duration(milliseconds: 20),
        Duration(milliseconds: 30)
      ]);
      try {
        h.connect(time);
        h.drop(time);
        time.elapse(const Duration(milliseconds: 9));
        expect(h.transports, hasLength(1));
        time.elapse(const Duration(milliseconds: 1));
        expect(h.transports, hasLength(2));
        h.drop(time);
        time.elapse(const Duration(milliseconds: 19));
        expect(h.transports, hasLength(2));
        time.elapse(const Duration(milliseconds: 1));
        expect(h.transports, hasLength(3));
        h.drop(time);
        expect(h.socket.transport, PhoenixSocketTransport.longPolling);
      } finally {
        h.dispose(time);
      }
    });
  });

  for (final error in [false, true]) {
    test(
        'loss after opening but before the probe reply falls back immediately on ${error ? 'error' : 'close'}',
        () {
      fakeAsync((time) {
        final h = _Harness(healthy: false, maxReconnectionAttempts: 0);
        try {
          h.connect(time);
          h.drop(time, error: error);
          expect(time.elapsed, Duration.zero);
          expect(h.transports, hasLength(1));
          expect(h.socket.transport, PhoenixSocketTransport.longPolling);
        } finally {
          h.dispose(time);
        }
      });
    });
  }

  test('a closed handshake selects HTTP without waiting for the timed deadline',
      () {
    fakeAsync((time) {
      final h = _Harness(ready: false);
      try {
        h.connect(time);
        expect(h.socket.isConnected, isFalse);
        h.drop(time);
        expect(time.elapsed, Duration.zero);
        expect(h.socket.transport, PhoenixSocketTransport.longPolling);
      } finally {
        h.dispose(time);
      }
    });
  });

  test(
      'long-poll session loss keeps the selected transport and does not consume a WebSocket budget',
      () {
    fakeAsync((time) {
      final h = _Harness(
          policy: const WebSocketStabilityPolicy(
              maxUnstableConnections: 1,
              minimumUptime: Duration(milliseconds: 100)));
      try {
        h.connect(time);
        h.drop(time);
        h.server.clients.single.expire();
        pump(time);
        expect(h.server.clients, hasLength(2));
        expect(h.transports, hasLength(1));
        expect(h.socket.transport, PhoenixSocketTransport.longPolling);
      } finally {
        h.dispose(time);
      }
    });
  });

  test('failed long-poll fallback is not memorized before HTTP opens', () {
    fakeAsync((time) {
      final h = _Harness(
          policy: const WebSocketStabilityPolicy(
              maxUnstableConnections: 1,
              minimumUptime: Duration(milliseconds: 100)),
          maxReconnectionAttempts: 0);
      h.server.forbidden = true;
      try {
        h.connect(time);
        h.drop(time);
        expect(h.socket.isConnected, isFalse);
        expect(h.store.values, isEmpty);
      } finally {
        h.dispose(time);
      }
    });
  });

  test('invalid minimum uptime is rejected without creating a transport',
      () async {
    final h = _Harness(
        policy: const WebSocketStabilityPolicy(minimumUptime: Duration.zero));
    addTearDown(h.socket.dispose);
    await expectLater(h.socket.connect(), throwsArgumentError);
    expect(h.transports, isEmpty);
    expect(h.server.clients, isEmpty);
  });
}
