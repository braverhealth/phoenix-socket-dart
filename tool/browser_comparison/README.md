# Controlled Chrome comparison

This harness compiles the same workloads against pinned alpha/master snapshots
and the uncommitted implementation. Baseline library source is extracted from
Git without checking out or modifying another worktree. Separate pub resolutions
retain each baseline's dependency constraints; resolved dependency versions,
source hashes, compiler flags and browser version are recorded.

Requirements: Dart >=3.4, Node >=22 with a global WebSocket implementation, Git,
tar, Chrome and the repository's `rtk` command wrapper. There are no npm dependencies.

The runner serves only its compiled benchmark files on an OS-assigned loopback
port. Its browser profile and server are owned by this run. Original checkouts,
local development clusters, and existing browser profiles are not modified.

```sh
dart pub get # In this directory, for analysis and workload fidelity tests.
dart analyze --fatal-infos
dart test
cd ../..
node tool/run_chrome_comparison.mjs --smoke --output /tmp/phoenix-smoke.json
node tool/run_chrome_comparison.mjs --rounds 9 --output docs/benchmarks/chrome-comparison-isolated-2026-10-03.json
node tool/summarize_chrome_comparison.mjs docs/benchmarks/chrome-comparison-isolated-2026-10-03.json
```

`--chrome /path/to/chrome` overrides the executable. The runner owns a temporary
Chrome profile and an ephemeral loopback static-file server; it does not use an
existing browser session or development backend. It closes its browser/server
and removes its snapshots at completion. No virtual-time budget is used.

Each pair checks full decoded content hashes and identical wire sizes, then
uses the same iteration count and fixed JSON adapter. A fresh page and at least
200 ms of warmup isolate each workload from preceding formats and JIT history.
It alternates target order across nine measured batches. Timing uses performance.now() on the main thread;
hash verification runs outside measured batches. It records encode/decode cost,
batch averages, individual operation stalls, browser long tasks and CDP heap
snapshots. The report explains what each metric does and does not measure.

The checked-in protobuf schema models text, records with nested fields, integer
arrays and bytes. To regenerate, use protoc-gen-dart backed by protoc_plugin
21.1.2 (the existing example/protobuf package can supply that generator):

```sh
protoc --plugin=protoc-gen-dart=/path/to/wrapper --dart_out=lib/generated \
  -I protos protos/content.proto
dart format lib/generated
```
