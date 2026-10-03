import 'dart:convert';
import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket/src/msgpack_serializer.dart';

import 'adapter_contract.dart';
import 'adapter_json.dart';
import 'generated/content.pb.dart';
import 'workloads.dart';

CodecAdapter createAdapter(String mode, Workload data) =>
    mode == 'json' ? createJsonAdapter(data) : _Master(mode, data);

class _Master implements CodecAdapter {
  _Master(this.mode, Workload data) {
    _message = Message(
        joinRef: '1',
        ref: '2',
        topic: topic,
        event: PhoenixChannelEvent.custom(event),
        payload: sourceBody(mode, data));
    _codec = switch (mode) {
      'binary_json' => MessageSerializer(
          payloadDecoder: (bytes) => jsonDecode(utf8.decode(bytes))),
      'binary_protobuf' =>
        MessageSerializer(payloadDecoder: Content.fromBuffer),
      'msgpack_binary' => createMessagePackSerializer(),
      'msgpack_base64' => MessageSerializer(
          decoder: MessagePackCodec.decode, encoder: MessagePackCodec.encode),
      _ => const MessageSerializer(),
    };
  }
  final String mode;
  late final Message _message;
  late final MessageSerializer _codec;
  @override
  Object encode() {
    if (mode == 'binary_json' || mode == 'binary_protobuf') {
      final Uint8List bytes = mode == 'binary_json'
          ? Uint8List.fromList(utf8.encode(jsonEncode(_message.payload)))
          : (_message.payload as Content).writeToBuffer();
      return _codec.encode(Message(
          joinRef: '1',
          ref: '2',
          topic: topic,
          event: PhoenixChannelEvent.custom(event),
          payload: bytes));
    }
    return _codec.encode(_message);
  }

  @override
  Object? decode(Object frame) => _codec.decode(frame).payload;
}
