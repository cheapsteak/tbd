// main.js's boot, driven in Node through a fake window, document and IndexedDB: the pairing
// link leaves the address before anything else, links opened later are stripped whatever the
// page is doing, a store that does not answer ends in "Reload this page", never a blank page,
// and time while the page is hidden never counts against it. The strip's menu reads the store
// too, and a read of its that stalls only closes it. What needs a real browser (a handshake,
// the app frame) is in the e2e suite.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';

import { base64urlEncode } from '../../channel/pairingLink.js';
import { STORE_TIMEOUT_MS } from '../../constants.js';
import { createWrappedPhoneKey } from '../../keys.js';
import { boot } from '../../main.js';
import { MESSAGES } from '../../messages.js';
import { validateLaptopRecord } from '../../store.js';
import { FakeClock } from '../support/fake-clock.js';
import { FakeDocument, FakeWindow } from '../support/fake-dom.js';

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

  matchMedia() {
    return new EventTarget();
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
 * turn, and the transaction completes once none is left.
 * @param {any[]} laptops
 */
function answeringTransaction(laptops) {
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
 * transaction as `plan` says, in turn: `answer` reads `laptops`, `fail` throws as a closing
 * database does, and `stall` (also once the plan runs out) starts and never finishes, as a
 * stalled store does.
 * @param {string[]} log
 * @param {any[]} laptops the stored laptop rows
 */
function fakeIndexedDB(log, laptops) {
  /** @type {any[]} */
  const requests = [];
  /** @type {Array<'answer' | 'stall' | 'fail'>} */
  const plan = [];
  let transactions = 0;
  const db = {
    /** @type {(() => void) | null} */
    onclose: null,
    onversionchange: null,
    transaction() {
      transactions += 1;
      const how = plan.shift() ?? 'stall';
      if (how === 'fail') throw new DOMException('the database connection is closing', 'InvalidStateError');
      if (how === 'answer') return answeringTransaction(laptops);
      return { objectStore: () => ({ getAllKeys: () => ({}), get: () => ({}) }), abort() {} };
    },
    close() {},
  };
  return {
    requests,
    plan,
    db,
    transactions: () => transactions,
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
 * @param {{ href?: string, framed?: boolean, laptops?: any[], openSocket?: (url: string) => any }} [options]
 */
function bootPage({
  href = PAGE, framed = false, laptops = [], openSocket = () => {
    throw new TypeError('no sockets in these tests');
  },
} = {}) {
  /** @type {string[]} */
  const log = [];
  const win = new PageWindow(href, log, framed);
  const doc = new FakeDocument(win);
  for (const [tag, id] of [['header', 'strip'], ['main', 'screen'], ['div', 'frame-host'], ['div', 'safe-probe']]) {
    const el = doc.createElement(tag);
    el.setAttribute('id', id);
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
    fetch: async () => {
      throw new TypeError('no network in these tests');
    },
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
 */
async function bootOnOfflineLaptop() {
  const relay = relaySockets();
  const page = bootPage({ laptops: [await storedLaptop('acme-mbp')], openSocket: (url) => relay.openSocket(url) });
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
