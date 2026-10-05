# Controlled headless Chrome codec comparison

Run: 2026-10-05T10:50:39.622Z. Chrome/154.0.8037.97, Dart SDK version: 3.9.0 (stable) (Mon Aug 11 07:58:10 2025 -0700) on "macos_arm64".

All 395 version/workload measurements and 215 old/new pairs completed.

Each comparable pair uses identical generated content, the same encoded frame size, the same loop count,
the same compiler optimization (-O2), and alternating execution order in one isolated Chrome instance.
Decoded content hashes are checked before and after measurement. There is no virtual-time budget.
All codec work runs on the browser main thread. Each case uses a fresh page, the same fixed JSON adapter,
and at least three warmup batches totaling 200 ms per version before nine timed batches.
Background-tab throttling is disabled and the measured target is activated before each batch.

Baselines: alpha `86d4f1175345d082f67a9f571adb857d9080785a`, master `6dc4b429f6bafda907af8a5da94dafa055c2c06f`.
New implementation source SHA-256: `8af8d69173cc0d6893bb11bef4030acce73bc85f73df054760922f304bef66e7`.
Harness SHA-256: `dd96001a2162b9884ae9aad46515a05400962d9f015969485d2d2bbfddb0615e`.

The benchmark uses seven content families and five target sizes: 256 B, 4 KiB, 64 KiB, 1 MiB and 4 MiB.
Structured/text targets are JSON payload bytes. Byte-buffer targets are raw byte counts, so their JSON
number-array representation is larger. Actual payload/frame lengths are recorded in the raw data.

## Overview

Speedup is old median batch time per operation divided by new. Values above 1 favor the new code.
Geometric means summarize ratios across varied sizes; they are not production traffic weighting.

| Baseline | Mechanism | Pairs | Geometric mean speedup |
|---|---|---:|---:|
| alpha | json | 35 | 1.54× |
| master | json | 35 | 1.54× |
| master | binary_json | 35 | 1.04× |
| master | binary_protobuf | 35 | 1.07× |
| master | msgpack_binary | 35 | 2.17× |
| master | msgpack_base64 | 35 | 1.57× |
| master | binary_raw | 5 | 1.77× |

## JSON at the largest target

| Content | Actual JSON MiB | Alpha ms | Master ms | New ms |
|---|---:|---:|---:|---:|
| ascii | 4.000 | 5.62 | 5.08 | 4.58 |
| unicode | 4.000 | 9.43 | 7.34 | 7.19 |
| escaped | 4.000 | 46.84 | 47.26 | 47.64 |
| flat_records | 4.000 | 85.93 | 82.90 | 43.48 |
| nested_records | 4.000 | 98.14 | 94.61 | 50.99 |
| numbers | 4.000 | 98.44 | 103.40 | 37.88 |
| bytes | 14.281 | 664.63 | 639.15 | 256.55 |

## Binary and format comparisons at the largest target

| Content | Mechanism | Master ms | New ms | Speedup |
|---|---|---:|---:|---:|
| ascii | binary_json | 12.37 | 12.47 | 0.99× |
| ascii | binary_protobuf | 9.15 | 8.59 | 1.07× |
| ascii | msgpack_binary | 17.54 | 15.65 | 1.12× |
| ascii | msgpack_base64 | 43.64 | 42.30 | 1.03× |
| unicode | binary_json | 17.49 | 16.88 | 1.04× |
| unicode | binary_protobuf | 12.24 | 11.90 | 1.03× |
| unicode | msgpack_binary | 9.93 | 8.93 | 1.11× |
| unicode | msgpack_base64 | 40.38 | 38.14 | 1.06× |
| escaped | binary_json | 53.13 | 55.13 | 0.96× |
| escaped | binary_protobuf | 5.59 | 5.36 | 1.04× |
| escaped | msgpack_binary | 11.76 | 10.24 | 1.15× |
| escaped | msgpack_base64 | 28.40 | 27.34 | 1.04× |
| flat_records | binary_json | 51.11 | 54.03 | 0.95× |
| flat_records | binary_protobuf | 110.58 | 111.51 | 0.99× |
| flat_records | msgpack_binary | 231.45 | 205.07 | 1.13× |
| flat_records | msgpack_base64 | 261.25 | 222.71 | 1.17× |
| nested_records | binary_json | 53.67 | 54.69 | 0.98× |
| nested_records | binary_protobuf | 123.28 | 125.16 | 0.99× |
| nested_records | msgpack_binary | 256.91 | 218.65 | 1.18× |
| nested_records | msgpack_base64 | 280.07 | 242.97 | 1.15× |
| numbers | binary_json | 44.85 | 44.92 | 1.00× |
| numbers | binary_protobuf | 24.01 | 24.63 | 0.97× |
| numbers | msgpack_binary | 127.85 | 45.16 | 2.83× |
| numbers | msgpack_base64 | 134.18 | 60.32 | 2.22× |
| bytes | binary_raw | 0.64 | 0.32 | 2.00× |
| bytes | binary_json | 299.08 | 288.30 | 1.04× |
| bytes | binary_protobuf | 3.66 | 3.45 | 1.06× |
| bytes | msgpack_binary | 678.69 | 0.46 | 1475.41× |
| bytes | msgpack_base64 | 683.40 | 26.94 | 25.37× |

## Main-thread stalls

The maximum below is an individual encode+decode duration, including any GC pause inside that operation.
The separate raw browser-long-task counts cover an entire timed batch; they must not be treated as individual
message counts. Calibration and content verification are excluded from the recorded batches.

| Baseline | Content | Target MiB | Mechanism | Old max ms | New max ms | Old operations >50 ms | New operations >50 ms |
|---|---|---:|---|---:|---:|---:|---:|
| alpha | bytes | 4.000 | json | 740.61 | 252.74 | 9 | 9 |
| master | bytes | 4.000 | json | 726.14 | 252.74 | 9 | 9 |
| master | bytes | 4.000 | msgpack_base64 | 710.24 | 28.20 | 9 | 0 |
| master | bytes | 4.000 | msgpack_binary | 699.62 | 0.59 | 9 | 0 |
| master | nested_records | 4.000 | msgpack_base64 | 342.39 | 274.29 | 9 | 9 |
| master | flat_records | 4.000 | msgpack_base64 | 313.66 | 271.86 | 9 | 9 |
| master | bytes | 4.000 | binary_json | 311.01 | 306.01 | 9 | 9 |
| master | nested_records | 4.000 | msgpack_binary | 296.94 | 242.41 | 9 | 9 |
| master | flat_records | 4.000 | msgpack_binary | 294.13 | 264.41 | 9 | 9 |
| master | numbers | 4.000 | msgpack_base64 | 173.33 | 72.27 | 9 | 9 |
| master | bytes | 1.000 | msgpack_base64 | 163.09 | 7.34 | 9 | 0 |
| master | bytes | 1.000 | msgpack_binary | 159.00 | 0.27 | 9 | 0 |

## Slower cases requiring attention

This list uses a 10% median increase and a baseline of at least 20 µs to avoid emphasizing tiny absolute differences.
One run does not establish significance; raw per-round samples are available for reruns.

| Baseline | Content | Target bytes | Mechanism | Old µs | New µs |
|---|---|---:|---|---:|---:|
| master | flat_records | 1048576 | binary_json | 8210.00 | 9535.00 |
| master | numbers | 1048576 | binary_json | 6190.00 | 8175.00 |

## Interpretation and reproduction

- Median and p95 are distributions of **batch mean time per operation**, not per-message latency percentiles.
- Raw binary measures opaque-byte framing. Binary JSON and protobuf additionally parse application content.
- The master protobuf adapter manually serializes on send and uses its legacy payload decoder on receive;
  the new adapter uses PayloadCodec in both directions. Both use exactly the same generated protobuf schema/runtime.
- Recorded protobuf timings use the benchmark payload codec. The optional protobuf convenience package
  was added afterward and its overhead is not measured separately.
- Original eager logging remains in both historical baselines; new lazy logging is part of the measured change.
- JSON rows use the same JSON encoding and content; binary support is inactive for those rows. The JSON
  optimization is lazy payload logging, not a replacement or tuning of jsonEncode/jsonDecode. This comparison
  measures the complete implementations and does not isolate the contribution of each optimization.
- Heap snapshots record live JavaScript heap/backing storage before, after, and after forced GC. They are not
  total allocated bytes or peak memory. GC is forced before timing, not between timed rounds.
- No network RTT, TLS, compression, Flutter rendering or real Braver records are included. These results isolate
  the main-thread codec work that can contribute to UI stalls. Other host activity/JIT/GC can cause variance.

```sh
node tool/run_chrome_comparison.mjs --rounds 9 --output docs/benchmarks/chrome-comparison-isolated-2026-10-05.json
node tool/summarize_chrome_comparison.mjs docs/benchmarks/chrome-comparison-isolated-2026-10-05.json
```

Raw JSON measurements are generated locally and ignored by Git. The commands above regenerate them.
Full size/content comparisons: [CSV](benchmarks/chrome-comparison.csv).
