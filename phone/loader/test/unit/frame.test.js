import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  AppFrame, FRAME_SANDBOX, isRunnerReady, frameInsets, openableURL, appPortMessage,
} from '../../frame.js';
import { RUNNER_START_TIMEOUT_MS } from '../../constants.js';
import { FakeDocument } from '../support/fake-dom.js';

test('isRunnerReady', () => {
  const w = {};
  const ok = { source: w, origin: 'null', data: { type: 'ready', nonce: 'n1' } };
  assert.equal(isRunnerReady(ok, { frameWindow: w, nonce: 'n1', loadCount: 0, started: false }), true);
  assert.equal(isRunnerReady(ok, { frameWindow: w, nonce: 'n1', loadCount: 1, started: false }), true);
  assert.equal(isRunnerReady(ok, { frameWindow: w, nonce: 'n1', loadCount: 2, started: false }), false);
  assert.equal(isRunnerReady(ok, { frameWindow: w, nonce: 'n1', loadCount: 1, started: true }), false);
  assert.equal(isRunnerReady({ ...ok, source: {} }, { frameWindow: w, nonce: 'n1', loadCount: 1, started: false }), false);
  assert.equal(isRunnerReady({ ...ok, data: { type: 'ready', nonce: 'n2' } }, { frameWindow: w, nonce: 'n1', loadCount: 1, started: false }), false);
});

test('isRunnerReady refuses a ready from any origin but the opaque one', () => {
  const w = {};
  const state = { frameWindow: w, nonce: 'n1', loadCount: 0, started: false };
  // A frame that loaded without its sandbox posts with a real origin.
  for (const origin of ['https://acme.example', 'https://loader-origin.invalid', '', undefined, null]) {
    assert.equal(isRunnerReady({ source: w, origin, data: { type: 'ready', nonce: 'n1' } }, state), false, String(origin));
  }
});

test('isRunnerReady refuses a missing frame window, a malformed message and an empty nonce', () => {
  const w = {};
  const state = { frameWindow: w, nonce: 'n1', loadCount: 0, started: false };
  // A frame that has no window yet must not match a message with no source.
  assert.equal(isRunnerReady({ source: null, origin: 'null', data: { type: 'ready', nonce: 'n1' } }, { ...state, frameWindow: null }), false);
  for (const data of [null, undefined, 'ready', ['ready', 'n1'], { type: 'bundle', nonce: 'n1' }, { nonce: 'n1' }, { type: 'ready' }]) {
    assert.equal(isRunnerReady({ source: w, origin: 'null', data }, state), false, JSON.stringify(data));
  }
  assert.equal(isRunnerReady({ source: w, origin: 'null', data: { type: 'ready', nonce: '' } }, { ...state, nonce: '' }), false);
});

test('frameInsets pads only where the frame meets an inset', () => {
  const insets = { top: 47, right: 0, bottom: 34, left: 0 }, layout = { width: 390, height: 844 };
  assert.deepEqual(frameInsets(insets, { top: 91, bottom: 844, left: 0, right: 390 }, layout), { top: 0, right: 0, bottom: 34, left: 0 });
  assert.deepEqual(frameInsets(insets, { top: 0, bottom: 800, left: 0, right: 390 }, layout), { top: 47, right: 0, bottom: 0, left: 0 });
});

test('frameInsets cuts the side insets in landscape', () => {
  const insets = { top: 0, right: 47, bottom: 21, left: 47 }, layout = { width: 844, height: 390 };
  assert.deepEqual(frameInsets(insets, { top: 44, bottom: 390, left: 0, right: 844 }, layout), { top: 0, right: 47, bottom: 21, left: 47 });
  assert.deepEqual(frameInsets(insets, { top: 44, bottom: 390, left: 20, right: 800 }, layout), { top: 0, right: 3, bottom: 21, left: 27 });
});

test('openableURL', () => {
  assert.equal(openableURL('https://acme.example/x'), 'https://acme.example/x');
  assert.equal(openableURL('http://acme.example/'), 'http://acme.example/');
  for (const bad of ['javascript:alert(1)', 'data:text/html,x', 'blob:null/1', 'x', 'https://a.example/' + 'a'.repeat(2049)])
    assert.equal(openableURL(bad), null);
});

test('openableURL normalizes, and refuses credentials, relative URLs and non-strings', () => {
  assert.equal(openableURL('HTTPS://Acme.Example'), 'https://acme.example/');
  assert.equal(openableURL('https://acme.example/a b'), 'https://acme.example/a%20b');
  for (const bad of [
    'https://user@acme.example/', 'https://user:pass@acme.example/', 'https://:pass@acme.example/',
    '/relative', '//acme.example/x', 'ftp://acme.example/', 'file:///etc/hosts', 'about:blank', '',
  ]) {
    assert.equal(openableURL(bad), null, bad);
  }
  for (const bad of [null, undefined, 42, {}, ['https://acme.example/'], new URL('https://acme.example/')]) {
    assert.equal(openableURL(bad), null);
  }
});

test('openableURL allows exactly 2,048 characters, before and after normalizing', () => {
  const prefix = 'https://acme.example/';
  const max = prefix + 'a'.repeat(2048 - prefix.length);
  assert.equal(max.length, 2048);
  assert.equal(openableURL(max), max);
  assert.equal(openableURL(max + 'a'), null);
  // Short enough as typed, too long once the space is percent-encoded.
  const grows = prefix + ' ' + 'a'.repeat(2048 - prefix.length - 1);
  assert.equal(grows.length, 2048);
  assert.equal(openableURL(grows), null);
});

test('appPortMessage', () => {
  assert.deepEqual(appPortMessage({ t: 'app', body: {} }), { t: 'app', body: {} });
  assert.deepEqual(appPortMessage({ t: 'app', body: { method: 'sessions.subscribe' } }), { t: 'app', body: { method: 'sessions.subscribe' } });
  for (const body of [[], null, undefined, 'x', 1, true]) {
    assert.equal(appPortMessage({ t: 'app', body }), null, String(body));
  }
  assert.equal(appPortMessage({ t: 'app' }), null);
  assert.deepEqual(appPortMessage({ t: 'openLink', url: 'https://acme.example/' }), { t: 'openLink', url: 'https://acme.example/' });
  // The url is only checked for type here; openableURL decides what opens.
  assert.deepEqual(appPortMessage({ t: 'openLink', url: 'javascript:x' }), { t: 'openLink', url: 'javascript:x' });
  for (const url of [undefined, null, 1, {}, ['https://acme.example/']]) {
    assert.equal(appPortMessage({ t: 'openLink', url }), null);
  }
  for (const data of [{ t: 'other' }, { t: 'started' }, { t: 'fault', reason: 'hash' }, {}, null, undefined, 'app', ['app', {}]]) {
    assert.equal(appPortMessage(data), null, JSON.stringify(data));
  }
});

test('appPortMessage takes only a plain object as an app body', () => {
  const bare = Object.create(null);
  bare.a = 1;
  assert.deepEqual(appPortMessage({ t: 'app', body: bare }), { t: 'app', body: bare });
  class Body { a = 1; }
  for (const body of [new Date(0), new Map([['a', 1]]), new Set(), [1], new Body(), Object.create({ a: 1 }), new Uint8Array(1), /x/]) {
    assert.equal(appPortMessage({ t: 'app', body }), null, Object.prototype.toString.call(body));
  }
});

test('appPortMessage keeps only the known fields', () => {
  assert.deepEqual(appPortMessage({ t: 'app', body: { a: 1 }, extra: 'x' }), { t: 'app', body: { a: 1 } });
  assert.deepEqual(appPortMessage({ t: 'openLink', url: 'https://acme.example/', target: '_top' }), { t: 'openLink', url: 'https://acme.example/' });
});

test('the sandbox is exactly allow-scripts', () => assert.equal(FRAME_SANDBOX, 'allow-scripts'));

// --- AppFrame, in a fake DOM with a real MessageChannel and a manual clock --------------

const RUNNER_URL = 'https://acme.example/runner.html';
const TEXT = 'globalThis.answer = 42;';
const SHA256 = 'a'.repeat(64);

/** A clock whose timers run only when advance() passes their due time. */
class ManualClock {
  #now = 0;
  #nextID = 1;
  /** @type {Map<number, {due: number, fn: () => void}>} */
  #timers = new Map();

  now() { return this.#now; }

  setTimeout(fn, ms) {
    const id = this.#nextID++;
    this.#timers.set(id, { due: this.#now + ms, fn });
    return id;
  }

  clearTimeout(id) { this.#timers.delete(id); }

  get pending() { return this.#timers.size; }

  advance(ms) {
    const target = this.#now + ms;
    for (;;) {
      const due = [...this.#timers].filter(([, timer]) => timer.due <= target)
        .sort((a, b) => a[1].due - b[1].due)[0];
      if (due === undefined) break;
      this.#timers.delete(due[0]);
      this.#now = due[1].due;
      due[1].fn();
    }
    this.#now = target;
  }
}

/**
 * Opens an AppFrame in a fresh fake DOM, destroyed when the test ends. `reply` decides what
 * sendApp returns, or throws, for each body.
 */
function openFrame(t, { reply = () => 'sent' } = {}) {
  const doc = new FakeDocument();
  const host = doc.createElement('div');
  const clock = new ManualClock();
  const faults = [];
  const sent = [];
  const links = [];
  const frame = new AppFrame({
    host,
    runnerURL: RUNNER_URL,
    text: TEXT,
    sha256: SHA256,
    sendApp: (body) => {
      sent.push(body);
      return reply(body);
    },
    onOpenLink: (url) => links.push(url),
    onFault: (reason) => faults.push(reason),
    clock,
  });
  t.after(() => frame.destroy());
  const iframe = doc.created.find((element) => element.tagName === 'iframe');
  const nonce = iframe.src.slice(`${RUNNER_URL}#n=`.length);
  const frameWindow = iframe.frameWindow;
  /** The runner's `ready`, from the frame's window and the opaque origin unless overridden. */
  const ready = (fields = {}) => doc.defaultView.message({
    data: { type: 'ready', nonce }, source: frameWindow, origin: 'null', ...fields,
  });
  return { win: doc.defaultView, host, iframe, frameWindow, clock, frame, faults, sent, links, nonce, ready };
}

/**
 * Readies the frame and returns the runner's end of the channel, collecting what it gets.
 * The port is closed when the test ends, so a frame that leaves its end open cannot keep
 * the process alive.
 */
function connect(t, f) {
  f.ready();
  const port = f.frameWindow.posts[0].transfer[0];
  t.after(() => port.close());
  const received = [];
  port.addEventListener('message', (event) => received.push(event.data));
  port.start();
  return { port, received };
}

/** Waits for something a port message will make true. Fails after about two seconds. */
async function until(condition, what) {
  for (let i = 0; i < 1000; i++) {
    if (condition()) return;
    await new Promise((resolve) => setTimeout(resolve, 2));
  }
  assert.fail(`timed out waiting for ${what}`);
}

/** Lets queued port messages arrive, for checks that nothing happened. */
async function settle() {
  for (let i = 0; i < 10; i++) await new Promise((resolve) => setTimeout(resolve, 2));
}

test('AppFrame sandboxes the iframe and listens before it sets src, then appends it', (t) => {
  const f = openFrame(t);
  const expected = { sandbox: 'allow-scripts', title: 'TBD app', src: `${RUNNER_URL}#n=${f.nonce}`, loadListeners: 1, windowMessageListeners: 1 };
  assert.deepEqual(f.iframe.atSrc, { ...expected, appended: false });
  assert.deepEqual(f.iframe.atAppend, { ...expected, appended: true });
  assert.match(f.nonce, /^[A-Za-z0-9_-]{22}$/);
  assert.deepEqual(f.host.children, [f.iframe]);
  assert.equal(f.clock.pending, 1);
  assert.notEqual(openFrame(t).nonce, f.nonce);
});

test('AppFrame posts nothing for a ready from another window, with another nonce or from a real origin', (t) => {
  const f = openFrame(t);
  f.ready({ source: {} });
  f.ready({ source: null });
  f.ready({ data: { type: 'ready', nonce: f.nonce.slice(1) } });
  f.ready({ origin: 'https://acme.example' });
  assert.equal(f.frameWindow.posts.length, 0);
  f.ready();
  assert.equal(f.frameWindow.posts.length, 1);
});

test('AppFrame posts the bundle and port2 once, for the first valid ready', async (t) => {
  const f = openFrame(t);
  f.ready();
  f.ready();
  assert.equal(f.frameWindow.posts.length, 1);
  const [{ data, targetOrigin, transfer }] = f.frameWindow.posts;
  assert.deepEqual(data, { type: 'bundle', nonce: f.nonce, text: TEXT, sha256: SHA256 });
  assert.equal(targetOrigin, '*');
  assert.equal(transfer.length, 1);
  assert.ok(transfer[0] instanceof MessagePort);
  t.after(() => transfer[0].close());

  // The transferred port is the other end of the frame's channel.
  const received = [];
  transfer[0].addEventListener('message', (event) => received.push(event.data));
  transfer[0].start();
  f.frame.deliver({ hello: 1 });
  await until(() => received.length === 1, 'the delivered body');
  assert.deepEqual(received, [{ t: 'app', body: { hello: 1 } }]);
});

test('AppFrame faults navigated once on a second load, and removes the frame', (t) => {
  const f = openFrame(t);
  f.iframe.load();
  assert.deepEqual(f.faults, []);
  assert.deepEqual(f.host.children, [f.iframe]);
  f.iframe.load();
  assert.deepEqual(f.faults, ['navigated']);
  assert.deepEqual(f.host.children, []);
  assert.equal(f.clock.pending, 0);
  f.iframe.load();
  assert.deepEqual(f.faults, ['navigated']);
});

test('AppFrame clears the start timeout on started, and ignores a fault after it', async (t) => {
  const f = openFrame(t);
  const { port } = connect(t, f);
  port.postMessage({ t: 'started' });
  await until(() => f.clock.pending === 0, 'the start timer to clear');
  f.clock.advance(RUNNER_START_TIMEOUT_MS * 2);
  // The runner sends one of started or fault. A fault after started is the app's.
  port.postMessage({ t: 'fault', reason: 'script' });
  port.postMessage({ t: 'app', body: { after: true } });
  await until(() => f.sent.length === 1, 'the app message');
  assert.deepEqual(f.faults, []);
  assert.deepEqual(f.host.children, [f.iframe]);
});

test('AppFrame faults timeout when the runner does not start in time', (t) => {
  const f = openFrame(t);
  connect(t, f);
  f.clock.advance(RUNNER_START_TIMEOUT_MS - 1);
  assert.deepEqual(f.faults, []);
  f.clock.advance(1);
  assert.deepEqual(f.faults, ['timeout']);
  assert.deepEqual(f.host.children, []);
  assert.equal(f.win.listenerCount('message'), 0);
});

test('AppFrame ends on a runner fault before started, with the runner reason only', async (t) => {
  const f = openFrame(t);
  const { port } = connect(t, f);
  port.postMessage({ t: 'fault', reason: 'navigated' });
  port.postMessage({ t: 'fault', reason: 'hash' });
  await until(() => f.faults.length > 0, 'the fault');
  assert.deepEqual(f.faults, ['hash']);
  assert.deepEqual(f.host.children, []);
  assert.equal(f.clock.pending, 0);
});

test('AppFrame sends app bodies, and answers anything but sent with sendFailed', async (t) => {
  const f = openFrame(t, { reply: (body) => body.result });
  const { port, received } = connect(t, f);
  port.postMessage({ t: 'started' });
  port.postMessage({ t: 'app', body: { result: 'sent' } });
  for (const body of [[1], new Date(0), new Map(), 'x', null]) port.postMessage({ t: 'app', body });
  port.postMessage({ t: 'app', body: { result: 'tooLarge' } });
  port.postMessage({ t: 'app', body: { result: 'offline' } });
  await until(() => received.length === 2, 'two sendFailed replies');
  assert.deepEqual(f.sent, [{ result: 'sent' }, { result: 'tooLarge' }, { result: 'offline' }]);
  assert.deepEqual(received, [
    { t: 'sendFailed', reason: 'tooLarge' },
    { t: 'sendFailed', reason: 'offline' },
  ]);
});

test('AppFrame answers a body sendApp cannot encode with sendFailed tooLarge', async (t) => {
  const f = openFrame(t, {
    reply: (body) => {
      JSON.stringify(body);
      return 'sent';
    },
  });
  const { port, received } = connect(t, f);
  const cyclic = { a: 1 };
  cyclic.self = cyclic;
  port.postMessage({ t: 'app', body: cyclic });
  port.postMessage({ t: 'app', body: { big: 10n } });
  port.postMessage({ t: 'app', body: { ok: true } });
  await until(() => f.sent.length === 3, 'all three bodies');
  await until(() => received.length === 2, 'two sendFailed replies');
  assert.deepEqual(received, [
    { t: 'sendFailed', reason: 'tooLarge' },
    { t: 'sendFailed', reason: 'tooLarge' },
  ]);
  assert.deepEqual(f.faults, []);
});

test('AppFrame opens only links that pass openableURL', async (t) => {
  const f = openFrame(t);
  const { port } = connect(t, f);
  port.postMessage({ t: 'openLink', url: 'javascript:alert(1)' });
  port.postMessage({ t: 'openLink', url: 'https://user:pass@acme.example/' });
  port.postMessage({ t: 'openLink', url: 42 });
  port.postMessage({ t: 'openLink', url: 'HTTPS://Acme.Example/docs' });
  await until(() => f.links.length > 0, 'a link');
  assert.deepEqual(f.links, ['https://acme.example/docs']);
});

test('AppFrame passes deliver, setChannel and sendEnv to the app', async (t) => {
  const f = openFrame(t);
  const { received } = connect(t, f);
  const env = {
    t: 'env',
    safeArea: { top: 0, right: 0, bottom: 34, left: 0 },
    viewport: { width: 390, height: 600, offsetTop: 0, offsetLeft: 0, scale: 1 },
    layout: { width: 390, height: 844 },
    colorScheme: 'dark',
  };
  f.frame.deliver({ m: 1 });
  f.frame.setChannel(true);
  f.frame.setChannel(false);
  f.frame.sendEnv({ ...env, extra: 'dropped' });
  await until(() => received.length === 4, 'four messages');
  assert.deepEqual(received, [
    { t: 'app', body: { m: 1 } },
    { t: 'channel', state: 'up' },
    { t: 'channel', state: 'down' },
    env,
  ]);
});

test('AppFrame destroy removes the frame, its listeners and its timer, and nothing fires afterwards', async (t) => {
  const f = openFrame(t);
  const { port, received } = connect(t, f);
  let closed = false;
  port.addEventListener('close', () => { closed = true; });

  f.frame.destroy();
  assert.deepEqual(f.host.children, []);
  assert.equal(f.win.listenerCount('message'), 0);
  assert.equal(f.iframe.listenerCount('load'), 0);
  assert.equal(f.clock.pending, 0);
  await until(() => closed, 'the channel to close');

  f.iframe.load();
  f.iframe.load();
  port.postMessage({ t: 'app', body: { late: true } });
  port.postMessage({ t: 'fault', reason: 'hash' });
  f.clock.advance(RUNNER_START_TIMEOUT_MS * 2);
  f.frame.deliver({ late: true });
  f.frame.setChannel(true);
  await settle();
  assert.deepEqual(f.faults, []);
  assert.deepEqual(f.sent, []);
  assert.deepEqual(received, []);
  assert.doesNotThrow(() => f.frame.destroy());
});

test('AppFrame destroyed before ready posts nothing to the frame', (t) => {
  const f = openFrame(t);
  f.frame.destroy();
  f.ready();
  assert.equal(f.frameWindow.posts.length, 0);
  assert.equal(f.win.listenerCount('message'), 0);
});
