// Fixtures and helpers shared by the phone loader's end-to-end specs.
//
// - `server`: a fresh fake-laptop.js server for each test, built from the `serverOptions`
//   option (`test.use({ serverOptions: { … } })`).
// - Every page of the test's context records each screen the loader mounts (the elements
//   that carry `data-state`), so a test can check a screen that is on show only for a moment,
//   such as the code, which `paired` replaces at once. Read them with `screensSeen`.
// - The pairing helpers drive the loader through its real screens and controls.
// - `watchSockets` records the WebSockets a page opens, the pings it sends and the pongs it
//   gets, so a test can count the phone's joins from the phone's side.

import { expect, test as base } from '@playwright/test';

import { base64urlDecode } from '../../channel/pairingLink.js';
import { startFakeLaptop } from './fake-laptop.js';

export { linkFromFields } from './fake-laptop.js';

/** @typedef {import('@playwright/test').Page} Page */
/** @typedef {import('./fake-laptop.js').FakeLaptopServer} FakeLaptopServer */
/** @typedef {import('./fake-laptop.js').PairingLinkOptions} PairingLinkOptions */
/** @typedef {FakeLaptopServer['laptops'][number]} ScriptedLaptop */

/**
 * One screen as it was mounted: its `data-state`, its whole text, and the text of its code
 * element (`.check`) when it has one.
 * @typedef {{ state: string, text: string, code: string | null }} SeenScreen
 */

/**
 * @typedef {object} PairOptions
 * @property {ScriptedLaptop} [laptop] Default `server.laptops[0]`.
 * @property {string} [name] Typed into the name field; the default name stays when absent.
 * @property {string} [link] A link to use instead of a fresh offer from `laptop`.
 * @property {boolean} [waitForFrame] Wait for the app frame. Default: true for an `allow`
 *   offer, false otherwise.
 */

const utf8Decoder = new TextDecoder();

export const test = base.extend({
  serverOptions: [{}, { option: true }],
  server: async ({ serverOptions }, use) => {
    const server = await startFakeLaptop(serverOptions);
    try {
      await use(server);
    } finally {
      await server.close();
    }
  },
  context: async ({ context }, use) => {
    await context.addInitScript(recordScreens);
    await use(context);
  },
});

export { expect };

/**
 * Runs in every document of the context before its scripts: keeps a list of the loader's
 * screens in `window.__tbdScreens`. Only in a top-level page, never in the app frame.
 */
function recordScreens() {
  if (window.top !== window || '__tbdScreens' in window) return;
  /** @type {SeenScreen[]} */
  const seen = [];
  Object.defineProperty(window, '__tbdScreens', { value: seen });
  /** @param {Node} node */
  const take = (node) => {
    if (!(node instanceof Element)) return;
    const roots = node.matches('[data-state]') ? [node] : [];
    roots.push(...node.querySelectorAll('[data-state]'));
    for (const el of roots) {
      seen.push({
        state: el.getAttribute('data-state') ?? '',
        text: el.textContent ?? '',
        code: el.querySelector('.check')?.textContent ?? null,
      });
    }
  };
  new MutationObserver((records) => {
    for (const record of records) record.addedNodes.forEach(take);
  }).observe(document, { childList: true, subtree: true });
}

/**
 * Every screen the page's current document has mounted, in order.
 * @param {Page} page
 * @returns {Promise<SeenScreen[]>}
 */
export function screensSeen(page) {
  return page.evaluate(() => /** @type {any} */ (window).__tbdScreens ?? []);
}

/**
 * The fields of a pairing link's `#p=` payload.
 * @param {string} link
 * @returns {Record<string, any>}
 */
export function linkFields(link) {
  const payload = new URL(link).hash.slice('#p='.length);
  const bytes = base64urlDecode(payload);
  if (bytes === null) throw new TypeError('not a base64url payload');
  return JSON.parse(utf8Decoder.decode(bytes));
}

/**
 * Brings the loader to its pair screen from wherever it starts: the pair screen itself (no
 * laptops), the Laptops screen, or one laptop with the header strip (through its menu).
 * @param {Page} page
 */
export async function openPairScreen(page) {
  const pair = page.locator('[data-state="scan"], [data-state="paste"]');
  const laptops = page.locator('[data-state="laptops"]');
  const strip = page.locator('#strip .lapbtn');
  await expect(pair.or(laptops).or(strip).first()).toBeVisible();
  if (await pair.count() > 0) return;
  if (await laptops.isVisible()) {
    await laptops.getByRole('button', { name: 'Pair a laptop' }).click();
  } else {
    await strip.click();
    await page.locator('[data-state="lapmenu"]').getByRole('menuitem', { name: 'Pair a laptop' }).click();
  }
  await expect(pair.first()).toBeVisible();
}

/**
 * From the pair screen, the paste screen. The camera settles first: where it fails, the
 * scanner moves the page to the paste screen by itself, and a tap racing that move would land
 * on a screen that is gone. Once a stream is showing, the page stays on the scan screen until
 * a tap.
 * @param {Page} page
 */
export async function openPasteScreen(page) {
  const scan = page.locator('[data-state="scan"]');
  const paste = page.locator('[data-state="paste"]');
  await expect(scan.or(paste)).toBeVisible();
  await page.waitForFunction(() => document.querySelector('[data-state="paste"]') !== null
    || /** @type {HTMLVideoElement | null} */ (document.querySelector('[data-state="scan"] video'))?.srcObject != null);
  if (await scan.count() > 0) await scan.getByRole('button', { name: 'Paste link instead' }).click();
  await expect(paste).toBeVisible();
}

/**
 * Pastes `text` into the paste screen's field and taps Continue.
 * @param {Page} page
 * @param {string} text
 */
export async function pasteLink(page, text) {
  const paste = page.locator('[data-state="paste"]');
  await paste.locator('#paste-link').fill(text);
  await paste.getByRole('button', { name: 'Continue' }).click();
}

/**
 * On the name screen, types `name` (when given) and taps Continue.
 * @param {Page} page
 * @param {string} [name]
 */
export async function submitName(page, name) {
  const screen = page.locator('[data-state="name"]');
  await expect(screen).toBeVisible();
  if (name !== undefined) await screen.locator('#phone-name').fill(name);
  await screen.getByRole('button', { name: 'Continue' }).click();
}

/**
 * Pairs through the paste screen: opens the loader at `origin + '/'`, goes to the pair screen
 * and on to the paste screen, pastes the link and names the phone.
 * @param {Page} page
 * @param {FakeLaptopServer} server
 * @param {PairOptions & PairingLinkOptions} [options] the offer options go to `pairingLink`
 * @returns {Promise<{ laptop: ScriptedLaptop, link: string }>}
 */
export async function pairViaPaste(page, server, options = {}) {
  const { laptop, link, offer, waitForFrame } = prepare(server, options);
  await page.goto(`${server.origin}/`);
  await openPairScreen(page);
  await openPasteScreen(page);
  await pasteLink(page, link);
  await submitName(page, options.name);
  if (waitForFrame ?? offer.decision === 'allow') await waitForAppFrame(page);
  return { laptop, link };
}

/**
 * Pairs by opening the link itself, `${origin}/#p=…`, and naming the phone.
 * @param {Page} page
 * @param {FakeLaptopServer} server
 * @param {PairOptions & PairingLinkOptions} [options]
 * @returns {Promise<{ laptop: ScriptedLaptop, link: string }>}
 */
export async function pairViaFragment(page, server, options = {}) {
  const { laptop, link, offer, waitForFrame } = prepare(server, options);
  await page.goto(link);
  await submitName(page, options.name);
  if (waitForFrame ?? offer.decision === 'allow') await waitForAppFrame(page);
  return { laptop, link };
}

/**
 * @param {FakeLaptopServer} server
 * @param {PairOptions & PairingLinkOptions} options
 */
function prepare(server, options) {
  const { laptop = server.laptops[0], name: _name, link, waitForFrame, ...rest } = options;
  const offer = { decision: 'allow', ...rest };
  return { laptop, offer, waitForFrame, link: link ?? server.pairingLink(laptop, offer) };
}

/**
 * Waits for the app frame to be in the page, on show.
 * @param {Page} page
 */
export async function waitForAppFrame(page) {
  await expect(page.locator('#frame-host iframe')).toHaveCount(1);
  await expect(page.locator('#frame-host')).toBeVisible();
}

/**
 * What the loader's IndexedDB holds: each laptop's ID and stored room, in the store's key
 * order, and the key `[laptopID, sha256]` of each cached bundle. A loader that has not made
 * its database yet reads as empty, and reading never makes one.
 * @param {Page} page on the loader's origin
 * @returns {Promise<{ laptops: string[], rooms: string[], bundles: Array<[string, string]> }>}
 */
export function readLoaderDB(page) {
  return page.evaluate(() => new Promise((resolve, reject) => {
    const empty = { laptops: [], rooms: [], bundles: [] };
    let creating = false;
    const request = indexedDB.open('tbd-loader');
    request.onupgradeneeded = () => {
      // No database yet. Abort, so this read does not make one at version 1 with no stores.
      creating = true;
      request.transaction?.abort();
    };
    request.onerror = () => {
      if (creating) resolve(empty);
      else reject(new Error(`could not open tbd-loader: ${request.error?.name}`));
    };
    request.onblocked = () => reject(new Error('opening tbd-loader was blocked'));
    request.onsuccess = () => {
      const db = request.result;
      const tx = db.transaction(['laptops', 'bundles'], 'readonly');
      const laptops = tx.objectStore('laptops').getAll();
      const bundles = tx.objectStore('bundles').getAllKeys();
      tx.oncomplete = () => {
        db.close();
        resolve({
          laptops: laptops.result.map((record) => record?.id),
          rooms: laptops.result.map((record) => record?.room),
          bundles: bundles.result,
        });
      };
      tx.onabort = () => {
        db.close();
        reject(new Error(`reading tbd-loader failed: ${tx.error?.name}`));
      };
    };
  }));
}

/**
 * The text of the app frame's document, or '' while there is no app frame.
 * @param {Page} page
 * @returns {Promise<string>}
 */
export async function frameText(page) {
  const frame = page.frames().find((f) => f !== page.mainFrame() && f.url().includes('/runner.html'));
  if (frame === undefined) return '';
  try {
    return await frame.evaluate(() => document.body?.textContent ?? '');
  } catch {
    // The frame went away while it was read.
    return '';
  }
}

/**
 * The device room of a laptop this phone paired with once: the room its `paired` carried.
 * @param {ScriptedLaptop} laptop
 * @returns {string}
 */
export function deviceRoom(laptop) {
  const rooms = [...laptop.devices.keys()];
  if (rooms.length !== 1) throw new Error(`the laptop has ${rooms.length} devices, not 1`);
  return rooms[0];
}

/**
 * Waits for the app frame's text to contain `text`: the debug app's sessions, by default.
 * @param {Page} page
 * @param {string} [text]
 */
export async function waitForAppText(page, text = 'acme-api') {
  await expect.poll(() => frameText(page)).toContain(text);
}

/**
 * The header strip's laptop button; its `b` is the laptop's name.
 * @param {Page} page
 */
export function stripButton(page) {
  return page.locator('#strip .lapbtn');
}

/**
 * Taps the header strip and waits for its laptop menu.
 * @param {Page} page
 * @returns {Promise<import('@playwright/test').Locator>} the menu
 */
export async function openStripMenu(page) {
  const menu = page.locator('[data-state="lapmenu"]');
  await stripButton(page).click();
  await expect(menu).toBeVisible();
  return menu;
}

/**
 * On the Laptops screen, taps the laptop named `name` and waits for its app.
 * @param {Page} page
 * @param {string} name
 * @param {string} [text] what the app frame then shows
 */
export async function openLaptop(page, name, text = 'acme-api') {
  const list = page.locator('[data-state="laptops"]');
  await expect(list).toBeVisible();
  await list.locator('button.lap-row', { hasText: name }).click();
  await waitForAppFrame(page);
  await waitForAppText(page, text);
  await expect(stripButton(page).locator('b')).toHaveText(name);
}

/**
 * Pairs each laptop in turn and waits for its app: the first by opening its link, so the page
 * starts afresh, and the others through the paste screen, which the header strip's menu reaches.
 * The page ends connected to the last.
 * @param {Page} page
 * @param {FakeLaptopServer} server
 * @param {ScriptedLaptop[]} laptops
 */
export async function pairLaptops(page, server, laptops) {
  for (const [i, laptop] of laptops.entries()) {
    if (i === 0) await pairViaFragment(page, server, { laptop });
    else await pairViaPaste(page, server, { laptop });
    await waitForAppText(page);
  }
}

/**
 * What a page's WebSockets did, as `watchSockets` records it.
 * @typedef {{ opened: string[], pingsSent: number, pongs: number }} SocketLog
 */

/**
 * Makes each later document of `page` record its WebSockets: the URL of each one it opens,
 * the pings it sends and the pongs it gets. A pong is counted before the loader's own handler
 * sees it, in the same dispatch, so a count read afterwards means the loader has had it too.
 * Read it with `socketLog`.
 * @param {Page} page
 */
export async function watchSockets(page) {
  await page.addInitScript(() => {
    if (window.top !== window || '__tbdSockets' in window) return;
    /** @type {SocketLog} */
    const log = { opened: [], pingsSent: 0, pongs: 0 };
    Object.defineProperty(window, '__tbdSockets', { value: log });
    const Native = window.WebSocket;
    class Watched extends Native {
      /**
       * @param {string | URL} url
       * @param {string | string[]} [protocols]
       */
      constructor(url, protocols) {
        super(url, protocols);
        log.opened.push(String(url));
        this.addEventListener('message', (event) => {
          if (event.data === 'pong') log.pongs += 1;
        });
      }

      /** @param {string | ArrayBufferLike | Blob | ArrayBufferView} data */
      send(data) {
        if (data === 'ping') log.pingsSent += 1;
        super.send(data);
      }
    }
    window.WebSocket = Watched;
  });
}

/**
 * @param {Page} page
 * @returns {Promise<SocketLog>}
 */
export function socketLog(page) {
  return page.evaluate(() => /** @type {any} */ (window).__tbdSockets);
}

/**
 * How many phone sockets the page has opened to `room`.
 * @param {Page} page
 * @param {string} room
 */
export async function phoneSocketsTo(page, room) {
  const { opened } = await socketLog(page);
  return opened.filter((url) => url.endsWith(`/v1/rooms/${room}?role=phone`)).length;
}

let roundTrips = 0;

/**
 * One app message each way: the laptop asks the debug app to open a link, the app asks the
 * loader (which shows the link sheet) and tells the laptop. The sheet is then cancelled.
 * @param {Page} page
 * @param {ScriptedLaptop} laptop
 */
export async function appRoundTrip(page, laptop) {
  roundTrips += 1;
  const url = `https://example.com/acme-${roundTrips}`;
  const sent = await laptop.sendApp(deviceRoom(laptop), { kind: 'event', event: 'debug.openLink', data: { url } });
  expect(sent).toBe(true);
  await expect.poll(() => laptop.appBodies.some((body) => /** @type {any} */ (body).event === 'debug.openLinkSent'
    && /** @type {any} */ (body).data?.url === url)).toBe(true);
  const sheet = page.locator('[data-state="link"]');
  await expect(sheet.locator('.url')).toHaveText(url);
  await sheet.getByRole('button', { name: 'Cancel' }).click();
  await expect(sheet).toHaveCount(0);
}

/**
 * Runs in a runner document (pass it to `frame.evaluate`): claims the Trusted Types policy
 * name `runner`, which the runner's policy allows exactly once. 'free' means runner.js never
 * made its policy, so it stopped before step 2 or never ran.
 * @returns {string}
 */
export function claimRunnerPolicy() {
  const trustedTypes = /** @type {any} */ (globalThis).trustedTypes;
  if (!trustedTypes) return 'no trustedTypes';
  try {
    trustedTypes.createPolicy('runner', {});
    return 'free';
  } catch (error) {
    return `taken: ${String(error)}`;
  }
}
