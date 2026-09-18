import 'dart:async';

import 'package:rxdart/rxdart.dart';

import 'events.dart';
import 'message.dart';
import 'pheonix_channel.dart';
import 'presence_models.dart';

export 'presence_models.dart'
    show
        PresenceSyncStatus,
        PresenceSnapshot,
        PresenceChange,
        PresenceError,
        Presence,
        PhoenixPresenceMeta;

/// Legacy join notification. Prefer [PhoenixPresence.changes].
typedef JoinHandler<T> = void Function(
    String key, Presence<T>? current, Presence<T> joined);

/// Legacy leave notification. [current] contains the remaining metadata.
typedef LeaveHandler<T> = void Function(
    String key, Presence<T> current, Presence<T> left);

/// Reconciles Phoenix presence state and diffs for one channel.
///
/// Attach before joining the channel: channel messages are not replayed.
/// Without a decoder, metadata values are immutable JSON maps. When using a
/// custom type [T], provide a decoder that returns immutable values.
///
/// This client observes presence. Tracking/updating a presence on the server
/// requires an application-defined channel event.
class PhoenixPresence<T> {
  /// Starts listening without joining or taking ownership of [channel].
  ///
  /// Named event options override entries in the legacy [eventNames] map.
  PhoenixPresence({
    required this.channel,
    T Function(Map<String, Object?> json)? decodeMeta,
    String? stateEvent,
    String? diffEvent,
    @Deprecated('Use stateEvent and diffEvent instead.')
    Map<String, String>? eventNames,
  })  : _decodeMeta = decodeMeta,
        stateEventName = stateEvent ?? eventNames?['state'] ?? 'presence_state',
        diffEventName = diffEvent ?? eventNames?['diff'] ?? 'presence_diff' {
    if (decodeMeta == null && <String, Object?>{} is! T) {
      throw ArgumentError('A decodeMeta function is required for $T.');
    }
    if (stateEventName.isEmpty ||
        diffEventName.isEmpty ||
        stateEventName == diffEventName ||
        {stateEventName, diffEventName}.any((name) =>
            PhoenixChannelEvent.statuses.any((e) => e.value == name))) {
      throw ArgumentError('Presence event names must be distinct, non-empty '
          'and must not be channel lifecycle events.');
    }
    _snapshots = BehaviorSubject.seeded(
      PresenceSnapshot<T>(
        presences: {},
        status: PresenceSyncStatus.awaitingState,
      ),
    );
    _subscriptions.add(channel.messages.listen(
      _onMessage,
      onError: _onSourceError,
      onDone: () => unawaited(dispose()),
    ));
    _subscriptions.add(channel.stateStream.listen(
      _onChannelState,
      onError: _onSourceError,
      onDone: () => unawaited(dispose()),
    ));
    _subscriptions.add(channel.socket.closeStream.listen(
      (_) => _invalidate(),
      onError: _onSourceError,
    ));
    _subscriptions.add(channel.socket.errorStream.listen(
      (event) {
        _invalidate();
        _reportError(
            event.error ?? event,
            event.stacktrace is StackTrace
                ? event.stacktrace as StackTrace
                : StackTrace.current);
      },
      onError: _onSourceError,
    ));
  }

  /// The channel being observed. Disposing presence does not close it.
  final PhoenixChannel channel;

  /// The full-state event name.
  final String stateEventName;

  /// The incremental-diff event name.
  final String diffEventName;

  final T Function(Map<String, Object?>)? _decodeMeta;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _pendingDiffs = <_PresenceDiff<T>>[];
  late final BehaviorSubject<PresenceSnapshot<T>> _snapshots;
  final _changes = StreamController<PresenceChange<T>>.broadcast();
  final _errors = StreamController<PresenceError>.broadcast();
  String? _joinRef;
  String? _pendingJoinRef;
  bool _disposed = false;
  Future<void>? _disposeFuture;

  /// The latest immutable state, including its synchronization status.
  PresenceSnapshot<T> get snapshot => _snapshots.value;

  /// Broadcast snapshots, replaying the latest value to each new subscriber.
  ///
  /// A full state and its buffered diffs produce one synchronized snapshot.
  /// Lifecycle changes also produce snapshots, retaining the last known data.
  Stream<PresenceSnapshot<T>> get snapshots => _snapshots.stream;

  /// Per-key changes between committed synchronized snapshots; no replay.
  ///
  /// Each change includes its resulting snapshot. Consumers should use that
  /// value rather than assuming [snapshot] has not advanced by delivery time.
  /// Connection loss alone does not produce leave notifications.
  Stream<PresenceChange<T>> get changes => _changes.stream;

  /// Decode, source-stream and legacy-callback failures, delivered as values.
  ///
  /// This broadcast stream does not replay or throw unhandled stream errors
  /// when nobody listens. Invalid payloads retain the last known data and mark
  /// it stale until a valid full state arrives. No resync request is sent.
  Stream<PresenceError> get errors => _errors.stream;

  /// Immutable presences from the current snapshot.
  Map<String, Presence<T>> get state => snapshot.presences;

  /// Whether a full state is still needed for the current channel join.
  bool get inPendingSyncState =>
      _joinRef == null || _joinRef != channel.joinRef;

  /// Resolved event names, including defaults.
  @Deprecated('Use stateEventName and diffEventName instead.')
  Map<String, String> get eventNames =>
      Map.unmodifiable({'state': stateEventName, 'diff': diffEventName});

  /// Legacy protocol-level join callback, called after state is committed.
  @Deprecated('Listen to changes instead.')
  JoinHandler<T> onJoin = (_, __, ___) {};

  /// Legacy protocol-level leave callback, called after state is committed.
  @Deprecated('Listen to changes instead.')
  LeaveHandler<T> onLeave = (_, __, ___) {};

  /// Legacy synchronization callback, called after state is committed.
  @Deprecated('Listen to snapshots instead.')
  void Function() onSync = () {};

  /// Legacy projection helper.
  @Deprecated('Use snapshot.presences.values or entries with Iterable.map.')
  List<dynamic> list(Map<String, Presence<T>> presences,
          [dynamic Function(String, Presence<T>)? chooser]) =>
      presences.entries
          .map((entry) =>
              chooser == null ? entry.value : chooser(entry.key, entry.value))
          .toList();

  /// Stops observing, publishes a closed snapshot, and closes output streams.
  ///
  /// Idempotent. Awaits input subscription cleanup, without closing the channel
  /// or socket. Output completion is queued; paused consumers do not delay this
  /// future and receive queued events when resumed.
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _joinRef = null;
    _pendingDiffs.clear();
    _setStatus(PresenceSyncStatus.closed);
    try {
      await Future.wait(_subscriptions.map((sub) => sub.cancel()));
    } finally {
      unawaited(_snapshots.close());
      unawaited(_changes.close());
      unawaited(_errors.close());
    }
  }

  void _setStatus(PresenceSyncStatus status) {
    if (snapshot.status == status) return;
    _snapshots.add(PresenceSnapshot(
      presences: state,
      status: status,
    ));
  }

  void _invalidate() {
    if (_disposed) return;
    _joinRef = null;
    _pendingJoinRef = null;
    _pendingDiffs.clear();
    _setStatus(PresenceSyncStatus.stale);
  }

  void _onChannelState(PhoenixChannelState state) {
    if (_disposed) return;
    switch (state) {
      case PhoenixChannelState.closed:
        unawaited(dispose());
      case PhoenixChannelState.errored:
      case PhoenixChannelState.leaving:
        _invalidate();
      case PhoenixChannelState.joining:
        if (snapshot.status == PresenceSyncStatus.awaitingState) {
          _joinRef = null;
          _pendingJoinRef = null;
          _pendingDiffs.clear();
        } else {
          _invalidate();
        }
      case PhoenixChannelState.joined:
        // Only a full presence state can establish synchronization.
        break;
    }
  }

  void _onSourceError(Object error, StackTrace stackTrace) {
    _invalidate();
    _reportError(error, stackTrace);
  }

  void _reportError(Object error, StackTrace stackTrace, [String? event]) {
    if (!_disposed) {
      _errors.add(PresenceError(error, stackTrace, event: event));
    }
  }

  void _onMessage(Message message) {
    if (_disposed) return;
    final event = message.event.value;
    // Broadcast diffs may have a null join ref. Explicit old refs are stale.
    if (message.joinRef != null && message.joinRef != channel.joinRef) return;
    if (message.event == PhoenixChannelEvent.close) {
      unawaited(dispose());
      return;
    }
    if (message.event == PhoenixChannelEvent.error) {
      _invalidate();
      return;
    }
    if (event != stateEventName && event != diffEventName) return;

    final currentJoinRef = channel.joinRef;
    if (_pendingJoinRef != currentJoinRef) {
      _pendingDiffs.clear();
      _pendingJoinRef = currentJoinRef;
      if (_joinRef != null && _joinRef != currentJoinRef) {
        _joinRef = null;
        _setStatus(PresenceSyncStatus.stale);
      }
    }

    final before = state;
    final notifications = <_LegacyNotification<T>>[];
    late Map<String, Presence<T>> next;
    try {
      if (event == stateEventName) {
        final incoming = _decodeState(message.payload, 'state');
        // Calculate protocol callbacks, but use the authoritative full payload
        // so enriched fields and unchanged-reference metadata also refresh.
        _applyDiff(before, _stateDiff(before, incoming), notifications);
        next = incoming;
        for (final diff in _pendingDiffs) {
          next = _applyDiff(next, diff, notifications);
        }
      } else {
        final payload = presenceJsonObject(message.payload, 'diff');
        final diff = _PresenceDiff(
          _decodeState(
              payload.containsKey('joins') ? payload['joins'] : {}, 'joins'),
          _decodeState(
              payload.containsKey('leaves') ? payload['leaves'] : {}, 'leaves'),
        );
        if (inPendingSyncState) {
          _pendingDiffs.add(diff);
          return;
        }
        next = _applyDiff(before, diff, notifications);
      }
    } catch (error, stackTrace) {
      _invalidate();
      _reportError(error, stackTrace, event);
      return;
    }
    _joinRef = currentJoinRef;
    _pendingDiffs.clear();
    final committed = PresenceSnapshot<T>(
      presences: next,
      status: PresenceSyncStatus.synchronized,
    );
    _snapshots.add(committed);
    for (final key in {...before.keys, ...next.keys}) {
      final previous = before[key];
      final current = next[key];
      if (presenceJsonEquals(previous?.toJson(), current?.toJson())) continue;
      _changes.add(PresenceChange(
        key: key,
        before: previous,
        after: current,
        snapshot: committed,
      ));
    }
    for (final notification in notifications) {
      if (_disposed) break;
      _notify(() {
        if (notification.isJoin) {
          // ignore: deprecated_member_use_from_same_package
          onJoin(notification.key, notification.current, notification.changed);
        } else {
          // ignore: deprecated_member_use_from_same_package
          onLeave(
              notification.key, notification.current!, notification.changed);
        }
      }, event);
    }
    // ignore: deprecated_member_use_from_same_package
    if (!_disposed) _notify(onSync, event);
  }

  void _notify(void Function() callback, String event) {
    try {
      callback();
    } catch (error, stackTrace) {
      _reportError(error, stackTrace, event);
    }
  }

  Map<String, Presence<T>> _decodeState(Object? value, String path) {
    final json = presenceJsonObject(value, path);
    return json.map((key, value) => MapEntry(
        key,
        Presence<T>.fromPayload(
          key,
          presenceJsonObject(value, '$path.$key'),
          decodeMeta: _decodeMeta,
        )));
  }

  _PresenceDiff<T> _stateDiff(
      Map<String, Presence<T>> before, Map<String, Presence<T>> after) {
    final joins = <String, Presence<T>>{};
    final leaves = <String, Presence<T>>{};
    for (final key in {...before.keys, ...after.keys}) {
      final previous = before[key];
      final current = after[key];
      final oldRefs = previous?.metas.map((m) => m.phxRef).toSet() ?? {};
      final newRefs = current?.metas.map((m) => m.phxRef).toSet() ?? {};
      final added =
          current?.metas.where((m) => !oldRefs.contains(m.phxRef)).toList() ??
              [];
      final removed =
          previous?.metas.where((m) => !newRefs.contains(m.phxRef)).toList() ??
              [];
      if (added.isNotEmpty) joins[key] = current!.withMetas(added);
      if (removed.isNotEmpty) leaves[key] = previous!.withMetas(removed);
    }
    return _PresenceDiff(joins, leaves);
  }

  Map<String, Presence<T>> _applyDiff(
    Map<String, Presence<T>> before,
    _PresenceDiff<T> diff,
    List<_LegacyNotification<T>> notifications,
  ) {
    final next = Map<String, Presence<T>>.of(before);
    for (final entry in diff.joins.entries) {
      final current = next[entry.key];
      final joined = entry.value;
      final refs = joined.metas.map((m) => m.phxRef).toSet();
      next[entry.key] = joined.withMetas([
        ...?current?.metas.where((m) => !refs.contains(m.phxRef)),
        ...joined.metas,
      ]);
      notifications.add(_LegacyNotification(true, entry.key, current, joined));
    }
    for (final entry in diff.leaves.entries) {
      final current = next[entry.key];
      if (current == null) continue;
      final refs = entry.value.metas.map((m) => m.phxRef).toSet();
      final remaining = current
          .withMetas(current.metas.where((m) => !refs.contains(m.phxRef)));
      if (remaining.metas.isEmpty) {
        next.remove(entry.key);
      } else {
        next[entry.key] = remaining;
      }
      notifications
          .add(_LegacyNotification(false, entry.key, remaining, entry.value));
    }
    return next;
  }
}

class _PresenceDiff<T> {
  _PresenceDiff(this.joins, this.leaves);
  final Map<String, Presence<T>> joins;
  final Map<String, Presence<T>> leaves;
}

class _LegacyNotification<T> {
  _LegacyNotification(this.isJoin, this.key, this.current, this.changed);
  final bool isJoin;
  final String key;
  final Presence<T>? current;
  final Presence<T> changed;
}
