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
//
// A state is captured once the tap guard lets its acting buttons go, since the mocks draw them
// enabled.

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
