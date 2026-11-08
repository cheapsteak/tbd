// A screenshot of each state the app shell draws, light and dark, for review beside the mocks'
// (docs/design/phone-control/screenshots/<scheme>/<state>.webp) with pairs.mjs. WebKit only,
// at the mocks' size: 390 × 844 points at 2× pixels. Each test drives the app into one state
// and saves screenshots/<light|dark>/<state>.png through `capture`. The folder is gitignored;
// CI uploads it. Run only the screenshot specs with `npm run screenshots:app` in phone/.
//
// - `loading`: the laptop holds its subscribe reply. No mock.
// - `app-error`: the laptop refuses the subscribe, in the daemon's words. No mock.
// - `sessions`: the mock scenario after its subscribe. Until part 6b, this is 6a's stub list.
// - `reconnect`: the same, then the channel drops, so the loader's strip says "Reconnecting…".

import { TEXT } from './fake-laptop-app.js';
import { app, capture, expect, hostCall, hostRequests, openApp, test } from './fixtures.js';

/** @typedef {import('@playwright/test').Page} Page */

test.skip(({ browserName }) => browserName !== 'webkit', 'the screenshots are taken in WebKit only');
test.use({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });

/**
 * The rows of the sessions list: the mocks' (part 6b) or 6a's stub.
 * @param {Page} page
 */
function rows(page) {
  return app(page).locator('button.row, button[data-row]');
}

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

test('sessions', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await capture(page, 'sessions', rows(page).first());
});

test('reconnect', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await expect(rows(page).first()).toBeVisible();
  await hostCall(page, 'setChannel', false);
  await expect(page.locator('#strip [data-state="reconnect"]')).toHaveText('Reconnecting…');
  await capture(page, 'reconnect', rows(page).first());
});
