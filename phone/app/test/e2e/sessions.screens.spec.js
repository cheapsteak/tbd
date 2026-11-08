// A screenshot of each state the sessions list draws, light and dark, for review beside the
// mocks' (docs/design/phone-control/screenshots/<scheme>/<state>.webp) with pairs.mjs. WebKit
// only, at the mocks' size: 390 × 844 points at 2× pixels. Each test drives the app into one
// state and saves screenshots/<light|dark>/<state>.png through `capture`.
//
// - `sessions`: the mock scenario after its subscribe.
// - `reconnect`: the same, then the channel drops, so the loader's strip says "Reconnecting…".

import { readFileSync } from 'node:fs';

import { app, capture, expect, hostCall, openApp, rowNames, test } from './fixtures.js';

test.skip(({ browserName }) => browserName !== 'webkit', 'the screenshots are taken in WebKit only');
test.use({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });

const MOCK = JSON.parse(readFileSync(new URL('scenarios/mock.json', import.meta.url), 'utf8'));
/** Every row of the mock scenario, by name, sorted as `rowNames` returns them. */
const MOCK_NAMES = MOCK.rows.map((/** @type {any} */ r) => r.name).sort();

test('sessions', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await expect.poll(() => rowNames(page)).toEqual(MOCK_NAMES);
  await capture(page, 'sessions', app(page).locator('.list-foot'));
});

test('reconnect', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await expect.poll(() => rowNames(page)).toEqual(MOCK_NAMES);
  await hostCall(page, 'setChannel', false);
  await expect(page.locator('#strip [data-state="reconnect"]')).toHaveText('Reconnecting…');
  await capture(page, 'reconnect', app(page).locator('.list-foot'));
});
