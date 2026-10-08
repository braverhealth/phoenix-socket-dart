import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync, writeFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';

const sourceUrl = new URL('../test/reference/phoenix-1.8.15/longpoll.js', import.meta.url);
const upstreamSource = readFileSync(sourceUrl, 'utf8');
assert.equal(createHash('sha256').update(upstreamSource).digest('hex'),
  '1688d2f2776eea349f730a6a1c0dd58009af37a3c3abb3efd34ccecb2d3a9937',
  'The pinned upstream JavaScript reference was modified.');
const source = upstreamSource
  .replace(/^import[\s\S]*?from "[^"]+"\s*$/gm, '')
  .replace('export default class LongPoll', 'class LongPoll');

function harness(endpoint, authToken) {
  const timers = new Map();
  const requests = [];
  const events = [];
  let timerId = 0;
  const context = {
    SOCKET_STATES: {connecting: 0, open: 1, closing: 2, closed: 3},
    TRANSPORTS: {websocket: 'websocket', longpoll: 'longpoll'},
    AUTH_TOKEN_PREFIX: 'base64url.bearer.phx.',
    MAX_LONGPOLL_BATCH_SIZE: 100,
    Uint8Array, ArrayBuffer,
    btoa: value => Buffer.from(value, 'latin1').toString('base64'),
    atob: value => Buffer.from(value, 'base64').toString('latin1'),
    setTimeout: callback => { timers.set(++timerId, callback); return timerId; },
    clearTimeout: id => timers.delete(id),
    Ajax: {
      appendParams: (url, {token}) => `${url}${url.includes('?') ? '&' : '?'}${token === null ? '' : `token=${encodeURIComponent(token)}`}`,
      request(method, url, headers, body, timeout, ontimeout, callback) {
        const request = {method, url, headers, body, timeout, ontimeout, callback, aborted: false};
        requests.push(request);
        return {abort() { request.aborted = true; }};
      },
    },
  };
  vm.createContext(context);
  vm.runInContext(`${source}\nglobalThis.LongPoll = LongPoll`, context);
  const protocols = authToken ? ['phoenix', `base64url.bearer.phx.${Buffer.from(authToken, 'latin1').toString('base64')}`] : undefined;
  const poll = new context.LongPoll(endpoint, protocols);
  poll.timeout = 20000;
  poll.onopen = () => events.push(['open']);
  poll.onerror = error => events.push(['error', error ?? null]);
  poll.onclose = event => events.push(['close', event.code, event.reason]);
  poll.onmessage = event => events.push(['message', event.data]);
  function tick() {
    for (const [id, callback] of [...timers]) {
      if (timers.delete(id)) callback();
    }
  }
  const trace = () => requests.map(({method, url, headers, body}) => ({method, url, headers, body}));
  return {poll, requests, events, tick, trace};
}

const endpoint = 'wss://example.invalid/socket/websocket?vsn=2.0.0';
const output = {
  version: '1.8.15',
  commit: 'bd1801833b4fd7ceb02497cc7ba2d05e9bd391c8',
  endpoints: [], poll: [], batches: {},
};
for (const input of [endpoint, 'ws://localhost/socket/websocket', 'https://example.invalid/socket/longpoll?x=1', 'wss://example.invalid/a/websocket/socket/websocket?x=1']) {
  const h = harness(input);
  output.endpoints.push({input, expected: h.poll.pollEndpoint});
  h.poll.close();
}
for (const status of [403, 500, 0, 410]) {
  const h = harness(endpoint);
  h.tick();
  if (status === 410) {
    h.requests[0].callback({status: 410, token: 'original', messages: []});
    h.requests[1].callback({status: 410, token: 'replacement', messages: []});
  } else {
    h.requests[0].callback({status});
  }
  output.poll.push({status, events: h.events.map(event => [...event])});
  h.poll.close();
}
{
  const h = harness(endpoint, 'reference-token');
  h.tick();
  h.requests[0].callback({status: 410, token: 'session +/=&', messages: []});
  h.requests[1].callback({status: 204, token: 'session +/=&', messages: []});
  h.requests[2].callback({status: 200, token: 'session +/=&', messages: ['a', 'b', 'c']});
  h.tick();
  output.session = {requests: h.trace(), events: h.events.map(event => [...event])};
  h.poll.close();
}
{
  const h = harness(endpoint);
  h.tick();
  h.requests[0].callback({status: 410, token: 't', messages: []});
  for (let i = 0; i < 250; i++) h.poll.send(`m${i}`);
  h.tick();
  h.poll.send('buffered');
  h.requests.at(-1).callback({status: 200});
  h.requests.at(-1).callback({status: 200});
  h.requests.at(-1).callback({status: 200});
  h.requests.at(-1).callback({status: 200});
  output.batches.requests = h.trace().filter(r => r.method === 'POST');
  assert.deepEqual(output.batches.requests.map(r => r.body.split('\n').length), [100, 100, 50, 1]);
  h.poll.close();
}
{
  const h = harness(endpoint);
  h.tick();
  h.requests[0].callback({status: 410, token: 't', messages: []});
  h.poll.send(Uint8Array.from([0, 128, 255]).buffer);
  h.poll.send('[null,"0","audit","echo",{"unicode":"é🐦"}]');
  h.tick();
  output.binary = h.trace().at(-1);
  h.poll.close();
}
{
  const h = harness(endpoint);
  h.tick();
  h.requests[0].callback({status: 410, token: 't', messages: []});
  h.poll.send('first');
  h.tick();
  h.requests.at(-1).ontimeout();
  output.timeout = h.events.map(event => [...event]);
  h.poll.close();
}

const target = new URL('../test/fixtures/long_poll_reference.dart', import.meta.url);
const text = `// Generated by tool/long_poll_reference.mjs from Phoenix v1.8.15.\n// Do not edit expectations manually.\nconst phoenixLongPollReferenceJson = r'''\n${JSON.stringify(output, null, 2)}\n''';\n`;
if (process.argv.includes('--check')) {
  assert.equal(readFileSync(target, 'utf8'), text, 'Reference fixtures are stale. Regenerate them.');
} else {
  writeFileSync(target, text);
}
console.log(`Phoenix v1.8.15 reference verified: ${fileURLToPath(target)}`);
