import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

import 'fixtures/long_poll_reference.dart';
import 'helpers/controlled_http_client.dart';

void main() {
  final reference =
      jsonDecode(phoenixLongPollReferenceJson) as Map<String, dynamic>;
  final endpoint =
      Uri.parse('wss://example.invalid/socket/websocket?vsn=2.0.0');

  for (final vector in reference['endpoints'] as List) {
    test('reference endpoint ${vector['input']}', () {
      expect(
          PhoenixLongPoll.normalizeEndpoint(
                  Uri.parse(vector['input'] as String))
              .toString(),
          vector['expected']);
    });
  }

  for (final vector in reference['poll'] as List) {
    test('reference poll status ${vector['status']}', () async {
      final client = ControlledHttpClient();
      final transport = PhoenixLongPoll(endpoint, client: client);
      addTearDown(transport.close);
      final errors = <Object?>[];
      final done = Completer<void>();
      transport.stream.listen((_) {},
          onError: (Object error) =>
              errors.add((error as PhoenixLongPollException).status),
          onDone: done.complete);
      final status = vector['status'] as int;
      if (status == 410) {
        (await client.take('GET'))
            .reply({'status': 410, 'token': 'original', 'messages': []});
        await transport.ready;
        (await client.take('GET'))
            .reply({'status': 410, 'token': 'replacement', 'messages': []});
      } else {
        (await client.take('GET')).reply({'status': status});
      }
      await done.future;
      final events = vector['events'] as List;
      expect(errors,
          events.where((e) => e[0] == 'error').map((e) => e[1]).toList());
      final close = events.singleWhere((e) => e[0] == 'close');
      expect(transport.closeCode, close[1]);
      expect(transport.closeReason, close[2]);
    });
  }

  test('reference session request trace and ordered delivery', () async {
    final client = ControlledHttpClient();
    final transport =
        PhoenixLongPoll(endpoint, client: client, authToken: 'reference-token');
    addTearDown(transport.close);
    final frames = <String>[];
    transport.stream.listen((frame) => frames.add(frame as String));
    (await client.take('GET'))
        .reply({'status': 410, 'token': 'session +/=&', 'messages': []});
    await transport.ready;
    (await client.take('GET'))
        .reply({'status': 204, 'token': 'session +/=&', 'messages': []});
    (await client.take('GET')).reply({
      'status': 200,
      'token': 'session +/=&',
      'messages': ['a', 'b', 'c']
    });
    await client.take('GET');
    while (frames.length < 3) {
      await Future<void>.delayed(Duration.zero);
    }
    final session = reference['session'] as Map;
    final requests = session['requests'] as List;
    expect(client.requests, hasLength(requests.length));
    for (var i = 0; i < requests.length; i++) {
      final referenceQuery =
          Uri.parse(requests[i]['url'] as String).queryParameters;
      // Connection parameters are deliberately omitted from resumed requests.
      expect(client.requests[i].request.url.queryParameters,
          i == 0 ? referenceQuery : {'token': referenceQuery['token']!});
      expect(client.requests[i].request.headers, requests[i]['headers']);
    }
    expect(
        frames,
        (session['events'] as List)
            .where((e) => e[0] == 'message')
            .map((e) => e[1])
            .toList());
  });

  test('reference batch trace including buffered writes', () async {
    final client = ControlledHttpClient();
    final transport = PhoenixLongPoll(endpoint, client: client);
    addTearDown(transport.close);
    transport.stream.listen((_) {});
    (await client.take('GET'))
        .reply({'status': 410, 'token': 't', 'messages': []});
    await transport.ready;
    for (var i = 0; i < 250; i++) {
      transport.send('m$i');
    }
    final requests = reference['batches']['requests'] as List;
    for (var i = 0; i < requests.length; i++) {
      final post = await client.take('POST');
      if (i == 0) transport.send('buffered');
      expect(post.request.body, requests[i]['body']);
      expect(post.request.headers, requests[i]['headers']);
      final referenceUri = Uri.parse(requests[i]['url'] as String);
      expect(
          post.request.url,
          referenceUri.replace(queryParameters: {
            'token': referenceUri.queryParameters['token']!
          }));
      post.reply({'status': 200});
    }
  });

  test('reference binary POST representation', () async {
    final client = ControlledHttpClient();
    final transport = PhoenixLongPoll(endpoint, client: client);
    addTearDown(transport.close);
    transport.stream.listen((_) {});
    (await client.take('GET'))
        .reply({'status': 410, 'token': 't', 'messages': []});
    await transport.ready;
    transport.send(Uint8List.fromList([0, 128, 255]));
    transport.send('[null,"0","audit","echo",{"unicode":"é🐦"}]');
    final post = await client.take('POST');
    expect(post.request.body, reference['binary']['body']);
    expect(post.request.headers, reference['binary']['headers']);
  });
}
