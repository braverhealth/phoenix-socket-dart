# Controlled headless Chrome codec comparison

Run: 2026-10-03T19:37:10.325Z. Chrome/154.0.8037.97, Dart SDK version: 3.9.2 (stable) (Wed Aug 27 03:49:40 2025 -0700) on "macos_arm64".

All 395 version/workload measurements and 215 old/new pairs completed.

Each comparable pair uses identical generated content, the same encoded frame size, the same loop count,
the same compiler optimization (-O2), and alternating execution order in one isolated Chrome instance.
Decoded content hashes are checked before and after measurement. There is no virtual-time budget.
All codec work runs on the browser main thread. Each case uses a fresh page, the same fixed JSON adapter,
and at least three warmup batches totaling 200 ms per version before nine timed batches.
Background-tab throttling is disabled and the measured target is activated before each batch.

Baselines: alpha `86d4f1175345d082f67a9f571adb857d9080785a`, master `6dc4b429f6bafda907af8a5da94dafa055c2c06f`.
New implementation source SHA-256: `a24520a7f41df5dfd04fe1e76414e4f3b3c091734b3117d624207b9e43cd56e3`.
Harness SHA-256: `dd96001a2162b9884ae9aad46515a05400962d9f015969485d2d2bbfddb0615e`.

The benchmark uses seven content families and five target sizes: 256 B, 4 KiB, 64 KiB, 1 MiB and 4 MiB.
Structured/text targets are JSON payload bytes. Byte-buffer targets are raw byte counts, so their JSON
number-array representation is larger. Actual payload/frame lengths are recorded in the raw data.

## Overview

Speedup is old median batch time per operation divided by new. Values above 1 favor the new code.
Geometric means summarize ratios across varied sizes; they are not production traffic weighting.

| Baseline | Mechanism | Pairs | Geometric mean speedup |
|---|---|---:|---:|
| alpha | json | 35 | 1.56× |
| master | json | 35 | 1.56× |
| master | binary_json | 35 | 1.05× |
| master | binary_protobuf | 35 | 1.08× |
| master | msgpack_binary | 35 | 2.32× |
| master | msgpack_base64 | 35 | 1.63× |
| master | binary_raw | 5 | 1.70× |

## JSON at the largest target

| Content | Actual JSON MiB | Alpha ms | Master ms | New ms |
|---|---:|---:|---:|---:|
| ascii | 4.000 | 5.43 | 4.78 | 4.19 |
| unicode | 4.000 | 8.77 | 6.85 | 6.79 |
| escaped | 4.000 | 42.99 | 42.68 | 42.20 |
| flat_records | 4.000 | 77.60 | 72.40 | 39.99 |
| nested_records | 4.000 | 92.42 | 88.06 | 47.53 |
| numbers | 4.000 | 80.66 | 87.16 | 32.67 |
| bytes | 14.281 | 555.41 | 575.49 | 218.98 |

## Binary and format comparisons at the largest target

| Content | Mechanism | Master ms | New ms | Speedup |
|---|---|---:|---:|---:|
| ascii | binary_json | 10.75 | 10.44 | 1.03× |
| ascii | binary_protobuf | 7.36 | 7.44 | 0.99× |
| ascii | msgpack_binary | 14.71 | 13.18 | 1.12× |
| ascii | msgpack_base64 | 36.20 | 35.14 | 1.03× |
| unicode | binary_json | 15.99 | 15.61 | 1.02× |
| unicode | binary_protobuf | 11.08 | 10.76 | 1.03× |
| unicode | msgpack_binary | 8.80 | 8.13 | 1.08× |
| unicode | msgpack_base64 | 37.14 | 37.04 | 1.00× |
| escaped | binary_json | 50.68 | 50.16 | 1.01× |
| escaped | binary_protobuf | 4.82 | 4.70 | 1.03× |
| escaped | msgpack_binary | 10.14 | 9.36 | 1.08× |
| escaped | msgpack_base64 | 25.43 | 24.60 | 1.03× |
| flat_records | binary_json | 45.24 | 46.23 | 0.98× |
| flat_records | binary_protobuf | 100.01 | 99.23 | 1.01× |
| flat_records | msgpack_binary | 230.12 | 181.71 | 1.27× |
| flat_records | msgpack_base64 | 248.95 | 207.35 | 1.20× |
| nested_records | binary_json | 50.88 | 51.76 | 0.98× |
| nested_records | binary_protobuf | 124.92 | 123.28 | 1.01× |
| nested_records | msgpack_binary | 245.35 | 196.17 | 1.25× |
| nested_records | msgpack_base64 | 273.76 | 225.51 | 1.21× |
| numbers | binary_json | 39.73 | 38.32 | 1.04× |
| numbers | binary_protobuf | 21.55 | 21.47 | 1.00× |
| numbers | msgpack_binary | 114.32 | 32.34 | 3.53× |
| numbers | msgpack_base64 | 121.89 | 45.62 | 2.67× |
| bytes | binary_raw | 0.54 | 0.27 | 1.95× |
| bytes | binary_json | 247.35 | 240.13 | 1.03× |
| bytes | binary_protobuf | 3.31 | 2.97 | 1.12× |
| bytes | msgpack_binary | 575.22 | 0.40 | 1438.04× |
| bytes | msgpack_base64 | 605.55 | 24.99 | 24.23× |

## Main-thread stalls

The maximum below is an individual encode+decode duration, including any GC pause inside that operation.
The separate raw browser-long-task counts cover an entire timed batch; they must not be treated as individual
message counts. Calibration and content verification are excluded from the recorded batches.

| Baseline | Content | Target MiB | Mechanism | Old max ms | New max ms | Old operations >50 ms | New operations >50 ms |
|---|---|---:|---|---:|---:|---:|---:|
| master | bytes | 4.000 | msgpack_base64 | 686.69 | 26.49 | 9 | 0 |
| master | bytes | 4.000 | msgpack_binary | 626.49 | 0.70 | 9 | 0 |
| master | bytes | 4.000 | json | 621.89 | 220.98 | 9 | 9 |
| alpha | bytes | 4.000 | json | 601.36 | 220.98 | 9 | 9 |
| master | nested_records | 4.000 | msgpack_base64 | 333.02 | 254.16 | 9 | 9 |
| master | flat_records | 4.000 | msgpack_base64 | 289.40 | 241.68 | 9 | 9 |
| master | nested_records | 4.000 | msgpack_binary | 284.22 | 227.82 | 9 | 9 |
| master | flat_records | 4.000 | msgpack_binary | 269.24 | 210.66 | 9 | 9 |
| master | bytes | 4.000 | binary_json | 246.44 | 246.39 | 9 | 9 |
| master | numbers | 4.000 | msgpack_base64 | 154.19 | 53.23 | 9 | 2 |
| master | nested_records | 4.000 | binary_protobuf | 149.92 | 150.70 | 9 | 9 |
| master | bytes | 1.000 | msgpack_binary | 146.00 | 0.27 | 9 | 0 |

## Slower cases requiring attention

This list uses a 10% median increase and a baseline of at least 20 µs to avoid emphasizing tiny absolute differences.
One run does not establish significance; raw per-round samples are available for reruns.

No cases crossed that threshold in this run.

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
node tool/run_chrome_comparison.mjs --rounds 9 --output docs/benchmarks/chrome-comparison-isolated-2026-10-03.json
node tool/summarize_chrome_comparison.mjs docs/benchmarks/chrome-comparison-isolated-2026-10-03.json
```

Raw JSON measurements are generated locally and ignored by Git. The commands above regenerate them.
Full size/content comparisons: [CSV](benchmarks/chrome-comparison.csv).
