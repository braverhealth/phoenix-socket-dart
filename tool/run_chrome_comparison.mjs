import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {promises as fs} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const option = (name, fallback) => args.includes(name) ? args[args.indexOf(name) + 1] : fallback;
const smoke = args.includes('--smoke');
const rounds = Number(option('--rounds', smoke ? '3' : '9'));
if (!Number.isInteger(rounds) || rounds < 3 || rounds > 31) throw Error('Rounds must be 3..31');
const output = path.resolve(option('--output', path.join(root, 'docs/benchmarks/chrome-comparison.json')));
const dart = option('--dart', 'dart');
const chrome = option('--chrome', process.env.CHROME_EXECUTABLE ?? (process.platform === 'darwin'
  ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' : '/usr/bin/google-chrome'));
const temp = await fs.mkdtemp(path.join(os.tmpdir(), 'phoenix-chrome-comparison-'));
const versions = [
  {name: 'alpha', revision: '86d4f1175345d082f67a9f571adb857d9080785a'},
  {name: 'master', revision: '6dc4b429f6bafda907af8a5da94dafa055c2c06f'},
  {name: 'new', revision: 'worktree'},
];
const families = smoke ? ['ascii', 'nested_records', 'bytes']
  : ['ascii', 'unicode', 'escaped', 'flat_records', 'nested_records', 'numbers', 'bytes'];
const sizes = smoke ? [4096] : [256, 4096, 65536, 1048576, 4194304];
const modes = ['json', 'binary_raw', 'binary_json', 'binary_protobuf', 'msgpack_binary', 'msgpack_base64'];
const runs = [];
let browser, browserExited, server, cdp;

async function sourceHash(directories) {
  const hash = (await import('node:crypto')).createHash('sha256');
  async function walk(directory, prefix) {
    for (const entry of (await fs.readdir(directory, {withFileTypes: true})).sort((a,b) => a.name.localeCompare(b.name))) {
      const relative = prefix + '/' + entry.name;
      if (entry.isDirectory()) await walk(path.join(directory, entry.name), relative);
      else { hash.update(relative); hash.update(await fs.readFile(path.join(directory, entry.name))); }
    }
  }
  for (let i = 0; i < directories.length; i++) await walk(directories[i], String(i));
  return hash.digest('hex');
}

async function command(command, commandArgs, cwd = root, includeStderr = false) {
  return new Promise((resolve, reject) => {
    const child = spawn('rtk', [command, ...commandArgs], {cwd, stdio: ['ignore', 'pipe', 'pipe']});
    let stdout = '', stderr = '';
    child.stdout.on('data', chunk => stdout += chunk);
    child.stderr.on('data', chunk => stderr += chunk);
    child.on('error', reject);
    child.on('exit', code => code === 0 ? resolve((stdout + (includeStderr ? stderr : '')).trim())
      : reject(Error(`${command} failed (${code}): ${stderr || stdout}`)));
  });
}

async function dartVersion(cwd = root) {
  const output = await command(dart, ['--version'], cwd, true);
  const match = output.match(/Dart SDK version:[^\r\n]+/);
  if (!match) throw Error(`Dart did not report a compiler version: ${output}`);
  return match[0];
}

class CDP {
  constructor(ws) {
    this.ws = ws; this.id = 0; this.pending = new Map();
    ws.addEventListener('message', event => {
      const response = JSON.parse(event.data);
      if (!response.id) return;
      const request = this.pending.get(response.id);
      if (!request) return;
      this.pending.delete(response.id); clearTimeout(request.timer);
      response.error ? request.reject(Error(JSON.stringify(response.error))) : request.resolve(response.result);
    });
    ws.addEventListener('close', () => {
      for (const request of this.pending.values()) {
        clearTimeout(request.timer); request.reject(Error('Chrome connection closed'));
      }
      this.pending.clear();
    });
  }
  static async connect(url) {
    const ws = new WebSocket(url);
    await new Promise((resolve, reject) => {
      ws.addEventListener('open', resolve, {once: true});
      ws.addEventListener('error', reject, {once: true});
    });
    return new CDP(ws);
  }
  call(method, params = {}, sessionId) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(Error(`${method} timed out`)); }, 120000);
      this.pending.set(id, {resolve, reject, timer});
      this.ws.send(JSON.stringify({id, method, params, ...(sessionId ? {sessionId} : {})}));
    });
  }
}

const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function evaluate(version, expression) {
  const result = await cdp.call('Runtime.evaluate', {expression, returnByValue: true, awaitPromise: true}, version.session);
  if (result.exceptionDetails) throw Error(`${version.name}: ${JSON.stringify(result.exceptionDetails)}`);
  return result.result.value;
}
async function heap(version) { return cdp.call('Runtime.getHeapUsage', {}, version.session); }
const median = values => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];
const percentile = (values, p) => [...values].sort((a, b) => a - b)[Math.ceil(values.length * p) - 1];

try {
  console.log('Preparing pinned source snapshots and identical benchmark programs');
  await fs.cp(path.join(root, 'packages/phoenix_socket_msgpack'), path.join(temp, 'msgpack'),
    {recursive: true, filter: source => !source.includes('.dart_tool') && !source.endsWith('pubspec.lock')});
  for (const version of versions) {
    const snapshot = path.join(temp, version.name, 'socket');
    const program = path.join(temp, version.name, 'benchmark');
    await fs.mkdir(snapshot, {recursive: true});
    if (version.name === 'new') {
      const core = path.join(root, 'packages/phoenix_socket');
      await fs.cp(path.join(core, 'lib'), path.join(snapshot, 'lib'), {recursive: true});
      await fs.copyFile(path.join(core, 'pubspec.yaml'), path.join(snapshot, 'pubspec.yaml'));
    } else {
      const archive = path.join(temp, `${version.name}.tar`);
      await command('git', ['archive', version.revision, 'lib', 'pubspec.yaml', '--output=' + archive]);
      await command('tar', ['-xf', archive, '-C', snapshot]);
    }
    await fs.cp(path.join(root, 'tool/browser_comparison'), program,
      {recursive: true, filter: source => !source.includes('.dart_tool') && !source.endsWith('pubspec.lock')});
    await fs.writeFile(path.join(program, 'pubspec_overrides.yaml'),
      `dependency_overrides:\n  phoenix_socket:\n    path: ${snapshot}\n  phoenix_socket_msgpack:\n    path: ${path.join(temp, 'msgpack')}\n`);
    await fs.writeFile(path.join(program, 'lib/active_adapter.dart'), `export 'adapter_${version.name}.dart';\n`);
    // Legacy adapters are compiled only against their own snapshot.
    for (const other of versions.filter(other => other.name !== version.name)) {
      await fs.rm(path.join(program, `lib/adapter_${other.name}.dart`));
    }
    await command(dart, ['pub', 'get'], program);
    version.dartCompiler = await dartVersion(program);
    await command(dart, ['compile', 'js', '-O2', 'lib/runner.dart', '-o', path.join(temp, `${version.name}.js`)], program);
    version.compiledBytes = (await fs.stat(path.join(temp, `${version.name}.js`))).size;
    version.resolvedPackages = (JSON.parse(await fs.readFile(path.join(program, '.dart_tool/package_config.json'), 'utf8')))
      .packages.filter(p => ['logging', 'rxdart', 'protobuf', 'msgpack_dart', 'web_socket_channel'].includes(p.name))
      .map(p => ({name:p.name, location:p.rootUri.split('/').at(-1) || p.rootUri.split('/').at(-2)}));
    console.log(`Compiled ${version.name} (${version.revision})`);
  }
  if (new Set(versions.map(v => v.dartCompiler)).size !== 1) {
    throw Error(`Compiler versions differ: ${JSON.stringify(versions.map(v => ({name:v.name, dart:v.dartCompiler})))}`);
  }
  server = createServer(async (request, response) => {
    response.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
    response.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
    response.setHeader('Cache-Control', 'no-store');
    const name = request.url.slice(1).split('.')[0];
    if (!versions.some(version => version.name === name)) { response.writeHead(404).end(); return; }
    if (request.url.endsWith('.js')) {
      response.setHeader('Content-Type', 'application/javascript');
      response.end(await fs.readFile(path.join(temp, `${name}.js`)));
    } else {
      response.setHeader('Content-Type', 'text/html');
      response.end(`<!doctype html><title>${name}</title><script>
        window.caseToken = ${JSON.stringify(request.url)};
        window.longTasks = [];
        if (PerformanceObserver.supportedEntryTypes.includes('longtask')) {
          new PerformanceObserver(list => window.longTasks.push(...list.getEntries().map(e => ({start:e.startTime,duration:e.duration}))))
            .observe({type:'longtask',buffered:true});
        }
        window.measuredBatch = n => new Promise(resolve => setTimeout(() => {
          const start = performance.now();
          const data = JSON.parse(measureCase(n));
          const end = performance.now();
          setTimeout(() => resolve({...data, browser_task_start:start, browser_task_end:end,
            long_tasks:window.longTasks.filter(e => e.start >= start - 2 && e.start <= end).map(e => e.duration)}), 0);
        }, 0));
        </script><script src="/${name}.js"></script>`);
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const profile = path.join(temp, 'chrome-profile');
  browser = spawn('rtk', [chrome, '--headless=new', '--remote-debugging-port=0', '--no-first-run',
    '--disable-background-networking', '--disable-component-update', '--disable-sync',
    '--disable-background-timer-throttling', '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows',
    '--enable-precise-memory-info', `--user-data-dir=${profile}`, 'about:blank'],
    {detached: true, stdio: 'ignore'});
  browser.on('error', error => console.error(error));
  browserExited = new Promise(resolve => browser.once('exit', resolve));
  let debug;
  const deadline = Date.now() + 30000;
  while (!debug) {
    try { debug = (await fs.readFile(path.join(profile, 'DevToolsActivePort'), 'utf8')).trim().split('\n'); }
    catch { if (Date.now() > deadline) throw Error('Chrome did not start'); await delay(100); }
  }
  cdp = await CDP.connect(`ws://127.0.0.1:${debug[0]}${debug[1]}`);
  const browserVersion = await cdp.call('Browser.getVersion');
  for (const version of versions) {
    const target = await cdp.call('Target.createTarget', {url: 'about:blank'});
    const attached = await cdp.call('Target.attachToTarget', {targetId: target.targetId, flatten: true});
    version.session = attached.sessionId;
    version.target = target.targetId;
    await cdp.call('Page.enable', {}, version.session);
    await cdp.call('Runtime.enable', {}, version.session);
    await cdp.call('Page.navigate', {url: `http://127.0.0.1:${server.address().port}/${version.name}.html`}, version.session);
    let ready = false;
    for (let i = 0; i < 100 && !ready; i++) {
      ready = await evaluate(version, 'typeof prepareCase === "function"');
      if (!ready) await delay(50);
    }
    if (!ready) throw Error(`${version.name} bundle did not initialize`);
  }
  const metadata = {date: new Date().toISOString(), browser: browserVersion,
    dart: versions[0].dartCompiler, optimization: '-O2', rounds,
    warmup_min_batches: 3, warmup_min_ms: 200, fresh_page_per_case: true,
    target_batch_ms: 20, virtual_time: false,
    cross_origin_isolated: await evaluate(versions[0], 'crossOriginIsolated'),
    old_alpha: versions[0].revision, old_master: versions[1].revision,
    new_base: await command('git', ['rev-parse', 'HEAD']),
    new_source_sha256: await sourceHash([path.join(temp, 'new/socket/lib'), path.join(temp, 'msgpack/lib')]),
    harness_source_sha256: await sourceHash([path.join(root, 'tool/browser_comparison/lib')]),
    resolved_packages: Object.fromEntries(versions.map(v => [v.name, v.resolvedPackages])),
    compiled_js_bytes: Object.fromEntries(versions.map(v => [v.name, v.compiledBytes])),
    note: 'Codec encode + decode on main thread; no network/TLS or application rendering.'};
  for (const family of families) {
    for (const size of sizes) {
      for (const mode of modes) {
        if (mode === 'binary_raw' && family !== 'bytes') continue;
        const supported = mode === 'json' ? versions : versions.slice(1);
        const measurements = new Map();
        let slowest = 0;
        for (const version of supported) {
          const pagePath = `/${version.name}.html?case=${family}-${size}-${mode}`;
          await cdp.call('Page.navigate', {url: `http://127.0.0.1:${server.address().port}${pagePath}`}, version.session);
          let ready = false;
          for (let attempt = 0; attempt < 200 && !ready; attempt++) {
            ready = await evaluate(version, `typeof prepareCase === "function" && window.caseToken === ${JSON.stringify(pagePath)}`).catch(() => false);
            if (!ready) await delay(10);
          }
          if (!ready) throw Error('Fresh benchmark page did not initialize');
          const config = JSON.stringify({family, size, mode});
          const info = JSON.parse(await evaluate(version, `prepareCase(${JSON.stringify(config)})`));
          await cdp.call('HeapProfiler.collectGarbage', {}, version.session);
          let n = 1, calibration;
          do {
            calibration = await evaluate(version, `measuredBatch(${n})`);
            if (calibration.elapsed_ms >= 10 || n >= 8192) break;
            n *= 2;
          } while (true);
          slowest = Math.max(slowest, calibration.mean_us);
          measurements.set(version.name, {info, samples: [], warmup_batches: 0, warmup_ms: 0});
        }
        const infos = [...measurements.values()].map(v => v.info);
        if (new Set(infos.map(v => v.fingerprint)).size !== 1 ||
            new Set(infos.map(v => v.frame_bytes)).size !== 1) throw Error(`Non-equivalent ${family}/${size}/${mode}`);
        const iterations = Math.max(1, Math.min(8192, Math.floor(20000 / slowest)));
        for (const version of supported) {
          const measurement = measurements.get(version.name);
          await cdp.call('Target.activateTarget', {targetId: version.target});
          while (measurement.warmup_batches < 3 || measurement.warmup_ms < 200) {
            const sample = await evaluate(version, `measuredBatch(${iterations})`);
            measurement.warmup_ms += sample.elapsed_ms;
            measurement.warmup_batches++;
          }
        }
        for (let round = 0; round < rounds; round++) {
          const order = round % 2 === 0 ? supported : [...supported].reverse();
          for (const version of order) {
            await cdp.call('Target.activateTarget', {targetId: version.target});
            const measurement = measurements.get(version.name);
            if (round === 0) {
              await cdp.call('HeapProfiler.collectGarbage', {}, version.session);
              measurement.heap_before = await heap(version);
            }
            const sample = await evaluate(version, `measuredBatch(${iterations})`);
            if (round >= 0) measurement.samples.push(sample);
          }
        }
        for (const version of supported) {
          const measurement = measurements.get(version.name);
          measurement.heap_after = await heap(version);
          await cdp.call('HeapProfiler.collectGarbage', {}, version.session);
          measurement.heap_after_gc = await heap(version);
          if (!await evaluate(version, 'verifyCase()')) throw Error('Measured decoded content differs');
          const means = measurement.samples.map(v => v.mean_us);
          runs.push({version: version.name, family, mode, target_bytes: size, iterations,
            ...measurement, summary: {median_us: median(means), p95_batch_mean_us: percentile(means, .95),
              max_operation_ms: Math.max(...measurement.samples.map(v => v.max_operation_ms)),
              operations_over_16ms: measurement.samples.reduce((s,v) => s + v.operations_over_16ms, 0),
              operations_over_50ms: measurement.samples.reduce((s,v) => s + v.operations_over_50ms, 0),
              browser_long_tasks: measurement.samples.reduce((s,v) => s + v.long_tasks.length, 0),
              max_browser_long_task_ms: Math.max(0, ...measurement.samples.flatMap(v => v.long_tasks)),
              encode_median_us: median(measurement.samples.map(v => v.encode_us)),
              decode_median_us: median(measurement.samples.map(v => v.decode_us))}});
        }
        await fs.mkdir(path.dirname(output), {recursive: true});
        await fs.writeFile(output, JSON.stringify({metadata, complete: false, runs}, null, 2) + '\n');
        console.log(`${family} ${size} ${mode}: ` + supported.map(v =>
          `${v.name}=${runs.findLast(r => r.version === v.name).summary.median_us.toFixed(2)}us`).join(' '));
      }
    }
  }
  await fs.writeFile(output, JSON.stringify({metadata, complete: true, runs}, null, 2) + '\n');
  console.log(`Saved ${runs.length} measurements to ${output}`);
} finally {
  if (cdp) {
    await cdp.call('Browser.close').catch(() => {});
    cdp.ws.close();
  }
  if (browser) { try { process.kill(-browser.pid, 'SIGTERM'); } catch {} }
  if (browserExited) await Promise.race([browserExited, delay(5000)]);
  if (server) await new Promise(resolve => server.close(resolve));
  await fs.rm(temp, {recursive: true, force: true, maxRetries: 5, retryDelay: 300});
}
