import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// An in-memory Phoenix JSON session server for lifecycle tests on VM and web.
class LongPollServer {
  final clients = <LongPollServerClient>[];
  final requests = <http.Request>[];
  int joins = 0;
  int sessions = 0;
  int posts = 0;
  bool forbidden = false;

  LongPollServerClient createClient() {
    final client = LongPollServerClient(this);
    clients.add(client);
    return client;
  }
}

class LongPollServerClient extends http.BaseClient {
  LongPollServerClient(this.server);

  final LongPollServer server;
  bool closed = false;
  bool expired = false;
  String? token;
  Completer<http.StreamedResponse>? _poll;
  final _messages = <String>[];

  void expire() {
    expired = true;
    _flush();
  }

  http.StreamedResponse _response(Map<String, dynamic> body) =>
      http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), 200);

  void _flush() {
    final pending = _poll;
    if (pending == null || pending.isCompleted) return;
    if (expired) {
      pending.complete(
          _response({'status': 410, 'token': 'replacement', 'messages': []}));
    } else if (_messages.isNotEmpty) {
      pending.complete(_response(
          {'status': 200, 'token': token, 'messages': List.of(_messages)}));
      _messages.clear();
    } else {
      return;
    }
    _poll = null;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest base) async {
    final request = base as http.Request;
    server.requests.add(request);
    if (closed) throw StateError('HTTP client closed');
    if (request.method == 'GET') {
      if (server.forbidden) return _response({'status': 403});
      if (request.url.queryParameters['token'] == null) {
        token = 'session-${server.sessions++}';
        return _response({'status': 410, 'token': token, 'messages': []});
      }
      final response = Completer<http.StreamedResponse>();
      _poll = response;
      _flush();
      final abort = (base as http.Abortable).abortTrigger;
      return Future.any([
        response.future,
        if (abort != null)
          abort.then<http.StreamedResponse>((_) {
            throw http.RequestAbortedException(request.url);
          }),
      ]);
    }
    server.posts++;
    for (final text in request.body.split('\n')) {
      final frame = jsonDecode(text) as List;
      final event = frame[3];
      if (event == 'phx_join') server.joins++;
      if (event == 'disconnect') {
        expire();
        continue;
      }
      if (event == 'no_reply') {
        _messages
            .add(jsonEncode([frame[0], null, frame[2], 'observed', frame[4]]));
        continue;
      }
      _messages.add(jsonEncode([
        frame[0],
        frame[1],
        frame[2],
        'phx_reply',
        {
          'status': 'ok',
          'response': event == 'echo' ? frame[4] : <String, dynamic>{}
        },
      ]));
    }
    _flush();
    return _response({'status': 200});
  }

  @override
  void close() {
    closed = true;
    _messages.clear();
    _poll = null;
  }
}
