// The app bundle, end to end: downloading it, caching it, replacing it when the laptop's
// changes, and refusing a damaged or cut one, in WebKit as an iPhone and in Chromium as an
// Android phone.

import { createHash, randomBytes } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { base64urlEncode } from '../../channel/pairingLink.js';
import {
  deviceRoom, expect, pairViaFragment, readLoaderDB, screensSeen, stripButton, test, waitForAppFrame,
  waitForAppText,
} from './fixtures.js';

const DEBUG_APP = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../fixtures/debug-app.js');

/**
 * The lowercase hex SHA-256 of a bundle's UTF-8 text, as `welcome` names it.
 * @param {string} text
 */
const sha256 = (text) => createHash('sha256').update(text, 'utf8').digest('hex');

/**
 * The cached bundles' hashes, for one laptop.
 * @param {Array<[string, string]>} bundles from `readLoaderDB`
 * @param {string} laptopID
 */
const cachedFor = (bundles, laptopID) => bundles.filter(([id]) => id === laptopID).map(([, sha]) => sha).sort();

test('first connection downloads and caches the bundle; a reload fetches nothing', async ({ page, server }) => {
  const { laptop } = await pairViaFragment(page, server);
  await waitForAppText(page);
  expect(laptop.counts.bundleGet).toBe(1);
  const sha = sha256(await readFile(DEBUG_APP, 'utf8'));
  // The phone asked for exactly the hash `welcome` named.
  expect(laptop.log.filter((entry) => entry.type === 'bundle.get').map((entry) => entry.message.sha256)).toEqual([sha]);

  await page.reload();
  await waitForAppFrame(page);
  await waitForAppText(page);
  expect(laptop.counts.bundleGet).toBe(1);
  expect(laptop.counts.ikHandshakes).toBe(2);
  const db = await readLoaderDB(page);
  expect(db.bundles).toEqual([[base64urlEncode(laptop.publicKey), sha]]);
});

test('an updated laptop\'s bundle replaces the frame and at most two stay cached', async ({ page, server }) => {
  const { laptop } = await pairViaFragment(page, server);
  await waitForAppText(page);
  const id = base64urlEncode(laptop.publicKey);
  const first = sha256(await readFile(DEBUG_APP, 'utf8'));

  // B arrives on a fresh page load.
  const b = server.debugBundle('B');
  laptop.setBundle(b);
  await page.reload();
  await waitForAppText(page, 'Variant: B');
  expect(cachedFor((await readLoaderDB(page)).bundles, id)).toEqual([first, sha256(b)].sort());

  // C arrives while the page runs B: the laptop restarts its link, the phone reconnects and
  // the new bundle replaces the running frame in place.
  await page.locator('#frame-host iframe').evaluate((el) => {
    /** @type {any} */ (el).__acmeOld = true;
  });
  const c = server.debugBundle('C');
  laptop.setBundle(c);
  const room = deviceRoom(laptop);
  laptop.leave(room);
  await expect(page.locator('[data-state="reconnect"]')).toBeVisible();
  laptop.join(room);
  await waitForAppText(page, 'Variant: C');
  await expect(page.locator('iframe')).toHaveCount(1);
  expect(await page.locator('#frame-host iframe').evaluate((el) => /** @type {any} */ (el).__acmeOld === true)).toBe(false);
  await expect(page.locator('[data-state="reconnect"]')).toHaveCount(0);

  await expect.poll(async () => cachedFor((await readLoaderDB(page)).bundles, id)).toEqual([sha256(b), sha256(c)].sort());
  // And from the cache on the next load, with nothing fetched.
  const fetched = laptop.counts.bundleGet;
  await page.reload();
  await waitForAppText(page, 'Variant: C');
  expect(laptop.counts.bundleGet).toBe(fetched);
});

test('a damaged bundle shows Reload this page and is not cached', async ({ page, server }) => {
  const laptop = server.laptops[0];
  // `welcome` names a hash the bundle the laptop then sends does not have.
  laptop.setWelcome({ bundle: { sha256: '0'.repeat(64) } });
  await pairViaFragment(page, server, { waitForFrame: false });
  await expect(page.locator('[data-state="reload"] h2')).toHaveText('Reload this page');
  expect(laptop.counts.bundleGet).toBe(1);
  await expect(page.locator('iframe')).toHaveCount(0);
  await expect(stripButton(page).locator('b')).toHaveText('acme-mbp');
  const db = await readLoaderDB(page);
  expect(db.laptops).toEqual([base64urlEncode(laptop.publicKey)]);
  expect(db.bundles).toEqual([]);
});

test('a transfer cut by the laptop leaving caches nothing, and completes once it returns', async ({ page, server }) => {
  const laptop = server.laptops[0];
  // Random text deflates to about its own size, so this bundle takes at least two chunks.
  const big = `${server.debugBundle('big')}\n// ${randomBytes(90_000).toString('base64')}\n`;
  laptop.setBundle(big);
  /** @type {number[]} */
  const asked = [];
  laptop.onChunk((index) => {
    asked.push(index);
    return index === 1 ? 'stop' : undefined;
  });
  await pairViaFragment(page, server, { waitForFrame: false });
  await expect.poll(() => asked).toEqual([0, 1]);
  await expect(page.locator('[data-state="connecting"]')).toBeVisible();
  const room = deviceRoom(laptop);
  laptop.leave(room);

  await page.reload();
  await expect(page.locator('[data-state="offline"] h2')).toHaveText('Laptop offline');
  expect((await readLoaderDB(page)).bundles).toEqual([]);

  laptop.onChunk(null);
  laptop.join(room);
  await waitForAppFrame(page);
  await waitForAppText(page, 'Variant: big');
  expect(laptop.counts.bundleGet).toBe(2);
  await expect.poll(async () => (await readLoaderDB(page)).bundles).toEqual([[base64urlEncode(laptop.publicKey), sha256(big)]]);
  await waitForAppText(page);
  expect((await screensSeen(page)).map((screen) => screen.state)).not.toContain('reload');
});
