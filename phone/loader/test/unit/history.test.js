// history.js over a fake History API: what an entry must hold to count as the loader's, how
// an app's history message is rebuilt, and the page's rules for a frame that starts, the app's
// push, replace and back, and the browser's own moves.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  MAX_APP_STATE_LENGTH, PageHistory, historyRequest, readEntry, windowHistory,
} from '../../history.js';

const DOC = 'D';

/**
 * The state the loader writes for an entry.
 * @param {Record<string, unknown>} fields merged over a list entry for laptop L in this page load
 */
const entry = (fields = {}) => ({ tbdPhone: { v: 1, laptop: 'L', doc: DOC, step: 0, app: null, ...fields } });

/**
 * A History API with entries and a current index, as a browser keeps them. `back()` moves on
 * a later microtask and then fires `popstate`, as a browser does; `go` is the browser's own
 * back or forward, and `follow` a link to a fragment of the page. Each call is recorded with
 * every argument it got. `refuse` makes the calls it names throw, as WebKit's throttle on the
 * History API does, changing nothing, until it is called again without them.
 * @param {unknown[]} [states] the entries' states, oldest first
 * @param {number} [at] the current entry's index; the last entry by default
 */
function fakeHistory(states = [null], at = states.length - 1) {
  const entries = states.map((state) => structuredClone(state));
  let index = at;
  /** @type {Array<{ method: string, args: unknown[] }>} */
  const calls = [];
  /** @type {Set<() => void>} */
  const listeners = new Set();
  /** @type {Set<string>} */
  let refused = new Set();
  const popState = () => {
    for (const listener of [...listeners]) listener();
  };
  /** @param {number} delta */
  const go = (delta) => {
    const to = index + delta;
    if (to < 0 || to >= entries.length) return;
    index = to;
    popState();
  };
  /**
   * @param {string} method
   * @param {unknown[]} args
   */
  const record = (method, args) => {
    calls.push({ method, args });
    if (refused.has(method)) throw new DOMException(`${method} refused`, 'SecurityError');
  };
  /** @type {import('../../history.js').HistoryPort} */
  const port = {
    get state() {
      return entries[index];
    },
    pushState(...args) {
      record('pushState', args);
      entries.splice(index + 1);
      entries.push(structuredClone(args[0]));
      index += 1;
    },
    replaceState(...args) {
      record('replaceState', args);
      entries[index] = structuredClone(args[0]);
    },
    back(...args) {
      record('back', args);
      queueMicrotask(() => go(-1));
    },
    onPopState(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
  return {
    port,
    calls,
    go,
    /**
     * A link to a fragment of the page, followed: an entry with no state after the current
     * one, in place of those forward of it, and a popstate. The page's `hashchange` follows.
     */
    follow() {
      entries.splice(index + 1);
      entries.push(null);
      index += 1;
      popState();
    },
    /** @param {...('pushState' | 'replaceState' | 'back')} methods */
    refuse(...methods) {
      refused = new Set(methods);
    },
    /** Every entry's state, oldest first. */
    entries: () => entries,
    index: () => index,
    /** The calls that wrote to the history or moved it, refused ones included. */
    writes: () => calls.map((call) => call.method),
    listeners: () => listeners.size,
  };
}

/**
 * A page history over a fake History API, with one frame attached for laptop L, unless
 * `attach` is false. `routes` records each `route` the frame was sent.
 * @param {{ states?: unknown[], at?: number, attach?: boolean, laptop?: string }} [options]
 */
function setUp({ states, at, attach = true, laptop = 'L' } = {}) {
  const fake = fakeHistory(states, at);
  const page = new PageHistory({ port: fake.port, doc: DOC });
  /** @type {Array<[string | null, number]>} */
  const routes = [];
  const frame = attach ? page.attach(laptop, (state, move) => routes.push([state, move])) : null;
  return { ...fake, page, routes, frame };
}

/** Lets a `back()` land. */
const settle = () => new Promise((resolve) => setImmediate(resolve));

// --- readEntry ----------------------------------------------------------------------------

test('readEntry takes an entry the loader wrote, and returns a fresh copy of its fields', () => {
  const state = entry({ step: 3, app: 'acme' });
  const read = readEntry(state);
  assert.deepEqual(read, state.tbdPhone);
  assert.notEqual(read, state.tbdPhone);
  assert.deepEqual(readEntry(entry()), { v: 1, laptop: 'L', doc: DOC, step: 0, app: null });
  assert.equal(readEntry(entry({ app: 'a'.repeat(MAX_APP_STATE_LENGTH) }))?.app?.length, 1024);
});

test('readEntry keeps only the known fields', () => {
  const read = readEntry({ tbdPhone: { ...entry().tbdPhone, url: 'https://acme.example/' }, other: 1 });
  assert.deepEqual(read, { v: 1, laptop: 'L', doc: DOC, step: 0, app: null });
});

test('readEntry takes a null-prototype object', () => {
  const inner = Object.assign(Object.create(null), entry().tbdPhone);
  const outer = Object.assign(Object.create(null), { tbdPhone: inner });
  assert.deepEqual(readEntry(outer), { v: 1, laptop: 'L', doc: DOC, step: 0, app: null });
});

test('readEntry refuses anything that is not a plain object holding a plain-object tbdPhone', () => {
  class Entry {
    tbdPhone = entry().tbdPhone;
  }
  class Fields {
    v = 1;
    laptop = 'L';
    doc = DOC;
    step = 0;
    app = null;
  }
  for (const state of [
    null, undefined, 'tbdPhone', 1, true, [], [entry()], new Entry(), new Map([['tbdPhone', entry().tbdPhone]]),
    {}, { tbdPhone: null }, { tbdPhone: 'x' }, { tbdPhone: [] }, { tbdPhone: new Fields() },
  ]) {
    assert.equal(readEntry(state), null, String(state));
  }
});

test('readEntry ignores inherited fields', () => {
  assert.equal(readEntry(Object.create(entry())), null);
  assert.equal(readEntry({ tbdPhone: Object.create(entry().tbdPhone) }), null);
});

test('readEntry refuses a wrong version or a field of the wrong type or range', () => {
  /** @type {Array<Record<string, unknown>>} */
  const bad = [
    { v: 2 }, { v: '1' }, { v: undefined },
    { laptop: undefined }, { laptop: 1 }, { laptop: null },
    { doc: undefined }, { doc: 1 }, { doc: null },
    { step: undefined }, { step: -1 }, { step: 1.5 }, { step: '0' }, { step: Number.NaN },
    { step: Number.POSITIVE_INFINITY }, { step: 2 ** 53 },
    { app: undefined }, { app: 3 }, { app: 'a'.repeat(MAX_APP_STATE_LENGTH + 1) }, { app: {} },
  ];
  for (const fields of bad) {
    assert.equal(readEntry(entry(fields)), null, JSON.stringify(fields));
  }
  const missing = entry();
  delete (/** @type {any} */ (missing.tbdPhone)).app;
  assert.equal(readEntry(missing), null, 'no app field at all');
});

// --- historyRequest -----------------------------------------------------------------------

test('historyRequest rebuilds push, replace and back from their known fields', () => {
  assert.equal(MAX_APP_STATE_LENGTH, 1024);
  assert.deepEqual(historyRequest({ t: 'history', op: 'push', state: 'a', move: 0 }), { op: 'push', state: 'a', move: 0 });
  assert.deepEqual(historyRequest({ t: 'history', op: 'push', state: null, move: 7 }), { op: 'push', state: null, move: 7 });
  assert.deepEqual(historyRequest({ t: 'history', op: 'replace', state: 'b', move: 2 }), { op: 'replace', state: 'b', move: 2 });
  assert.deepEqual(historyRequest({ t: 'history', op: 'back', move: 3 }), { op: 'back', move: 3 });
  const max = 'a'.repeat(MAX_APP_STATE_LENGTH);
  assert.deepEqual(historyRequest({ t: 'history', op: 'push', state: max, move: 0 }), { op: 'push', state: max, move: 0 });
});

test('historyRequest drops extra fields, and a back carries no state', () => {
  const push = historyRequest({ t: 'history', op: 'push', state: 'a', move: 0, url: '/x', title: 'x' });
  assert.deepEqual(push, { op: 'push', state: 'a', move: 0 });
  assert.deepEqual(Object.keys(/** @type {object} */ (push)).sort(), ['move', 'op', 'state']);
  const back = historyRequest({ t: 'history', op: 'back', state: 'a', move: 0, url: '/x' });
  assert.deepEqual(back, { op: 'back', move: 0 });
  assert.deepEqual(Object.keys(/** @type {object} */ (back)).sort(), ['move', 'op']);
});

test('historyRequest refuses a malformed message', () => {
  const over = 'a'.repeat(MAX_APP_STATE_LENGTH + 1);
  for (const data of [
    null, undefined, 'history', 1, [], ['history', 'push'],
    { op: 'push', state: null, move: 0 },
    { t: 'app', op: 'push', state: null, move: 0 },
    { t: 'history', op: 'go', state: null, move: 0 },
    { t: 'history', op: 'pushState', state: null, move: 0 },
    { t: 'history', state: null, move: 0 },
    { t: 'history', op: 'push', state: over, move: 0 },
    { t: 'history', op: 'replace', state: over, move: 0 },
    { t: 'history', op: 'push', state: 3, move: 0 },
    { t: 'history', op: 'push', state: {}, move: 0 },
    { t: 'history', op: 'push', move: 0 },
    { t: 'history', op: 'push', state: null, move: -1 },
    { t: 'history', op: 'push', state: null, move: 1.5 },
    { t: 'history', op: 'push', state: null, move: '1' },
    { t: 'history', op: 'push', state: null, move: Number.NaN },
    { t: 'history', op: 'push', state: null, move: 2 ** 53 },
    { t: 'history', op: 'push', state: null },
    { t: 'history', op: 'back', move: -1 },
    { t: 'history', op: 'back', move: 0.5 },
    { t: 'history', op: 'back' },
  ]) {
    assert.equal(historyRequest(data), null, JSON.stringify(data));
  }
});

// --- windowHistory ------------------------------------------------------------------------

test('windowHistory calls the window\'s History API with an empty title and never a URL', () => {
  /** @type {Array<{ method: string, args: unknown[] }>} */
  const calls = [];
  const win = new EventTarget();
  /** @type {any} */ (win).history = {
    state: { tbdPhone: 'x' },
    pushState: (/** @type {unknown[]} */ ...args) => calls.push({ method: 'pushState', args }),
    replaceState: (/** @type {unknown[]} */ ...args) => calls.push({ method: 'replaceState', args }),
    back: (/** @type {unknown[]} */ ...args) => calls.push({ method: 'back', args }),
  };
  const port = windowHistory(/** @type {any} */ (win));
  const data = entry();
  port.pushState(data);
  port.replaceState(data);
  port.back();
  assert.deepEqual(calls, [
    { method: 'pushState', args: [data, ''] },
    { method: 'replaceState', args: [data, ''] },
    { method: 'back', args: [] },
  ]);
  assert.deepEqual(port.state, { tbdPhone: 'x' });

  let pops = 0;
  const stop = port.onPopState(() => { pops += 1; });
  win.dispatchEvent(new Event('popstate'));
  stop();
  win.dispatchEvent(new Event('popstate'));
  assert.equal(pops, 1);
});

// --- PageHistory: a frame starts ----------------------------------------------------------

test('a frame that starts on an entry with no state makes it this laptop\'s list', () => {
  const h = setUp({ states: [null] });
  assert.deepEqual(h.entries(), [entry()]);
  assert.deepEqual(h.writes(), ['replaceState']);
  assert.deepEqual(h.routes, [[null, 0]]);
});

test('a frame that starts on this laptop\'s entry from this page load keeps its step and screen', () => {
  const h = setUp({ states: [entry(), entry({ step: 1 }), entry({ step: 2, app: 'x' })] });
  assert.deepEqual(h.entries()[2], entry({ step: 2, app: 'x' }));
  assert.deepEqual(h.routes, [['x', 0]]);
});

test('a frame that starts on another laptop\'s entry from this page load keeps the step, not the screen', () => {
  const h = setUp({ states: [entry({ laptop: 'K' }), entry({ laptop: 'K', step: 1, app: 'k' })] });
  assert.deepEqual(h.entries()[1], entry({ step: 1, app: null }));
  assert.deepEqual(h.routes, [[null, 0]]);
});

test('a frame that starts on this laptop\'s entry from an earlier page load keeps the screen, from step 0', () => {
  const h = setUp({ states: [entry({ doc: 'old', step: 4, app: 'x' })] });
  assert.deepEqual(h.entries(), [entry({ step: 0, app: 'x' })]);
  assert.deepEqual(h.routes, [['x', 0]]);
});

test('a frame that starts on another laptop\'s entry from an earlier page load gets a fresh list entry', () => {
  const h = setUp({ states: [entry({ laptop: 'K', doc: 'old', step: 4, app: 'k' })] });
  assert.deepEqual(h.entries(), [entry()]);
  assert.deepEqual(h.routes, [[null, 0]]);
});

test('a frame that starts on an entry that is not the loader\'s gets a fresh list entry', () => {
  const h = setUp({ states: [{ tbdPhone: { ...entry().tbdPhone, v: 2, app: 'x' } }] });
  assert.deepEqual(h.entries(), [entry()]);
  assert.deepEqual(h.routes, [[null, 0]]);
});

test('a frame that starts after browser moves hears the current count', () => {
  const h = setUp({ states: [entry(), entry({ step: 1 })], attach: false });
  h.go(-1);
  h.go(1);
  assert.equal(h.page.move, 2);
  assert.deepEqual(h.writes(), [], 'with no frame, a move writes nothing');
  /** @type {Array<[string | null, number]>} */
  const routes = [];
  h.page.attach('L', (state, move) => routes.push([state, move]));
  assert.deepEqual(routes, [[null, 2]]);
});

// --- PageHistory: the app's requests ------------------------------------------------------

test('push adds an entry one step on, with the app\'s string; replace rewrites it and keeps the step', () => {
  const h = setUp();
  h.frame?.apply({ op: 'push', state: 'a', move: 0 });
  assert.deepEqual(h.entries(), [entry(), entry({ step: 1, app: 'a' })]);
  h.frame?.apply({ op: 'replace', state: 'b', move: 0 });
  assert.deepEqual(h.entries(), [entry(), entry({ step: 1, app: 'b' })]);
  h.frame?.apply({ op: 'replace', state: null, move: 0 });
  assert.deepEqual(h.entries(), [entry(), entry({ step: 1, app: null })]);
  assert.equal(h.page.move, 0, 'the app\'s own pushes and replaces are not moves');
  assert.deepEqual(h.routes, [[null, 0]], 'nor do they send a route');
});

test('push drops every entry forward of the current one', () => {
  const h = setUp();
  h.frame?.apply({ op: 'push', state: 'a', move: 0 });
  h.frame?.apply({ op: 'push', state: 'b', move: 0 });
  h.go(-1);
  h.frame?.apply({ op: 'push', state: 'c', move: 1 });
  assert.deepEqual(h.entries(), [entry(), entry({ step: 1, app: 'a' }), entry({ step: 2, app: 'c' })]);
});

test('a push, replace or back with a stale move is dropped', () => {
  const h = setUp({ states: [entry(), entry({ step: 1, app: 'a' })] });
  h.go(-1);
  assert.equal(h.page.move, 1);
  const before = h.writes().length;
  h.frame?.apply({ op: 'push', state: 'x', move: 0 });
  h.frame?.apply({ op: 'replace', state: 'x', move: 0 });
  h.frame?.apply({ op: 'back', move: 0 });
  h.frame?.apply({ op: 'push', state: 'x', move: 2 });
  assert.deepEqual(h.writes().slice(before), []);
  assert.equal(h.page.move, 1);
});

test('back from step 1 goes back one entry, and the route follows the popstate', async () => {
  const h = setUp();
  h.frame?.apply({ op: 'push', state: 'a', move: 0 });
  h.frame?.apply({ op: 'back', move: 0 });
  assert.equal(h.page.move, 1, 'the back counts as a move at once');
  assert.deepEqual(h.writes(), ['replaceState', 'pushState', 'back']);
  await settle();
  assert.equal(h.page.move, 2, 'and so does the popstate it causes');
  assert.equal(h.index(), 0);
  assert.deepEqual(h.routes, [[null, 0], [null, 2]]);
  assert.deepEqual(h.entries(), [entry(), entry({ step: 1, app: 'a' })], 'the entry left stays for forward');
});

test('a double tap on the back chevron goes back one entry, not two', async () => {
  const h = setUp();
  h.frame?.apply({ op: 'push', state: 'a', move: 0 });
  h.frame?.apply({ op: 'push', state: 'b', move: 0 });
  h.frame?.apply({ op: 'back', move: 0 });
  h.frame?.apply({ op: 'back', move: 0 });
  await settle();
  assert.equal(h.writes().filter((method) => method === 'back').length, 1);
  assert.equal(h.index(), 1);
  assert.deepEqual(h.routes, [[null, 0], ['a', 2]]);
});

test('back from step 0 stays on the page: the entry becomes the list and the route says so', async () => {
  const h = setUp({ states: [null, entry({ step: 0, app: 'a' })] });
  h.frame?.apply({ op: 'back', move: 0 });
  await settle();
  assert.equal(h.writes().includes('back'), false);
  assert.equal(h.index(), 1);
  assert.deepEqual(h.entries(), [null, entry()]);
  assert.deepEqual(h.routes, [['a', 0], [null, 1]]);
  assert.equal(h.page.move, 1);
});

test('back on an entry from an earlier page load stays on the page too', async () => {
  // After a reload, the frame starts on an entry an earlier page load made. The entry before
  // it belongs to that load, so going back to it would load the page again.
  const h = setUp({ states: [entry({ doc: 'old' }), entry({ doc: 'old', step: 1, app: 'a' })] });
  // The frame start made it this page load's at step 0.
  assert.deepEqual(h.entries()[1], entry({ step: 0, app: 'a' }));
  h.frame?.apply({ op: 'back', move: 0 });
  await settle();
  assert.equal(h.writes().includes('back'), false);
  assert.deepEqual(h.routes, [['a', 0], [null, 1]]);
});

// --- PageHistory: the browser's moves -----------------------------------------------------

test('a popstate onto this laptop\'s entry sends its screen and writes nothing', () => {
  const h = setUp();
  h.frame?.apply({ op: 'push', state: 'a', move: 0 });
  h.go(-1);
  h.go(1);
  assert.deepEqual(h.routes, [[null, 0], [null, 1], ['a', 2]]);
  assert.deepEqual(h.writes(), ['replaceState', 'pushState']);
});

test('a popstate onto another laptop\'s entry makes it this laptop\'s list, keeping its step', () => {
  const h = setUp({ states: [entry({ laptop: 'K', step: 0, app: 'k' }), null] });
  h.frame?.apply({ op: 'push', state: 'a', move: 0 });
  // Entry 0 is the other laptop's, from this page load; entry 1 is this frame's start.
  h.go(-2);
  assert.deepEqual(h.entries()[0], entry({ step: 0, app: null }));
  assert.deepEqual(h.routes.at(-1), [null, 1]);
});

test('a popstate onto an entry that is not the loader\'s makes it this laptop\'s list at step 0', () => {
  const h = setUp({ states: [null, entry({ step: 3, app: 'a' })] });
  h.go(-1);
  assert.deepEqual(h.entries()[0], entry({ step: 0, app: null }));
  assert.deepEqual(h.routes, [['a', 0], [null, 1]]);
});

test('two quick back swipes send two routes, and a push from before the second is dropped', () => {
  const h = setUp();
  h.frame?.apply({ op: 'push', state: 'a', move: 0 });
  h.frame?.apply({ op: 'push', state: 'b', move: 0 });
  h.go(-1);
  h.go(-1);
  assert.deepEqual(h.routes, [[null, 0], ['a', 1], [null, 2]]);
  // The app answered the first route's screen with a tap that pushes, carrying move 1.
  h.frame?.apply({ op: 'push', state: 'c', move: 1 });
  assert.equal(h.index(), 0);
  assert.equal(h.entries().length, 3);
  assert.deepEqual(h.writes(), ['replaceState', 'pushState', 'pushState']);
});

test('a popstate with no frame attached counts a move and does nothing else', () => {
  const h = setUp({ states: [null, entry({ laptop: 'K' })], attach: false });
  h.go(-1);
  assert.equal(h.page.move, 1);
  assert.deepEqual(h.writes(), []);
  assert.deepEqual(h.entries(), [null, entry({ laptop: 'K' })]);
});

test('a pairing link opened under a running app: the frame detaches, and later moves send and write nothing', () => {
  const h = setUp();
  // The link's fragment adds an entry with no state, and its popstate comes before the
  // hashchange, while the frame still runs: the entry becomes this laptop's list, the screen
  // the app is sent.
  h.follow();
  assert.deepEqual(h.entries(), [entry(), entry()]);
  assert.deepEqual(h.routes, [[null, 0], [null, 1]]);
  // On hashchange, main.js takes the link out of the address, which leaves the entry with no
  // state, and only then acts on the link, which removes the frame.
  h.port.replaceState(null);
  h.frame?.detach();
  const writes = h.writes().length;
  h.go(-1);
  h.go(1);
  h.frame?.apply({ op: 'push', state: 'x', move: h.page.move });
  h.frame?.apply({ op: 'back', move: h.page.move });
  assert.deepEqual(h.routes, [[null, 0], [null, 1]]);
  assert.equal(h.writes().length, writes);
  assert.deepEqual(h.entries(), [entry(), null], 'the link\'s entry keeps no state');
  assert.equal(h.page.move, 3);
});

test('attach detaches the frame before it: only the newest frame hears routes and is heard', () => {
  const h = setUp();
  const first = /** @type {import('../../history.js').FrameHistory} */ (h.frame);
  first.apply({ op: 'push', state: 'a', move: 0 });
  /** @type {Array<[string | null, number]>} */
  const routes = [];
  const second = h.page.attach('L', (state, move) => routes.push([state, move]));
  assert.deepEqual(routes, [['a', 0]], 'the new frame opens the entry\'s screen');
  first.apply({ op: 'push', state: 'x', move: 0 });
  first.detach();
  h.go(-1);
  assert.deepEqual(h.routes, [[null, 0]], 'the first frame heard nothing after the second attached');
  assert.deepEqual(routes, [['a', 0], [null, 1]], 'and its detach did not detach the second');
  second.apply({ op: 'push', state: 'b', move: 1 });
  assert.deepEqual(h.entries(), [entry(), entry({ step: 1, app: 'b' })]);
});

// --- PageHistory: calls the browser refuses ------------------------------------------------

test('a frame that starts while the browser refuses replaceState gets the screen of the entry as it was', () => {
  /** @type {Array<[unknown[], string | null]>} the entries, and the screen the frame is sent */
  const cases = [
    [[null], null],
    // Another laptop's entry reads as this laptop's list.
    [[entry({ laptop: 'K', step: 1, app: 'k' })], null],
    [[entry({ doc: 'old', step: 4, app: 'x' })], 'x'],
  ];
  for (const [states, screen] of cases) {
    const fake = fakeHistory(states);
    fake.refuse('replaceState');
    const page = new PageHistory({ port: fake.port, doc: DOC });
    /** @type {Array<[string | null, number]>} */
    const routes = [];
    page.attach('L', (state, move) => routes.push([state, move]));
    assert.deepEqual(fake.writes(), ['replaceState']);
    assert.deepEqual(fake.entries(), states, 'the entry stays as it was');
    assert.deepEqual(routes, [[screen, 0]]);
  }
});

test('a push or replace the browser refuses leaves the entries as they were, owes no route, and the next one lands', () => {
  const h = setUp();
  h.refuse('pushState', 'replaceState');
  h.frame?.apply({ op: 'push', state: 'a', move: 0 });
  h.frame?.apply({ op: 'replace', state: 'b', move: 0 });
  assert.deepEqual(h.writes(), ['replaceState', 'pushState', 'replaceState']);
  assert.deepEqual(h.entries(), [entry()]);
  assert.deepEqual(h.routes, [[null, 0]]);
  assert.equal(h.page.move, 0);
  h.refuse();
  h.frame?.apply({ op: 'push', state: 'c', move: 0 });
  assert.deepEqual(h.entries(), [entry(), entry({ step: 1, app: 'c' })]);
});

test('a back the browser refuses moves nothing, and the route names the entry it stays on, so the app is heard again', async () => {
  const h = setUp();
  h.frame?.apply({ op: 'push', state: 'a', move: 0 });
  h.refuse('back');
  h.frame?.apply({ op: 'back', move: 0 });
  await settle();
  assert.equal(h.index(), 1);
  assert.equal(h.page.move, 1);
  assert.deepEqual(h.routes, [[null, 0], ['a', 1]]);
  // The app answers with the count that route carried.
  h.refuse();
  h.frame?.apply({ op: 'back', move: 1 });
  await settle();
  assert.equal(h.index(), 0);
  assert.deepEqual(h.routes, [[null, 0], ['a', 1], [null, 3]]);
});

test('a back from step 0 whose rewrite the browser refuses sends the screen the entry still names', async () => {
  const h = setUp({ states: [null, entry({ app: 'a' })] });
  h.refuse('replaceState');
  h.frame?.apply({ op: 'back', move: 0 });
  await settle();
  assert.equal(h.writes().includes('back'), false);
  assert.deepEqual(h.entries(), [null, entry({ app: 'a' })]);
  assert.deepEqual(h.routes, [['a', 0], ['a', 1]]);
  assert.equal(h.page.move, 1);
});

test('a popstate onto another laptop\'s entry whose rewrite the browser refuses still sends the list', () => {
  const h = setUp({ states: [entry({ laptop: 'K', app: 'k' }), null] });
  h.refuse('replaceState');
  h.go(-1);
  assert.deepEqual(h.entries()[0], entry({ laptop: 'K', app: 'k' }));
  assert.deepEqual(h.routes, [[null, 0], [null, 1]]);
  // The entry still reads as this laptop's list, so the chevron there shows the list too.
  h.frame?.apply({ op: 'back', move: 1 });
  assert.deepEqual(h.routes, [[null, 0], [null, 1], [null, 2]]);
  assert.deepEqual(h.entries()[0], entry({ laptop: 'K', app: 'k' }));
});

test('no write passes a URL or a title: each gets the entry\'s state alone', () => {
  const h = setUp({ states: [entry({ laptop: 'K' }), null] });
  h.frame?.apply({ op: 'push', state: 'a', move: 0 });
  h.frame?.apply({ op: 'replace', state: 'b', move: 0 });
  h.go(-2);
  h.frame?.apply({ op: 'back', move: 1 });
  const writes = h.calls.filter((call) => call.method !== 'back');
  assert.ok(writes.length >= 4);
  for (const call of writes) assert.equal(call.args.length, 1, call.method);
  for (const call of h.calls.filter((c) => c.method === 'back')) assert.equal(call.args.length, 0);
});

test('a page history picks a fresh random document ID, and listens for popstate once', () => {
  const a = fakeHistory();
  const b = fakeHistory();
  const pa = new PageHistory({ port: a.port });
  const pb = new PageHistory({ port: b.port });
  assert.equal(a.listeners(), 1);
  pa.attach('L', () => {});
  pb.attach('L', () => {});
  const docA = /** @type {any} */ (a.entries()[0]).tbdPhone.doc;
  const docB = /** @type {any} */ (b.entries()[0]).tbdPhone.doc;
  assert.match(docA, /^[A-Za-z0-9_-]{22}$/);
  assert.notEqual(docA, docB);
});
