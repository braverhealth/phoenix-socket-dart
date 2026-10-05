import 'dart:convert';
import 'dart:typed_data';

import 'generated/content.pb.dart';

const families = [
  'ascii',
  'unicode',
  'escaped',
  'flat_records',
  'nested_records',
  'numbers',
  'bytes'
];
const sizes = [256, 4096, 65536, 1048576, 4194304];

class Workload {
  Workload(this.family, this.targetBytes) {
    if (!families.contains(family) || targetBytes < 128) {
      throw ArgumentError('Invalid workload');
    }
    var low = 0;
    final baseBytes = utf8.encode(jsonEncode(_body(family, 0))).length;
    final average =
        (utf8.encode(jsonEncode(_body(family, 128))).length - baseBytes) / 128;
    var high = ((targetBytes - baseBytes) / average).ceil() + 128;
    if (family == 'bytes') {
      low = targetBytes;
      high = targetBytes;
    }
    while (low < high) {
      final count = (low + high + 1) ~/ 2;
      final candidate = _body(family, count);
      if (utf8.encode(jsonEncode(candidate)).length <= targetBytes) {
        low = count;
      } else {
        high = count - 1;
      }
    }
    body = _body(family, low);
    jsonBytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
    proto = _toProto(body);
    fingerprint = digest(body);
  }

  final String family;
  final int targetBytes;
  late final Map<String, dynamic> body;
  late final Uint8List jsonBytes;
  late final Content proto;
  late final int fingerprint;

  Uint8List get rawBytes => body['bytes'] as Uint8List;
}

Map<String, dynamic> _body(String family, int count) {
  switch (family) {
    case 'ascii':
      return {'text': List.filled(count, 'Healthcare status update. ').join()};
    case 'unicode':
      return {
        'text': List.filled(count, 'Équipe — Québec 👩🏽‍⚕️ 日本語\n').join()
      };
    case 'escaped':
      return {
        'text': List.filled(count, 'line\n"quoted"\\path\t\u0000').join()
      };
    case 'numbers':
      return {
        'numbers':
            List.generate(count, (i) => (i % 10000) * (i.isEven ? 1 : -1))
      };
    case 'bytes':
      return {
        'bytes':
            Uint8List.fromList(List.generate(count, (i) => (i * 31 + 17) & 255))
      };
    default:
      return {
        'records': List.generate(
            count,
            (i) => <String, dynamic>{
                  'id': i,
                  'name': 'record-$i',
                  'active': i.isEven,
                  'score': (i % 100) / 4,
                  'tags': ['team-${i % 7}', 'status-${i % 3}'],
                  if (family == 'nested_records')
                    'detail': {
                      'note': 'nested record-$i',
                      'values': [i % 11, i % 13, i % 17],
                      'attributes': [
                        {'key': 'owner', 'value': 'team-${i % 7}'},
                        {'key': 'locale', 'value': 'fr-CA'},
                      ],
                    },
                })
      };
  }
}

Content _toProto(Map<String, dynamic> body) {
  final content = Content();
  if (body.containsKey('text')) content.text = body['text'] as String;
  if (body.containsKey('numbers')) {
    content.numbers.addAll(body['numbers'] as List<int>);
  }
  if (body.containsKey('bytes')) content.bytes = body['bytes'] as Uint8List;
  if (body.containsKey('records')) {
    for (final row in body['records'] as List) {
      final record = Record(
          id: row['id'],
          name: row['name'],
          active: row['active'],
          score: row['score'],
          tags: (row['tags'] as List).cast<String>());
      if (row.containsKey('detail')) {
        final detail = row['detail'] as Map;
        record.detail = Detail(
            note: detail['note'],
            values: (detail['values'] as List).cast<int>(),
            attributes: (detail['attributes'] as List)
                .map((v) => Attribute(key: v['key'], value: v['value'])));
      }
      content.records.add(record);
    }
  }
  return content;
}

Object canonicalProto(Content content, String family) {
  if (['ascii', 'unicode', 'escaped'].contains(family)) {
    return {'text': content.text};
  }
  if (family == 'numbers') return {'numbers': content.numbers};
  if (family == 'bytes') return {'bytes': content.bytes};
  return {
    'records': content.records
        .map((r) => <String, dynamic>{
              'id': r.id,
              'name': r.name,
              'active': r.active,
              'score': r.score,
              'tags': r.tags,
              if (family == 'nested_records')
                'detail': {
                  'note': r.detail.note,
                  'values': r.detail.values,
                  'attributes': r.detail.attributes
                      .map((v) => {'key': v.key, 'value': v.value})
                      .toList(),
                },
            })
        .toList()
  };
}

/// Hash all decoded content outside the timed section, including byte values.
int digest(Object? value) {
  Object? canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: canonical(value[key])};
    }
    if (value is List) return value.map(canonical).toList();
    return value;
  }

  var hash = 2166136261;
  for (final byte in utf8.encode(jsonEncode(canonical(value)))) {
    hash = ((hash ^ byte) * 16777619) & 0xffffffff;
  }
  return hash;
}
