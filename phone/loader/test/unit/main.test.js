// main.js's boot, driven in Node through a fake window, document and IndexedDB: the pairing
// link leaves the address before anything else, links opened later are stripped whatever the
// page is doing, a store that does not answer ends in "Reload this page", never a blank page,
// and time while the page is hidden never counts against it. The strip's menu reads the store
// too, and a read of its that stalls only closes it. A scripted laptop on a fake relay runs the
// handshake: what a connection records in the store, and when, and what the app frame hears
// about its channel. What needs a real browser (the runner inside the frame) is in the e2e
// suite.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';

import { base64urlEncode } from '../../channel/pairingLink.js';
import { RESUME_COALESCE_MS, SIGNAL_TIMEOUT_MS, STORE_TIMEOUT_MS } from '../../constants.js';
import { createWrappedPhoneKey } from '../../keys.js';
import { boot } from '../../main.js';
import { MESSAGES } from '../../messages.js';
import { validateLaptopRecord } from '../../store.js';
import { FakeClock } from '../support/fake-clock.js';
import { FakeDocument, FakeWindow } from '../support/fake-dom.js';
import { createFakeRelay } from '../support/fake-relay.js';
import { fakeSocketFactory } from '../support/fake-websocket.js';
import { quiet, until as waitFor } from '../support/helpers.js';
import { createScriptedLaptop } from '../support/scripted-laptop.js';

const vectors = JSON.parse(readFileSync(new URL('../../../test-vectors/pairing-link.json', import.meta.url), 'utf8'));
const NOW = vectors.now * 1000;
/** The loader page's address, with no fragment. */
const PAGE = vectors.loaderURL;
const [V1, V2] = vectors.valid;
const IPHONE_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2 Mobile/15E148 Safari/604.1';

const flush = () => new Promise((resolve) => setImmediate(resolve));

/**
 * @param {() => boolean} predicate
 * @param {string} what
 */
async function until(predicate, what) {
  for (let turn = 0; turn < 1000; turn += 1) {
    if (predicate()) return;
    await flush();
  }
  assert.fail(`never saw ${what}`);
}

/** The page's window: its address, its history and whether it is framed. */
class PageWindow extends FakeWindow {
  /** @type {string[]} Each URL `history.replaceState` was given. */
  replaced = [];

  /**
   * @param {string} href
   * @param {string[]} log shared with the IndexedDB fake, to see what came first
   * @param {boolean} framed
   */
  constructor(href, log, framed) {
    super();
    this.location = { href, reload() {} };
    this.history = {
      replaceState: (/** @type {unknown} */ _state, /** @type {string} */ _title, /** @type {string} */ url) => {
        log.push('replaceState');
        this.replaced.push(url);
        this.location.href = url;
      },
    };
    this.self = this;
    this.top = framed ? new FakeWindow() : this;
    this.navigator = { userAgent: IPHONE_UA, maxTouchPoints: 5 };
  }

  innerWidth = 390;
  innerHeight = 844;

  matchMedia() {
    return new EventTarget();
  }

  /** What `readEnv` reads off the safe-area probe: no insets. */
  getComputedStyle() {
    return { paddingTop: '0px', paddingRight: '0px', paddingBottom: '0px', paddingLeft: '0px' };
  }

  /**
   * Opens `href` on the page that is already open, as following a link to it does: only the
   * fragment changes, so the page gets `hashchange` and does not load again.
   * @param {string} href
   */
  follow(href) {
    this.location.href = href;
    this.dispatchEvent(new Event('hashchange'));
  }
}

/**
 * A transaction that reads `laptops` (the stored rows): every request answers on a later
 * turn, and the transaction completes once none is left. A `put` answers too, and is recorded
 * in `writes` without changing the rows.
 * @param {any[]} laptops
 * @param {any[]} writes
 */
function answeringTransaction(laptops, writes) {
  let pending = 0;
  const tx = {
    /** @type {(() => void) | null} */
    oncomplete: null,
    onerror: null,
    onabort: null,
    abort() {},
    objectStore: () => ({
      getAllKeys: () => answer(laptops.map((row) => row.id)),
      get: (/** @type {string} */ key) => answer(laptops.find((row) => row.id === key)),
      put: (/** @type {unknown} */ value) => {
        writes.push(value);
        return answer(undefined);
      },
    }),
  };
  /** @param {unknown} result */
  const answer = (result) => {
    /** @type {any} */
    const request = { result };
    pending += 1;
    setImmediate(() => {
      request.onsuccess?.();
      pending -= 1;
      if (pending === 0) setImmediate(() => tx.oncomplete?.());
    });
    return request;
  };
  return tx;
}

/**
 * An IndexedDB whose `open` answers only when the test says so. The opened database runs each
 * transaction as `plan` says, in turn: `answer` reads `laptops` (and records each `put` in
 * `writes`), `fail` throws as a closing database does, and `stall` (also once the plan runs
 * out) starts and never finishes, as a stalled store does. `calls` records the store names and
 * mode of each transaction.
 * @param {string[]} log
 * @param {any[]} laptops the stored laptop rows
 */
function fakeIndexedDB(log, laptops) {
  /** @type {any[]} */
  const requests = [];
  /** @type {Array<'answer' | 'stall' | 'fail'>} */
  const plan = [];
  /** @type {Array<{ names: string[], mode: string }>} */
  const calls = [];
  /** @type {any[]} */
  const writes = [];
  const db = {
    /** @type {(() => void) | null} */
    onclose: null,
    onversionchange: null,
    /**
     * @param {string[]} names
     * @param {string} mode
     */
    transaction(names, mode) {
      calls.push({ names, mode });
      const how = plan.shift() ?? 'stall';
      if (how === 'fail') throw new DOMException('the database connection is closing', 'InvalidStateError');
      if (how === 'answer') return answeringTransaction(laptops, writes);
      return { objectStore: () => ({ getAllKeys: () => ({}), get: () => ({}), put: () => ({}) }), abort() {} };
    },
    close() {},
  };
  return {
    requests,
    plan,
    calls,
    writes,
    db,
    transactions: () => calls.length,
    open() {
      log.push('indexedDB.open');
      const request = {};
      requests.push(request);
      return request;
    },
    succeed() {
      requests[0].result = db;
      requests[0].onsuccess();
    },
    fail() {
      requests[0].error = new DOMException('the open failed', 'UnknownError');
      requests[0].onerror();
    },
  };
}

/**
 * A paired laptop's stored row, with a real wrapped key so the page can connect to it.
 * @param {string} laptopName
 */
async function storedLaptop(laptopName) {
  const laptopKey = new Uint8Array(randomBytes(32));
  const id = base64urlEncode(laptopKey);
  const keys = await createWrappedPhoneKey(crypto.subtle, id);
  return validateLaptopRecord({
    id,
    relay: V1.link.relay,
    room: base64urlEncode(new Uint8Array(randomBytes(32))),
    laptopKey,
    laptopName,
    phoneName: 'iPhone',
    phoneKey: keys.publicRaw,
    wrapKey: keys.wrapKey,
    wrappedKey: keys.wrappedKey,
    wrapIV: keys.wrapIV,
    pairedAt: NOW,
    lastConnectedAt: null,
  });
}

/**
 * Relay sockets that stay as the test leaves them: each records the codes `close()` was
 * called with, and `open(i)` and `signal(i, name)` play the relay's side.
 */
function relaySockets() {
  /** @type {any[]} */
  const sockets = [];
  return {
    sockets,
    /** @param {string} url */
    openSocket(url) {
      const ws = {
        url,
        binaryType: 'blob',
        readyState: 0,
        /** @type {any} */ onopen: null,
        /** @type {any} */ onmessage: null,
        onclose: null,
        onerror: null,
        /** @type {Array<number | undefined>} */ closes: [],
        send() {},
        /** @param {number} [code] */
        close(code) {
          ws.closes.push(code);
          ws.readyState = 3;
        },
      };
      sockets.push(ws);
      return ws;
    },
    /** @param {number} i */
    open(i) {
      sockets[i].readyState = 1;
      sockets[i].onopen?.({});
    },
    /**
     * @param {number} i
     * @param {string} name
     */
    signal(i, name) {
      sockets[i].onmessage?.({ data: name });
    },
  };
}

/**
 * Boots the loader on a fake page at `href`.
 * @param {{ href?: string, framed?: boolean, laptops?: any[], openSocket?: (url: string) => any,
 *   fetch?: (url: string, init: RequestInit) => Promise<any> }} [options]
 */
function bootPage({
  href = PAGE, framed = false, laptops = [], openSocket = () => {
    throw new TypeError('no sockets in these tests');
  }, fetch = async () => {
    throw new TypeError('no network in these tests');
  },
} = {}) {
  /** @type {string[]} */
  const log = [];
  const win = new PageWindow(href, log, framed);
  const doc = new FakeDocument(win);
  for (const [tag, id] of [['header', 'strip'], ['main', 'screen'], ['div', 'frame-host'], ['div', 'safe-probe']]) {
    const el = doc.createElement(tag);
    el.setAttribute('id', id);
    // What `readEnv` measures the app frame's host by: the whole layout viewport.
    /** @type {any} */ (el).getBoundingClientRect = () => ({ top: 0, right: win.innerWidth, bottom: win.innerHeight, left: 0 });
    doc.body.append(el);
  }
  // ui.js builds with the global document.
  globalThis.document = /** @type {any} */ (doc);
  const clock = new FakeClock(NOW);
  const idb = fakeIndexedDB(log, laptops);
  const booted = boot(/** @type {any} */ ({
    window: win,
    document: doc,
    clock,
    indexedDB: idb,
    subtle: crypto.subtle,
    fetch,
    openSocket,
    requestAnimationFrame: (/** @type {() => void} */ callback) => setImmediate(callback),
  }));
  const screenEl = /** @type {any} */ (doc.getElementById('screen'));
  const stripEl = /** @type {any} */ (doc.getElementById('strip'));
  return {
    win,
    doc,
    strip: stripEl,
    clock,
    idb,
    log,
    booted,
    /** The `data-state` of what the screen shows, or null when it shows nothing. */
    screen: () => screenEl.children[0]?.getAttribute('data-state') ?? null,
    text: () => screenEl.textContent,
    /** The strip's laptop button, or undefined while the strip is empty. */
    stripButton: () => stripEl.children.find((/** @type {any} */ node) => node.tagName === 'button'),
    /** Whether the strip shows its laptop menu. */
    menuShown: () => [...stripEl.descendants()].some((node) => node.getAttribute('data-state') === 'lapmenu'),
    /** Whether the layer that catches taps outside the menu is in the strip. */
    catcherShown: () => [...stripEl.descendants()].some((node) => node.className === 'lapcatch'),
    /** @param {'visible' | 'hidden'} state */
    setVisibility(state) {
      doc.visibilityState = state;
      doc.dispatchEvent(new Event('visibilitychange'));
    },
  };
}

test('framed, the loader does nothing at all', async () => {
  const page = bootPage({ href: V1.url, framed: true });
  await page.booted;
  assert.deepEqual(page.log, [], 'no replaceState, no store');
  assert.equal(page.win.location.href, V1.url);
  assert.equal(page.win.listenerCount('hashchange'), 0);
  assert.equal(page.screen(), null);
});

test('a pairing link leaves the address before the store opens, and is taken once it has', async () => {
  const page = bootPage({ href: V1.url });
  assert.deepEqual(page.log, ['replaceState', 'indexedDB.open']);
  assert.deepEqual(page.win.replaced, [PAGE]);
  assert.equal(page.screen(), 'loading');
  page.idb.succeed();
  await flush();
  assert.equal(page.screen(), 'name');
  assert.ok(page.text().includes(`Found ${V1.link.name}.`));
});

test('a link opened while the store opens is stripped at once, and the latest one is taken', async () => {
  const page = bootPage();
  assert.deepEqual(page.win.replaced, [], 'no fragment, nothing to strip');
  page.win.follow(V1.url);
  assert.deepEqual(page.win.replaced, [PAGE]);
  page.win.follow(V2.url);
  assert.deepEqual(page.win.replaced, [PAGE, PAGE]);
  assert.equal(page.win.location.href, PAGE);
  assert.equal(page.screen(), 'loading');
  page.idb.succeed();
  await flush();
  assert.equal(page.screen(), 'name');
  assert.ok(page.text().includes(`Found ${V2.link.name}.`), page.text());
});

test('a fragment that is not a pairing link stays', async () => {
  const page = bootPage({ href: `${PAGE}#about` });
  page.win.follow(`${PAGE}#help`);
  assert.deepEqual(page.win.replaced, []);
  assert.equal(page.win.location.href, `${PAGE}#help`);
});

test('a store that does not open in time shows Reload; a later link is still stripped, and dropped', async () => {
  const page = bootPage({ href: V1.url });
  await page.clock.advance(STORE_TIMEOUT_MS - 1);
  assert.equal(page.screen(), 'loading');
  await page.clock.advance(1);
  await flush();
  assert.equal(page.screen(), 'reload');
  assert.ok(page.text().includes(MESSAGES.reload));

  page.win.follow(V2.url);
  assert.deepEqual(page.win.replaced, [PAGE, PAGE]);
  assert.equal(page.win.location.href, PAGE);
  page.idb.succeed();
  await flush();
  assert.equal(page.screen(), 'reload', 'neither link is acted on, and a late store changes nothing');
});

test('a store that fails to open shows Reload, and the link that waited is dropped', async () => {
  const page = bootPage({ href: V1.url });
  page.idb.fail();
  await flush();
  assert.equal(page.screen(), 'reload');
  page.win.follow(V2.url);
  assert.equal(page.win.location.href, PAGE);
  await flush();
  assert.equal(page.screen(), 'reload');
});

test('without a link, a spinner shows while the laptops are read, and a stalled read ends in Reload', async () => {
  const page = bootPage();
  page.idb.succeed();
  await flush();
  assert.equal(page.screen(), 'loading');
  await page.clock.advance(STORE_TIMEOUT_MS - 1);
  assert.equal(page.screen(), 'loading');
  await page.clock.advance(1);
  await flush();
  assert.equal(page.screen(), 'reload');
});

test('time while the page is hidden does not count against the store: a link that waits is kept', async () => {
  const page = bootPage({ href: V1.url });
  await page.clock.advance(STORE_TIMEOUT_MS - 1);
  page.setVisibility('hidden');
  await page.clock.advance(STORE_TIMEOUT_MS * 6);
  assert.equal(page.screen(), 'loading', 'iOS froze the page with the open in flight');

  // Back on the page, a fresh full STORE_TIMEOUT_MS; the store answers within it.
  page.setVisibility('visible');
  await page.clock.advance(STORE_TIMEOUT_MS - 1);
  assert.equal(page.screen(), 'loading');
  page.idb.succeed();
  await flush();
  assert.equal(page.screen(), 'name');
  assert.ok(page.text().includes(`Found ${V1.link.name}.`));
});

test('a store that never answers still shows Reload after STORE_TIMEOUT_MS of visible time', async () => {
  const page = bootPage();
  page.setVisibility('hidden');
  await page.clock.advance(STORE_TIMEOUT_MS * 2);
  page.setVisibility('visible');
  await page.clock.advance(STORE_TIMEOUT_MS - 1);
  assert.equal(page.screen(), 'loading');
  await page.clock.advance(1);
  await flush();
  assert.equal(page.screen(), 'reload');
});

/**
 * Boots on a store holding one laptop, which the page connects to, and has the relay say the
 * laptop is away, so the page sits on the offline screen with the strip naming the laptop and
 * no timer of the connection's pending.
 * @param {{ fetch?: (url: string, init: RequestInit) => Promise<any> }} [options] the presence fetch
 */
async function bootOnOfflineLaptop({ fetch } = {}) {
  const relay = relaySockets();
  const page = bootPage({ laptops: [await storedLaptop('acme-mbp')], openSocket: (url) => relay.openSocket(url), fetch });
  page.idb.plan.push('answer');
  page.idb.succeed();
  await until(() => relay.sockets.length === 1, 'the laptop\'s socket');
  relay.open(0);
  relay.signal(0, 'peer-absent');
  await until(() => page.screen() === 'offline', 'the offline screen');
  assert.ok(page.stripButton()?.textContent.includes('acme-mbp'));
  return { page, relay };
}

test('a menu read that stalls only closes the menu: the connection and the page go on', async () => {
  const { page, relay } = await bootOnOfflineLaptop();
  const reads = page.idb.transactions();
  page.stripButton().dispatchEvent(new Event('click'));
  assert.equal(page.idb.transactions(), reads + 1, 'the menu reads the laptops');
  await page.clock.advance(STORE_TIMEOUT_MS - 1);
  assert.equal(page.menuShown(), false);
  await page.clock.advance(1);
  await flush();
  assert.equal(page.screen(), 'offline', 'not Reload this page');
  assert.deepEqual(relay.sockets[0].closes, [], 'the connection was not stopped');
  assert.equal(page.stripButton()?.getAttribute('aria-expanded'), 'false');

  // The menu closed, so the next tap opens it afresh, and a read that answers shows it.
  page.idb.plan.push('answer');
  page.stripButton().dispatchEvent(new Event('click'));
  assert.equal(page.idb.transactions(), reads + 2);
  await until(() => page.menuShown(), 'the menu');
  assert.equal(page.stripButton()?.getAttribute('aria-expanded'), 'true');
  assert.equal(page.screen(), 'offline');
  assert.deepEqual(relay.sockets[0].closes, []);
});

test('a menu read that fails only closes the menu, and a store that closes still shows Reload', async () => {
  const { page, relay } = await bootOnOfflineLaptop();
  page.idb.plan.push('fail');
  page.stripButton().dispatchEvent(new Event('click'));
  await flush();
  assert.equal(page.menuShown(), false);
  assert.equal(page.screen(), 'offline');
  assert.deepEqual(relay.sockets[0].closes, []);

  // A store the browser closes is lost for good: that is Reload, through the store's onClosed.
  page.stripButton().dispatchEvent(new Event('click'));
  /** @type {any} */ (page.idb.db).onclose();
  assert.equal(page.screen(), 'reload');
  assert.deepEqual(relay.sockets[0].closes, [1000], 'the connection stops with the page');
});

test('a full screen that arrives while the menu is open closes the menu and its tap catcher', async () => {
  const { page, relay } = await bootOnOfflineLaptop();
  page.idb.plan.push('answer');
  page.stripButton().dispatchEvent(new Event('click'));
  await until(() => page.menuShown(), 'the menu');
  assert.equal(page.catcherShown(), true);

  // Another tab takes the room: the connection ends and its screen replaces the offline one.
  relay.sockets[0].onclose?.({ code: 4000 });
  await until(() => page.screen() === 'replaced', 'the replaced screen');
  assert.equal(page.menuShown(), false);
  assert.equal(page.catcherShown(), false, 'nothing is left to swallow the first tap on the new screen');
  assert.equal(page.stripButton()?.getAttribute('aria-expanded'), 'false');

  // The strip still names the laptop, and its menu opens afresh.
  page.idb.plan.push('answer');
  page.stripButton().dispatchEvent(new Event('click'));
  await until(() => page.menuShown(), 'the menu again');
  assert.equal(page.screen(), 'replaced');
});

test('a connection state that changes the screen under an open menu closes it too', async () => {
  const { page, relay } = await bootOnOfflineLaptop();
  page.idb.plan.push('answer');
  page.stripButton().dispatchEvent(new Event('click'));
  await until(() => page.menuShown(), 'the menu');

  // The laptop comes back: the handshake starts, and the connecting screen replaces offline.
  relay.signal(0, 'peer-joined');
  await until(() => page.screen() === 'connecting', 'the connecting screen');
  assert.equal(page.menuShown(), false);
  assert.equal(page.catcherShown(), false);
});

test('a key that does not unwrap shows the missing-key screen and opens no socket', async () => {
  const record = await storedLaptop('acme-mbp');
  record.wrappedKey[0] ^= 1;
  const relay = relaySockets();
  const page = bootPage({ laptops: [record], openSocket: (url) => relay.openSocket(url) });
  page.idb.plan.push('answer');
  page.idb.succeed();
  await until(() => page.screen() === 'key-missing', 'the missing-key screen');
  assert.ok(page.text().includes(MESSAGES.keyMissing('acme-mbp')));
  assert.equal(relay.sockets.length, 0);
});

test('the connection\'s signal timeout counts only time while the page is visible', async () => {
  const relay = relaySockets();
  const page = bootPage({ laptops: [await storedLaptop('acme-mbp')], openSocket: (url) => relay.openSocket(url) });
  page.idb.plan.push('answer');
  page.idb.succeed();
  await until(() => relay.sockets.length === 1, 'the laptop\'s socket');
  relay.open(0);
  page.setVisibility('hidden');
  await page.clock.advance(SIGNAL_TIMEOUT_MS * 3);
  await flush();
  assert.deepEqual(relay.sockets[0].closes, [], 'no signal yet, but the page was hidden');
  assert.equal(relay.sockets.length, 1);
  assert.equal(page.screen(), 'connecting');
});

test('the pairing\'s signal timeout counts only time while the page is visible', async () => {
  const relay = relaySockets();
  const page = bootPage({ href: V1.url, openSocket: (url) => relay.openSocket(url) });
  page.idb.succeed();
  await flush();
  assert.equal(page.screen(), 'name');
  const form = page.doc.created.find((element) => element.tagName === 'form');
  form?.dispatchEvent(new Event('submit'));
  await waitFor(() => relay.sockets.length === 1, 'the pairing socket');
  relay.open(0);
  page.setVisibility('hidden');
  await page.clock.advance(SIGNAL_TIMEOUT_MS * 3);
  await flush();
  assert.deepEqual(relay.sockets[0].closes, [], 'no signal yet, but the page was hidden');
  assert.equal(page.screen(), 'pairing');
});

// --- presence, and a return to the page ---------------------------------------------------

/** A presence fetch whose answers the test gives, call by call. */
function presenceFetch() {
  /**
   * @type {Array<{ url: string, signal: AbortSignal | null | undefined, resolve: (value: unknown) => void,
   *   reject: (error: unknown) => void }>}
   */
  const calls = [];
  return {
    calls,
    /**
     * @param {string} url
     * @param {RequestInit} init
     */
    fetch: (url, init) => new Promise((resolve, reject) => {
      calls.push({ url, signal: init.signal, resolve, reject });
    }),
    /**
     * The calls from `from` on, by the room each asked about.
     * @param {number} from
     */
    roomsFrom: (from) => calls.slice(from).map((call) => call.url.split('/').at(-2)),
    /**
     * @param {number} i
     * @param {boolean} laptop
     */
    answer: (i, laptop) => calls[i].resolve({ status: 200, json: async () => ({ laptop }) }),
    /** @param {number} i */
    fail: (i) => calls[i].reject(new TypeError('Load failed')),
  };
}

test('a return to the page asks again for the presence the Laptops screen shows, and updates its rows in place', async () => {
  const net = presenceFetch();
  const page = bootPage({ laptops: [await storedLaptop('acme-mbp'), await storedLaptop('acme-mini')], fetch: net.fetch });
  page.idb.plan.push('answer');
  page.idb.succeed();
  await until(() => page.screen() === 'laptops' && net.calls.length === 2, 'the Laptops screen asking for presence');
  const drawn = /** @type {any} */ (page.doc.getElementById('screen')).children[0];

  // The phone locks with both requests out, and on its return both have failed.
  page.setVisibility('hidden');
  net.fail(0);
  net.fail(1);
  await until(() => page.text().split(MESSAGES.relay).length === 3, 'both rows reading Can\'t reach the relay');
  page.setVisibility('visible');
  assert.equal(net.calls.length, 4, 'one new request per laptop');
  net.answer(2, true);
  net.answer(3, false);
  await until(() => !page.text().includes(MESSAGES.relay), 'both rows updated');
  assert.ok(page.text().includes(MESSAGES.online));
  assert.ok(page.text().includes(MESSAGES.offlineRow));
  assert.equal(/** @type {any} */ (page.doc.getElementById('screen')).children[0], drawn, 'the rows changed in place');
});

test('a return to the page asks again for the presence the strip menu shows, and the menu stays open', async () => {
  const net = presenceFetch();
  const { page } = await bootOnOfflineLaptop({ fetch: net.fetch });
  page.idb.plan.push('answer');
  page.stripButton().dispatchEvent(new Event('click'));
  await until(() => page.menuShown() && net.calls.length === 1, 'the menu asking for presence');

  page.setVisibility('hidden');
  net.fail(0);
  await until(() => page.strip.textContent.includes(MESSAGES.relay), 'the menu reading Can\'t reach the relay');
  page.setVisibility('visible');
  assert.equal(net.calls.length, 2, 'a new request');
  net.answer(1, true);
  await until(() => !page.strip.textContent.includes(MESSAGES.relay), 'the menu updated');
  assert.ok(page.strip.textContent.includes(MESSAGES.online));
  assert.equal(page.menuShown(), true);
});

test('a return to the page asks again only for rows not known: one that read Can\'t reach the relay, and one still out', async () => {
  const net = presenceFetch();
  const laptops = [
    await storedLaptop('acme-mbp'), await storedLaptop('acme-mini'), await storedLaptop('acme-studio'), await storedLaptop('acme-air'),
  ];
  const page = bootPage({ laptops, fetch: net.fetch });
  page.idb.plan.push('answer');
  page.idb.succeed();
  await until(() => page.screen() === 'laptops' && net.calls.length === 4, 'the Laptops screen asking for presence');
  /** @param {string} room */
  const callFor = (room) => net.calls.findIndex((call) => call.url.split('/').at(-2) === room);
  const [online, offline, relay, out] = laptops.map((laptop) => laptop.room);
  net.answer(callFor(online), true);
  net.answer(callFor(offline), false);
  net.fail(callFor(relay));
  await until(
    () => page.text().includes(MESSAGES.online) && page.text().includes(MESSAGES.offlineRow) && page.text().includes(MESSAGES.relay),
    'three rows answered',
  );
  const stillOut = net.calls[callFor(out)];

  await page.clock.advance(RESUME_COALESCE_MS);
  page.setVisibility('hidden');
  page.setVisibility('visible');
  assert.deepEqual(net.roomsFrom(4).sort(), [relay, out].sort(), 'only the relay row and the row still out are asked again');
  assert.equal(stillOut.signal?.aborted, true, 'the request still out is cancelled');
  net.answer(4, true);
  net.answer(5, true);
  await until(() => !page.text().includes(MESSAGES.relay), 'the relay row updated');
  assert.ok(page.text().includes(MESSAGES.offlineRow), 'the offline row keeps its answer');
  stillOut.resolve({ status: 200, json: async () => ({ laptop: false }) });
  await flush();
  assert.equal(page.text().split(MESSAGES.online).length, 4, 'the cancelled request\'s late answer is dropped');
});

test('the two events of one return to the page ask once; a later return asks again for a request still out', async () => {
  const net = presenceFetch();
  const page = bootPage({ laptops: [await storedLaptop('acme-mbp'), await storedLaptop('acme-mini')], fetch: net.fetch });
  page.idb.plan.push('answer');
  page.idb.succeed();
  await until(() => page.screen() === 'laptops' && net.calls.length === 2, 'the Laptops screen asking for presence');
  page.setVisibility('hidden');
  net.fail(0);
  net.fail(1);
  await until(() => page.text().split(MESSAGES.relay).length === 3, 'both rows reading Can\'t reach the relay');

  // Shown from the back-forward cache: visibilitychange and pageshow, back to back.
  page.setVisibility('visible');
  page.win.dispatchEvent(Object.assign(new Event('pageshow'), { persisted: true }));
  assert.equal(net.calls.length, 4, 'one new request per row, not two');
  await page.clock.advance(RESUME_COALESCE_MS - 1);
  page.win.dispatchEvent(Object.assign(new Event('pageshow'), { persisted: true }));
  assert.equal(net.calls.length, 4, 'still one within RESUME_COALESCE_MS');
  assert.equal(net.calls[2].signal?.aborted, false);

  // A later return, with those requests still out: asked again, the old ones cancelled.
  await page.clock.advance(1);
  page.setVisibility('hidden');
  page.setVisibility('visible');
  assert.equal(net.calls.length, 6);
  assert.equal(net.calls[2].signal?.aborted, true);
  assert.equal(net.calls[3].signal?.aborted, true);
});

test('a return to the page leaves a strip menu row that answered alone', async () => {
  const net = presenceFetch();
  const { page } = await bootOnOfflineLaptop({ fetch: net.fetch });
  page.idb.plan.push('answer');
  page.stripButton().dispatchEvent(new Event('click'));
  await until(() => page.menuShown() && net.calls.length === 1, 'the menu asking for presence');
  net.answer(0, false);
  await until(() => page.strip.textContent.includes(MESSAGES.offlineRow), 'the menu reading offline');
  await page.clock.advance(RESUME_COALESCE_MS);
  page.setVisibility('hidden');
  page.setVisibility('visible');
  assert.equal(net.calls.length, 1, 'no new request');
  assert.ok(page.strip.textContent.includes(MESSAGES.offlineRow));
});

test('a return to the page asks for no presence once the menu has closed', async () => {
  const net = presenceFetch();
  const { page } = await bootOnOfflineLaptop({ fetch: net.fetch });
  page.idb.plan.push('answer');
  page.stripButton().dispatchEvent(new Event('click'));
  await until(() => page.menuShown() && net.calls.length === 1, 'the menu asking for presence');
  page.doc.dispatchEvent(Object.assign(new Event('keydown'), { key: 'Escape' }));
  assert.equal(page.menuShown(), false);
  page.setVisibility('hidden');
  page.setVisibility('visible');
  assert.equal(net.calls.length, 1);
});

// --- a connection, against a scripted laptop -----------------------------------------------

/**
 * Boots on a store holding one laptop, stored as `storedName`, that a scripted laptop on a fake
 * relay already waits for in its room. The page connects to it at once. After the store's
 * first read, each transaction runs as `plan` says.
 * @param {{ plan?: Array<'answer' | 'stall' | 'fail'>, prepare?: (laptop: any) => void }} [options]
 *   `prepare` runs with the scripted laptop before the page boots
 */
async function bootOnScriptedLaptop({ plan = [], prepare = () => {} } = {}) {
  const relay = createFakeRelay();
  const laptop = await createScriptedLaptop({ relay });
  const id = base64urlEncode(laptop.publicKey);
  const keys = await createWrappedPhoneKey(crypto.subtle, id);
  const room = base64urlEncode(new Uint8Array(randomBytes(32)));
  const record = validateLaptopRecord({
    id,
    relay: laptop.relayOrigin,
    room,
    laptopKey: laptop.publicKey,
    laptopName: 'old-name',
    phoneName: 'iPhone',
    phoneKey: keys.publicRaw,
    wrapKey: keys.wrapKey,
    wrappedKey: keys.wrappedKey,
    wrapIV: keys.wrapIV,
    pairedAt: NOW - 86_400_000,
    lastConnectedAt: NOW - 3_600_000,
  });
  laptop.devices.set(room, { phoneKey: keys.publicRaw, deviceName: 'iPhone' });
  laptop.join(room);
  prepare(laptop);
  const page = bootPage({ laptops: [record], openSocket: fakeSocketFactory(relay, { origin: laptop.relayOrigin }) });
  page.idb.plan.push('answer', ...plan);
  page.idb.succeed();
  /** The store names and mode of each transaction, as `names/mode`. */
  const calls = () => page.idb.calls.map(({ names, mode }) => `${names.join('+')}/${mode}`);
  return { page, laptop, room, record, calls };
}

test('a session that ends incompatible after message 2 records nothing, though the strip shows the handshake\'s name', async () => {
  const { page, laptop, calls } = await bootOnScriptedLaptop({ prepare: (l) => l.setIncompatible('laptop') });
  await waitFor(() => page.screen() === 'update', 'the Update TBD screen');
  assert.ok(laptop.counts.ikHandshakes >= 1, 'message 2 was read');
  assert.ok(page.stripButton()?.textContent.includes('acme-mbp'), 'the strip names the laptop as its handshake did');
  await quiet();
  assert.deepEqual(calls(), ['laptops/readonly'], 'no write: lastConnectedAt and the stored name stay as they were');
  assert.deepEqual(page.idb.writes, []);
});

test('the connecting screen takes the name the handshake reports, as the strip does', async () => {
  // The laptop was renamed since the last visit: stored as old-name, it is acme-mbp now. The
  // cache read stalls, so the page stays on the connecting screen after message 2.
  const { page } = await bootOnScriptedLaptop({ plan: ['stall'] });
  await waitFor(() => page.stripButton()?.textContent.includes('acme-mbp') ?? false, 'the strip naming the laptop from the handshake');
  assert.equal(page.screen(), 'connecting');
  assert.equal(page.text(), 'Connecting to acme-mbp…');
});

/**
 * Boots on the scripted laptop and waits until the app frame runs its bundle and the page has
 * recorded the connection. The store answers the cache read (a miss), stalls the cache write
 * and answers the record of the visit. Returns the runner's end of the frame's channel, and
 * the `channel` messages it receives.
 * @param {import('node:test').TestContext} t
 */
async function readyWithFrame(t) {
  const env = await bootOnScriptedLaptop({ plan: ['answer', 'stall', 'answer'] });
  const { page } = env;
  await waitFor(() => page.idb.writes.length === 1, 'the visit recorded');
  const iframe = page.doc.created.find((element) => element.tagName === 'iframe');
  assert.ok(iframe !== undefined, 'the app frame');
  // The runner's `ready`, as the sandboxed frame posts it: the page answers with the bundle
  // and the frame's end of the channel, which kept every message posted before it.
  const frameWindow = /** @type {any} */ (iframe).frameWindow;
  page.win.message({
    data: { type: 'ready', nonce: iframe.src.slice(iframe.src.indexOf('#n=') + 3) }, source: frameWindow, origin: 'null',
  });
  const port = /** @type {MessagePort} */ (frameWindow.posts[0].transfer[0]);
  t.after(() => port.close());
  /** @type {string[]} */
  const channel = [];
  port.addEventListener('message', (event) => {
    if (event.data?.t === 'channel') channel.push(event.data.state);
  });
  port.start();
  return { ...env, channel };
}

test('only a session that reaches ready records the visit, with the handshake\'s name, after its bundle', async (t) => {
  const { page, record, calls } = await readyWithFrame(t);
  assert.deepEqual(calls(), [
    'laptops/readonly', // the laptops, at boot
    'bundles+bundleMeta/readonly', // the cache read, a miss
    'laptops+bundles+bundleMeta/readwrite', // the bundle cached
    'laptops/readwrite', // the visit, once ready
  ]);
  const [written] = page.idb.writes;
  assert.equal(written.id, record.id);
  assert.equal(written.laptopName, 'acme-mbp');
  assert.equal(written.lastConnectedAt, page.clock.now());
  assert.equal(page.stripButton()?.textContent.includes('acme-mbp'), true);
});

test('a rename after the app frame replaced the connecting screen does nothing to that screen', async (t) => {
  const { page, laptop, room } = await readyWithFrame(t);
  /** The connecting screens drawn so far. */
  const connecting = () => page.doc.created.filter((element) => element.getAttribute('data-state') === 'connecting');
  const [drawn] = connecting();
  assert.equal(connecting().length, 1);
  assert.equal(drawn.textContent, 'Connecting to acme-mbp…');

  // The laptop is renamed and comes back: the strip takes the new name from the handshake.
  laptop.setLaptopName('acme-studio');
  laptop.leave(room);
  await waitFor(() => page.strip.textContent.includes('Reconnecting'), 'the strip reading Reconnecting…');
  laptop.join(room);
  await waitFor(() => page.stripButton()?.textContent.includes('acme-studio') ?? false, 'the strip naming acme-studio');
  assert.equal(drawn.textContent, 'Connecting to acme-mbp…', 'the connecting screen that went keeps its text');
  assert.equal(connecting().length, 1, 'no connecting screen was drawn again');
});

test('the app frame hears its channel go down once and come up once across a reconnect', async (t) => {
  const { page, laptop, room, channel } = await readyWithFrame(t);
  await waitFor(() => channel.length === 1, 'the first channel message');
  assert.deepEqual(channel, ['up']);

  // The laptop leaves (offline), then comes back: handshaking, then ready on the bundle the
  // frame already runs. Two states with the channel down, one message for them.
  laptop.leave(room);
  await waitFor(() => page.strip.textContent.includes('Reconnecting'), 'the strip reading Reconnecting…');
  laptop.join(room);
  await waitFor(() => channel.length > 1 && channel.at(-1) === 'up', 'the channel back up');
  await quiet();
  assert.deepEqual(channel, ['up', 'down', 'up']);
  assert.equal(page.idb.calls.filter((c) => c.mode === 'readwrite' && c.names.join() === 'laptops').length, 2, 'each ready records a visit');
});
