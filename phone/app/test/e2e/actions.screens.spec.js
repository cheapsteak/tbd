// A screenshot of each state the session header's menus and the session's sheets draw, light and
// dark, for review beside the mocks' (docs/design/phone-control/screenshots/<scheme>/<state>.webp)
// with pairs.mjs. WebKit only, at the mocks' size: 390 × 844 points at 2× pixels. Each test drives
// the app into one state and saves screenshots/<light|dark>/<state>.png through `capture`. Each
// opens the session the mock's state shows (mock 1348-1357), with the transcript read at its
// bottom.
//
// - `profmenu`: Checkout v2's Review tab (the mock's `s-co-rev`, on acme-work) with its account
//   menu open.
// - `prof-ask`: the same with Personal picked, so the menu asks about restarting under it.
// - `modelmenu`: the same tab with its model menu open.
// - `menu`: Login redirect fix (the mock's `s-login`), its question in the dock, with the session
//   menu sheet open.
// - `switch`: Checkout v2's Review tab with the Switch account sheet open.
// - `switch-ask`: the same with Personal picked, so the sheet asks about restarting under it.
// - `fork`: the same tab with the Fork sheet open.
// - `model`: the same tab with the Model sheet open, nothing picked yet, so Set waits.
// - `new-local`: the sessions list with acme-web's New sheet open, its first message the mock's.
// - `new-remote`: acme-api's New sheet on Remote session, acme-cloud picked, with the mock's
//   message (mock 1356-1357).
//
// A state is captured once the tap guard lets its acting buttons go, since the mocks draw them
// enabled. The Model sheet's Set is the exception: it waits for a pick, which the mock makes the
// current model when the sheet opens.

import { app, capture, expect, openApp, openSessionByName, test } from './fixtures.js';

/** @typedef {import('@playwright/test').Page} Page */

test.skip(({ browserName }) => browserName !== 'webkit', 'the screenshots are taken in WebKit only');
test.use({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });

/**
 * Opens Checkout v2's tab named `tab` and waits until its transcript is read at its bottom.
 * @param {Page} page
 * @param {string} rowName
 * @param {string} [tab]
 */
async function openAtBottom(page, rowName, tab) {
  await openSessionByName(page, rowName, tab);
  const tx = app(page).locator('.tx');
  await expect(tx.locator('[data-tx-row]').first()).toBeVisible();
  await expect.poll(() => tx.evaluate((el) => el.scrollHeight - el.scrollTop - el.clientHeight)).toBeLessThanOrEqual(1);
}

test('profmenu', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openAtBottom(page, 'Checkout v2', 'Review');
  await app(page).getByRole('button', { name: 'Account: acme-work. Switch account' }).click();
  const menu = app(page).getByRole('menu', { name: 'Account for this session' });
  await expect(menu.getByRole('menuitemradio')).toHaveCount(3);
  await capture(page, 'profmenu', menu.getByRole('menuitemradio').last());
});

test('prof-ask', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openAtBottom(page, 'Checkout v2', 'Review');
  await app(page).getByRole('button', { name: 'Account: acme-work. Switch account' }).click();
  const menu = app(page).getByRole('menu', { name: 'Account for this session' });
  await menu.getByRole('menuitemradio', { name: /^Personal/ }).click();
  const restart = menu.getByRole('button', { name: 'Restart' });
  await expect(restart).toBeEnabled();
  await capture(page, 'prof-ask', restart);
});

test('modelmenu', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openAtBottom(page, 'Checkout v2', 'Review');
  await app(page).getByRole('button', { name: 'Model: opus. Change model' }).click();
  const menu = app(page).getByRole('menu', { name: 'Model for this session' });
  await expect(menu.getByRole('menuitemradio').last()).toBeEnabled();
  await capture(page, 'modelmenu', menu.getByRole('menuitemradio').last());
});

/**
 * Opens the session menu sheet from the header, then the row of it named `row`, if given.
 * @param {Page} page
 * @param {string} [row]
 */
async function openSheet(page, row) {
  await app(page).getByRole('button', { name: 'Session menu' }).click();
  const sheet = app(page).getByRole('dialog');
  await expect(sheet).toBeVisible();
  if (row !== undefined) await sheet.locator('button.mi', { hasText: row }).click();
  return sheet;
}

test('menu', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openAtBottom(page, 'Login redirect fix');
  await expect(app(page).locator('.dock .card')).toBeVisible();
  const sheet = await openSheet(page);
  await capture(page, 'menu', sheet.getByRole('button', { name: 'Cancel' }));
});

test('switch', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openAtBottom(page, 'Checkout v2', 'Review');
  const sheet = await openSheet(page, 'Switch account');
  await expect(sheet.locator('button.mi')).toHaveCount(3);
  await capture(page, 'switch', sheet.locator('button.mi').last());
});

test('switch-ask', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openAtBottom(page, 'Checkout v2', 'Review');
  const sheet = await openSheet(page, 'Switch account');
  await sheet.locator('button.mi', { hasText: 'Personal' }).click();
  const restart = sheet.getByRole('button', { name: 'Restart' });
  await expect(restart).toBeEnabled();
  await capture(page, 'switch-ask', restart);
});

test('fork', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openAtBottom(page, 'Checkout v2', 'Review');
  const sheet = await openSheet(page, 'Copy this conversation into a new tab');
  await expect(sheet.locator('button.mi')).toHaveCount(3);
  await expect(sheet.locator('button.mi').last()).toBeEnabled();
  await capture(page, 'fork', sheet.locator('button.mi').last());
});

test('model', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openAtBottom(page, 'Checkout v2', 'Review');
  const sheet = await openSheet(page, 'Now opus');
  await expect(sheet.locator('.sh-title')).toHaveText('Model');
  await capture(page, 'model', sheet.getByLabel('Other model name'));
});

/**
 * Opens the New sheet of `repo` from its "+" on the sessions list.
 * @param {Page} page
 * @param {string} repo
 */
async function openNew(page, repo) {
  await app(page).getByRole('button', { name: `New session in ${repo}` }).click();
  const sheet = app(page).getByRole('dialog');
  await expect(sheet.locator('.sh-title')).toHaveText(`New in ${repo}`);
  return sheet;
}

test('new-local', async ({ page, appHost }) => {
  await openApp(page, appHost);
  const sheet = await openNew(page, 'acme-web');
  const message = sheet.getByRole('textbox', { name: 'First message' });
  await message.fill('Add a dark mode toggle to the settings screen.');
  // The mock draws the field without focus.
  await message.blur();
  const create = sheet.getByRole('button', { name: 'Create', exact: true });
  await expect(create).toBeEnabled();
  await capture(page, 'new-local', create);
});

test('new-remote', async ({ page, appHost }) => {
  await openApp(page, appHost);
  const sheet = await openNew(page, 'acme-api');
  await sheet.getByRole('button', { name: 'Remote session' }).click();
  const cloud = sheet.locator('button.mi', { hasText: 'acme-cloud' });
  await expect(cloud).toBeEnabled();
  await cloud.click();
  const message = sheet.getByRole('textbox', { name: 'First message' });
  await message.fill('Profile the slow orders query and suggest an index.');
  await message.blur();
  const create = sheet.getByRole('button', { name: 'Create', exact: true });
  await expect(create).toBeEnabled();
  await expect(cloud).toBeEnabled();
  await capture(page, 'new-remote', create);
});
