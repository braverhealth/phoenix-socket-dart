import 'package:web_socket_channel/web_socket_channel.dart';

/// The underlying Phoenix connection protocol.
enum PhoenixSocketTransport { webSocket, longPolling }

/// Frame transport shared by Phoenix's WebSocket and HTTP connections.
abstract interface class PhoenixTransport {
  Future<void> get ready;
  Stream<dynamic> get stream;
  bool get skipHeartbeat;
  int? get closeCode;
  String? get closeReason;
  void send(Object frame);
  Future<void> close([int? code, String? reason]);
}

/// Adapts web_socket_channel without changing its frame representation.
class WebSocketTransport implements PhoenixTransport {
  WebSocketTransport(this.channel);

  final WebSocketChannel channel;

  @override
  Future<void> get ready => channel.ready;
  @override
  Stream<dynamic> get stream => channel.stream;
  @override
  bool get skipHeartbeat => false;
  @override
  int? get closeCode => channel.closeCode;
  @override
  String? get closeReason => channel.closeReason;
  @override
  void send(Object frame) => channel.sink.add(frame);
  @override
  Future<void> close([int? code, String? reason]) async {
    await channel.sink.close(code, reason);
  }
}
