import 'dart:convert';

import 'message.dart';

typedef DecoderCallback = dynamic Function(String rawData);
typedef EncoderCallback = String Function(Object? data);

/// Default class to serialize [Message] instances to JSON.
class MessageSerializer {
  late DecoderCallback _decoder;
  late EncoderCallback _encoder;

  MessageSerializer._();

  /// Default constructor returning the singleton instance of this class.
  factory MessageSerializer({
    DecoderCallback? decoder,
    EncoderCallback? encoder,
  }) {
    MessageSerializer instance = _instance ??= MessageSerializer._();
    instance._decoder = decoder ?? jsonDecode;
    instance._encoder = encoder ?? jsonEncode;

    return instance;
  }

  static MessageSerializer? _instance;

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
