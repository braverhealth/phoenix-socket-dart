import 'dart:convert';

/// Synchronous codec measurements; checksums keep decoded values observable.
void benchmark(
    String codec, int size, int frameBytes, int Function() exchange) {
  final iterations = size > 1024 * 1024 ? 20 : 200;
  for (var i = 0; i < 20; i++) {
    exchange();
  }
  final samples = <int>[];
  var checksum = 0;
  final total = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    final watch = Stopwatch()..start();
    checksum += exchange();
    samples.add(watch.elapsedMicroseconds);
  }
  total.stop();
  samples.sort();
  print(jsonEncode({
    'codec': codec,
    'payload_bytes': size,
    'frame_bytes': frameBytes,
    'iterations': iterations,
    'microseconds_per_exchange': total.elapsedMicroseconds / iterations,
    'p50_microseconds': samples[samples.length ~/ 2],
    'p95_microseconds': samples[(samples.length * .95).ceil() - 1],
    'exchanges_per_second': iterations * 1000000 / total.elapsedMicroseconds,
    'checksum': checksum
  }));
}
