// ignore_for_file: public_member_api_docs

// TODO: This is a very much a non-tested port of the javascript code!
//       Feel free to test, improve and make a pull request.

import 'dart:async';

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
  final Map<String, String> eventNames;
  StreamSubscription _subscription;
  var state = <String, Presence>{};
  var pendingDiffs = <Map<String, Map<String, Presence>>>[];

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
    Map<String, Presence> presences, [
    dynamic Function(String, Presence) chooser,
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
      final newState = message.payload.map(
          (key, metas) => MapEntry(key, Presence.fromJson(key, {key: metas})));
      state = _syncState(state, newState, joinHandler, leaveHandler);
      for (final diff in pendingDiffs) {
        state = _syncDiff(state, diff, joinHandler, leaveHandler);
      }
      pendingDiffs = [];
      syncHandler();
    } else if (message.event.value == diffEventName) {
      final diff = message.payload.map((key, presence) {
        if ((presence as Map).isEmpty) {
          return MapEntry(key, <String, Presence>{});
        }
        final presenceKey = (presence as Map<String, dynamic>).keys.first;
        return MapEntry(
            key, {presenceKey: Presence.fromJson(presenceKey, presence)});
      });
      if (inPendingSyncState) {
        pendingDiffs.add(diff);
      } else {
        state = _syncDiff(state, diff, joinHandler, leaveHandler);
        syncHandler();
      }
    }
  }
}

Map<String, Presence> _syncState(
  Map<String, Presence> currentState,
  Map<String, Presence> newState,
  JoinHandler onJoin,
  LeaveHandler onLeave,
) {
  final state = _clone(currentState);
  final joins = <String, Presence>{};
  final leaves = <String, Presence>{};

  _map(state, (key, presence) {
    if (!newState.containsKey(key)) {
      leaves[key] = presence;
    }
  });
  _map(newState, (key, newPresence) {
    if (state.containsKey(key)) {
      final currentPresence = state[key];
      final newRefs = (newPresence.metas).map((m) => m.phxRef).toSet();
      final curRefs = (currentPresence.metas).map((m) => m.phxRef).toSet();

      final joinedMetas = (newPresence.metas)
          .where((m) => !curRefs.contains(m.phxRef))
          .toList();

      final leftMetas = (currentPresence.metas)
          .where((m) => !newRefs.contains(m.phxRef))
          .toList();

      if (joinedMetas.isNotEmpty) {
        joins[key] = newPresence;
        joins[key].metas = joinedMetas;
      }
      if (leftMetas.isNotEmpty) {
        leaves[key] = currentPresence.clone();
        leaves[key].metas = leftMetas;
      }
    } else {
      joins[key] = newPresence;
    }
  });
  return _syncDiff(state, {'joins': joins, 'leaves': leaves}, onJoin, onLeave);
}

Map<String, Presence> _syncDiff(
  Map<String, Presence> currentState,
  Map<String, Map<String, Presence>> diff,
  JoinHandler onJoin,
  LeaveHandler onLeave,
) {
  final state = _clone(currentState);

  final joins = diff['joins'];
  final leaves = diff['leaves'];

  _map(joins, (key, newPresence) {
    final currentPresence = state[key];
    state[key] = newPresence;
    if (currentPresence != null) {
      final joinedRefs = (state[key].metas).map((m) => m.phxRef).toSet();
      final curMetas =
          (currentPresence.metas).where((m) => !joinedRefs.contains(m.phxRef));
      (state[key].metas).insertAll(0, curMetas);
    }
    onJoin(key, currentPresence, newPresence);
  });
  _map(leaves, (key, leftPresence) {
    final currentPresence = state[key];
    if (currentPresence == null) return;
    final refsToRemove = (leftPresence.metas).map((m) => m.phxRef).toSet();
    currentPresence.metas = (currentPresence.metas)
        .where((p) => !refsToRemove.contains(p.phxRef))
        .toList();
    onLeave(key, currentPresence, leftPresence);
    if ((currentPresence.metas).isEmpty) {
      state.remove(key);
    }
  });
  return state;
}

List<dynamic> _map(
  Map<String, dynamic> presences,
  dynamic Function(String, Presence) mapper,
) {
  if (presences?.isNotEmpty ?? false) {
    return presences.entries
        .map((entry) => mapper(entry.key, entry.value))
        .toList();
  } else {
    return [];
  }
}

Map<String, Presence> _clone(Map<String, Presence> presences) {
  return presences.map((key, value) => MapEntry(key, value.clone()));
}

class Presence {
  Presence.fromJson(this.key, Map<String, dynamic> events)
      : metas = List<Map<String, dynamic>>.from(events[key]['metas'])
            .map((meta) => PhoenixPresenceMeta.fromJson(meta))
            .toList();

  final String key;
  List<PhoenixPresenceMeta> metas;

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    json[key] = <String, dynamic>{};
    json[key]['metas'] = metas.map((meta) => meta.toJson()).toList();
    return json;
  }

  Presence clone() {
    final json = toJson();
    final key = json.keys.first;
    return Presence.fromJson(key, json);
  }
}

class PhoenixPresenceMeta {
  PhoenixPresenceMeta.fromJson(Map<String, dynamic> meta)
      : onlineAt =
            DateTime.fromMillisecondsSinceEpoch(int.parse(meta['online_at'])),
        phxRef = meta['phx_ref'];

  final DateTime onlineAt;
  final String phxRef;
  // TODO this is not limited to the two metadata, their could be custom ones...

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    json['online_at'] = onlineAt.millisecondsSinceEpoch.toString();
    json['phx_ref'] = phxRef;
    return json;
  }

  PhoenixPresenceMeta clone() {
    final json = toJson();
    return PhoenixPresenceMeta.fromJson(json);
  }
}
