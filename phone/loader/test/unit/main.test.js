// main.js's boot, driven in Node through a fake window, document and IndexedDB: the pairing
// link leaves the address before anything else, links opened later are stripped whatever the
// page is doing, and a store that does not answer ends in "Reload this page", never a blank
// page. What needs a real browser (a connection, the app frame) is in the e2e suite.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import { STORE_TIMEOUT_MS } from '../../constants.js';
import { boot } from '../../main.js';
import { MESSAGES } from '../../messages.js';
import { FakeClock } from '../support/fake-clock.js';
import { FakeDocument, FakeWindow } from '../support/fake-dom.js';

const vectors = JSON.parse(readFileSync(new URL('../../../test-vectors/pairing-link.json', import.meta.url), 'utf8'));
const NOW = vectors.now * 1000;
/** The loader page's address, with no fragment. */
const PAGE = vectors.loaderURL;
const [V1, V2] = vectors.valid;
const IPHONE_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2 Mobile/15E148 Safari/604.1';

const flush = () => new Promise((resolve) => setImmediate(resolve));

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
 * An IndexedDB whose `open` answers only when the test says so. An opened database starts
 * every transaction and never finishes one, as a stalled store does.
 * @param {string[]} log
 */
function fakeIndexedDB(log) {
  /** @type {any[]} */
  const requests = [];
  const stalled = {
    transaction: () => ({ objectStore: () => ({ getAllKeys: () => ({}), get: () => ({}) }), abort() {} }),
    close() {},
  };
  return {
    requests,
    open() {
      log.push('indexedDB.open');
      const request = {};
      requests.push(request);
      return request;
    },
    succeed() {
      requests[0].result = stalled;
      requests[0].onsuccess();
    },
    fail() {
      requests[0].error = new DOMException('the open failed', 'UnknownError');
      requests[0].onerror();
    },
  };
}

/**
 * Boots the loader on a fake page at `href`.
 * @param {{ href?: string, framed?: boolean }} [options]
 */
function bootPage({ href = PAGE, framed = false } = {}) {
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
  const idb = fakeIndexedDB(log);
  const booted = boot(/** @type {any} */ ({
    window: win,
    document: doc,
    clock,
    indexedDB: idb,
    subtle: crypto.subtle,
    fetch: async () => {
      throw new TypeError('no network in these tests');
    },
    openSocket: () => {
      throw new TypeError('no sockets in these tests');
    },
    requestAnimationFrame: (/** @type {() => void} */ callback) => setImmediate(callback),
  }));
  const screenEl = /** @type {any} */ (doc.getElementById('screen'));
  return {
    win,
    clock,
    idb,
    log,
    booted,
    /** The `data-state` of what the screen shows, or null when it shows nothing. */
    screen: () => screenEl.children[0]?.getAttribute('data-state') ?? null,
    text: () => screenEl.textContent,
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
