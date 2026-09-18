// Compatibility callbacks are deliberately exercised alongside the new API.
// ignore_for_file: deprecated_member_use_from_same_package

import 'dart:async';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

import 'helpers/fake_transport.dart';

typedef Json = Map<String, Object?>;

Json entry(List<String> refs, {Json fields = const {}}) => {
      ...fields,
      'metas': refs.map((ref) => {'phx_ref': ref}).toList(),
    };

List<String> refs(Presence<dynamic>? presence) =>
    presence?.metas.map((meta) => meta.phxRef).toList() ?? [];

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeChannel channel;
  late PhoenixPresence<Json> presence;

  setUp(() {
    channel = FakeChannel();
    presence = PhoenixPresence<Json>(channel: channel);
  });
  tearDown(() async {
    await presence.dispose();
    await channel.shutdown();
  });

  test('full state and batched joins/leaves reconcile every key', () {
    channel.emitState({
      'a': entry(['a1']),
      'b': entry(['b1'])
    });
    channel.diff(
      joins: {
        'c': entry(['c1']),
        'd': entry(['d1'])
      },
      leaves: {
        'a': entry(['a1']),
        'b': entry(['b1'])
      },
    );
    expect(presence.state.keys, ['c', 'd']);
    expect(presence.snapshot.isSynchronized, isTrue);
    channel.emitState({});
    expect(presence.state, isEmpty);
    expect(presence.snapshot.isSynchronized, isTrue);
  });

  test('only removes a key when its last metadata leaves', () {
    channel.emitState({
      'a': entry(['a1', 'a2'])
    });
    channel.diff(leaves: {
      'a': entry(['a1']),
      'unknown': entry(['x'])
    });
    expect(refs(presence.state['a']), ['a2']);
    channel.diff(leaves: {
      'a': entry(['a2'])
    });
    expect(presence.state, isEmpty);
  });

  test('repeated joins replace matching refs without duplicating metadata', () {
    channel.emitState({
      'a': entry(['a1', 'a2'])
    });
    channel.diff(joins: {
      'a': entry(['a2', 'a3'])
    });
    channel.diff(joins: {
      'a': entry(['a2', 'a3'])
    });
    expect(refs(presence.state['a']), ['a1', 'a2', 'a3']);
  });

  test('legacy callbacks receive deltas after the complete state commits', () {
    channel.emitState({
      'a': entry(['a1'])
    });
    Presence<Json>? joined;
    Presence<Json>? previous;
    Presence<Json>? remaining;
    presence.onJoin = (key, current, added) {
      previous = current;
      joined = added;
      expect(refs(presence.state['a']), ['a2']);
    };
    presence.onLeave = (key, current, left) {
      remaining = current;
      expect(refs(left), ['a1']);
      expect(refs(presence.state['a']), ['a2']);
    };
    channel.diff(joins: {
      'a': entry(['a2'])
    }, leaves: {
      'a': entry(['a1'])
    });
    expect(refs(previous), ['a1']);
    expect(refs(joined), ['a2']);
    expect(refs(remaining), ['a2']);
    expect(presence.list(presence.state, (key, p) => key), ['a']);
    expect(presence.list(presence.state), [presence.state['a']]);
  });

  test('full resync reports only added/removed metadata', () {
    channel.emitState({
      'a': entry(['a1', 'a2']),
      'gone': entry(['g1'])
    });
    final joins = <String, List<String>>{};
    final leaves = <String, List<String>>{};
    presence.onJoin = (key, current, joined) => joins[key] = refs(joined);
    presence.onLeave = (key, current, left) => leaves[key] = refs(left);
    channel.emitState({
      'a': entry(['a2', 'a3']),
      'new': entry(['n1'])
    });
    expect(joins, {
      'a': ['a3'],
      'new': ['n1']
    });
    expect(leaves, {
      'a': ['a1'],
      'gone': ['g1']
    });
    expect(refs(presence.state['a']), ['a2', 'a3']);
  });

  test('initial state plus buffered diffs emits one coherent snapshot',
      () async {
    final snapshots = <PresenceSnapshot<Json>>[];
    final changes = <PresenceChange<Json>>[];
    final sub = presence.snapshots.listen(snapshots.add);
    final changeSub = presence.changes.listen(changes.add);
    channel.diff(joins: {
      'c': entry(['c1'])
    }, leaves: {
      'b': entry(['b1'])
    });
    expect(presence.state, isEmpty);
    expect(presence.inPendingSyncState, isTrue);
    channel.emitState({
      'a': entry(['a1']),
      'b': entry(['b1'])
    });
    await flush();
    expect(snapshots.map((s) => s.status), [
      PresenceSyncStatus.awaitingState,
      PresenceSyncStatus.synchronized,
    ]);
    expect(snapshots.last.presences.keys, ['a', 'c']);
    expect(changes.map((c) => c.key), ['a', 'c']);
    expect(presence.inPendingSyncState, isFalse);
    await sub.cancel();
    await changeSub.cancel();
  });

  test('rejoin buffers diffs and discards pending diffs from older joins', () {
    channel.emitState({
      'a': entry(['a1'])
    });
    channel.joinRef = '2';
    channel.diff(joins: {
      'obsolete': entry(['o1'])
    });
    expect(presence.snapshot.status, PresenceSyncStatus.stale);
    expect(presence.state.keys, ['a']);
    channel.joinRef = '3';
    channel.diff(leaves: {
      'b': entry(['b1'])
    });
    channel.emitState({
      'b': entry(['b1']),
      'c': entry(['c1'])
    });
    expect(presence.state.keys, ['c']);
    expect(presence.snapshot.isSynchronized, isTrue);
  });

  test('explicit old join refs are ignored; null broadcast refs are accepted',
      () {
    channel.emitState({
      'a': entry(['a1'])
    });
    channel.send(
        'presence_state',
        {
          'wrong': entry(['w1'])
        },
        joinRef: 'old');
    channel.send(
        'presence_diff',
        {
          'joins': {
            'wrong': entry(['w1'])
          }
        },
        joinRef: 'old');
    channel.send('phx_close', {}, joinRef: 'old');
    channel.diff(joins: {
      'b': entry(['b1'])
    });
    expect(presence.state.keys, ['a', 'b']);
    expect(presence.snapshot.isSynchronized, isTrue);
  });

  test('enriched data and nested metadata are preserved and deeply immutable',
      () {
    final nested = <String, Object?>{
      'tags': ['one']
    };
    final payload = <String, dynamic>{
      'a': {
        'user': {'name': 'Ada'},
        'metas': [
          {'phx_ref': 'a1', 'nested': nested}
        ],
      }
    };
    channel.emitState(payload);
    final old = presence.snapshot;
    (nested['tags'] as List).add('two');
    ((payload['a'] as Map)['user'] as Map)['name'] = 'Changed';
    channel.diff(joins: {
      'b': entry(['b1'])
    });
    final a = presence.state['a']!;
    expect(a.data['user'], {'name': 'Ada'});
    expect(a.metas.single.data['nested'], {
      'tags': ['one']
    });
    expect(old.presences.keys, ['a']);
    expect(() => presence.state.clear(), throwsUnsupportedError);
    expect(() => a.metas.clear(), throwsUnsupportedError);
    expect(
        () => (a.data['user'] as Map)['name'] = 'No', throwsUnsupportedError);
    expect(() => (a.metas.single.data['nested'] as Map).clear(),
        throwsUnsupportedError);
    expect(
        () => ((a.metas.single.data['nested'] as Map)['tags'] as List).clear(),
        throwsUnsupportedError);
  });

  test('full states refresh enriched fields even when refs do not change',
      () async {
    channel.emitState({
      'a': entry(['a1'], fields: {'name': 'old'})
    });
    final changes = <PresenceChange<Json>>[];
    final sub = presence.changes.listen(changes.add);
    channel.emitState({
      'a': entry(['a1'], fields: {'name': 'new'})
    });
    await flush();
    expect(presence.state['a']!.data['name'], 'new');
    expect(changes.single.joined, isEmpty);
    expect(changes.single.left, isEmpty);
    expect(changes.single.before!.data['name'], 'old');
    await sub.cancel();
  });

  test('custom decoder keeps protocol refs separate from application values',
      () async {
    final typed = PhoenixPresence<String>(
      channel: channel,
      decodeMeta: (json) => json['name'] as String,
    );
    addTearDown(typed.dispose);
    channel.emitState({
      'a': {
        'metas': [
          {'phx_ref': 'a1', 'name': 'Ada'}
        ]
      }
    });
    channel.diff(
      joins: {
        'a': {
          'metas': [
            {'phx_ref': 'a2', 'phx_ref_prev': 'a1', 'name': 'Grace'}
          ]
        }
      },
      leaves: {
        'a': {
          'metas': [
            {'phx_ref': 'a1', 'name': 'Ada'}
          ]
        }
      },
    );
    final meta = typed.state['a']!.metas.single;
    expect(meta.value, 'Grace');
    expect(meta.phxRef, 'a2');
    expect(meta.phxRefPrev, 'a1');
    expect(() => PhoenixPresence<int>(channel: channel), throwsArgumentError);
  });

  test('raw construction and legacy model decoding remain available', () async {
    final raw = PhoenixPresence(channel: channel);
    addTearDown(raw.dispose);
    channel.emitState({
      'a': entry(['a1'])
    });
    expect(raw.state['a']!.metas.single.value, {'phx_ref': 'a1'});
    final model = Presence.fromJson('a', {
      'a': entry(['a1'])
    });
    expect(refs(model.clone()), ['a1']);
    expect(model.metas.single.clone().data, {'phx_ref': 'a1'});
  });

  test(
      'metadata replacement emits one change without a false offline transition',
      () async {
    channel.emitState({
      'a': entry(['a1'])
    });
    final changes = <PresenceChange<Json>>[];
    final sub = presence.changes.listen(changes.add);
    channel.diff(joins: {
      'a': entry(['a2'])
    }, leaves: {
      'a': entry(['a1'])
    });
    await flush();
    final change = changes.single;
    expect(change.joined.map((m) => m.phxRef), ['a2']);
    expect(change.left.map((m) => m.phxRef), ['a1']);
    expect(change.becamePresent, isFalse);
    expect(change.becameAbsent, isFalse);
    expect(refs(change.snapshot.presences['a']), ['a2']);
    await sub.cancel();
  });

  test('key transitions distinguish additional devices and final departures',
      () async {
    channel.emitState({});
    final changes = <PresenceChange<Json>>[];
    final sub = presence.changes.listen(changes.add);
    channel.diff(joins: {
      'a': entry(['a1'])
    });
    channel.diff(joins: {
      'a': entry(['a2'])
    });
    channel.diff(leaves: {
      'a': entry(['a1'])
    });
    channel.diff(leaves: {
      'a': entry(['a2'])
    });
    await flush();
    expect(changes.map((c) => c.becamePresent), [true, false, false, false]);
    expect(changes.map((c) => c.becameAbsent), [false, false, false, true]);
    expect(refs(changes.first.snapshot.presences['a']), ['a1']);
    await sub.cancel();
  });

  test('unchanged state, duplicate joins and unknown leaves emit no changes',
      () async {
    channel.emitState({
      'a': entry(['a1'])
    });
    final changes = <PresenceChange<Json>>[];
    final sub = presence.changes.listen(changes.add);
    channel.emitState({
      'a': entry(['a1'])
    });
    channel.diff(joins: {
      'a': entry(['a1'])
    });
    channel.diff(leaves: {
      'missing': entry(['m1'])
    });
    await flush();
    expect(changes, isEmpty);
    await sub.cancel();
  });

  test('snapshots replay to independent late listeners; changes do not',
      () async {
    channel.emitState({
      'a': entry(['a1'])
    });
    final first = <PresenceSnapshot<Json>>[];
    final second = <PresenceSnapshot<Json>>[];
    final changes = <PresenceChange<Json>>[];
    final sub1 = presence.snapshots.listen(first.add);
    final sub2 = presence.snapshots.listen(second.add);
    final sub3 = presence.changes.listen(changes.add);
    channel.diff(joins: {
      'b': entry(['b1'])
    });
    await flush();
    expect(first.map((s) => s.presences.keys.toList()), [
      ['a'],
      ['a', 'b']
    ]);
    expect(second, first);
    expect(changes.map((c) => c.key), ['b']);
    await sub1.cancel();
    channel.diff(joins: {
      'c': entry(['c1'])
    });
    await flush();
    expect(second.last.presences.keys, ['a', 'b', 'c']);
    await sub2.cancel();
    await sub3.cancel();
  });

  test('custom events support partial legacy configuration and named overrides',
      () async {
    final custom = PhoenixPresence<Json>(
      channel: channel,
      eventNames: {'state': 'old_state'},
      stateEvent: 'custom_state',
    );
    addTearDown(custom.dispose);
    channel.send('old_state', {
      'ignored': entry(['x'])
    });
    channel.send('custom_state', {
      'a': entry(['a1'])
    });
    channel.diff(joins: {
      'b': entry(['b1'])
    });
    expect(custom.state.keys, ['a', 'b']);
    expect(
        custom.eventNames, {'state': 'custom_state', 'diff': 'presence_diff'});
    final diffOnly = PhoenixPresence<Json>(
      channel: channel,
      eventNames: {'diff': 'custom_diff'},
    );
    addTearDown(diffOnly.dispose);
    channel.emitState({
      'a': entry(['a1'])
    });
    channel.send('custom_diff', {
      'leaves': {
        'a': entry(['a1'])
      }
    });
    expect(diffOnly.state, isEmpty);
    expect(() => PhoenixPresence(channel: channel, stateEvent: ''),
        throwsArgumentError);
    expect(() => PhoenixPresence(channel: channel, stateEvent: 'presence_diff'),
        throwsArgumentError);
    expect(() => PhoenixPresence(channel: channel, diffEvent: 'phx_close'),
        throwsArgumentError);
  });

  for (final bad in <Map<String, dynamic>?>[
    null,
    {'bad': {}},
    {
      'bad': {'metas': 'invalid'}
    },
    {
      'bad': {
        'metas': [42]
      }
    },
    {
      'bad': {
        'metas': [{}]
      }
    },
    {
      'bad': {
        'metas': [
          {'phx_ref': 42}
        ]
      }
    },
    {
      'bad': {
        'metas': [
          {'phx_ref': 'x', 'phx_ref_prev': 42}
        ]
      }
    },
    {
      'bad': entry(['duplicate', 'duplicate'])
    },
  ]) {
    test('malformed full state is atomic and recoverable: $bad', () async {
      channel.emitState({
        'a': entry(['a1'])
      });
      final errors = <PresenceError>[];
      final sub = presence.errors.listen(errors.add);
      var joins = 0;
      presence.onJoin = (_, __, ___) => joins++;
      channel.send('presence_state', bad);
      await flush();
      expect(presence.state.keys, ['a']);
      expect(presence.snapshot.status, PresenceSyncStatus.stale);
      expect(presence.inPendingSyncState, isTrue);
      expect(errors.single.error, isFormatException);
      expect(errors.single.event, 'presence_state');
      expect(joins, 0);
      channel.emitState({
        'b': entry(['b1'])
      });
      expect(presence.state.keys, ['b']);
      expect(presence.snapshot.isSynchronized, isTrue);
      await sub.cancel();
    });
  }

  test('a malformed later diff entry cannot partially commit a batch',
      () async {
    channel.emitState({
      'a': entry(['a1'])
    });
    final errors = <PresenceError>[];
    final sub = presence.errors.listen(errors.add);
    channel.send('presence_diff', {
      'joins': {
        'b': entry(['b1']),
        'bad': {'metas': 'invalid'}
      },
      'leaves': {
        'a': entry(['a1'])
      },
    });
    await flush();
    expect(presence.state.keys, ['a']);
    expect(errors.single.error, isFormatException);
    channel.diff(joins: {
      'c': entry(['c1'])
    });
    expect(presence.state.keys, ['a']);
    channel.emitState({
      'b': entry(['b1'])
    });
    expect(presence.state.keys, ['b', 'c']);
    await sub.cancel();
  });

  test('decoder failures are reported without advancing synchronization',
      () async {
    final typed = PhoenixPresence<int>(
      channel: channel,
      decodeMeta: (json) => int.parse(json['number'] as String),
    );
    addTearDown(typed.dispose);
    final errors = <PresenceError>[];
    final sub = typed.errors.listen(errors.add);
    channel.emitState({
      'a': {
        'metas': [
          {'phx_ref': 'a1', 'number': 'invalid'}
        ]
      }
    });
    await flush();
    expect(typed.state, isEmpty);
    expect(typed.inPendingSyncState, isTrue);
    expect(errors.single.error, isFormatException);
    channel.emitState({
      'a': {
        'metas': [
          {'phx_ref': 'a1', 'number': '42'}
        ]
      }
    });
    expect(typed.state['a']!.metas.single.value, 42);
    await sub.cancel();
  });

  test('callback failures cannot stop reconciliation or subsequent observers',
      () async {
    final errors = <PresenceError>[];
    final sub = presence.errors.listen(errors.add);
    var joins = 0;
    var syncs = 0;
    presence.onJoin = (_, __, ___) {
      joins++;
      throw StateError('observer');
    };
    presence.onSync = () => syncs++;
    channel.emitState({
      'a': entry(['a1']),
      'b': entry(['b1'])
    });
    await flush();
    expect(presence.state.keys, ['a', 'b']);
    expect(presence.snapshot.isSynchronized, isTrue);
    expect(joins, 2);
    expect(syncs, 1);
    expect(errors.length, 2);
    await sub.cancel();
  });

  test('socket disconnect and channel errors retain stale state without leaves',
      () async {
    channel.emitState({
      'a': entry(['a1'])
    });
    final changes = <PresenceChange<Json>>[];
    final sub = presence.changes.listen(changes.add);
    channel.socket.closes.add(const PhoenixSocketCloseEvent());
    expect(presence.snapshot.status, PresenceSyncStatus.stale);
    expect(presence.state.keys, ['a']);
    channel.joinRef = '2';
    channel.diff(joins: {
      'discarded': entry(['d1'])
    });
    channel.send('phx_error', {});
    channel.emitState({
      'a': entry(['a1'])
    });
    await flush();
    expect(presence.state.keys, ['a']);
    expect(changes, isEmpty);
    await sub.cancel();
  });

  test('source errors and socket errors are observable and invalidate sync',
      () async {
    final errors = <PresenceError>[];
    final sub = presence.errors.listen(errors.add);
    channel.emitState({});
    channel.controller.addError(StateError('source'));
    expect(presence.snapshot.status, PresenceSyncStatus.stale);
    channel.emitState({});
    channel.socket.errors.add(PhoenixSocketErrorEvent(
      error: StateError('socket'),
      stacktrace: StackTrace.current,
    ));
    await flush();
    expect(errors.length, 2);
    expect(presence.snapshot.status, PresenceSyncStatus.stale);
    await sub.cancel();
  });

  test('errors without listeners do not become unhandled asynchronous errors',
      () async {
    channel.send('presence_state', null);
    await flush();
    expect(presence.snapshot.status, PresenceSyncStatus.stale);
  });

  test('dispose is idempotent, releases inputs, and leaves the channel open',
      () async {
    channel.emitState({
      'a': entry(['a1'])
    });
    final values = <PresenceSnapshot<Json>>[];
    final done = Completer<void>();
    final sub = presence.snapshots.listen(values.add, onDone: done.complete);
    final first = presence.dispose();
    expect(identical(first, presence.dispose()), isTrue);
    await first;
    await done.future;
    expect(channel.controller.hasListener, isFalse);
    expect(channel.socket.closes.hasListener, isFalse);
    expect(channel.socket.errors.hasListener, isFalse);
    expect(channel.closed, isFalse);
    expect(values.last.status, PresenceSyncStatus.closed);
    channel.emitState({
      'ignored': entry(['x'])
    });
    expect(presence.state.keys, ['a']);
    expect((await presence.snapshots.first).status, PresenceSyncStatus.closed);
    await sub.cancel();
  });

  test('paused output listeners do not block dispose', () async {
    final done = Completer<void>();
    final sub = presence.snapshots.listen((_) {}, onDone: done.complete)
      ..pause();
    await presence.dispose().timeout(const Duration(seconds: 1));
    sub.resume();
    await done.future;
  });

  test('closing the channel message stream closes the presence streams',
      () async {
    final changesDone = presence.changes.drain<void>();
    final errorsDone = presence.errors.drain<void>();
    await channel.controller.close();
    await Future.wait([presence.dispose(), changesDone, errorsDone]);
    expect(presence.snapshot.status, PresenceSyncStatus.closed);
  });

  for (final bad in <Object?>[null, [], 'invalid']) {
    test('invalid diff sections invalidate sync: $bad', () async {
      channel.emitState({
        'a': entry(['a1'])
      });
      final failures = <PresenceError>[];
      final sub = presence.errors.listen(failures.add);
      channel.send('presence_diff', {'joins': bad, 'leaves': {}});
      await flush();
      expect(failures.single.error, isFormatException);
      expect(presence.state.keys, ['a']);
      expect(presence.snapshot.status, PresenceSyncStatus.stale);
      await sub.cancel();
    });
  }

  test('real channel messages and closure work without a network connection',
      () async {
    final transport = FakeTransport(readyImmediately: true);
    transport.onSend = transport.replyTo;
    final socket = PhoenixSocket('ws://unused.invalid/socket',
        webSocketChannelFactory: (_) => transport);
    final realChannel = socket.addChannel(topic: 'presence:lobby');
    final client = PhoenixPresence<Json>(channel: realChannel);
    addTearDown(() async {
      await client.dispose();
      socket.dispose();
    });
    // The transport is entirely in memory; exercise the real join lifecycle.
    await socket.connect();
    await realChannel.join().future;
    realChannel.trigger(Message(
      event: const PhoenixChannelEvent.custom('presence_state'),
      payload: {
        'a': entry(['a1'])
      },
    ));
    await flush();
    expect(client.state.keys, ['a']);
    expect(realChannel.state, PhoenixChannelState.joined);
    realChannel.triggerError(ChannelClosedError(message: 'Local failure'));
    expect(client.snapshot.status, PresenceSyncStatus.stale);
    expect(client.state.keys, ['a']);
    final closed = client.snapshots
        .firstWhere((snapshot) => snapshot.status == PresenceSyncStatus.closed);
    realChannel.close();
    await closed;
    expect(client.snapshot.status, PresenceSyncStatus.closed);
  });

  test('real channel leave invalidates presence and settles pending pushes',
      () async {
    final transport = FakeTransport(readyImmediately: true);
    transport.onSend = (message) {
      if (message[3] == 'phx_join' || message[3] == 'phx_leave') {
        transport.replyTo(message);
      }
    };
    final socket = PhoenixSocket('ws://unused.invalid/socket',
        webSocketChannelFactory: (_) => transport);
    final realChannel = socket.addChannel(topic: 'presence:lobby');
    final client = PhoenixPresence<Json>(channel: realChannel);
    addTearDown(() async {
      await client.dispose();
      socket.dispose();
    });
    await socket.connect();
    await realChannel.join().future;
    realChannel.trigger(Message(
      event: const PhoenixChannelEvent.custom('presence_state'),
      payload: {
        'a': entry(['a1'])
      },
    ));
    await flush();
    expect(client.snapshot.isSynchronized, isTrue);

    final pending = realChannel.push('request', {}, expectingReply: true);
    final requestFailure =
        expectLater(pending.future, throwsA(isA<ChannelClosedError>()));
    final leave = realChannel.leave();
    expect(client.snapshot.status, PresenceSyncStatus.stale);
    expect(client.state.keys, ['a']);
    expect((await leave.future).isOk, isTrue);
    await requestFailure;
    expect(client.snapshot.status, PresenceSyncStatus.closed);
    expect(socket.channels, isEmpty);
  });

  test('deferred initial join preserves awaiting state for late subscribers',
      () async {
    final transport = FakeTransport(readyImmediately: true);
    transport.onSend = transport.replyTo;
    final socket = PhoenixSocket('ws://unused.invalid/socket',
        webSocketChannelFactory: (_) => transport);
    final realChannel = socket.addChannel(topic: 'presence:lobby');
    final client = PhoenixPresence<Json>(channel: realChannel);
    addTearDown(() async {
      await client.dispose();
      socket.dispose();
    });

    // This is the documented pre-connect join sequence. The later connection
    // uses the in-memory transport rather than a network backend.
    final join = realChannel.join();
    expect(realChannel.state, PhoenixChannelState.errored);
    expect(client.snapshot.status, PresenceSyncStatus.awaitingState);
    expect((await client.snapshots.first).status,
        PresenceSyncStatus.awaitingState);

    await socket.connect();
    await join.future;
    expect(realChannel.state, PhoenixChannelState.joined);
    expect(client.snapshot.status, PresenceSyncStatus.awaitingState);
    realChannel.trigger(Message(
      event: const PhoenixChannelEvent.custom('presence_state'),
      payload: {},
    ));
    await flush();
    expect(client.snapshot.isSynchronized, isTrue);

    // An empty synchronized snapshot still becomes stale on a later failure.
    realChannel.triggerError(ChannelClosedError(message: 'Local failure'));
    expect(client.snapshot.status, PresenceSyncStatus.stale);
  });

  test('initial channel retries preserve awaiting state and clear old diffs',
      () {
    channel.diff(joins: {
      'obsolete': entry(['o1'])
    });
    channel.transition(PhoenixChannelState.errored);
    channel.transition(PhoenixChannelState.joining);
    channel.transition(PhoenixChannelState.joined);
    expect(presence.snapshot.status, PresenceSyncStatus.awaitingState);
    channel.emitState({});
    expect(presence.snapshot.isSynchronized, isTrue);
    expect(presence.state, isEmpty);
  });

  for (final lifecycle in [
    PhoenixChannelState.errored,
    PhoenixChannelState.leaving,
  ]) {
    test('delayed presence messages cannot synchronize a $lifecycle channel',
        () async {
      channel.emitState({
        'a': entry(['a1'])
      });
      final changes = <PresenceChange<Json>>[];
      final sub = presence.changes.listen(changes.add);
      addTearDown(sub.cancel);
      var syncs = 0;
      presence.onSync = () => syncs++;

      channel.transition(lifecycle);
      final stale = presence.snapshot;
      expect(stale.status, PresenceSyncStatus.stale);
      for (final ref in [channel.joinRef, null]) {
        channel.send(
            'presence_diff',
            {
              'joins': {
                'delayed': entry(['d1'])
              },
              'leaves': {},
            },
            joinRef: ref);
        channel.send(
            'presence_state',
            {
              'delayed': entry(['d1'])
            },
            joinRef: ref);
      }
      await flush();
      expect(presence.snapshot.status, PresenceSyncStatus.stale);
      expect(presence.snapshot, same(stale));
      expect(presence.state.keys, ['a']);
      expect(changes, isEmpty);
      expect(syncs, 0);

      if (lifecycle == PhoenixChannelState.errored) {
        channel.transition(PhoenixChannelState.joining);
        channel.joinRef = '2';
        channel.transition(PhoenixChannelState.joined);
        channel.emitState({
          'b': entry(['b1'])
        });
        expect(presence.snapshot.isSynchronized, isTrue);
        expect(presence.state.keys, ['b']);
      }
    });
  }

  test('phx_close terminates observation', () async {
    channel.send('phx_close', {});
    await presence.dispose();
    expect(presence.snapshot.status, PresenceSyncStatus.closed);
    expect(channel.controller.hasListener, isFalse);
  });

  test('local channel lifecycle invalidates presence before new messages', () {
    channel.emitState({
      'a': entry(['a1'])
    });
    channel.transition(PhoenixChannelState.errored);
    expect(presence.snapshot.status, PresenceSyncStatus.stale);
    channel.transition(PhoenixChannelState.joining);
    channel.joinRef = '2';
    channel.transition(PhoenixChannelState.joined);
    expect(presence.snapshot.status, PresenceSyncStatus.stale);
    channel.diff(joins: {
      'b': entry(['b1'])
    });
    expect(presence.state.keys, ['a']);
    channel.emitState({
      'a': entry(['a1'])
    });
    expect(presence.state.keys, ['a', 'b']);
    channel.transition(PhoenixChannelState.leaving);
    expect(presence.snapshot.status, PresenceSyncStatus.stale);
  });

  test('closing a never-joined real channel disposes its presence client',
      () async {
    final socket = PhoenixSocket('ws://unused.invalid/socket');
    final realChannel = socket.addChannel(topic: 'presence:lobby');
    final client = PhoenixPresence<Json>(channel: realChannel);
    addTearDown(() async {
      await client.dispose();
      socket.dispose();
    });
    final closed = client.snapshots
        .firstWhere((snapshot) => snapshot.status == PresenceSyncStatus.closed);
    realChannel.close();
    await closed;
    expect(socket.channels, isEmpty);
    expect(client.snapshot.status, PresenceSyncStatus.closed);
    realChannel.close();
  });
}

class FakeSocket implements PhoenixSocket {
  final closes =
      StreamController<PhoenixSocketCloseEvent>.broadcast(sync: true);
  final errors =
      StreamController<PhoenixSocketErrorEvent>.broadcast(sync: true);

  @override
  Stream<PhoenixSocketCloseEvent> get closeStream => closes.stream;
  @override
  Stream<PhoenixSocketErrorEvent> get errorStream => errors.stream;

  Future<void> shutdown() async {
    await closes.close();
    await errors.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeChannel implements PhoenixChannel {
  final controller = StreamController<Message>.broadcast(sync: true);
  final states = StreamController<PhoenixChannelState>.broadcast(sync: true);
  @override
  final FakeSocket socket = FakeSocket();
  @override
  String joinRef = '1';
  bool closed = false;
  PhoenixChannelState _state = PhoenixChannelState.joined;

  @override
  PhoenixChannelState get state => _state;

  void transition(PhoenixChannelState value) {
    _state = value;
    states.add(value);
  }

  @override
  Stream<Message> get messages => controller.stream;
  @override
  Stream<PhoenixChannelState> get stateStream => states.stream;
  @override
  void close() {
    closed = true;
    unawaited(controller.close());
  }

  void send(String event, Map<String, dynamic>? payload, {String? joinRef}) =>
      controller.add(Message(
        event: PhoenixChannelEvent.custom(event),
        payload: payload,
        joinRef: joinRef,
      ));

  void emitState(Map<String, dynamic> payload) =>
      send('presence_state', payload);
  void diff({Json joins = const {}, Json leaves = const {}}) =>
      send('presence_diff', {'joins': joins, 'leaves': leaves});

  Future<void> shutdown() async {
    await controller.close();
    await states.close();
    await socket.shutdown();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
