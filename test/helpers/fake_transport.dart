import 'dart:async';
import 'dart:convert';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// An in-memory transport with independently controlled handshake and frames.
class FakeTransport extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  FakeTransport({bool readyImmediately = false}) {
    sink = FakeTransportSink(this);
    if (readyImmediately) readyCompleter.complete();
  }

  final incoming = StreamController<dynamic>();
  final sent = <List<dynamic>>[];
  final readyCompleter = Completer<void>();
  void Function(List<dynamic>)? onSend;

  void replyTo(List<dynamic> message) {
    incoming.add(jsonEncode([
      message[0],
      message[1],
      message[2],
      'phx_reply',
      {'status': 'ok', 'response': <String, dynamic>{}},
    ]));
  }

  @override
  late final FakeTransportSink sink;
  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  Future<void> get ready => readyCompleter.future;
  @override
  int? closeCode;
  @override
  String? closeReason;
  @override
  String? get protocol => null;
}

class FakeTransportSink implements WebSocketSink {
  FakeTransportSink(this.transport);

  final FakeTransport transport;
  final _done = Completer<void>();
  int closeCalls = 0;

  @override
  void add(dynamic data) {
    if (_done.isCompleted) throw StateError('Transport is closed');
    final message = jsonDecode(data as String) as List<dynamic>;
    transport.sent.add(message);
    if (message[3] == 'heartbeat') {
      transport.replyTo(message);
    } else {
      transport.onSend?.call(message);
    }
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    closeCalls++;
    transport.closeCode = code;
    transport.closeReason = reason;
    if (!_done.isCompleted) _done.complete();
    await transport.incoming.close();
  }

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> addStream(Stream<dynamic> stream) => stream.forEach(add);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      throw UnsupportedError('Use the incoming controller for server errors');
}
