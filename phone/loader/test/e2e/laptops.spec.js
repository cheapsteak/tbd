// The Laptops screen, the header strip's laptop menu and Forget, end to end: status from the
// relay's presence endpoint (never a socket), switching laptops, and Forget behind a
// confirmation. WebKit as an iPhone and Chromium as an Android phone.

import { MESSAGES } from '../../messages.js';
import {
  appRoundTrip, deviceRoom, expect, openLaptop, openStripMenu, pairLaptops, pairViaFragment, readLoaderDB,
  screensSeen, stripButton, test, waitForAppText,
} from './fixtures.js';

/** @typedef {import('@playwright/test').Page} Page */
/** @typedef {import('./fake-laptop.js').FakeLaptopServer} FakeLaptopServer */

const EMPTY_DB = { laptops: [], rooms: [], bundles: [] };

/**
 * The sum of a per-room counter over every room.
 * @param {Map<string, number>} counter
 */
const total = (counter) => [...counter.values()].reduce((sum, n) => sum + n, 0);

/**
 * The Laptops screen's openable rows, in the order shown.
 * @param {Page} page
 */
const laptopRows = (page) => page.locator('[data-state="laptops"] button.lap-row');

/**
 * Adds acme-mini beside acme-mbp and pairs both, acme-mbp first, so the page ends connected
 * to acme-mini.
 * @param {Page} page
 * @param {FakeLaptopServer} server
 */
async function pairTwo(page, server) {
  const mbp = server.laptops[0];
  const mini = await server.addLaptop({ laptopName: 'acme-mini' });
  await pairLaptops(page, server, [mbp, mini]);
  return { mbp, mini };
}

/**
 * Gives every element matching `selector` a JS property, so a test can tell a node kept from
 * one built afresh.
 * @param {Page} page
 * @param {string} selector
 * @returns {Promise<number>} how many were tagged
 */
function tag(page, selector) {
  return page.evaluate((sel) => {
    const nodes = [...document.querySelectorAll(sel)];
    for (const node of nodes) /** @type {any} */ (node).__acmeTag = true;
    return nodes.length;
  }, selector);
}

/**
 * How many elements matching `selector` still carry the tag, and how many match.
 * @param {Page} page
 * @param {string} selector
 */
function tagged(page, selector) {
  return page.evaluate((sel) => {
    const nodes = [...document.querySelectorAll(sel)];
    return { tagged: nodes.filter((node) => /** @type {any} */ (node).__acmeTag === true).length, all: nodes.length };
  }, selector);
}

test('two laptops: the list shows both with status, and switching tears down the frame', async ({ page, server }) => {
  const mbp = server.laptops[0];
  const mini = await server.addLaptop({ laptopName: 'acme-mini' });
  mini.setBundle(server.debugBundle('mini'));
  await pairLaptops(page, server, [mbp, mini]);
  const joins = total(server.relay.stats.phoneJoins);
  const rooms = [deviceRoom(mbp), deviceRoom(mini)];
  const presence = () => rooms.map((room) => server.relay.stats.presence.get(room) ?? 0);
  const checked = presence();

  await page.reload();
  const rows = laptopRows(page);
  await expect(rows).toHaveCount(2);
  await expect(rows.nth(0).locator('b')).toHaveText('acme-mbp');
  await expect(rows.nth(1).locator('b')).toHaveText('acme-mini');
  await expect(rows.nth(0).locator('small')).toHaveText(/^Online · last connected/);
  await expect(rows.nth(1).locator('small')).toHaveText(/^Online · last connected/);
  // Each status came from the presence endpoint, and showing the list joined no room.
  const now = presence();
  expect(now[0]).toBeGreaterThan(checked[0]);
  expect(now[1]).toBeGreaterThan(checked[1]);
  expect(total(server.relay.stats.phoneJoins)).toBe(joins);

  await openLaptop(page, 'acme-mbp');
  await page.locator('#frame-host iframe').evaluate((el) => {
    /** @type {any} */ (el).__acmeTag = true;
  });
  const menu = await openStripMenu(page);
  await menu.getByRole('menuitemradio', { name: /acme-mini/ }).click();
  await waitForAppText(page, 'Variant: mini');
  await waitForAppText(page);
  await expect(page.locator('iframe')).toHaveCount(1);
  expect(await page.locator('#frame-host iframe').evaluate((el) => /** @type {any} */ (el).__acmeTag === true)).toBe(false);
  await expect(stripButton(page).locator('b')).toHaveText('acme-mini');
  await appRoundTrip(page, mini);
});

test('the laptops list shows Can\'t reach the relay on a row when presence fails', async ({ page, server }) => {
  await pairTwo(page, server);
  server.refusePresence = true;
  await page.reload();
  const rows = laptopRows(page);
  await expect(rows).toHaveCount(2);
  await expect(rows.nth(0).locator('small')).toHaveText(/^Can't reach the relay · last connected/);
  await expect(rows.nth(1).locator('small')).toHaveText(/^Can't reach the relay · last connected/);
});

test('a status check never knocks another tab off', async ({ context, page, server }) => {
  await page.clock.install();
  const { mbp, mini } = await pairTwo(page, server);
  const room = deviceRoom(mini);
  const joins = server.relay.stats.phoneJoins.get(room);
  const presence = () => server.relay.stats.presence.get(room) ?? 0;
  const checked = presence();

  // A second tab opens on the Laptops screen, which checks both laptops' status.
  const other = await context.newPage();
  await other.goto(`${server.origin}/`);
  const rows = laptopRows(other);
  await expect(rows.nth(0).locator('small')).toHaveText(/^Online/);
  await expect(rows.nth(1).locator('small')).toHaveText(/^Online/);
  expect(presence()).toBe(checked + 1);
  expect(server.relay.stats.presence.get(deviceRoom(mbp))).toBeGreaterThanOrEqual(1);

  await page.clock.fastForward(30_000);
  await appRoundTrip(page, mini);
  expect((await screensSeen(page)).map((screen) => screen.state)).not.toContain('replaced');
  await expect(page.locator('[data-state="reconnect"]')).toHaveCount(0);
  await expect(page.locator('#frame-host iframe')).toHaveCount(1);
  expect(server.relay.stats.phoneJoins.get(room)).toBe(joins);
});

test('the strip menu lists every paired laptop with its status and a check on the current one, plus Pair a laptop and Manage laptops', async ({ page, server }) => {
  await pairTwo(page, server);
  const menu = await openStripMenu(page);
  await expect(stripButton(page)).toHaveAttribute('aria-expanded', 'true');
  const items = menu.getByRole('menuitemradio');
  await expect(items).toHaveCount(2);
  await expect(items.nth(0)).toContainText('acme-mbp');
  await expect(items.nth(0)).toHaveAttribute('aria-checked', 'false');
  await expect(items.nth(0).locator('.tick')).toHaveCount(0);
  await expect(items.nth(1)).toContainText('acme-mini');
  await expect(items.nth(1)).toHaveAttribute('aria-checked', 'true');
  await expect(items.nth(1).locator('.tick')).toHaveCount(1);
  await expect(items.nth(0).locator('small')).toHaveText('Online');
  await expect(items.nth(1).locator('small')).toHaveText('Online');
  await expect(menu.getByRole('menuitem')).toHaveText(['Pair a laptop', 'Manage laptops']);

  await menu.getByRole('menuitem', { name: 'Manage laptops' }).click();
  await expect(page.locator('[data-state="laptops"]')).toBeVisible();
  await expect(page.locator('iframe')).toHaveCount(0);
});

test('the Laptops screen shows the Home Screen hint', async ({ page, server }) => {
  await pairViaFragment(page, server);
  await waitForAppText(page);
  const menu = await openStripMenu(page);
  await menu.getByRole('menuitem', { name: 'Manage laptops' }).click();
  await expect(page.locator('[data-state="laptops"] .homehint')).toHaveText(MESSAGES.homeScreenHint);
});

// --- Forget -----------------------------------------------------------------------------------

test('Forget from the laptops list deletes keys and bundles', async ({ page, server }) => {
  await pairViaFragment(page, server);
  await waitForAppText(page);
  await expect.poll(async () => (await readLoaderDB(page)).bundles.length).toBe(1);
  const menu = await openStripMenu(page);
  await menu.getByRole('menuitem', { name: 'Manage laptops' }).click();
  await page.locator('[data-state="laptops"]').getByRole('button', { name: 'Forget acme-mbp' }).click();
  await page.locator('[data-state="forget-ask"]').getByRole('button', { name: 'Forget', exact: true }).click();
  await expect(page.locator('[data-state="laptops"]')).toContainText('No laptops yet. Pair one to start.');
  expect(await readLoaderDB(page)).toEqual(EMPTY_DB);
});

test('Forget asks for confirmation, and Cancel keeps the keys and bundles', async ({ page, server }) => {
  const { mbp, mini } = await pairTwo(page, server);
  await expect.poll(async () => (await readLoaderDB(page)).bundles.length).toBe(2);
  const kept = await readLoaderDB(page);
  const menu = await openStripMenu(page);
  await menu.getByRole('menuitem', { name: 'Manage laptops' }).click();

  const list = page.locator('[data-state="laptops"]');
  await list.getByRole('button', { name: 'Forget acme-mbp' }).click();
  const ask = page.locator('[data-state="forget-ask"]');
  await expect(ask.locator('.ask')).toContainText('Forget acme-mbp? This phone deletes its keys for that laptop.');
  // Only the asked row turns into the question; the other stays a row.
  await expect(ask.locator('button.lap-row')).toHaveText([/acme-mini/]);
  expect(await readLoaderDB(page)).toEqual(kept);

  await ask.getByRole('button', { name: 'Cancel' }).click();
  await expect(list).toBeVisible();
  await expect(laptopRows(page)).toHaveCount(2);
  expect(await readLoaderDB(page)).toEqual(kept);

  await list.getByRole('button', { name: 'Forget acme-mbp' }).click();
  await ask.getByRole('button', { name: 'Forget', exact: true }).click();
  await expect(laptopRows(page)).toHaveText([/acme-mini/]);
  const after = await readLoaderDB(page);
  const miniID = after.laptops[0];
  expect(after.laptops).toHaveLength(1);
  expect(after.rooms).toEqual([deviceRoom(mini)]);
  expect(after.bundles.map(([id]) => id)).toEqual([miniID]);
  expect(kept.rooms).toContain(deviceRoom(mbp));
});

// --- presence answers --------------------------------------------------------------------------

test('a presence answer updates its row in place: a tap held across it still opens that laptop', async ({ page, server }) => {
  const { mbp } = await pairTwo(page, server);
  const release = server.holdPresence(deviceRoom(mbp));
  await page.reload();
  const rows = laptopRows(page);
  await expect(rows.nth(1).locator('small')).toHaveText(/^Online/);
  // acme-mbp's answer is held, so its row shows only when it last connected.
  await expect(rows.nth(0).locator('small')).toHaveText(/^Last connected/);

  const box = await rows.nth(0).boundingBox();
  if (box === null) throw new Error('the row is not on screen');
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  release();
  await expect(rows.nth(0).locator('small')).toHaveText(/^Online/);
  await page.mouse.up();

  await waitForAppText(page);
  await expect(stripButton(page).locator('b')).toHaveText('acme-mbp');
});

test('presence answers keep the rows and the menu items they update', async ({ page, server }) => {
  const { mbp, mini } = await pairTwo(page, server);
  const holds = () => [server.holdPresence(deviceRoom(mbp)), server.holdPresence(deviceRoom(mini))];

  let releases = holds();
  await page.reload();
  await expect(laptopRows(page)).toHaveCount(2);
  const rowNodes = '[data-state="laptops"] li, [data-state="laptops"] .lap-row, [data-state="laptops"] small';
  expect(await tag(page, rowNodes)).toBe(6);
  for (const release of releases) release();
  await expect(laptopRows(page).locator('small')).toHaveText([/^Online/, /^Online/]);
  expect(await tagged(page, rowNodes)).toEqual({ tagged: 6, all: 6 });

  await openLaptop(page, 'acme-mbp');
  releases = holds();
  const menu = await openStripMenu(page);
  const itemNodes = '[data-state="lapmenu"] .ldi, [data-state="lapmenu"] small';
  expect(await tag(page, itemNodes)).toBe(6);
  for (const release of releases) release();
  await expect(menu.getByRole('menuitemradio').locator('small')).toHaveText(['Online', 'Online']);
  expect(await tagged(page, itemNodes)).toEqual({ tagged: 6, all: 6 });
});
