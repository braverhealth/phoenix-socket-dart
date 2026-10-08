import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'endpoint.dart';

class TrackingClient extends http.BaseClient {
  final http.Client inner = http.Client();
  final requests = <http.Request>[];
  int closeCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request as http.Request);
    return inner.send(request);
  }

  @override
  void close() {
    closeCalls++;
    inner.close();
  }
}

class NoSessionHistory implements PhoenixSocketSessionStore {
  @override
  String? getItem(String key) => null;
  @override
  void setItem(String key, String value) {}
  @override
  void removeItem(String key) {}
}

Future<void> eventually(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Long-poll connection did not recover');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  final endpoint = e2eEndpoint;
  var sequence = 0;
  const polling = PhoenixSocketOptions(
      transport: PhoenixSocketTransport.longPolling,
      timeout: Duration(seconds: 5),
      longPollTimeout: Duration(seconds: 3),
      heartbeat: Duration(milliseconds: 20),
      reconnectDelays: [Duration(milliseconds: 20)]);

  group('Phoenix 1.8.15 HTTP long polling', () {
    late PhoenixSocket socket;
    late String topic;
    late List<TrackingClient> clients;
    setUp(() async {
      topic =
          'audit:poll-${DateTime.now().microsecondsSinceEpoch}-${sequence++}';
      clients = [];
      socket = PhoenixSocket(endpoint!,
          socketOptions: PhoenixSocketOptions(
            transport: PhoenixSocketTransport.longPolling,
            params: {'user_id': topic},
            timeout: polling.timeout,
            longPollTimeout: polling.longPollTimeout,
            heartbeat: polling.heartbeat,
            reconnectDelays: polling.reconnectDelays,
          ), httpClientFactory: () {
        final client = TrackingClient();
        clients.add(client);
        return client;
      });
      addTearDown(socket.dispose);
      expect(await socket.connect(), same(socket));
    });

    test('real HTTP join, reply, server push and leave, with no heartbeats',
        () async {
      final channel = socket.addChannel(topic: topic);
      expect((await channel.join().future).isOk, isTrue);
      expect(
          (await channel
                  .push(
                      'echo',
                      {
                        'unicode': 'é🐦',
                        'nested': [true, null, 42]
                      },
                      expectingReply: true)
                  .future)
              .responseMap,
          {
            'unicode': 'é🐦',
            'nested': [true, null, 42]
          });
      final observed =
          channel.messages.firstWhere((m) => m.event.value == 'observed');
      channel.push('no_reply', {'value': 42}, expectingReply: false);
      expect((await observed).payloadMap, {'value': 42});
      expect((await channel.leave().future).isOk, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final requests = clients.single.requests;
      expect(requests.every((r) => r.url.path == '/socket/longpoll'), isTrue);
      expect(
          requests
              .where((r) => r.method == 'POST')
              .any((r) => r.body.contains('heartbeat')),
          isFalse);
      socket.close();
      expect(clients.single.closeCalls, 1);
    });

    test('250 concurrent requests survive reference NDJSON batching', () async {
      final channel = socket.addChannel(topic: topic);
      await channel.join().future;
      final before = clients.single.requests.length;
      final replies = await Future.wait(List.generate(
          250,
          (i) => channel
              .push('echo', {'sequence': i}, expectingReply: true)
              .future));
      expect(replies.map((r) => r.responseMap!['sequence']),
          List.generate(250, (i) => i));
      final posts = clients.single.requests
          .skip(before)
          .where((r) => r.method == 'POST')
          .toList();
      expect(posts, hasLength(3));
      expect(posts.map((r) => r.body.split('\n').length), [100, 100, 50]);
      expect(
          posts.every(
              (r) => r.headers['Content-Type'] == 'application/x-ndjson'),
          isTrue);
    });

    test('Phoenix decodes binary uploads and returns a compatible JSON reply',
        () async {
      final channel = socket.addChannel(topic: topic);
      await channel.join().future;
      final backing =
          Uint8List.fromList(List.generate(256 * 1024 + 2, (i) => i % 256));
      final bytes = Uint8List.sublistView(backing, 1, backing.length - 1);
      final reply = await channel
          .push('binary_upload', bytes, expectingReply: true)
          .future;
      expect(reply.responseMap!['size'], bytes.length);
      expect(base64Decode(reply.responseMap!['base64'] as String), bytes);
      final post = clients.single.requests.lastWhere((r) => r.method == 'POST');
      expect(post.body.startsWith('['), isFalse);
      expect(base64Decode(post.body).first, 0); // Phoenix binary push kind.
    });

    test('JSON broadcast reaches two long-poll sessions', () async {
      final other = PhoenixSocket(endpoint!, socketOptions: polling);
      addTearDown(other.dispose);
      await other.connect();
      final first = socket.addChannel(topic: 'channel3');
      final second = other.addChannel(topic: 'channel3');
      await Future.wait([first.join().future, second.join().future]);
      final one = first.messages.firstWhere((m) => m.event.value == 'pong');
      final two = second.messages.firstWhere((m) => m.event.value == 'pong');
      first.push('ping', {'source': topic}, expectingReply: false);
      expect((await one).payloadMap, {'source': topic});
      expect((await two).payloadMap, {'source': topic});
    });

    test('server session loss closes with 3410 and rejoins the channel',
        () async {
      final channel = socket.addChannel(topic: topic);
      await channel.join().future;
      final originalRef = channel.joinRef;
      final closed = socket.closeStream.first;
      channel.push('disconnect', {}, expectingReply: false);
      expect((await closed).code, 3410);
      await eventually(() =>
          clients.length == 2 &&
          channel.canPush &&
          channel.joinRef != originalRef);
      expect(
          (await channel
                  .push('echo', {'recovered': true}, expectingReply: true)
                  .future)
              .responseMap,
          {'recovered': true});
      expect(clients.first.closeCalls, 1);
    });

    test('auth token GET header passes the server connect_info contract',
        () async {
      final authenticated = PhoenixSocket(endpoint!,
          socketOptions: const PhoenixSocketOptions(
            transport: PhoenixSocketTransport.longPolling,
            authToken: 'long-poll-auth-token',
            params: {'expected_auth_token': 'long-poll-auth-token'},
            maxReconnectionAttempts: 0,
          ));
      addTearDown(authenticated.dispose);
      expect(await authenticated.connect(), same(authenticated));
      expect((await authenticated.addChannel(topic: topic).join().future).isOk,
          isTrue);
    });

    test('default WebSocket factory uses the same Phoenix auth token contract',
        () async {
      final authenticated = PhoenixSocket(endpoint!,
          socketOptions: const PhoenixSocketOptions(
            authToken: 'websocket-auth-token',
            params: {'expected_auth_token': 'websocket-auth-token'},
            maxReconnectionAttempts: 0,
          ));
      addTearDown(authenticated.dispose);
      expect(await authenticated.connect(), same(authenticated));
      expect((await authenticated.addChannel(topic: topic).join().future).isOk,
          isTrue);
    });

    test('forbidden connect exposes 403 and closes with 1008', () async {
      final forbidden = PhoenixSocket(endpoint!,
          socketOptions: const PhoenixSocketOptions(
            transport: PhoenixSocketTransport.longPolling,
            params: {'reject_socket': 'true'},
            maxReconnectionAttempts: 0,
          ));
      addTearDown(forbidden.dispose);
      final error = forbidden.errorStream.first;
      final close = forbidden.closeStream.first;
      expect(await forbidden.connect(), isNull);
      expect(((await error).error as PhoenixLongPollException).status, 403);
      expect(forbidden.isConnected, isFalse);
      expect((await close).code, 1008);
    });

    test('a real failed WebSocket handshake falls back to working HTTP',
        () async {
      final fallback = PhoenixSocket(endpoint!,
          socketOptions: PhoenixSocketOptions(
            longPollFallbackAfter: const Duration(seconds: 2),
            sessionStorage: NoSessionHistory(),
          ),
          webSocketChannelFactory: (uri) =>
              WebSocketChannel.connect(uri.replace(path: '/not-a-websocket')));
      addTearDown(fallback.dispose);
      expect(await fallback.connect(), same(fallback));
      expect(fallback.transport, PhoenixSocketTransport.longPolling);
      final channel = fallback.addChannel(topic: topic);
      await channel.join().future;
      expect(
          (await channel
                  .push('echo', {'fallback': true}, expectingReply: true)
                  .future)
              .responseMap,
          {'fallback': true});
    });
  },
      skip: endpoint == null
          ? 'Run dart run tool/run_e2e.dart --long-poll.'
          : false,
      timeout: const Timeout(Duration(seconds: 20)));
}
