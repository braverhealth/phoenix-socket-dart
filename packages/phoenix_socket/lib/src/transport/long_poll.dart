import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'transport.dart';

/// A failure reported by Phoenix's long-poll protocol.
class PhoenixLongPollException implements Exception {
  const PhoenixLongPollException(this.status);

  /// Phoenix's JSON-body status, or `timeout` for an expired HTTP request.
  final Object? status;

  @override
  String toString() => 'PhoenixLongPollException($status)';
}

/// Phoenix JavaScript v1.8.15-compatible HTTP long polling.
///
/// Text frames are posted unchanged and byte frames are base64 encoded.
/// Incoming poll messages remain text frames, as in the reference client.
/// The transport owns [client] and closes it when the session ends. Use a
/// dedicated client, without transparent POST retries.
class PhoenixLongPoll implements PhoenixTransport {
  PhoenixLongPoll(
    Uri endpoint, {
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
    this.authToken,
  })  : endpoint = normalizeEndpoint(endpoint),
        _client = client ?? http.Client() {
    // Match the reference's deferred initial GET and allow handlers to attach.
    _ready.future.ignore();
    _initialPoll = Timer(Duration.zero, _poll);
  }

  /// Convert the WebSocket endpoint into Phoenix's HTTP endpoint.
  static Uri normalizeEndpoint(Uri endpoint) => Uri.parse(endpoint
      .toString()
      .replaceFirst('ws://', 'http://')
      .replaceFirst('wss://', 'https://')
      .replaceFirstMapped(
          RegExp(r'(.*)/websocket'), (match) => '${match[1]}/longpoll'));

  final Uri endpoint;
  final Duration timeout;
  final String? authToken;
  final http.Client _client;
  final _ready = Completer<void>();
  final _incoming = StreamController<dynamic>();
  final Set<Completer<void>> _requests = {};
  final Set<Timer> _deliveryTimers = {};
  Timer? _initialPoll;
  Timer? _batchTimer;
  List<String>? _currentBatch;
  List<String> _batchBuffer = [];
  bool _awaitingBatchAck = false;
  bool _closed = false;
  String? _token;

  @override
  Future<void> get ready => _ready.future;
  @override
  Stream<dynamic> get stream => _incoming.stream;
  @override
  bool get skipHeartbeat => true;
  @override
  int? closeCode;
  @override
  String? closeReason;

  Uri get _requestUri {
    if (_token == null) return endpoint;
    return endpoint.replace(queryParameters: {'token': _token!});
  }

  Future<Map<String, dynamic>?> _request(
    String method,
    Map<String, String> headers, [
    String? body,
  ]) async {
    if (_closed) return null;
    final abort = Completer<void>();
    _requests.add(abort);
    final request =
        http.AbortableRequest(method, _requestUri, abortTrigger: abort.future)
          ..headers.addAll(headers);
    if (body != null) request.bodyBytes = utf8.encode(body);
    try {
      Future<Map<String, dynamic>?> read() async {
        final response = await _client.send(request);
        final bytes = await response.stream.toBytes();
        if (_closed) return null;
        // Phoenix statuses are in JSON, not the HTTP response status.
        final data = jsonDecode(utf8.decode(bytes));
        return data is Map<String, dynamic> ? data : null;
      }

      return await (timeout == Duration.zero
          ? read()
          : read().timeout(timeout));
    } on TimeoutException {
      if (!_closed) _fail('timeout', 1005, 'timeout');
      return null;
    } on Object {
      // Like Ajax.parseJSON / the reference network callback, invalid JSON
      // and failed requests are represented by a null response.
      return null;
    } finally {
      _requests.remove(abort);
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<void> _poll() async {
    _initialPoll = null;
    final response = await _request('GET', {
      'Accept': 'application/json',
      if (authToken != null && authToken!.isNotEmpty)
        'X-Phoenix-AuthToken': authToken!,
    });
    if (_closed) return;
    final status = response?['status'] ?? 0;
    if (status == 410 && _token != null) {
      _fail(410, 3410, 'session_gone');
      return;
    }
    if (response != null) {
      final token = response['token'];
      if (token is! String &&
          (token != null || status == 200 || status == 204 || status == 410)) {
        _fail(500, 1011, 'internal server error');
        return;
      }
      _token = token as String?;
    }
    switch (status) {
      case 200:
        final messages = response!['messages'];
        if (messages is! List || messages.any((frame) => frame is! String)) {
          _fail(500, 1011, 'internal server error');
          return;
        }
        for (final message in messages) {
          late Timer delivery;
          delivery = Timer(Duration.zero, () {
            _deliveryTimers.remove(delivery);
            if (!_closed) _incoming.add(message);
          });
          _deliveryTimers.add(delivery);
        }
        unawaited(_poll());
      case 204:
        unawaited(_poll());
      case 410:
        if (!_ready.isCompleted) _ready.complete();
        unawaited(_poll());
      case 403:
        _fail(403, 1008, 'forbidden');
      case 0:
      case 500:
        _fail(500, 1011, 'internal server error');
      default:
        _fail(status, 1011, 'unhandled poll status $status');
    }
  }

  @override
  void send(Object frame) {
    if (_closed) throw StateError('Long-poll session is closed');
    final body = switch (frame) {
      String text => text,
      Uint8List bytes => base64Encode(bytes),
      _ => throw ArgumentError.value(frame, 'frame', 'String or Uint8List'),
    };
    if (_currentBatch != null) {
      _currentBatch!.add(body);
    } else if (_awaitingBatchAck) {
      _batchBuffer.add(body);
    } else {
      _currentBatch = [body];
      _batchTimer = Timer(Duration.zero, () {
        final batch = _currentBatch!;
        _currentBatch = null;
        _batchTimer = null;
        unawaited(_batchSend(batch));
      });
    }
  }

  Future<void> _batchSend(List<String> messages, [int offset = 0]) async {
    _awaitingBatchAck = true;
    final next = offset + 100;
    final end = next < messages.length ? next : messages.length;
    final response = await _request(
        'POST',
        {'Content-Type': 'application/x-ndjson'},
        messages.sublist(offset, end).join('\n'));
    if (_closed) return;
    if (response?['status'] != 200) {
      _fail(response?['status'], 1011, 'internal server error');
    } else if (next < messages.length) {
      unawaited(_batchSend(messages, next));
    } else if (_batchBuffer.isNotEmpty) {
      final buffered = _batchBuffer;
      _batchBuffer = [];
      unawaited(_batchSend(buffered));
    } else {
      _awaitingBatchAck = false;
    }
  }

  void _fail(Object? status, int code, String reason) {
    if (_closed) return;
    closeCode = code;
    closeReason = reason;
    final error = PhoenixLongPollException(status);
    _incoming.addError(error, StackTrace.current);
    if (!_ready.isCompleted) _ready.completeError(error);
    unawaited(close(code, reason));
  }

  @override
  Future<void> close([int? code, String? reason]) {
    if (_closed) return Future.value();
    _closed = true;
    closeCode = code ?? 1000;
    closeReason = reason;
    _initialPoll?.cancel();
    _batchTimer?.cancel();
    for (final timer in _deliveryTimers) {
      timer.cancel();
    }
    _deliveryTimers.clear();
    for (final abort in _requests) {
      if (!abort.isCompleted) abort.complete();
    }
    _requests.clear();
    _currentBatch = null;
    _batchBuffer.clear();
    _awaitingBatchAck = false;
    _client.close();
    if (!_ready.isCompleted) {
      _ready
          .completeError(StateError('Long-poll session closed before opening'));
    }
    // A paused or unattached listener must not hold request cleanup hostage.
    unawaited(_incoming.close());
    return Future.value();
  }
}
