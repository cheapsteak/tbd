// Tests host.ts, the bundle's contract with the loader: what the runner hands the bundle
// (`phone/loader/runner.js`), what AppFrame posts to the app and accepts from it
// (`phone/loader/frame.js`), and that nothing else crosses the port either way.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { appPortMessage } from '../../loader/frame.js';
import { decodeLoaderMessage, HostLink, readHost } from './host.ts';
import type { HostHandlers } from './host.ts';
import type { HostEnv } from './env.ts';

const ENV: HostEnv = {
  safeArea: { top: 0, right: 0, bottom: 34, left: 0 },
  viewport: { width: 390, height: 844, offsetTop: 0, offsetLeft: 0, scale: 1 },
  layout: { width: 390, height: 844 },
  colorScheme: 'light',
};

const NOOP: HostHandlers = { onApp() {}, onChannel() {}, onEnv() {}, onSendFailed() {} };

interface FakePort {
  started: boolean;
  posted: unknown[];
  calls: string[];
  postMessage(message: unknown): void;
  start(): void;
  addEventListener(type: string, listener: (event: { data: unknown }) => void): void;
  emit(data: unknown): void;
}

/** A port that records what the link does with it, and delivers `emit`ted data to its listeners. */
function fakePort(): FakePort {
  const listeners: Array<(event: { data: unknown }) => void> = [];
  return {
    started: false,
    posted: [],
    calls: [],
    postMessage(message) { this.calls.push('postMessage'); this.posted.push(message); },
    start() { this.calls.push('start'); this.started = true; },
    addEventListener(type, listener) { this.calls.push(`addEventListener:${type}`); listeners.push(listener); },
    emit(data) { for (const listener of listeners) listener({ data }); },
  };
}

function asPort(port: object): MessagePort {
  return port as unknown as MessagePort;
}

/** Handlers that record each call as `[name, argument]`. */
function recorder(): { calls: Array<[string, unknown]>; handlers: HostHandlers } {
  const calls: Array<[string, unknown]> = [];
  return {
    calls,
    handlers: {
      onApp(body) { calls.push(['app', body]); },
      onChannel(up) { calls.push(['channel', up]); },
      onEnv(env) { calls.push(['env', env]); },
      onSendFailed(reason) { calls.push(['sendFailed', reason]); },
    },
  };
}

class Point { x = 1; }

// --- decodeLoaderMessage -----------------------------------------------------------------------

test('decodes the four loader messages', () => {
  assert.deepEqual(decodeLoaderMessage({ t: 'app', body: { kind: 'event' } }), { t: 'app', body: { kind: 'event' } });
  assert.deepEqual(decodeLoaderMessage({ t: 'channel', state: 'up' }), { t: 'channel', up: true });
  assert.deepEqual(decodeLoaderMessage({ t: 'channel', state: 'down' }), { t: 'channel', up: false });
  assert.equal(decodeLoaderMessage({ t: 'env', ...ENV })?.t, 'env');
  assert.deepEqual(decodeLoaderMessage({ t: 'sendFailed', reason: 'tooLarge' }), { t: 'sendFailed', reason: 'tooLarge' });
  assert.deepEqual(decodeLoaderMessage({ t: 'sendFailed', reason: 'offline' }), { t: 'sendFailed', reason: 'offline' });
});

test("ignores the runner's own messages and malformed ones", () => {
  for (const m of [{ t: 'started' }, { t: 'fault', reason: 'hash' }, { t: 'channel', state: 'maybe' },
    { t: 'app', body: [] }, { t: 'sendFailed' }, { t: 'env', safeArea: {} }, null, 'app'])
    assert.equal(decodeLoaderMessage(m), null);
});

test('an env message is rebuilt with only its known fields', () => {
  const decoded = decodeLoaderMessage({
    t: 'env',
    safeArea: { ...ENV.safeArea, extra: 1 },
    viewport: { ...ENV.viewport, extra: 1 },
    layout: { ...ENV.layout, extra: 1 },
    colorScheme: 'light',
    extra: 1,
  });
  assert.deepEqual(decoded, { t: 'env', env: ENV });
});

test('an env message with any field missing, not a finite number, or of the wrong kind is ignored', () => {
  const groups = { safeArea: ENV.safeArea, viewport: ENV.viewport, layout: ENV.layout } as const;
  let cases = 0;
  for (const [group, fields] of Object.entries(groups)) {
    for (const field of Object.keys(fields)) {
      for (const bad of [undefined, Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY, '1', null, true, 1n]) {
        const copy: Record<string, unknown> = { ...fields };
        if (bad === undefined) delete copy[field]; else copy[field] = bad;
        assert.equal(decodeLoaderMessage({ t: 'env', ...ENV, [group]: copy }), null, `${group}.${field} = ${String(bad)}`);
        cases++;
      }
    }
  }
  assert.equal(cases, 11 * 8, 'every field of the three rectangles is tried');
  for (const group of Object.keys(groups)) {
    for (const bad of [undefined, null, [], 'x', new Point(), Object.create({ top: 0, right: 0, bottom: 0, left: 0 })]) {
      assert.equal(decodeLoaderMessage({ t: 'env', ...ENV, [group]: bad }), null, `${group} = ${String(bad)}`);
    }
  }
  for (const scheme of [undefined, 'Dark', 'auto', '', null, 1]) {
    assert.equal(decodeLoaderMessage({ t: 'env', ...ENV, colorScheme: scheme }), null, `colorScheme = ${String(scheme)}`);
  }
  assert.equal(decodeLoaderMessage({ t: 'env', ...ENV, colorScheme: 'dark' })?.t, 'env');
});

test('an env reaches the app as fresh objects, not the ones the message carried', () => {
  const message = { t: 'env', ...ENV };
  const decoded = decodeLoaderMessage(message);
  if (decoded?.t !== 'env') throw new Error('the env message did not decode');
  assert.notEqual(decoded.env.safeArea, message.safeArea);
  assert.notEqual(decoded.env.viewport, message.viewport);
  assert.notEqual(decoded.env.layout, message.layout);
});

test('an app body must be a plain record', () => {
  for (const body of [[], null, undefined, 'x', 1, new Date(0), new Map(), new Point(), Object.create({ kind: 'event' })]) {
    assert.equal(decodeLoaderMessage({ t: 'app', body }), null, String(body));
  }
  const bare = Object.assign(Object.create(null) as Record<string, unknown>, { kind: 'event' });
  assert.deepEqual(decodeLoaderMessage({ t: 'app', body: bare }), { t: 'app', body: bare });
});

test('the other messages are rebuilt with only their known fields', () => {
  assert.deepEqual(decodeLoaderMessage({ t: 'channel', state: 'up', up: false, extra: 1 }), { t: 'channel', up: true });
  assert.deepEqual(decodeLoaderMessage({ t: 'sendFailed', reason: 'offline', requestID: 'r1' }), { t: 'sendFailed', reason: 'offline' });
  const decoded = decodeLoaderMessage({ t: 'app', body: { kind: 'event' }, extra: 1 });
  assert.deepEqual(decoded, { t: 'app', body: { kind: 'event' } });
});

test('a message that is not a plain record is ignored, whatever it carries', () => {
  assert.equal(decodeLoaderMessage(Object.assign([], { t: 'channel', state: 'up' })), null);
  assert.equal(decodeLoaderMessage(Object.create({ t: 'channel', state: 'up' })), null);
  assert.equal(decodeLoaderMessage(Object.assign(new Point(), { t: 'channel', state: 'up' })), null);
  for (const m of [undefined, 1, true, 'channel', { t: 'openLink', url: 'https://acme.example/' }, { t: 'app' }, {}])
    assert.equal(decodeLoaderMessage(m), null, JSON.stringify(m) ?? String(m));
});

// --- HostLink ----------------------------------------------------------------------------------

test('starts the port and posts in the shapes the loader accepts', () => {
  const port = fakePort(); const link = new HostLink(asPort(port), NOOP);
  link.postApp({ a: 1 }); link.openLink('https://acme.example/x');
  assert.equal(port.started, true);
  assert.deepEqual(port.posted, [{ t: 'app', body: { a: 1 } }, { t: 'openLink', url: 'https://acme.example/x' }]);
});

test('the constructor listens and then starts the port, before it returns, and posts nothing', () => {
  const port = fakePort();
  new HostLink(asPort(port), NOOP);
  assert.deepEqual(port.calls, ['addEventListener:message', 'start']);
  assert.deepEqual(port.posted, []);
});

test("what the link posts is what the loader's appPortMessage accepts, unchanged", () => {
  const port = fakePort(); const link = new HostLink(asPort(port), NOOP);
  link.postApp({ kind: 'request', requestID: 'r1', method: 'sessions.subscribe', params: {} });
  link.openLink('https://acme.example/docs?q=1#top');
  assert.equal(port.posted.length, 2);
  for (const message of port.posted) assert.deepEqual(appPortMessage(message), message);
});

test('each decoded message reaches its handler, and nothing else does', () => {
  const port = fakePort(); const { calls, handlers } = recorder();
  new HostLink(asPort(port), handlers);
  port.emit({ t: 'started' });
  port.emit({ t: 'fault', reason: 'script' });
  port.emit({ t: 'channel', state: 'maybe' });
  port.emit({ t: 'app', body: [] });
  port.emit(null);
  port.emit({ t: 'app', body: { kind: 'event' } });
  port.emit({ t: 'channel', state: 'up' });
  port.emit({ t: 'env', ...ENV, extra: 1 });
  port.emit({ t: 'sendFailed', reason: 'tooLarge' });
  port.emit({ t: 'channel', state: 'down' });
  assert.deepEqual(calls, [
    ['app', { kind: 'event' }],
    ['channel', true],
    ['env', ENV],
    ['sendFailed', 'tooLarge'],
    ['channel', false],
  ]);
  assert.deepEqual(port.posted, [], 'the link never answers the loader by itself');
});

test('messages the loader posted before the bundle ran reach the app once the link starts the port', { timeout: 5_000 }, async () => {
  const { port1: loader, port2: app } = new MessageChannel();
  try {
    loader.postMessage({ t: 'started' });
    loader.postMessage({ t: 'channel', state: 'up' });
    loader.postMessage({ t: 'env', ...ENV });
    loader.postMessage({ t: 'app', body: { kind: 'event', seq: 1 } });
    const received: unknown[] = [];
    const loaderGotReply = new Promise<void>((resolve) => {
      loader.addEventListener('message', (event: MessageEvent) => { received.push(event.data); resolve(); });
      loader.start();
    });
    const { calls, handlers } = recorder();
    // A port delivers in order, so once the app body (posted last) arrives, the rest has too.
    const appGotBody = new Promise<void>((resolve) => {
      const onApp = handlers.onApp;
      handlers.onApp = (body) => { onApp(body); resolve(); };
    });
    const link = new HostLink(app, handlers);
    link.postApp({ kind: 'request', requestID: 'r1', method: 'sessions.subscribe', params: {} });
    await Promise.all([loaderGotReply, appGotBody]);
    assert.deepEqual(calls, [['channel', true], ['env', ENV], ['app', { kind: 'event', seq: 1 }]]);
    assert.deepEqual(received, [{ t: 'app', body: { kind: 'request', requestID: 'r1', method: 'sessions.subscribe', params: {} } }]);
  } finally {
    loader.close();
    app.close();
  }
});

// --- readHost ----------------------------------------------------------------------------------

test('readHost refuses a missing host and another protocol', () => {
  assert.throws(() => readHost({}), /protocol 1/);
  assert.throws(() => readHost({ tbdHost: { port: {}, protocol: 2 } }), /protocol 1/);
});

test('readHost refuses every host but a protocol 1 one with a port, with the one message', () => {
  const port = fakePort();
  const message = { message: 'TBD phone app: no tbdHost with protocol 1' };
  for (const tbdHost of [undefined, null, 1, 'host', {}, { protocol: 1 }, { port, protocol: '1' }, { port, protocol: 2 },
    { port: null, protocol: 1 }, { port: {}, protocol: 1 }, { port: 'port', protocol: 1 },
    { port: { ...port, start: undefined }, protocol: 1 },
    { port: { ...port, postMessage: undefined }, protocol: 1 },
    { port: { ...port, addEventListener: undefined }, protocol: 1 }]) {
    assert.throws(() => readHost({ tbdHost }), message, JSON.stringify(tbdHost) ?? String(tbdHost));
  }
  assert.throws(() => readHost(globalThis), message, 'Node has no tbdHost');
});

test("readHost takes the runner's frozen, non-writable host", () => {
  const port = fakePort();
  const g = {};
  Object.defineProperty(g, 'tbdHost', {
    value: Object.freeze({ port, protocol: 1 }), writable: false, configurable: false, enumerable: false,
  });
  const host = readHost(g);
  assert.equal(host.port, port);
  assert.equal(host.protocol, 1);
  assert.deepEqual(Object.keys(host).sort(), ['port', 'protocol']);
});

test('readHost takes a real MessagePort', () => {
  const { port1, port2 } = new MessageChannel();
  try {
    assert.equal(readHost({ tbdHost: { port: port2, protocol: 1 } }).port, port2);
  } finally {
    port1.close();
  }
});
