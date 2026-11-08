// A screenshot of each state the app shell draws, light and dark, for review beside the mocks'
// (docs/design/phone-control/screenshots/<scheme>/<state>.webp) with pairs.mjs. WebKit only,
// at the mocks' size: 390 × 844 points at 2× pixels. Each test drives the app into one state
// and saves screenshots/<light|dark>/<state>.png through `capture`. The folder is gitignored;
// CI uploads it. Run only the screenshot specs with `npm run screenshots:app` in phone/.
//
// - `loading`: the laptop holds its subscribe reply. No mock.
// - `app-error`: the laptop refuses the subscribe, in the daemon's words. No mock.
// - `shell-sessions`: the mock scenario after its subscribe, beside the mocks' `sessions`.
// - `shell-reconnect`: the same, then the channel drops, so the loader's strip says
//   "Reconnecting…", beside the mocks' `reconnect`.
// The last two take the shell's own names, because part 6b's sessions list captures `sessions`
// and `reconnect`, and one shot must never overwrite another. pairs.mjs pairs them with
// `shell-sessions=sessions shell-reconnect=reconnect`.

import { readFileSync } from 'node:fs';

import { TEXT } from './fake-laptop-app.js';
import { app, capture, expect, hostCall, hostRequests, openApp, rowButtons, rowNames, test } from './fixtures.js';

/** @typedef {import('@playwright/test').Page} Page */

test.skip(({ browserName }) => browserName !== 'webkit', 'the screenshots are taken in WebKit only');
test.use({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });

/** Every row of the mock scenario, by name, sorted as `rowNames` returns them. */
const MOCK_NAMES = JSON.parse(readFileSync(new URL('scenarios/mock.json', import.meta.url), 'utf8'))
  .rows.map((/** @type {any} */ r) => r.name).sort();

test('loading', async ({ page, appHost }) => {
  await openApp(page, appHost, { channel: 'down' });
  await hostCall(page, 'hold', 'sessions.subscribe');
  await hostCall(page, 'setChannel', true);
  // The channel is up and the laptop has the request, so the spinner is the wait for its reply.
  await expect.poll(async () => (await hostRequests(page)).map((r) => r.method)).toEqual(['sessions.subscribe']);
  await expect(page.locator('#strip [data-state="reconnect"]')).toHaveCount(0);
  await capture(page, 'loading', app(page).locator('[data-state="loading"]'));
});

test('app-error', async ({ page, appHost }) => {
  await openApp(page, appHost, { channel: 'down' });
  await hostCall(page, 'setReply', 'sessions.subscribe', { error: { code: 'phone_control_off', message: TEXT.phoneControlOff } });
  await hostCall(page, 'setChannel', true);
  const refused = app(page).locator('[data-state="app-error"]');
  await expect(refused.locator('p')).toHaveText(TEXT.phoneControlOff);
  await capture(page, 'app-error', refused);
});

test('shell-sessions', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await expect.poll(() => rowNames(page)).toEqual(MOCK_NAMES);
  await capture(page, 'shell-sessions', rowButtons(page).first());
});

test('shell-reconnect', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await expect.poll(() => rowNames(page)).toEqual(MOCK_NAMES);
  await hostCall(page, 'setChannel', false);
  await expect(page.locator('#strip [data-state="reconnect"]')).toHaveText('Reconnecting…');
  await capture(page, 'shell-reconnect', rowButtons(page).first());
});
