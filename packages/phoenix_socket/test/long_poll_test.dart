import 'dart:async';
import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

import 'helpers/controlled_http_client.dart';

Future<void> flushLongPoll() => Future<void>.delayed(Duration.zero);

void main() {
  late ControlledHttpClient client;
  late PhoenixLongPoll transport;
  late List<Object> errors;
  late List<String> messages;

  void create(
      {Duration timeout = const Duration(seconds: 3), String? authToken}) {
    client = ControlledHttpClient();
    errors = [];
    messages = [];
    transport = PhoenixLongPoll(
        Uri.parse('wss://example.invalid/socket/websocket?vsn=2.0.0'),
        client: client,
        timeout: timeout,
        authToken: authToken);
    transport.stream
        .listen((frame) => messages.add(frame as String), onError: errors.add);
    addTearDown(transport.close);
  }

  Future<void> open() async {
    (await client.take('GET'))
        .reply({'status': 410, 'token': 'session +/=&', 'messages': []});
    await transport.ready;
  }

  test('defaults, endpoint conversion and deferred initial GET', () async {
    create();
    expect(client.requests, isEmpty);
    expect(transport.timeout, const Duration(seconds: 3));
    expect(transport.skipHeartbeat, isTrue);
    final request = (await client.take('GET')).request;
    expect(request.url.scheme, 'https');
    expect(request.url.path, '/socket/longpoll');
    expect(request.url.queryParameters, {'vsn': '2.0.0'});
    expect(request.headers, {'Accept': 'application/json'});
    expect(request.body, isEmpty);
  });

  test('auth header is present only on GET and tokens round trip', () async {
    create(authToken: 'my-auth-token');
    final first = await client.take('GET');
    expect(first.request.headers['X-Phoenix-AuthToken'], 'my-auth-token');
    first.reply({'status': 410, 'token': 'session +/=&', 'messages': []});
    await transport.ready;
    final poll = await client.take('GET');
    expect(poll.request.url.queryParameters['token'], 'session +/=&');
    transport.send('[null,"0","audit","echo",{}]');
    final post = await client.take('POST');
    expect(post.request.headers, {'Content-Type': 'application/x-ndjson'});
    expect(post.request.url, poll.request.url);
  });

  test('410 opens, 204 repolls, 200 delivers ordered text frames', () async {
    create();
    await open();
    (await client.take('GET'))
        .reply({'status': 204, 'token': 'next-token', 'messages': []});
    final poll = await client.take('GET');
    expect(poll.request.url.queryParameters['token'], 'next-token');
    poll.reply({
      'status': 200,
      'token': 'next-token',
      'messages': ['a', 'b', 'c']
    });
    await client.take('GET');
    while (messages.length < 3) {
      await flushLongPoll();
    }
    expect(messages, ['a', 'b', 'c']);
    expect(errors, isEmpty);
  });

  test('each received frame permits microtasks before the next frame',
      () async {
    create();
    final order = <String>[];
    // Use a separate transport because its input stream has one listener.
    await transport.close();
    client = ControlledHttpClient();
    transport = PhoenixLongPoll(
        Uri.parse('http://example.invalid/socket/longpoll'),
        client: client);
    addTearDown(transport.close);
    transport.stream.listen((frame) {
      order.add(frame as String);
      scheduleMicrotask(() => order.add('microtask:$frame'));
    });
    await open();
    (await client.take('GET')).reply({
      'status': 200,
      'token': 't',
      'messages': ['a', 'b']
    });
    await client.take('GET');
    while (order.length < 4) {
      await flushLongPoll();
    }
    expect(order, ['a', 'microtask:a', 'b', 'microtask:b']);
  });

  test('a later 410 closes the old session instead of accepting its new token',
      () async {
    create();
    await open();
    (await client.take('GET'))
        .reply({'status': 410, 'token': 'replacement', 'messages': []});
    await flushLongPoll();
    expect(transport.closeCode, 3410);
    expect(transport.closeReason, 'session_gone');
    expect((errors.single as PhoenixLongPollException).status, 410);
    expect(client.requests, hasLength(2));
    expect(client.closed, isTrue);
  });

  for (final status in [403, 500, 0]) {
    test('GET body status $status reports the reference close code', () async {
      create();
      final failed = expectLater(
          transport.ready, throwsA(isA<PhoenixLongPollException>()));
      (await client.take('GET')).reply({'status': status});
      await failed;
      await flushLongPoll();
      expect(transport.closeCode, status == 403 ? 1008 : 1011);
      expect(transport.closeReason,
          status == 403 ? 'forbidden' : 'internal server error');
      expect((errors.single as PhoenixLongPollException).status,
          status == 403 ? 403 : 500);
    });
  }

  for (final response in ['', 'invalid', 'null', '[]', '"text"']) {
    test('invalid GET response $response is a network-style failure', () async {
      create();
      final failed = expectLater(
          transport.ready, throwsA(isA<PhoenixLongPollException>()));
      (await client.take('GET')).replyRaw(response);
      await failed;
      await flushLongPoll();
      expect(transport.closeCode, 1011);
    });
  }

  for (final body in [
    {'status': 410, 'messages': []},
    {'status': 410, 'token': 42, 'messages': []},
    {'status': 403, 'token': []},
    {
      'status': 200,
      'token': 't',
      'messages': [42]
    },
    {'status': 200, 'token': 't'},
  ]) {
    test('malformed poll body $body closes through the error stream', () async {
      create();
      final failed = expectLater(
          transport.ready, throwsA(isA<PhoenixLongPollException>()));
      (await client.take('GET')).reply(body);
      await failed;
      await flushLongPoll();
      expect(transport.closeCode, 1011);
      expect(errors, hasLength(1));
    });
  }

  test('HTTP status does not replace the status encoded in the body', () async {
    create();
    (await client.take('GET'))
        .reply({'status': 410, 'token': 't', 'messages': []}, httpStatus: 503);
    await transport.ready;
    expect(transport.closeCode, isNull);
    await client.take('GET');
  });

  test('GET timeout aborts its request and closes with 1005', () async {
    create(timeout: const Duration(milliseconds: 20));
    final failed =
        expectLater(transport.ready, throwsA(isA<PhoenixLongPollException>()));
    await client.take('GET');
    await failed;
    await flushLongPoll();
    expect(transport.closeCode, 1005);
    expect(transport.closeReason, 'timeout');
    expect(client.aborts, 1);
    expect(client.closed, isTrue);
  });

  test('zero disables the HTTP timeout', () async {
    create(timeout: Duration.zero);
    await client.take('GET');
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(client.closed, isFalse);
    expect(errors, isEmpty);
  });

  test('same-tick sends coalesce and sends during POST wait for its ack',
      () async {
    create();
    await open();
    for (final frame in ['a', 'b', 'c']) {
      transport.send(frame);
    }
    final first = await client.take('POST');
    expect(first.request.body, 'a\nb\nc');
    transport.send('d');
    transport.send('e');
    expect(
        client.requests.where((r) => r.request.method == 'POST'), hasLength(1));
    first.reply({'status': 200});
    final second = await client.take('POST');
    expect(second.request.body, 'd\ne');
    second.reply({'status': 200});
    await flushLongPoll();
    expect(errors, isEmpty);
  });

  test('250 sends split into ordered 100/100/50 batches before buffered sends',
      () async {
    create();
    await open();
    for (var i = 0; i < 250; i++) {
      transport.send('m$i');
    }
    var post = await client.take('POST');
    expect(post.request.body.split('\n'), List.generate(100, (i) => 'm$i'));
    transport.send('buffered');
    post.reply({'status': 200});
    post = await client.take('POST');
    expect(post.request.body.split('\n'),
        List.generate(100, (i) => 'm${i + 100}'));
    post.reply({'status': 200});
    post = await client.take('POST');
    expect(
        post.request.body.split('\n'), List.generate(50, (i) => 'm${i + 200}'));
    post.reply({'status': 200});
    post = await client.take('POST');
    expect(post.request.body, 'buffered');
    post.reply({'status': 200});
  });

  test('binary upload is base64 with the exact typed-data view bounds',
      () async {
    create();
    await open();
    final bytes = Uint8List.fromList([99, 0, 128, 255, 99]);
    transport.send(Uint8List.sublistView(bytes, 1, 4));
    transport.send('[null,"0","audit","echo",{"unicode":"é🐦"}]');
    final post = await client.take('POST');
    expect(
        post.request.body, 'AID/\n[null,"0","audit","echo",{"unicode":"é🐦"}]');
  });

  for (final status in [403, 410, 500]) {
    test('POST failure $status closes without replaying the batch', () async {
      create();
      await open();
      transport.send('first');
      final post = await client.take('POST');
      transport.send('buffered');
      post.reply({'status': status});
      await flushLongPoll();
      expect(transport.closeCode, 1011);
      expect((errors.single as PhoenixLongPollException).status, status);
      expect(client.requests.where((r) => r.request.method == 'POST'),
          hasLength(1));
    });
  }

  test('POST timeout aborts the concurrent GET and drops queued writes',
      () async {
    create(timeout: const Duration(milliseconds: 40));
    await open();
    final poll = await client.take('GET');
    // Keep refreshing GET so the POST, not the poll, expires first.
    transport.send('request');
    await client.take('POST');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    poll.reply({'status': 204, 'token': 't', 'messages': []});
    await client.take('GET');
    transport.send('buffered');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(transport.closeCode, 1005);
    expect(client.aborts, 2);
    expect(
        client.requests.where((r) => r.request.method == 'POST'), hasLength(1));
  });

  test('close aborts GET and POST and ignores late success responses',
      () async {
    create();
    await open();
    final poll = await client.take('GET');
    transport.send('first');
    final post = await client.take('POST');
    transport.send('buffered');
    await transport.close(1000, 'user left');
    await flushLongPoll();
    poll.reply({
      'status': 200,
      'token': 't',
      'messages': ['stale']
    });
    post.reply({'status': 200});
    await flushLongPoll();
    expect(messages, isEmpty);
    expect(errors, isEmpty);
    expect(client.aborts, 2);
    expect(transport.closeReason, 'user left');
    expect(() => transport.send('later'), throwsStateError);
    await transport.close();
  });

  test('close before the first tick prevents every HTTP request', () async {
    create();
    await transport.close();
    await flushLongPoll();
    expect(client.requests, isEmpty);
    expect(client.closed, isTrue);
  });

  test('close before the send tick discards its unsent batch', () async {
    create();
    await open();
    transport.send('unsent');
    await transport.close();
    await flushLongPoll();
    expect(client.requests.where((r) => r.request.method == 'POST'), isEmpty);
  });

  test('paused receive listener does not block HTTP cleanup', () async {
    final http = ControlledHttpClient();
    final poll = PhoenixLongPoll(
        Uri.parse('http://example.invalid/socket/longpoll'),
        client: http);
    final listener = poll.stream.listen((_) {});
    listener.pause();
    await http.take('GET');
    await poll.close().timeout(const Duration(seconds: 1));
    expect(http.closed, isTrue);
    listener.resume();
    await listener.cancel();
  });

  test('network exception is observed through the protocol error stream',
      () async {
    create();
    final failed =
        expectLater(transport.ready, throwsA(isA<PhoenixLongPollException>()));
    (await client.take('GET')).fail(StateError('offline'));
    await failed;
    await flushLongPoll();
    expect(transport.closeCode, 1011);
  });

  test('unsupported frame types do not start a POST', () async {
    create();
    await open();
    expect(() => transport.send([1, 2, 3]), throwsArgumentError);
    await flushLongPoll();
    expect(client.requests.where((r) => r.request.method == 'POST'), isEmpty);
  });
}
