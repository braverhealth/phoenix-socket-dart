import 'dart:convert';

import 'message.dart';

/// Default class to serialize [Message] instances to JSON.
class MessageSerializer {
  late Function decoder;
  late Function encoder;

  MessageSerializer._();

  /// Default constructor returning the singleton instance of this class.
  factory MessageSerializer({decoder, encoder}) {
    MessageSerializer instance = _instance ??= MessageSerializer._();
    instance.decoder = decoder ?? jsonDecode;
    instance.encoder = encoder ?? jsonEncode;

    return instance;
  }

  static MessageSerializer? _instance;

  /// Yield a [Message] from some raw string arriving from a websocket.
  Message decode(dynamic rawData) {
    if (rawData is String || rawData is List<int>) {
      return Message.fromJson(decoder(rawData));
    } else {
      throw ArgumentError('Received a non-string or a non-list of integers');
    }
  }

  /// Given a [Message], return the raw string that would be sent through
  /// a websocket.
  String encode(Message message) {
    return encoder(message.encode());
  }
}
