// ignore_for_file: public_member_api_docs

// TODO: This is a very much a non-tested port of the javascript code!
//       Feel free to test, improve and make a pull request.

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import 'channel.dart';
import 'message.dart';

typedef JoinHandler = void Function(
  String key,
  dynamic current,
  dynamic joined,
);
typedef LeaveHandler = void Function(
  String key,
  dynamic current,
  dynamic left,
);

void noopWithThreeArgs(String a, dynamic b, dynamic c) {}
void noopWithNoArg() {}

class PhoenixPresence {
  PhoenixPresence({
    @required this.channel,
    this.eventNames = const {
      'state': 'presence_state',
      'diff': 'presence_diff'
    },
  }) {
    _subscription = channel.messages
        .where((message) => eventNames.containsValue(message.event.value))
        .listen(_onMessage);
  }
  final PhoenixChannel channel;
  StreamSubscription _subscription;
  final Map<String, String> eventNames;
  Map<String, dynamic> state = {};
  List pendingDiffs = [];

  String _joinRef;

  JoinHandler joinHandler = noopWithThreeArgs;
  LeaveHandler leaveHandler = noopWithThreeArgs;
  Function() syncHandler = noopWithNoArg;

  bool get inPendingSyncState =>
      _joinRef == null || _joinRef != channel.joinRef;

  String get stateEventName {
    if (eventNames.containsKey('state')) return eventNames['state'];
    return 'presence_state';
  }

  String get diffEventName {
    if (eventNames.containsKey('diff')) return eventNames['diff'];
    return 'presence_diff';
  }

  List<dynamic> list(
    Map<String, dynamic> presences, [
    dynamic Function(String, dynamic) chooser,
  ]) {
    chooser = chooser ?? (k, v) => v;
    return _map(presences, (k, v) => chooser(k, v));
  }

  void dispose() {
    _subscription.cancel();
  }

  void _onMessage(Message message) {
    if (message.event.value == stateEventName) {
      _joinRef = channel.joinRef;
      final newState = message.payload;
      state = _syncState(state, newState, joinHandler, leaveHandler);
      for (final diff in pendingDiffs) {
        state = _syncDiff(state, diff, joinHandler, leaveHandler);
      }
      pendingDiffs = [];
      syncHandler();
    } else if (message.event.value == diffEventName) {
      final diff = message.payload;
      if (inPendingSyncState) {
        pendingDiffs.add(diff);
      } else {
        state = _syncDiff(state, diff, joinHandler, leaveHandler);
        syncHandler();
      }
    }
  }
}

Map<String, dynamic> _syncState(
  Map<String, dynamic> currentState,
  Map<String, dynamic> newState,
  JoinHandler onJoin,
  LeaveHandler onLeave,
) {
  final state = _clone(currentState);
  final joins = <String, dynamic>{};
  final leaves = <String, dynamic>{};

  _map(state, (key, presence) {
    if (newState.containsKey(key)) {
      leaves[key] = presence;
    }
  });
  _map(newState, (key, newPresence) {
    if (state.containsKey(key)) {
      final currentPresence = state[key];
      final newRefs =
          (newPresence['metas'] as List).map((m) => m['phx_ref']).toSet();
      final curRefs =
          (currentPresence['metas'] as List).map((m) => m['phx_ref']).toSet();

      final joinedMetas = (newPresence['metas'] as List)
          .where((m) => !curRefs.contains(m['phx_ref']))
          .toList();

      final leftMetas = (currentPresence['metas'] as List)
          .where((m) => !newRefs.contains(m['phx_ref']))
          .toList();

      if (joinedMetas.isNotEmpty) {
        joins[key] = newPresence;
        joins[key]['metas'] = joinedMetas;
      }
      if (leftMetas.isNotEmpty) {
        leaves[key] = _clone(currentPresence);
        leaves[key]['metas'] = leftMetas;
      }
    } else {
      joins[key] = newPresence;
    }
  });
  return _syncDiff(state, {'joins': joins, 'leaves': leaves}, onJoin, onLeave);
}

Map<String, dynamic> _syncDiff(
  Map<String, dynamic> currentState,
  Map<String, dynamic> diff,
  JoinHandler onJoin,
  LeaveHandler onLeave,
) {
  final state = _clone(currentState);

  final Map<String, dynamic> joins = diff['joins'];
  final Map<String, dynamic> leaves = diff['leaves'];

  _map(joins, (key, newPresence) {
    final currentPresence = state[key];
    state[key] = newPresence;
    if ((currentPresence != null) && (currentPresence != {})) {
      final joinedRefs =
          (state[key]['metas'] as List).map((m) => m['phx_ref']).toSet();
      final curMetas = (currentPresence['metas'] as List)
          .where((m) => !joinedRefs.contains(m['phx_ref']));
      (state[key]['metas'] as List).insertAll(0, curMetas);
    }
    onJoin(key, currentPresence, newPresence);
  });
  _map(leaves, (key, leftPresence) {
    final currentPresence = state[key];
    if ((currentPresence == null) | (currentPresence == {})) return;
    final refsToRemove =
        (leftPresence['metas'] as List).map((m) => m['phx_ref']).toSet();
    currentPresence['metas'] = (currentPresence['metas'] as List)
        .where((p) => !refsToRemove.contains(p['phx_ref']))
        .toList();
    onLeave(key, currentPresence, leftPresence);
    if ((currentPresence['metas'] as List).isEmpty) {
      state.remove(key);
    }
  });
  return state;
}

List<dynamic> _map(
  Map<String, dynamic> presences,
  dynamic Function(String, dynamic) mapper,
) {
  return presences.entries
      .map((entry) => mapper(entry.key, entry.value))
      .toList();
}

Map<String, dynamic> _clone(Map<String, dynamic> presences) {
  return jsonDecode(jsonEncode(presences));
}
