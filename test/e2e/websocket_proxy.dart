import 'dart:async';
import 'dart:io';

/// A test-owned loopback proxy that can blackhole the first connection's replies.
class WebSocketProxy {
  WebSocketProxy._(this._server, this._upstream) {
    _requests = _server.listen(_accept);
  }

  static Future<WebSocketProxy> start(Uri upstream) async => WebSocketProxy._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0), upstream);

  final HttpServer _server;
  final Uri _upstream;
  late final StreamSubscription<HttpRequest> _requests;
  final _sockets = <WebSocket>[];
  final _subscriptions = <StreamSubscription<dynamic>>[];
  bool dropFirstConnectionReplies = false;
  bool _closed = false;
  int connections = 0;

  String get endpoint => 'ws://127.0.0.1:${_server.port}/socket/websocket';

  Future<void> _accept(HttpRequest request) async {
    WebSocket? upstream;
    try {
      upstream = await WebSocket.connect(
          _upstream.replace(query: request.uri.query).toString());
      if (_closed) {
        await upstream.close();
        return;
      }
      final client = await WebSocketTransformer.upgrade(request);
      if (_closed) {
        await Future.wait([client.close(), upstream.close()]);
        return;
      }
      final connection = connections++;
      _sockets.addAll([client, upstream]);
      _forward(client, upstream);
      _forward(upstream, client,
          drop: () => connection == 0 && dropFirstConnectionReplies);
    } on Object {
      await upstream?.close();
      if (!_closed) {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      }
    }
  }

  void _forward(WebSocket from, WebSocket to, {bool Function()? drop}) {
    _subscriptions.add(from.listen(
        (frame) {
          if (to.readyState == WebSocket.open && !(drop?.call() ?? false)) {
            to.add(frame);
          }
        },
        onDone: () => to.close().ignore(),
        onError: (Object _) {
          to.close().ignore();
        }));
  }

  Future<void> close() async {
    _closed = true;
    await _requests.cancel();
    await _server.close(force: true);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await Future.wait(_sockets.map((socket) => socket.close()));
  }
}
