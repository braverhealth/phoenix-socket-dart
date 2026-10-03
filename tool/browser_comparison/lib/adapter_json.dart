import 'package:phoenix_socket/phoenix_socket.dart';

import 'adapter_contract.dart';
import 'workloads.dart';

/// Exactly the same fixed-codec adapter is compiled against every version.
CodecAdapter createJsonAdapter(Workload data) => _Json(data);

class _Json implements CodecAdapter {
  _Json(Workload data)
      : _message = Message(
            joinRef: '1',
            ref: '2',
            topic: topic,
            event: PhoenixChannelEvent.custom(event),
            payload: data.body);
  final Message _message;
  final _codec = const MessageSerializer();
  @override
  Object encode() => _codec.encode(_message);
  @override
  Object? decode(Object frame) => _codec.decode(frame).payload;
}
