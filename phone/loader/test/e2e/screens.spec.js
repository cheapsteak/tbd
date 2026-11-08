// A screenshot of every loader state, light and dark, for review beside the mocks'
// (docs/design/phone-control/screenshots/<scheme>/<state>.webp). WebKit only, at the mocks'
// size: 390 × 844 points at 2× pixels. Each test drives the real loader against
// fake-laptop.js into one state, waits for the element that carries its `data-state`, and
// saves screenshots/<light|dark>/<state>.png. The folder is gitignored; CI uploads it.
//
// Laptops are named as in the mocks: `acme-laptop`, online, and `acme-studio`, offline and
// last connected 2 days ago. The page's clock stands still: 2 days back while acme-studio
// pairs, then at the present, so every "last connected" text reads the same however long a
// run takes. Timers still run. Run only this file with `npm run screenshots` in phone/.

import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  deviceRoom, expect, openPasteScreen, openStripMenu, pairViaFragment, pasteLink, submitName, test, waitForAppFrame,
  waitForAppText,
} from './fixtures.js';

/** @typedef {import('@playwright/test').Page} Page */
/** @typedef {import('./fake-laptop.js').FakeLaptopServer} FakeLaptopServer */

const SHOTS = path.join(path.dirname(fileURLToPath(import.meta.url)), 'screenshots');
const DAY_MS = 24 * 60 * 60 * 1000;

test.skip(({ browserName }) => browserName !== 'webkit', 'the screenshots are taken in WebKit only');
test.use({
  viewport: { width: 390, height: 844 },
  deviceScaleFactor: 2,
  serverOptions: { laptopName: 'acme-laptop' },
});

/**
 * Saves the page in both colour schemes, once the element with `data-state="<state>"` shows.
 * Animations are stopped, so each spinner is drawn at its start.
 * @param {Page} page
 * @param {string} state
 */
async function capture(page, state) {
  for (const colorScheme of /** @type {const} */ (['light', 'dark'])) {
    await page.emulateMedia({ colorScheme });
    await expect(page.locator(`[data-state="${state}"]`)).toBeVisible();
    await page.screenshot({
      path: path.join(SHOTS, colorScheme, `${state}.png`),
      fullPage: true,
      animations: 'disabled',
    });
  }
}

/**
 * Pairs acme-studio two days back and acme-laptop now, as the mocks show them: the page ends
 * connected to acme-laptop, and acme-studio has left its room, so it reads as offline.
 * @param {Page} page
 * @param {FakeLaptopServer} server
 */
async function pairTwo(page, server) {
  const now = Date.now();
  await page.clock.setFixedTime(now - 2 * DAY_MS);
  const laptop = server.laptops[0];
  const studio = await server.addLaptop({ laptopName: 'acme-studio' });
  await pairViaFragment(page, server, { laptop: studio });
  await waitForAppText(page);
  // acme-studio leaves before the page loads again, so it is never reached, and keeps the
  // time it last connected.
  studio.leave(deviceRoom(studio));
  await page.clock.setFixedTime(now);
  await page.reload();
  await expect(page.locator('[data-state="offline"]')).toBeVisible();
  const menu = await openStripMenu(page);
  await menu.getByRole('menuitem', { name: 'Pair a laptop' }).click();
  await openPasteScreen(page);
  await pasteLink(page, server.pairingLink(laptop));
  await submitName(page);
  await waitForAppFrame(page);
  await waitForAppText(page);
  return { laptop, studio };
}

/**
 * Pairs acme-laptop alone and waits for its app.
 * @param {Page} page
 * @param {FakeLaptopServer} server
 */
async function pairOne(page, server) {
  const { laptop } = await pairViaFragment(page, server);
  await waitForAppText(page);
  return laptop;
}

/**
 * Makes the camera wait forever, as one does while the user decides on the permission
 * prompt: the pair screen then stays up with its camera area empty.
 * @param {Page} page
 */
async function holdCamera(page) {
  await page.addInitScript(() => {
    const getUserMedia = () => new Promise(() => {});
    // On the prototype: in WebKit, an own property on navigator.mediaDevices does not hold.
    if (typeof MediaDevices === 'function') {
      Object.defineProperty(MediaDevices.prototype, 'getUserMedia', { configurable: true, writable: true, value: getUserMedia });
    } else {
      Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: { getUserMedia } });
    }
  });
}

// --- two laptops -------------------------------------------------------------------------------

test('lapmenu', async ({ page, server }) => {
  await pairTwo(page, server);
  const menu = await openStripMenu(page);
  await expect(menu.getByRole('menuitemradio').locator('small'))
    .toHaveText(['Online', 'Offline · last connected 2 days ago']);
  await capture(page, 'lapmenu');
});

test('laptops', async ({ page, server }) => {
  await pairTwo(page, server);
  const menu = await openStripMenu(page);
  await menu.getByRole('menuitem', { name: 'Manage laptops' }).click();
  await expect(page.locator('[data-state="laptops"] .lap-row small'))
    .toHaveText(['Online · last connected just now', 'Offline · last connected 2 days ago']);
  await capture(page, 'laptops');
});

test('forget-ask', async ({ page, server }) => {
  await pairTwo(page, server);
  const menu = await openStripMenu(page);
  await menu.getByRole('menuitem', { name: 'Manage laptops' }).click();
  const list = page.locator('[data-state="laptops"]');
  await expect(list.locator('.lap-row small')).toHaveText([/^Online/, /^Offline/]);
  await list.getByRole('button', { name: 'Forget acme-studio' }).click();
  await expect(page.locator('[data-state="forget-ask"] .lap-row small')).toHaveText(['Online · last connected just now']);
  await capture(page, 'forget-ask');
});

test('offline', async ({ page, server }) => {
  await pairTwo(page, server);
  const menu = await openStripMenu(page);
  await menu.getByRole('menuitemradio', { name: /acme-studio/ }).click();
  await expect(page.locator('[data-state="offline"] p')).toHaveText(/^acme-studio last connected 2 days ago\./);
  await capture(page, 'offline');
});

// --- pairing -----------------------------------------------------------------------------------

test('scan', async ({ page, server }) => {
  await holdCamera(page);
  await page.goto(`${server.origin}/`);
  await capture(page, 'scan');
});

test('paste', async ({ page, server }) => {
  // The camera waits, so the paste screen is the user's choice and carries no camera error.
  await holdCamera(page);
  await page.goto(`${server.origin}/`);
  await page.locator('[data-state="scan"]').getByRole('button', { name: 'Paste link instead' }).click();
  await expect(page.locator('[data-state="paste"] [role="alert"]')).toHaveCount(0);
  await capture(page, 'paste');
});

test('name', async ({ page, server }) => {
  await page.goto(server.pairingLink(server.laptops[0]));
  await expect(page.locator('[data-state="name"] #phone-name')).toHaveValue('iPhone');
  await capture(page, 'name');
});

for (const { state, decision } of [
  // A laptop that never answers holds the code on screen, waiting for Allow.
  { state: 'code', decision: /** @type {const} */ ('silent') },
  { state: 'denied', decision: /** @type {const} */ ('deny') },
  { state: 'expired', decision: /** @type {const} */ ('expire') },
]) {
  test(state, async ({ page, server }) => {
    await page.goto(`${server.origin}/`);
    await openPasteScreen(page);
    await pasteLink(page, server.pairingLink(server.laptops[0], { decision }));
    await submitName(page);
    await capture(page, state);
  });
}

// --- one laptop --------------------------------------------------------------------------------

test('connecting', async ({ page, server }) => {
  await pairOne(page, server);
  // Every socket stays connecting, so the laptop never answers.
  server.holdUpgrades();
  await page.reload();
  await capture(page, 'connecting');
});

for (const { state, setup } of [
  { state: 'update', setup: (/** @type {any} */ laptop) => laptop.setIncompatible('laptop') },
  { state: 'reload', setup: (/** @type {any} */ laptop) => laptop.setIncompatible('loader') },
]) {
  test(state, async ({ page, server }) => {
    const laptop = await pairOne(page, server);
    setup(laptop);
    await page.reload();
    await capture(page, state);
  });
}

test('removed', async ({ page, server }) => {
  const laptop = await pairOne(page, server);
  await laptop.revoke(deviceRoom(laptop));
  await capture(page, 'removed');
});

test('relay', async ({ page, server }) => {
  await pairOne(page, server);
  server.refuseUpgrade = true;
  await page.reload();
  await capture(page, 'relay');
});

test('reconnect', async ({ page, server }) => {
  const laptop = await pairOne(page, server);
  laptop.leave(deviceRoom(laptop));
  await expect(page.locator('#frame-host iframe')).toHaveCount(1);
  await capture(page, 'reconnect');
});
