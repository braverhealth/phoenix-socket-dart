import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'adapter_contract.dart';
import 'active_adapter.dart';
import 'workloads.dart';

@JS('performance.now')
external double _now();
@JS('prepareCase')
external set _prepare(JSFunction value);
@JS('measureCase')
external set _measure(JSFunction value);
@JS('verifyCase')
external set _verify(JSFunction value);

Workload? _data;
CodecAdapter? _adapter;
Object? _inbound;
Object? _last;
String? _key;
String? _mode;

void main() {
  _prepare = ((JSString request) => _prepareCase(request.toDart).toJS).toJS;
  _measure = ((JSNumber iterations) =>
      jsonEncode(_measureBatch(iterations.toDartInt)).toJS).toJS;
  _verify = (() =>
          digest(canonicalDecoded(_last, _mode!, _data!)) == _data!.fingerprint)
      .toJS;
}

String _prepareCase(String request) {
  final config = jsonDecode(request) as Map;
  final family = config['family'] as String;
  final size = config['size'] as int;
  final mode = config['mode'] as String;
  final key = '$family:$size';
  if (_key != key) {
    _data = Workload(family, size);
    _key = key;
  }
  _mode = mode;
  _adapter = createAdapter(mode, _data!);
  _inbound = inboundFrame(mode, _data!, _adapter!);
  final encoded = _adapter!.encode();
  _last = _adapter!.decode(_inbound!);
  final decodedHash = digest(canonicalDecoded(_last, mode, _data!));
  if (decodedHash != _data!.fingerprint) {
    throw StateError('Decoded content differs');
  }
  return jsonEncode({
    'family': family,
    'target_bytes': size,
    'json_payload_bytes': _data!.jsonBytes.length,
    'frame_bytes': encoded is String
        ? utf8.encode(encoded).length
        : (encoded as Uint8List).length,
    'fingerprint': decodedHash,
  });
}

Map<String, Object?> _measureBatch(int iterations) {
  if (iterations < 1 || iterations > 8192) {
    throw ArgumentError('Invalid iteration count');
  }
  final adapter = _adapter!;
  final inbound = _inbound!;
  var checksum = 0;
  var maxOperation = 0.0;
  var encodeTime = 0.0;
  var decodeTime = 0.0;
  var over16 = 0;
  var over50 = 0;
  final start = _now();
  for (var i = 0; i < iterations; i++) {
    final begin = _now();
    final encoded = adapter.encode();
    final split = _now();
    _last = adapter.decode(inbound);
    final end = _now();
    encodeTime += split - begin;
    decodeTime += end - split;
    final elapsed = end - begin;
    if (elapsed > maxOperation) maxOperation = elapsed;
    if (elapsed > 16.67) over16++;
    if (elapsed > 50) over50++;
    checksum +=
        (encoded is String ? encoded.length : (encoded as Uint8List).length) +
            consume(_last);
  }
  final elapsed = _now() - start;
  return {
    'iterations': iterations,
    'elapsed_ms': elapsed,
    'encode_us': encodeTime * 1000 / iterations,
    'decode_us': decodeTime * 1000 / iterations,
    'mean_us': elapsed * 1000 / iterations,
    'max_operation_ms': maxOperation,
    'operations_over_16ms': over16,
    'operations_over_50ms': over50,
    'checksum': checksum,
    'verified': true
  };
}
