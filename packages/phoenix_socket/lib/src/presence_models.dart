import 'package:meta/meta.dart';

/// Whether a presence snapshot is authoritative for the current channel join.
enum PresenceSyncStatus {
  /// No full state has been received yet.
  awaitingState,

  /// A full state and all subsequent received diffs have been applied.
  synchronized,

  /// Connection loss, rejoining, or invalid input requires a new full state.
  stale,

  /// The presence client has stopped observing.
  closed,
}

/// Immutable presence state. Custom decoded metadata must also be immutable.
@immutable
class PresenceSnapshot<T> {
  /// Copies [presences] into an unmodifiable map.
  PresenceSnapshot({
    required Map<String, Presence<T>> presences,
    required this.status,
  }) : presences = Map.unmodifiable(presences);

  /// Presences indexed by the server's resource key.
  final Map<String, Presence<T>> presences;

  /// The synchronization status of this data.
  final PresenceSyncStatus status;

  /// Whether this snapshot is synchronized with the current channel join.
  bool get isSynchronized => status == PresenceSyncStatus.synchronized;
}

/// A single key's change between two fully reconciled snapshots.
@immutable
class PresenceChange<T> {
  /// Computes metadata additions/removals by protocol reference.
  PresenceChange({
    required this.key,
    required this.before,
    required this.after,
    required this.snapshot,
  })  : joined = List.unmodifiable((after?.metas ?? <PhoenixPresenceMeta<T>>[])
            .where((meta) => !(before?.metas
                    .any((previous) => previous.phxRef == meta.phxRef) ??
                false))),
        left = List.unmodifiable((before?.metas ?? <PhoenixPresenceMeta<T>>[])
            .where((meta) => !(after?.metas
                    .any((current) => current.phxRef == meta.phxRef) ??
                false)));

  /// The affected resource key.
  final String key;

  /// Previous presence, or null when the key was absent.
  final Presence<T>? before;

  /// Resulting presence, or null when the last metadata entry left.
  final Presence<T>? after;

  /// Metadata references added by this completed update.
  final List<PhoenixPresenceMeta<T>> joined;

  /// Metadata references removed by this completed update.
  final List<PhoenixPresenceMeta<T>> left;

  /// The complete resulting snapshot, even if newer updates arrive later.
  final PresenceSnapshot<T> snapshot;

  /// Whether the key became present, rather than adding another device.
  bool get becamePresent => before == null && after != null;

  /// Whether the key became absent, rather than losing one device.
  bool get becameAbsent => before != null && after == null;
}

/// A failure observed by a presence client, delivered as a stream value.
@immutable
class PresenceError {
  /// Wraps the original failure without losing its stack trace.
  const PresenceError(this.error, this.stackTrace, {this.event});

  /// Decode, input-stream, or legacy-observer failure.
  final Object error;

  /// The original failure location.
  final StackTrace stackTrace;

  /// The wire event being processed, when applicable.
  final String? event;

  @override
  String toString() =>
      'PresenceError${event == null ? '' : ' ($event)'}: $error';
}

/// One resource key and its currently tracked processes/devices.
@immutable
class Presence<T> {
  Presence._(this.key, Iterable<PhoenixPresenceMeta<T>> metas, this.data)
      : metas = List.unmodifiable(metas);

  /// Decodes one presence payload containing metas and any enriched fields.
  factory Presence.fromPayload(
    String key,
    Map<String, Object?> payload, {
    T Function(Map<String, Object?> json)? decodeMeta,
  }) {
    final json = presenceJsonObject(payload, 'presence.$key');
    final rawMetas = json['metas'];
    if (rawMetas is! List) {
      throw FormatException('presence.$key.metas must be a list.');
    }
    final metas = <PhoenixPresenceMeta<T>>[];
    final refs = <String>{};
    for (final raw in rawMetas) {
      final meta = PhoenixPresenceMeta<T>.fromJson(
        presenceJsonObject(raw, 'presence.$key.metas[]'),
        decodeMeta: decodeMeta,
      );
      if (!refs.add(meta.phxRef)) {
        throw FormatException(
            'Duplicate phx_ref in presence.$key: ${meta.phxRef}');
      }
      metas.add(meta);
    }
    return Presence._(key, metas,
        presenceJsonObject({...json}..remove('metas'), 'presence.$key'));
  }

  /// Legacy decoder accepting a map indexed by [key].
  @Deprecated('Use Presence.fromPayload(key, payload) instead.')
  factory Presence.fromJson(String key, Map<String, dynamic> events) =>
      Presence<T>.fromPayload(
          key, presenceJsonObject(events[key], 'presence.$key'));

  /// The presence key, typically a user ID.
  final String key;

  /// Immutable metadata for each currently tracked process/device.
  final List<PhoenixPresenceMeta<T>> metas;

  /// Deeply immutable enriched presence fields, excluding metas.
  final Map<String, Object?> data;

  /// Returns this immutable presence.
  Presence<T> clone() => this;

  /// Copies this presence with different metadata, retaining enriched fields.
  Presence<T> withMetas(Iterable<PhoenixPresenceMeta<T>> metas) =>
      Presence._(key, metas, data);

  /// The wire payload for this key, without the outer key wrapper.
  Map<String, Object?> toJson() => Map.unmodifiable({
        ...data,
        'metas': List.unmodifiable(metas.map((meta) => meta.toJson())),
      });
}

/// Protocol metadata plus a decoded application value.
///
/// Raw JSON is deeply immutable. A custom decoder must return an immutable [T].
@immutable
class PhoenixPresenceMeta<T> {
  /// Decodes protocol fields before invoking the application decoder.
  factory PhoenixPresenceMeta.fromJson(
    Map<String, Object?> meta, {
    T Function(Map<String, Object?> json)? decodeMeta,
  }) {
    final data = presenceJsonObject(meta, 'meta');
    final ref = data['phx_ref'];
    final previousRef = data['phx_ref_prev'];
    if (ref is! String || ref.isEmpty) {
      throw const FormatException('meta.phx_ref must be a non-empty string.');
    }
    if (previousRef != null && previousRef is! String) {
      throw const FormatException(
          'meta.phx_ref_prev must be a string or null.');
    }
    if (decodeMeta == null && data is! T) {
      throw ArgumentError('A decodeMeta function is required for $T.');
    }
    return PhoenixPresenceMeta._(data, ref, previousRef as String?,
        decodeMeta == null ? data as T : decodeMeta(data));
  }

  PhoenixPresenceMeta._(this.data, this.phxRef, this.phxRefPrev, this.value);

  /// Deeply immutable raw JSON, including protocol reference fields.
  final Map<String, Object?> data;

  /// The reference used to reconcile this tracked process.
  final String phxRef;

  /// The previous reference when server metadata was updated.
  final String? phxRefPrev;

  /// Decoded application metadata (the raw map when no decoder was supplied).
  final T value;

  /// Returns this immutable metadata.
  PhoenixPresenceMeta<T> clone() => this;

  /// The immutable wire representation.
  Map<String, Object?> toJson() => data;
}

/// Internal JSON validation shared by the presence decoder and value models.
@internal
Map<String, Object?> presenceJsonObject(Object? value, String path) {
  if (value is! Map) throw FormatException('$path must be an object.');
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$path must have string keys.');
    }
    result[entry.key as String] =
        _freezeJson(entry.value, '$path.${entry.key}');
  }
  return Map.unmodifiable(result);
}

Object? _freezeJson(Object? value, String path) {
  if (value == null || value is String || value is bool || value is num) {
    return value;
  }
  if (value is Map) return presenceJsonObject(value, path);
  if (value is List) {
    return List<Object?>.unmodifiable(
        value.map((item) => _freezeJson(item, '$path[]')));
  }
  throw FormatException('$path must contain JSON values.');
}

/// Internal structural comparison independent of custom decoded value equality.
@internal
bool presenceJsonEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every(
            (key) => b.containsKey(key) && presenceJsonEquals(a[key], b[key]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!presenceJsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
