// The loader's IndexedDB store, end to end: a lost or damaged key or record, bundle pruning,
// two tabs, a newer loader taking the database, and a store that stops answering. WebKit as an
// iPhone and Chromium as an Android phone.

import { base64urlEncode } from '../../channel/pairingLink.js';
import { STORE_TIMEOUT_MS } from '../../constants.js';
import { MESSAGES } from '../../messages.js';
import {
  appRoundTrip, deviceRoom, expect, openLaptop, openStripMenu, pairLaptops, pairViaFragment, readLoaderDB,
  stripButton, test, waitForAppText,
} from './fixtures.js';

/** @typedef {import('@playwright/test').Page} Page */
/** @typedef {import('./fake-laptop.js').FakeLaptopServer} FakeLaptopServer */
/** @typedef {FakeLaptopServer['laptops'][number]} ScriptedLaptop */

const EMPTY_DB = { laptops: [], rooms: [], bundles: [] };

/**
 * A laptop's ID in the store: the base64url of its public key.
 * @param {ScriptedLaptop} laptop
 */
const idOf = (laptop) => base64urlEncode(laptop.publicKey);

/**
 * Changes one stored laptop record in place, from the page, as another loader version or a
 * damaged disk might have left it:
 * - `flipWrappedKey`: one bit of the wrapped private key flipped;
 * - `otherWrapKey`: the wrap key replaced by a fresh AES-GCM key of the same kind;
 * - `breakPairedAt`: `pairedAt` a string.
 * @param {Page} page on the loader's origin
 * @param {string} id
 * @param {'flipWrappedKey' | 'otherWrapKey' | 'breakPairedAt'} edit
 */
function editLaptop(page, id, edit) {
  return page.evaluate(async ({ id: key, edit: change }) => {
    const wrapKey = change === 'otherWrapKey'
      ? await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['wrapKey', 'unwrapKey'])
      : null;
    /** @type {IDBDatabase} */
    const db = await new Promise((resolve, reject) => {
      const request = indexedDB.open('tbd-loader');
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
    try {
      await new Promise((resolve, reject) => {
        const tx = db.transaction('laptops', 'readwrite');
        const store = tx.objectStore('laptops');
        const get = store.get(key);
        get.onsuccess = () => {
          const record = get.result;
          if (change === 'flipWrappedKey') record.wrappedKey[7] ^= 0x01;
          else if (change === 'otherWrapKey') record.wrapKey = wrapKey;
          else record.pairedAt = 'acme';
          store.put(record);
        };
        tx.oncomplete = () => resolve(undefined);
        tx.onabort = () => reject(tx.error);
      });
    } finally {
      db.close();
    }
  }, { id, edit });
}

/**
 * Each cached bundle's meta row, as `[laptopID, sha256, usedAt]`.
 * @param {Page} page on the loader's origin
 * @returns {Promise<Array<[string, string, number]>>}
 */
function readBundleMeta(page) {
  return page.evaluate(() => new Promise((resolve, reject) => {
    const request = indexedDB.open('tbd-loader');
    request.onerror = () => reject(request.error);
    request.onsuccess = () => {
      const db = request.result;
      const all = db.transaction('bundleMeta', 'readonly').objectStore('bundleMeta').getAll();
      all.onsuccess = () => {
        db.close();
        resolve(all.result.map((row) => [row.laptopID, row.sha256, row.usedAt]));
      };
      all.onerror = () => {
        db.close();
        reject(all.error);
      };
    };
  }));
}

/**
 * The hashes cached for one laptop, sorted.
 * @param {Page} page
 * @param {ScriptedLaptop} laptop
 */
async function cachedFor(page, laptop) {
  return (await readLoaderDB(page)).bundles.filter(([id]) => id === idOf(laptop)).map(([, sha]) => sha).sort();
}

/**
 * The SHA-256 a bundle text is cached under, read from what the phone asked the laptop for.
 * @param {ScriptedLaptop} laptop
 * @param {number} n which `bundle.get`, from 0
 */
function askedSha(laptop, n) {
  const asked = laptop.log.filter((entry) => entry.type === 'bundle.get');
  return /** @type {string} */ (asked[n].message.sha256);
}

/**
 * Reloads onto the Laptops screen and opens acme-mbp, which then serves `text`'s variant.
 * @param {Page} page
 * @param {string} variant
 */
async function reopenMbp(page, variant) {
  await page.reload();
  await openLaptop(page, 'acme-mbp', `Variant: ${variant}`);
  await waitForAppText(page);
}

// --- keys and records ----------------------------------------------------------------------

test('a damaged wrapped key shows the missing-key screen, and Forget removes only that laptop', async ({ page, server }) => {
  const mbp = server.laptops[0];
  const mini = await server.addLaptop({ laptopName: 'acme-mini' });
  await pairLaptops(page, server, [mbp, mini]);
  await expect.poll(async () => (await readLoaderDB(page)).bundles.length).toBe(2);
  await editLaptop(page, idOf(mbp), 'flipWrappedKey');
  const joins = server.relay.stats.phoneJoins.get(deviceRoom(mbp));

  await page.reload();
  await page.locator('[data-state="laptops"] button.lap-row', { hasText: 'acme-mbp' }).click();
  const screen = page.locator('[data-state="key-missing"]');
  await expect(screen.locator('h2')).toHaveText('This phone\'s key for acme-mbp is missing. Forget it and pair again.');
  await expect(stripButton(page).locator('b')).toHaveText('acme-mbp');
  // A key that does not unwrap opens no socket.
  expect(server.relay.stats.phoneJoins.get(deviceRoom(mbp))).toBe(joins);

  await screen.getByRole('button', { name: 'Forget acme-mbp' }).click();
  await screen.getByRole('button', { name: 'Forget', exact: true }).click();
  await expect(page.locator('[data-state="laptops"] button.lap-row')).toHaveText([/acme-mini/]);
  const db = await readLoaderDB(page);
  expect(db.laptops).toEqual([idOf(mini)]);
  expect(db.bundles.map(([id]) => id)).toEqual([idOf(mini)]);
});

test('a wrap key replaced by another AES key shows the missing-key screen', async ({ page, server }) => {
  const { laptop } = await pairViaFragment(page, server);
  await waitForAppText(page);
  await editLaptop(page, idOf(laptop), 'otherWrapKey');
  await page.reload();
  const screen = page.locator('[data-state="key-missing"]');
  await expect(screen.locator('h2')).toHaveText(MESSAGES.keyMissing('acme-mbp'));
  await screen.getByRole('button', { name: 'Forget acme-mbp' }).click();
  await screen.getByRole('button', { name: 'Forget', exact: true }).click();
  await expect(page.locator('[data-state="scan"], [data-state="paste"]')).toBeVisible();
  expect(await readLoaderDB(page)).toEqual(EMPTY_DB);
});

test('a damaged record shows as a damaged row beside a good laptop, is kept, and Forget removes it', async ({ page, server }) => {
  const mbp = server.laptops[0];
  const mini = await server.addLaptop({ laptopName: 'acme-mini' });
  await pairLaptops(page, server, [mbp, mini]);
  await expect.poll(async () => (await readLoaderDB(page)).bundles.length).toBe(2);
  await editLaptop(page, idOf(mini), 'breakPairedAt');
  const before = await readLoaderDB(page);

  await page.reload();
  const list = page.locator('[data-state="laptops"]');
  await expect(list.locator('button.lap-row')).toHaveText([/acme-mbp/]);
  const damaged = list.locator('div.lap-row');
  await expect(damaged).toHaveCount(1);
  await expect(damaged.locator('b')).toHaveText('acme-mini');
  await expect(damaged.locator('small')).toHaveText(MESSAGES.keyMissing('acme-mini'));
  // Loading the list deleted nothing.
  expect(await readLoaderDB(page)).toEqual(before);

  await list.getByRole('button', { name: 'Forget acme-mini' }).click();
  await page.locator('[data-state="forget-ask"]').getByRole('button', { name: 'Forget', exact: true }).click();
  await expect(page.locator('[data-state="laptops"] div.lap-row')).toHaveCount(0);
  const after = await readLoaderDB(page);
  expect(after.laptops).toEqual([idOf(mbp)]);
  expect(after.bundles.map(([id]) => id)).toEqual([idOf(mbp)]);
  await openLaptop(page, 'acme-mbp');
});

// --- pruning ---------------------------------------------------------------------------------

/**
 * Pairs acme-mini (its own bundle) and then acme-mbp serving A, caches B for acme-mbp, and
 * marks A used by loading it from the cache again. acme-mbp then has A and B cached, A the
 * more recently used.
 * @param {Page} page
 * @param {FakeLaptopServer} server
 */
async function cacheAThenBThenUseA(page, server) {
  const mbp = server.laptops[0];
  const mini = await server.addLaptop({ laptopName: 'acme-mini' });
  mbp.setBundle(server.debugBundle('A'));
  await pairLaptops(page, server, [mini, mbp]);
  await expect.poll(() => cachedFor(page, mbp)).toHaveLength(1);
  const miniCache = await cachedFor(page, mini);
  expect(miniCache).toHaveLength(1);
  const a = askedSha(mbp, 0);

  mbp.setBundle(server.debugBundle('B'));
  await reopenMbp(page, 'B');
  const b = askedSha(mbp, 1);
  await expect.poll(() => cachedFor(page, mbp)).toEqual([a, b].sort());

  mbp.setBundle(server.debugBundle('A'));
  const fetched = mbp.counts.bundleGet;
  await reopenMbp(page, 'A');
  expect(mbp.counts.bundleGet).toBe(fetched);
  const usedAt = async (/** @type {string} */ sha) => (await readBundleMeta(page)).find(([id, s]) => id === idOf(mbp) && s === sha)?.[2] ?? NaN;
  await expect.poll(async () => await usedAt(a) > await usedAt(b)).toBe(true);
  return { mbp, mini, miniCache, a, b, usedAt };
}

test('caching a third bundle keeps it and the most recently used other', async ({ page, server }) => {
  const { mbp, mini, miniCache, a } = await cacheAThenBThenUseA(page, server);
  mbp.setBundle(server.debugBundle('C'));
  await reopenMbp(page, 'C');
  const c = askedSha(mbp, 2);
  await expect.poll(() => cachedFor(page, mbp)).toEqual([a, c].sort());
  expect(await cachedFor(page, mini)).toEqual(miniCache);
});

test('a bundle cached with the clock set back is still kept', async ({ page, server }) => {
  await page.clock.install();
  const { mbp, mini, miniCache, a, b, usedAt } = await cacheAThenBThenUseA(page, server);
  const oldest = Math.min(await usedAt(a), await usedAt(b));
  await page.clock.setSystemTime(oldest - 3_600_000);
  mbp.setBundle(server.debugBundle('C'));
  await reopenMbp(page, 'C');
  const c = askedSha(mbp, 2);
  await expect.poll(() => cachedFor(page, mbp)).toEqual([a, c].sort());
  // C really is the oldest by its own `usedAt`, and kept all the same.
  expect(await usedAt(c)).toBeLessThan(oldest);
  expect(await cachedFor(page, mini)).toEqual(miniCache);
});

// --- tabs and versions -----------------------------------------------------------------------

test('a Forget in one tab is not undone by the other tab\'s touchLaptop or putBundle', async ({ context, page, server }) => {
  const mbp = server.laptops[0];
  const mini = await server.addLaptop({ laptopName: 'acme-mini' });
  // The page ends connected to acme-mbp.
  await pairLaptops(page, server, [mini, mbp]);
  await expect.poll(async () => (await readLoaderDB(page)).bundles.length).toBe(2);

  // The other tab opens on the Laptops screen, without a socket, and forgets acme-mbp.
  const other = await context.newPage();
  await other.goto(`${server.origin}/`);
  const list = other.locator('[data-state="laptops"]');
  await list.getByRole('button', { name: 'Forget acme-mbp' }).click();
  await other.locator('[data-state="forget-ask"]').getByRole('button', { name: 'Forget', exact: true }).click();
  await expect(other.locator('[data-state="laptops"] button.lap-row')).toHaveText([/acme-mini/]);

  // The first tab's connection runs on: the laptop restarts its link with a new bundle, so the
  // tab records the visit (touchLaptop) and caches the download (putBundle).
  const room = deviceRoom(mbp);
  mbp.setBundle(server.debugBundle('V'));
  mbp.leave(room);
  await expect(page.locator('#strip [data-state="reconnect"]')).toBeVisible();
  mbp.join(room);
  await waitForAppText(page, 'Variant: V');
  await waitForAppText(page);

  // Both writes began before this read, and IndexedDB runs them first.
  const db = await readLoaderDB(page);
  expect(db.laptops).toEqual([idOf(mini)]);
  expect(db.bundles.map(([id]) => id)).toEqual([idOf(mini)]);
  expect(await readLoaderDB(other)).toEqual(db);
});

test('a newer loader opening the database in another tab makes this tab show Reload this page', async ({ context, page, server }) => {
  await pairViaFragment(page, server);
  await waitForAppText(page);
  const other = await context.newPage();
  await other.goto(`${server.origin}/__test/blank.html`);
  const outcome = await other.evaluate(() => new Promise((resolve) => {
    const request = indexedDB.open('tbd-loader', 2);
    request.onsuccess = () => {
      request.result.close();
      resolve('opened');
    };
    request.onerror = () => resolve(`error: ${request.error?.name}`);
    request.onblocked = () => resolve('blocked');
  }));
  expect(outcome).toBe('opened');
  await expect(page.locator('[data-state="reload"] h2')).toHaveText('Reload this page');
  await expect(page.locator('[data-state="reload"]').getByRole('button', { name: 'Reload' })).toBeVisible();
  await expect(page.locator('iframe')).toHaveCount(0);
});

// --- a store that stops answering ------------------------------------------------------------

test('a store that never opens shows the spinner, then Reload this page', async ({ page, server }) => {
  await page.clock.install();
  await page.addInitScript(() => {
    IDBFactory.prototype.open = function open() {
      // A request that never answers.
      return /** @type {any} */ ({});
    };
  });
  await page.goto(`${server.origin}/`);
  await expect(page.locator('[data-state="loading"]')).toBeVisible();
  await page.clock.fastForward(STORE_TIMEOUT_MS);
  await expect(page.locator('[data-state="reload"] h2')).toHaveText('Reload this page');
  await expect(page.locator('[data-state="loading"]')).toHaveCount(0);
});

test('the strip menu\'s read never ends a session', async ({ page, server }) => {
  await page.clock.install();
  const { laptop } = await pairViaFragment(page, server);
  await waitForAppText(page);
  // Every transaction from here on stays open and none of its requests answers, as when
  // IndexedDB stalls. Stubbing getAllKeys alone cannot stall the read: a transaction with no
  // real request commits at once, and the menu would open listing no laptops.
  await page.evaluate(() => {
    const w = /** @type {any} */ (window);
    w.__acmeTransaction = IDBDatabase.prototype.transaction;
    const pending = () => ({});
    const store = { get: pending, getAll: pending, getAllKeys: pending, count: pending, put: pending, delete: pending, index: () => ({ getAllKeys: pending }) };
    IDBDatabase.prototype.transaction = /** @type {any} */ (function transaction() {
      return { objectStore: () => store, abort() {} };
    });
  });

  await stripButton(page).click();
  await page.clock.fastForward(STORE_TIMEOUT_MS);
  await expect(page.locator('[data-state="lapmenu"]')).toHaveCount(0);
  await expect(page.locator('[data-state="reload"]')).toHaveCount(0);
  await expect(page.locator('#frame-host iframe')).toHaveCount(1);
  await appRoundTrip(page, laptop);

  // The menu gave up rather than waiting on: once the store answers again, one tap opens it.
  await page.evaluate(() => {
    IDBDatabase.prototype.transaction = /** @type {any} */ (window).__acmeTransaction;
  });
  await openStripMenu(page);
});
