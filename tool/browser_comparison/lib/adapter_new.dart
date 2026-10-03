import 'dart:convert';
import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket_msgpack/phoenix_socket_msgpack.dart';

import 'adapter_contract.dart';
import 'adapter_json.dart';
import 'generated/content.pb.dart';
import 'workloads.dart';

CodecAdapter createAdapter(String mode, Workload data) =>
    mode == 'json' ? createJsonAdapter(data) : _New(mode, data);

class _New implements CodecAdapter {
  _New(String mode, Workload data) {
    _message = Message(
        joinRef: '1',
        ref: '2',
        topic: topic,
        event: PhoenixChannelEvent.custom(event),
        payload: sourceBody(mode, data));
    _codec = switch (mode) {
      'binary_json' => MessageSerializer(
          payloadCodec: CallbackPayloadCodec(
              encoder: (value, _) =>
                  Uint8List.fromList(utf8.encode(jsonEncode(value))),
              decoder: (value, _) =>
                  jsonDecode(utf8.decode(value as Uint8List)))),
      'binary_protobuf' => MessageSerializer(
          payloadCodec: CallbackPayloadCodec(
              encoder: (value, _) => (value as Content).writeToBuffer(),
              decoder: (value, _) => Content.fromBuffer(value as Uint8List))),
      'msgpack_binary' => createMessagePackSerializer(),
      'msgpack_base64' => createBase64MessagePackSerializer(),
      _ => const MessageSerializer(),
    };
  }
  late final Message _message;
  late final MessageCodec _codec;
  @override
  Object encode() => _codec.encode(_message);
  @override
  Object? decode(Object frame) => _codec.decode(frame).payload;
}
