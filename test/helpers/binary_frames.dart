import 'dart:convert';
import 'dart:typed_data';

/// Independent server fixtures; client pushes use a different header.
Uint8List serverPush(
        String? joinRef, String topic, String event, List<int> body) =>
    _serverFrame(0, [joinRef ?? '', topic, event], body);

Uint8List serverReply(String? joinRef, String? ref, String topic, String status,
        List<int> body) =>
    _serverFrame(1, [joinRef ?? '', ref ?? '', topic, status], body);

Uint8List serverBroadcast(String topic, String event, List<int> body) =>
    _serverFrame(2, [topic, event], body);

Uint8List _serverFrame(int kind, List<String> fields, List<int> body) {
  final metadata = fields.map(utf8.encode).toList();
  final headerLength = 1 + metadata.length;
  final bodyOffset =
      headerLength + metadata.fold<int>(0, (sum, field) => sum + field.length);
  final frame = Uint8List(bodyOffset + body.length);
  frame[0] = kind;
  var offset = headerLength;
  for (var i = 0; i < metadata.length; i++) {
    frame[1 + i] = metadata[i].length;
    frame.setAll(offset, metadata[i]);
    offset += metadata[i].length;
  }
  frame.setAll(bodyOffset, body);
  return frame;
}

/// Read client framing independently of the production server decoder.
List<dynamic> clientFrameParts(Object frame) {
  if (frame is String) return jsonDecode(frame) as List<dynamic>;
  final bytes = frame as Uint8List;
  var offset = 5;
  final fields = <String>[];
  for (var index = 1; index <= 4; index++) {
    fields.add(utf8
        .decode(Uint8List.sublistView(bytes, offset, offset + bytes[index])));
    offset += bytes[index];
  }
  return [
    fields[0].isEmpty ? null : fields[0],
    fields[1].isEmpty ? null : fields[1],
    fields[2],
    fields[3],
    Uint8List.sublistView(bytes, offset),
  ];
}
