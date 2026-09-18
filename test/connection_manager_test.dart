import 'dart:async';

import 'package:phoenix_socket/src/connection_manager/connection_manager.dart';
import 'package:phoenix_socket/src/connection_manager/state.dart';
import 'package:phoenix_socket/src/events.dart';
import 'package:phoenix_socket/src/exceptions.dart';
import 'package:phoenix_socket/src/message.dart';
import 'package:phoenix_socket/src/socket_options.dart';
import 'package:test/test.dart';

import 'helpers/fake_transport.dart';

const options = PhoenixSocketOptions(
  maxReconnectionAttempts: 0,
  heartbeat: Duration(days: 1),
);

ConnectionManager managerFor(FakeTransport transport) {
  final manager = ConnectionManager(
    serverUri: 'ws://example.invalid/socket',
    webSocketChannelFactory: (_) => transport,
  );
  addTearDown(manager.dispose);
  return manager;
}

Future<void> flushEvents() => Future<void>.delayed(Duration.zero);

void main() {
  group('connection cancellation', () {
    test('close before the connect event starts prevents transport creation',
        () async {
      var creations = 0;
      final manager = ConnectionManager(
        serverUri: 'ws://example.invalid/socket',
        webSocketChannelFactory: (_) {
          creations++;
          return FakeTransport(readyImmediately: true);
        },
      );
      addTearDown(manager.dispose);
      final result = expectLater(
          manager.connect(options), throwsA(isA<SocketClosedError>()));
      manager.close();
      await result;
      await flushEvents();
      expect(creations, 0);
      expect(manager.currentState, isA<DisconnectedState>());
    });

    test('close cancels a handshake and ignores its late readiness', () async {
      final transport = FakeTransport();
      final manager = managerFor(transport);
      final connecting =
          manager.stateStream.firstWhere((s) => s is ConnectingState);
      final result = expectLater(
          manager.connect(options), throwsA(isA<SocketClosedError>()));
      await connecting;
      manager.close(code: 1000, reason: 'user left');
      await result;
      transport.readyCompleter.complete();
      await flushEvents();
      expect(manager.currentState, isA<DisconnectedState>());
      expect(transport.sink.closeCalls, 1);
      expect(transport.closeReason, 'user left');
    });

    for (final dispose in [false, true]) {
      test(
          '${dispose ? 'dispose' : 'close'} cancels unresolved parameters without creating a transport',
          () async {
        final params = Completer<Map<String, String>>();
        final entered = Completer<void>();
        var creations = 0;
        final manager = ConnectionManager(
          serverUri: 'ws://example.invalid/socket',
          webSocketChannelFactory: (_) {
            creations++;
            return FakeTransport(readyImmediately: true);
          },
        );
        addTearDown(manager.dispose);
        final result = expectLater(manager.connect(PhoenixSocketOptions(
          dynamicParams: () {
            entered.complete();
            return params.future;
          },
        )), throwsA(isA<SocketClosedError>()));
        await entered.future;
        if (dispose) {
          manager.dispose();
        } else {
          manager.close();
        }
        await result;
        params.complete({'token': 'stale'});
        await flushEvents();
        expect(creations, 0);
        expect(manager.currentState, isA<DisconnectedState>());
        expect(manager.isDisposed(), dispose);
      });
    }

    test('new connect proceeds without waiting for canceled parameters',
        () async {
      final params = Completer<Map<String, String>>();
      final entered = Completer<void>();
      final transport = FakeTransport(readyImmediately: true);
      final manager = managerFor(transport);
      final canceled = expectLater(manager.connect(PhoenixSocketOptions(
        dynamicParams: () {
          entered.complete();
          return params.future;
        },
      )), throwsA(isA<SocketClosedError>()));
      await entered.future;
      manager.close();
      await manager.connect(options).timeout(const Duration(seconds: 1));
      await canceled;
      expect(manager.currentState, isA<ConnectedState>());
      params.completeError(StateError('late parameter failure'));
      await flushEvents();
      expect(manager.currentState, isA<ConnectedState>());
    });

    test(
        'a parameter provider that closes synchronously cannot block the next connect',
        () async {
      final params = Completer<Map<String, String>>();
      final manager = managerFor(FakeTransport(readyImmediately: true));
      await expectLater(manager.connect(PhoenixSocketOptions(
        dynamicParams: () {
          manager.close();
          return params.future;
        },
      )), throwsA(isA<SocketClosedError>()));
      await manager.connect(options).timeout(const Duration(seconds: 1));
      expect(manager.currentState, isA<ConnectedState>());
    });

    test('a factory that closes the manager cannot leak its returned transport',
        () async {
      late ConnectionManager manager;
      final transport = FakeTransport(readyImmediately: true);
      manager = ConnectionManager(
        serverUri: 'ws://example.invalid/socket',
        webSocketChannelFactory: (_) {
          manager.close();
          return transport;
        },
      );
      addTearDown(manager.dispose);
      await expectLater(
          manager.connect(options), throwsA(isA<SocketClosedError>()));
      await flushEvents();
      expect(transport.sink.closeCalls, 1);
      expect(manager.currentState, isA<DisconnectedState>());
    });

    test('close cancels a scheduled reconnect', () async {
      final transports = <FakeTransport>[];
      final manager = ConnectionManager(
        serverUri: 'ws://example.invalid/socket',
        webSocketChannelFactory: (_) {
          final transport = FakeTransport(readyImmediately: true);
          transports.add(transport);
          return transport;
        },
      );
      addTearDown(manager.dispose);
      await manager.connect(const PhoenixSocketOptions(
        reconnectDelays: [Duration(milliseconds: 30)],
      ));
      final reconnecting =
          manager.stateStream.firstWhere((s) => s is ReconnectingState);
      await transports.single.incoming.close();
      await reconnecting;
      final reconnectResult = expectLater(
          manager.connect(options), throwsA(isA<SocketClosedError>()));
      manager.close();
      await reconnectResult;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(transports, hasLength(1));
      expect(manager.currentState, isA<DisconnectedState>());
    });

    test('disposed manager rejects future connects and waits', () async {
      final manager = managerFor(FakeTransport());
      manager.dispose();
      await expectLater(manager.connect(options),
          throwsA(isA<ConnectionManagerClosedError>()));
      await expectLater(manager.waitForMessage(Message.heartbeat('0')),
          throwsA(isA<ConnectionManagerClosedError>()));
      manager.dispose();
    });
  });

  group('failed connection attempts', () {
    test(
        'handshake timeout without closeCode closes transport and settles connect',
        () async {
      final transport = FakeTransport();
      final manager = managerFor(transport);
      final error = manager.errorStream.first;
      await expectLater(
          manager.connect(const PhoenixSocketOptions(
            timeout: Duration(milliseconds: 10),
            maxReconnectionAttempts: 0,
          )),
          throwsA(isA<SocketClosedError>()));
      expect((await error).error, isA<TimeoutException>());
      expect(transport.sink.closeCalls, 1);
      expect(manager.currentState, isA<DisconnectedState>());
    });

    test('handshake timeout retries and a late ready cannot replace the retry',
        () async {
      final first = FakeTransport();
      final second = FakeTransport(readyImmediately: true);
      var creations = 0;
      final manager = ConnectionManager(
        serverUri: 'ws://example.invalid/socket',
        webSocketChannelFactory: (_) => creations++ == 0 ? first : second,
      );
      addTearDown(manager.dispose);
      await manager.connect(const PhoenixSocketOptions(
        timeout: Duration(milliseconds: 10),
        maxReconnectionAttempts: 1,
        reconnectDelays: [],
      ));
      first.readyCompleter.complete();
      await flushEvents();
      expect(creations, 2);
      expect(first.sink.closeCalls, 1);
      expect((manager.currentState as ConnectedState).channel, same(second));
    });

    for (final failParams in [true, false]) {
      test(
          '${failParams ? 'parameter' : 'factory'} errors use errorStream and settle all callers',
          () async {
        final failure = StateError('setup failed');
        final manager = ConnectionManager(
          serverUri: 'ws://example.invalid/socket',
          webSocketChannelFactory: (_) => throw failure,
        );
        addTearDown(manager.dispose);
        final errors = <PhoenixSocketErrorEvent>[];
        manager.errorStream.listen(errors.add);
        final connectionOptions = PhoenixSocketOptions(
          maxReconnectionAttempts: 0,
          dynamicParams: failParams ? () async => throw failure : null,
        );
        final first = expectLater(
            manager.connect(connectionOptions), throwsA(same(failure)));
        final second = expectLater(
            manager.connect(connectionOptions), throwsA(same(failure)));
        await Future.wait([first, second]);
        await flushEvents();
        expect(errors.map((e) => e.error), [same(failure)]);
        expect(manager.currentState, isA<DisconnectedState>());
      });

      test(
          '${failParams ? 'parameter' : 'factory'} failures retry with refreshed parameters',
          () async {
        var paramsCalls = 0;
        var factoryCalls = 0;
        final transport = FakeTransport(readyImmediately: true);
        final manager = ConnectionManager(
          serverUri: 'ws://example.invalid/socket',
          webSocketChannelFactory: (_) {
            if (!failParams && factoryCalls++ == 0) throw StateError('factory');
            return transport;
          },
        );
        addTearDown(manager.dispose);
        await manager.connect(PhoenixSocketOptions(
          maxReconnectionAttempts: 1,
          reconnectDelays: [],
          dynamicParams: () async {
            if (paramsCalls++ == 0 && failParams) throw StateError('params');
            return {'token': '$paramsCalls'};
          },
        ));
        expect(paramsCalls, 2);
        expect(manager.mountPoint.queryParameters['token'], '2');
        expect(manager.currentState, isA<ConnectedState>());
      });
    }

    test(
        'automatic reconnect setup failure is handled without a connect caller',
        () async {
      final transport = FakeTransport(readyImmediately: true);
      var creations = 0;
      final manager = ConnectionManager(
        serverUri: 'ws://example.invalid/socket',
        webSocketChannelFactory: (_) {
          if (creations++ > 0) throw StateError('backend unavailable');
          return transport;
        },
      );
      addTearDown(manager.dispose);
      await manager.connect(const PhoenixSocketOptions(
        maxReconnectionAttempts: 1,
        reconnectDelays: [],
      ));
      final disconnected =
          manager.stateStream.firstWhere((s) => s is DisconnectedState);
      await transport.incoming.close();
      await disconnected;
      await flushEvents();
      expect(creations, 3);
    });
  });

  group('message lifetime', () {
    test(
        'close discards queued sends and settles unregistered waiters before reconnect',
        () async {
      final first = FakeTransport(readyImmediately: true);
      final second = FakeTransport(readyImmediately: true);
      var creations = 0;
      final manager = ConnectionManager(
        serverUri: 'ws://example.invalid/socket',
        webSocketChannelFactory: (_) => creations++ == 0 ? first : second,
      );
      addTearDown(manager.dispose);
      await manager.connect(options);
      final message = Message(
        event: PhoenixChannelEvent.custom('stale'),
        ref: manager.nextRef,
      );
      manager.sendMessage(message);
      final waiter = expectLater(
        manager.waitForMessage(message),
        throwsA(isA<SocketClosedError>()),
      );
      manager.close();
      await manager.connect(options);
      await waiter;
      await flushEvents();
      expect(first.sent.where((m) => m[3] == 'stale'), isEmpty);
      expect(second.sent.where((m) => m[3] == 'stale'), isEmpty);
      expect((manager.currentState as ConnectedState).pendingMessages, isEmpty);
    });

    test('queued fire-and-forget messages allocate no reply completer',
        () async {
      final transport = FakeTransport();
      final manager = managerFor(transport);
      final connection = manager.connect(options);
      await manager.stateStream.firstWhere((s) => s is ConnectingState);
      manager.sendMessage(Message(
          event: PhoenixChannelEvent.custom('notice'), ref: manager.nextRef));
      await flushEvents();
      final connecting = manager.currentState as ConnectingState;
      expect(connecting.queuedMessages.single.$2, isNull);
      transport.readyCompleter.complete();
      await connection;
      await flushEvents();
      expect((manager.currentState as ConnectedState).pendingMessages, isEmpty);
    });

    test('queued request waiter completes with its reply after readiness',
        () async {
      final transport = FakeTransport();
      final manager = managerFor(transport);
      final connection = manager.connect(options);
      await manager.stateStream.firstWhere((s) => s is ConnectingState);
      final message = Message(
          event: PhoenixChannelEvent.custom('request'), ref: manager.nextRef);
      manager.sendMessage(message);
      final reply = manager.waitForMessage(message);
      transport.onSend = transport.replyTo;
      await flushEvents();
      transport.readyCompleter.complete();
      await connection;
      expect((await reply).ref, message.ref);
      expect(
          (manager.currentState as ConnectedState)
              .pendingMessages
              .containsKey(message.ref),
          isFalse);
    });

    test('terminal handshake failure settles queued request waiters', () async {
      final transport = FakeTransport();
      final manager = managerFor(transport);
      final connection = expectLater(
          manager.connect(options), throwsA(isA<SocketClosedError>()));
      await manager.stateStream.firstWhere((s) => s is ConnectingState);
      final message = Message(
          event: PhoenixChannelEvent.custom('request'), ref: manager.nextRef);
      manager.sendMessage(message);
      final reply = expectLater(
          manager.waitForMessage(message), throwsA(isA<SocketClosedError>()));
      await flushEvents();
      transport.readyCompleter.completeError(StateError('handshake rejected'));
      await Future.wait([connection, reply]);
      expect(manager.currentState, isA<DisconnectedState>());
    });

    test('reentrant close while flushing queued requests settles every waiter',
        () async {
      final transport = FakeTransport();
      final manager = managerFor(transport);
      final connection = expectLater(
          manager.connect(options), throwsA(isA<SocketClosedError>()));
      await manager.stateStream.firstWhere((s) => s is ConnectingState);
      final replies = <Future<void>>[];
      for (var index = 0; index < 2; index++) {
        final message = Message(
            event: PhoenixChannelEvent.custom('request$index'),
            ref: manager.nextRef);
        manager.sendMessage(message);
        replies.add(expectLater(manager.waitForMessage(message),
            throwsA(isA<SocketClosedError>())));
      }
      await flushEvents();
      transport.onSend = (_) => manager.close();
      transport.readyCompleter.complete();
      await Future.wait([connection, ...replies]);
      expect(transport.sent.map((m) => m[3]), ['request0']);
      expect(manager.currentState, isA<DisconnectedState>());
    });

    test('write failures emit a socket error and settle reply waiters',
        () async {
      final transport = FakeTransport(readyImmediately: true);
      final manager = managerFor(transport);
      await manager.connect(options);
      final failure = StateError('write failed');
      transport.onSend = (_) => throw failure;
      final error = manager.errorStream.first;
      final message = Message(
          event: PhoenixChannelEvent.custom('request'), ref: manager.nextRef);
      manager.sendMessage(message);
      final reply = expectLater(
          manager.waitForMessage(message), throwsA(isA<SocketClosedError>()));
      expect((await error).error, same(failure));
      await reply;
      expect(manager.currentState, isA<DisconnectedState>());
    });
  });
}
