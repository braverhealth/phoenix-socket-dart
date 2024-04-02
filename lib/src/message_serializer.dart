import 'dart:convert';

import 'message.dart';

typedef DecoderCallback = dynamic Function(String rawData);
typedef EncoderCallback = String Function(Object? data);

/// Default class to serialize [Message] instances to JSON.
class MessageSerializer {
  final DecoderCallback _decoder;
  final EncoderCallback _encoder;

  /// Default constructor returning the singleton instance of this class.
  const MessageSerializer({
    DecoderCallback decoder = jsonDecode,
    EncoderCallback encoder = jsonEncode,
  })  : _decoder = decoder,
        _encoder = encoder;

  /// Yield a [Message] from some raw string arriving from a websocket.
  Message decode(dynamic rawData) {
    if (rawData is String || rawData is List<int>) {
      return Message.fromJson(_decoder(rawData));
    } else {
      throw ArgumentError('Received a non-string or a non-list of integers');
    }
  }

  /// Given a [Message], return the raw string that would be sent through
  /// a websocket.
  String encode(Message message) => _encoder(message.encode());
}
