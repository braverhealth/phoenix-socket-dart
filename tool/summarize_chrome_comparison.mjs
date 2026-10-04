import {promises as fs} from 'node:fs';
import path from 'node:path';

const input = process.argv[2];
if (!input) throw Error('Pass the completed comparison JSON file');
const data = JSON.parse(await fs.readFile(input, 'utf8'));
if (!data.complete) throw Error('Comparison is incomplete; do not publish partial results');
const root = path.resolve(path.dirname(input), '../..');
const output = process.argv[3] ?? path.join(root, 'docs/chrome-codec-comparison.md');
const key = r => [r.family, r.target_bytes, r.mode].join('/');
const newer = new Map(data.runs.filter(r => r.version === 'new').map(r => [key(r), r]));
const pairs = data.runs.filter(r => r.version !== 'new').map(old => {
  const next = newer.get(key(old));
  if (!next || old.info.fingerprint !== next.info.fingerprint || old.info.frame_bytes !== next.info.frame_bytes) {
    throw Error('Missing or unequal comparison');
  }
  return {old, next, speedup: old.summary.median_us / next.summary.median_us};
});
const fmt = n => Number(n).toFixed(2);
const mib = n => (n / 1048576).toFixed(3);
const lines = [
  '# Controlled headless Chrome codec comparison', '',
  `Run: ${data.metadata.date}. ${data.metadata.browser.product}, ${data.metadata.dart}.`, '',
  `All ${data.runs.length} version/workload measurements and ${pairs.length} old/new pairs completed.`, '',
  'Each comparable pair uses identical generated content, the same encoded frame size, the same loop count,',
  'the same compiler optimization (-O2), and alternating execution order in one isolated Chrome instance.',
  'Decoded content hashes are checked before and after measurement. There is no virtual-time budget.',
  'All codec work runs on the browser main thread. Each case uses a fresh page, the same fixed JSON adapter,',
  'and at least three warmup batches totaling 200 ms per version before nine timed batches.',
  'Background-tab throttling is disabled and the measured target is activated before each batch.', '',
  `Baselines: alpha \`${data.metadata.old_alpha}\`, master \`${data.metadata.old_master}\`.`,
  `New implementation source SHA-256: \`${data.metadata.new_source_sha256}\`.`,
  `Harness SHA-256: \`${data.metadata.harness_source_sha256}\`.`, '',
  'The benchmark uses seven content families and five target sizes: 256 B, 4 KiB, 64 KiB, 1 MiB and 4 MiB.',
  'Structured/text targets are JSON payload bytes. Byte-buffer targets are raw byte counts, so their JSON',
  'number-array representation is larger. Actual payload/frame lengths are recorded in the raw data.', '',
  '## Overview', '',
  'Speedup is old median batch time per operation divided by new. Values above 1 favor the new code.',
  'Geometric means summarize ratios across varied sizes; they are not production traffic weighting.', '',
  '| Baseline | Mechanism | Pairs | Geometric mean speedup |',
  '|---|---|---:|---:|',
];
for (const baseline of ['alpha', 'master']) {
  for (const mode of [...new Set(pairs.filter(p => p.old.version === baseline).map(p => p.old.mode))]) {
    const group = pairs.filter(p => p.old.version === baseline && p.old.mode === mode);
    const mean = Math.exp(group.reduce((s,p) => s + Math.log(p.speedup), 0) / group.length);
    lines.push(`| ${baseline} | ${mode} | ${group.length} | ${fmt(mean)}× |`);
  }
}
lines.push('', '## JSON at the largest target', '',
  '| Content | Actual JSON MiB | Alpha ms | Master ms | New ms |', '|---|---:|---:|---:|---:|');
for (const next of data.runs.filter(r => r.version === 'new' && r.mode === 'json' && r.target_bytes === 4194304)) {
  const before = data.runs.filter(r => key(r) === key(next));
  lines.push(`| ${next.family} | ${mib(next.info.json_payload_bytes)} | ${fmt(before.find(r => r.version === 'alpha').summary.median_us / 1000)} | ${fmt(before.find(r => r.version === 'master').summary.median_us / 1000)} | ${fmt(next.summary.median_us / 1000)} |`);
}
lines.push('', '## Binary and format comparisons at the largest target', '',
  '| Content | Mechanism | Master ms | New ms | Speedup |', '|---|---|---:|---:|---:|');
for (const p of pairs.filter(p => p.old.version === 'master' && p.old.mode !== 'json' && p.old.target_bytes === 4194304)) {
  lines.push(`| ${p.old.family} | ${p.old.mode} | ${fmt(p.old.summary.median_us / 1000)} | ${fmt(p.next.summary.median_us / 1000)} | ${fmt(p.speedup)}× |`);
}
lines.push('', '## Main-thread stalls', '',
  'The maximum below is an individual encode+decode duration, including any GC pause inside that operation.',
  'The separate raw browser-long-task counts cover an entire timed batch; they must not be treated as individual',
  'message counts. Calibration and content verification are excluded from the recorded batches.', '',
  '| Baseline | Content | Target MiB | Mechanism | Old max ms | New max ms | Old operations >50 ms | New operations >50 ms |',
  '|---|---|---:|---|---:|---:|---:|---:|');
for (const p of [...pairs].sort((a,b) => b.old.summary.max_operation_ms - a.old.summary.max_operation_ms).slice(0,12)) {
  lines.push(`| ${p.old.version} | ${p.old.family} | ${mib(p.old.target_bytes)} | ${p.old.mode} | ${fmt(p.old.summary.max_operation_ms)} | ${fmt(p.next.summary.max_operation_ms)} | ${p.old.summary.operations_over_50ms} | ${p.next.summary.operations_over_50ms} |`);
}
const slower = pairs.filter(p => p.old.summary.median_us >= 20 && p.speedup < 1 / 1.1);
lines.push('', '## Slower cases requiring attention', '',
  'This list uses a 10% median increase and a baseline of at least 20 µs to avoid emphasizing tiny absolute differences.',
  'One run does not establish significance; raw per-round samples are available for reruns.', '');
if (!slower.length) lines.push('No cases crossed that threshold in this run.');
else {
  lines.push('| Baseline | Content | Target bytes | Mechanism | Old µs | New µs |', '|---|---|---:|---|---:|---:|');
  for (const p of slower) lines.push(`| ${p.old.version} | ${p.old.family} | ${p.old.target_bytes} | ${p.old.mode} | ${fmt(p.old.summary.median_us)} | ${fmt(p.next.summary.median_us)} |`);
}
lines.push('', '## Interpretation and reproduction', '',
  '- Median and p95 are distributions of **batch mean time per operation**, not per-message latency percentiles.',
  '- Raw binary measures opaque-byte framing. Binary JSON and protobuf additionally parse application content.',
  '- The master protobuf adapter manually serializes on send and uses its legacy payload decoder on receive;',
  '  the new adapter uses PayloadCodec in both directions. Both use exactly the same generated protobuf schema/runtime.',
  '- Recorded protobuf timings use the benchmark payload codec. The optional protobuf convenience package',
  '  was added afterward and its overhead is not measured separately.',
  '- Original eager logging remains in both historical baselines; new lazy logging is part of the measured change.',
  '- JSON rows use the same JSON encoding and content; binary support is inactive for those rows. The JSON',
  '  optimization is lazy payload logging, not a replacement or tuning of jsonEncode/jsonDecode. This comparison',
  '  measures the complete implementations and does not isolate the contribution of each optimization.',
  '- Heap snapshots record live JavaScript heap/backing storage before, after, and after forced GC. They are not',
  '  total allocated bytes or peak memory. GC is forced before timing, not between timed rounds.',
  '- No network RTT, TLS, compression, Flutter rendering or real Braver records are included. These results isolate',
  '  the main-thread codec work that can contribute to UI stalls. Other host activity/JIT/GC can cause variance.', '',
  '```sh', 'node tool/run_chrome_comparison.mjs --rounds 9 --output docs/benchmarks/chrome-comparison-isolated-2026-10-03.json',
  'node tool/summarize_chrome_comparison.mjs docs/benchmarks/chrome-comparison-isolated-2026-10-03.json', '```', '',
  'Raw JSON measurements are generated locally and ignored by Git. The commands above regenerate them.',
  'Full size/content comparisons: [CSV](benchmarks/chrome-comparison.csv).', '');
await fs.writeFile(output, lines.join('\n'));
const columns = ['baseline','family','mode','target_bytes','json_payload_bytes','frame_bytes','iterations',
  'old_median_us','new_median_us','speedup','old_p95_batch_mean_us','new_p95_batch_mean_us','old_max_operation_ms','new_max_operation_ms'];
const csv = [columns.join(','), ...pairs.map(p => [p.old.version,p.old.family,p.old.mode,p.old.target_bytes,
  p.old.info.json_payload_bytes,p.old.info.frame_bytes,p.old.iterations,p.old.summary.median_us,p.next.summary.median_us,
  p.speedup,p.old.summary.p95_batch_mean_us,p.next.summary.p95_batch_mean_us,
  p.old.summary.max_operation_ms,p.next.summary.max_operation_ms].join(','))].join('\n') + '\n';
await fs.writeFile(path.join(path.dirname(input), 'chrome-comparison.csv'), csv);
console.log(`Wrote ${output} and ${pairs.length} CSV comparisons`);
