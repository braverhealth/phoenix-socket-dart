import 'dart:async';

import 'socket.dart';

/// Main class to use when wishing to establish a persistent connection
/// with a Phoenix backend using WebSockets.
class PhoenixRawSocket extends PhoenixSocket {
  final StreamController<List<int>> _receiveStreamController =
      StreamController.broadcast();

  /// Creates an instance of PhoenixRawSocket
  ///
  /// endpoint is the full url to which you wish to connect
  /// e.g. `ws://localhost:4000/websocket/socket`
  PhoenixRawSocket(super.endpoint, {super.socketOptions});

  @override
  void onSocketDataCallback(message) {
    if (message is List<int>) {
      if (!_receiveStreamController.isClosed) {
        _receiveStreamController.add(message);
      }
    } else {
      throw ArgumentError('Received a non-list of integers');
    }
  }
}
