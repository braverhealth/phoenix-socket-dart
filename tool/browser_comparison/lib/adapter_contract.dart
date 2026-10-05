import 'dart:convert';
import 'dart:typed_data';

import 'generated/content.pb.dart';
import 'workloads.dart';

const modes = [
  'json',
  'binary_raw',
  'binary_json',
  'binary_protobuf',
  'msgpack_binary',
  'msgpack_base64'
];
const topic = 'benchmark:room';
const event = 'update';

abstract interface class CodecAdapter {
  Object encode();
  Object? decode(Object frame);
}

Object sourceBody(String mode, Workload data) => switch (mode) {
      'binary_raw' => data.rawBytes,
      'binary_protobuf' => data.proto,
      _ => data.body,
    };

Object canonicalDecoded(Object? value, String mode, Workload data) {
  if (mode == 'binary_raw') return {'bytes': value};
  if (mode == 'binary_protobuf') {
    if (value is Map) value = value['data']; // master's legacy protobuf wrapper
    return canonicalProto(value as Content, data.family);
  }
  return value!;
}

int consume(Object? value) {
  if (value is Content) {
    return value.text.length +
        value.records.length +
        value.numbers.length +
        value.bytes.length;
  }
  if (value is List) return value.length;
  if (value is Map) {
    if (value['data'] is Content) return consume(value['data']);
    final element = value.values.first;
    if (element is String) return element.length;
    if (element is List) return element.length;
  }
  throw StateError('Unexpected decoded content');
}

/// Independent server broadcast fixture; client and server push headers differ.
Uint8List broadcast(Uint8List body) {
  final t = utf8.encode(topic), e = utf8.encode(event);
  final offset = 3 + t.length + e.length;
  final frame = Uint8List(offset + body.length);
  frame[0] = 2;
  frame[1] = t.length;
  frame[2] = e.length;
  frame.setAll(3, t);
  frame.setAll(3 + t.length, e);
  frame.setAll(offset, body);
  return frame;
}

Object inboundFrame(String mode, Workload data, CodecAdapter adapter) =>
    mode.startsWith('binary_')
        ? broadcast(switch (mode) {
            'binary_raw' => data.rawBytes,
            'binary_json' => data.jsonBytes,
            _ => data.proto.writeToBuffer(),
          })
        : adapter.encode();
