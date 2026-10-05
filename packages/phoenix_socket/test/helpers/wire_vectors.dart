import 'dart:convert';
import 'dart:typed_data';

import 'independent_wire_vectors.dart';

Map<String, dynamic> independentVectors() =>
    jsonDecode(independentWireVectorsJson) as Map<String, dynamic>;

Uint8List hexBytes(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

Object? wireValue(Object? value) {
  if (value is Map<String, dynamic>) {
    if (value.length == 1 && value['\$bytes'] is String) {
      return hexBytes(value['\$bytes'] as String);
    }
    return value.map((key, entry) => MapEntry(key, wireValue(entry)));
  }
  if (value is List) return value.map(wireValue).toList();
  return value;
}
