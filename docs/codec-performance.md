# Codec performance measurements

For a controlled old/new comparison in Chrome across seven content families and
five sizes, use [the headless Chrome comparison](chrome-codec-comparison.md).
It uses real browser time, fresh pages, matching JSON adapters, alternating
execution order, and content/wire-size verification. The exploratory Chrome
measurements below used virtual time and are retained as historical notes;
they should not replace the controlled comparison.

Measured on 2026-09-30, Apple M5 Pro / macOS arm64, Dart 3.9.2 and Chrome
154.0.8037.58. Functional validation also covers Dart 3.4.4. These are synthetic
development measurements, not production latency or statistically rigorous
performance guarantees. JIT warmup, GC and other host activity cause variation.

## Existing JSON path

The same standalone JSON encode/decode loop was run against baseline `86d4f11`
and this implementation. Payloads contain an ASCII string in a map. Ten warmup
exchanges precede 200 measured iterations (20 for 2 MiB); checksums and encoded
frame sizes match. Finest-level logging is disabled.

| Payload | Baseline mean, microseconds | New mean, microseconds |
|---|---:|---:|
| 1 KiB | 23.945 | 21.885 |
| 100 KiB | 174.985 | 175.025 |
| 2 MiB | 5106.750 | 3075.050 |

The 100 KiB results are effectively unchanged. The larger-string improvement
is consistent with removing eager payload stringification from disabled log
calls. It is not evidence that every workload becomes faster.

VM allocation tracing uses separate isolate groups and selected message,
map/list, string, byte-buffer and closure classes. For 100 KiB JSON exchanges it
recorded 58.73 samples/exchange before and 34.73 after. Raw Phoenix binary
framing recorded 18.73. These are traced samples of selected classes, not total
allocated bytes. Reported post-GC heap usage includes runtime/library overhead
and is not peak heap or a production memory estimate.

## Framing and application codecs

All times below include one encode and one decode. The binary framing case
transports raw bytes; protobuf cases additionally serialize and parse generated
echo messages. They therefore perform different application work. Protobuf
envelope decoding avoids copying a byte field already represented by Uint8List.
MessagePack cases use a map containing the same ASCII string. Compression is
not enabled, and the protobuf example schema is not Braver's production schema.

| Native, 2 MiB | Frame bytes | Mean microseconds | p95 microseconds |
|---|---:|---:|---:|
| Phoenix binary framing, raw bytes | 2097169 | 451.55 | 1651 |
| Protobuf payload in Phoenix framing | 2097177 | 6273.85 | 6730 |
| Complete protobuf envelope | 2097185 | 7078.00 | 7928 |
| MessagePack binary envelope | 2097180 | 5429.65 | 6560 |
| MessagePack base64 envelope | 2796240 | 17448.45 | 27511 |

Schema codec cost can dominate framing cost. This string-heavy example does
not show a protobuf CPU advantage over JSON. Base64 adds wire bytes and
conversion work, as expected. Measure actual Braver request/response shapes
before selecting a production protocol.

## Browser and client pipeline

The Dart-to-JavaScript core benchmark also ran in an isolated headless Chrome
profile. Its 2 MiB mean was 1680 microseconds for JSON and 170 for raw binary
framing. Browser clock resolution produces zero-duration samples for some
small messages, so those individual percentiles are not useful.

An in-memory request/reply harness includes the client event queues, channel
push tracking, codec operations and a fixture peer. The fixture peer uses one
binary reply buffer allocation rather than expanding payloads into boxed lists.
No network, server scheduling, TLS, compression or congestion is represented.

| 2 MiB request/reply | Native p95, microseconds | Chrome p95, microseconds |
|---|---:|---:|
| JSON | 8293 | 4000 |
| Raw binary | 3166 | 700 |

This establishes that the complete client pipeline can carry binary messages
without an extra asynchronous decoding stage. It does not predict remote RTT.

## Reproduction

From the repository root, enter the core package, then the protobuf example and MessagePack package respectively:

```sh
cd packages/phoenix_socket
dart run tool/codec_benchmark.dart
cd ../../example/protobuf
dart run tool/codec_benchmark.dart
cd ../../packages/phoenix_socket_msgpack
dart run tool/codec_benchmark.dart
```

Run allocation tracing from `packages/phoenix_socket` with the VM service enabled:

```sh
dart --observe=0 --no-pause-isolates-on-exit \
  --no-pause-isolates-on-unhandled-exceptions \
  run tool/allocation_benchmark.dart
```

Use `--json-only` when comparing the allocation tool against a baseline that
lacks binary framing. Do not interpret deprecated VM accumulated-size fields
as allocation totals; this tool uses allocation traces instead.

For Chrome, compile the core benchmark from `packages/phoenix_socket` to JavaScript, place
`tool/codec_benchmark.html` beside it, and open the HTML:

```sh
mkdir -p /tmp/phoenix-codec-web
dart compile js tool/codec_benchmark.dart -o /tmp/phoenix-codec-web/codec_benchmark.js
cp tool/codec_benchmark.html /tmp/phoenix-codec-web/
```

The recorded headless run used `--virtual-time-budget=10000` to allow the async
harness to finish and collected JSON output from the page's results element.
For application decisions, repeat in a real browser session using representative
data and inspect its allocation/GC profile as well.
