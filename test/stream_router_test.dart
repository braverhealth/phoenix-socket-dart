import 'dart:async';

import 'package:phoenix_socket/src/stream_router.dart';
import 'package:test/test.dart';

void main() {
  test('a routed broadcast stream supports cancellation and relistening',
      () async {
    final incoming = StreamController<int>();
    final router = PhoenixStreamRouter(incoming.stream);
    final route = router.route((value) => value.isEven);
    await route.listen((_) {}).cancel();
    final next = route.first;
    incoming.add(2);
    expect(await next, 2);
    await router.close();
    await incoming.close();
  });

  test('relistening retains the priority of overlapping routes', () async {
    final incoming = StreamController<int>();
    final router = PhoenixStreamRouter(incoming.stream);
    final first = router.route((_) => true);
    final laterEvents = <int>[];
    final second = router.route((_) => true).listen(laterEvents.add);
    await first.listen((_) {}).cancel();
    final next = first.first;
    incoming.add(3);
    expect(await next, 3);
    expect(laterEvents, isEmpty);
    await second.cancel();
    await router.close();
    await incoming.close();
  });

  test('closing the router closes all streams and is idempotent', () async {
    final incoming = StreamController<int>();
    final router = PhoenixStreamRouter(incoming.stream);
    final routed = expectLater(router.route((_) => true), emitsDone);
    final fallback = expectLater(router.defaultStream, emitsDone);
    await router.close();
    await router.close();
    await Future.wait([routed, fallback]);
    expect(() => router.route((_) => true), throwsStateError);
    await incoming.close();
  });
}
