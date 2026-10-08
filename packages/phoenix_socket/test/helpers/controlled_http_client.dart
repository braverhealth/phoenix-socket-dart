import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class ControlledHttpClient extends http.BaseClient {
  final requests = <PendingHttpRequest>[];
  final _changed = StreamController<void>.broadcast();
  bool closed = false;
  int aborts = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (closed) throw StateError('HTTP client is closed');
    final pending = PendingHttpRequest(request as http.Request);
    requests.add(pending);
    _changed.add(null);
    final abort = request is http.Abortable
        ? (request as http.Abortable).abortTrigger
        : null;
    return Future.any([
      pending.response.future,
      if (abort != null)
        abort.then<http.StreamedResponse>((_) {
          if (!pending.response.isCompleted) aborts++;
          throw http.RequestAbortedException(request.url);
        }),
    ]);
  }

  Future<PendingHttpRequest> take(String method) async {
    while (true) {
      for (final request in requests) {
        if (!request.taken && request.request.method == method) {
          request.taken = true;
          return request;
        }
      }
      await _changed.stream.first.timeout(const Duration(seconds: 3));
    }
  }

  @override
  void close() {
    closed = true;
  }
}

class PendingHttpRequest {
  PendingHttpRequest(this.request);

  final http.Request request;
  final response = Completer<http.StreamedResponse>();
  bool taken = false;

  void reply(Object? data, {int httpStatus = 200}) =>
      replyRaw(jsonEncode(data), httpStatus: httpStatus);

  void replyRaw(String body, {int httpStatus = 200}) {
    response.complete(http.StreamedResponse(
        Stream.value(utf8.encode(body)), httpStatus,
        headers: {'content-type': 'application/json; charset=utf-8'}));
  }

  void fail(Object error) => response.completeError(error);
}
