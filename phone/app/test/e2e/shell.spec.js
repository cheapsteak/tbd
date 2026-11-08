// The app shell end to end, in WebKit as an iPhone and in Chromium as an Android phone: the
// root and its layout variables, the theme, the first subscribe, a resubscribe after a drop,
// and a refused subscribe. host.spec.js covers the host itself (the runner's policy, the
// opaque origin, the committed bundle and the console check), so nothing here repeats it.
//
// These tests outlive 6a's stub list: they read the rows through `rowNames` (fixtures.js),
// which names them in either list, and compare the names as a set, never in order.

import { readFileSync } from 'node:fs';

import { TEXT } from './fake-laptop-app.js';
import { app, expect, hostCall, hostRequests, openApp, rowNames, test } from './fixtures.js';

/** @typedef {import('@playwright/test').Page} Page */

const MOCK = JSON.parse(readFileSync(new URL('scenarios/mock.json', import.meta.url), 'utf8'));
/** @type {string[]} */
const MOCK_NAMES = MOCK.rows.map((/** @type {any} */ r) => r.name);

/**
 * Waits until the sessions list shows exactly the rows named `names`, in any order.
 * @param {Page} page
 * @param {string[]} [names]
 */
async function expectRows(page, names = MOCK_NAMES) {
  await expect.poll(() => rowNames(page)).toEqual([...names].sort());
}

/** @param {Page} page */
function laptopSeq(page) {
  return page.evaluate(() => /** @type {any} */ (window).__host.state.seq);
}

/** @param {Page} page @returns {Promise<Array<{ requestID: string, params: any }>>} */
async function subscribes(page) {
  return (await hostRequests(page)).filter((r) => r.method === 'sessions.subscribe');
}

test('the app mounts #app on the sessions screen, with the layout variables from the loader', async ({ page, appHost }) => {
  await openApp(page, appHost);
  const root = app(page).locator('#app');
  await expect(root).toBeVisible();
  await expectRows(page);
  await expect(root).toHaveAttribute('data-screen', 'sessions');

  // The loader's safe area and keyboard reach the root as CSS variables. The bottom inset
  // lifts the dock until a keyboard taller than it comes up.
  const vars = () => root.evaluate((el) => Object.fromEntries(
    ['--safe-top', '--safe-bottom', '--dock-pad'].map((name) => [name, el.style.getPropertyValue(name)])));
  await hostCall(page, 'sendEnv', { safeArea: { top: 47, bottom: 34 } });
  await expect.poll(vars).toEqual({ '--safe-top': '47px', '--safe-bottom': '34px', '--dock-pad': '34px' });
  const { width, height } = /** @type {{ width: number, height: number }} */ (page.viewportSize());
  await hostCall(page, 'sendEnv', {
    safeArea: { top: 47, bottom: 34 },
    viewport: { width, height: height - 300, offsetTop: 0, offsetLeft: 0, scale: 1 },
    layout: { width, height },
  });
  await expect.poll(vars).toEqual({ '--safe-top': '47px', '--safe-bottom': '34px', '--dock-pad': '300px' });
  await hostCall(page, 'sendEnv', null);
  await expect.poll(vars).toEqual({ '--safe-top': '0px', '--safe-bottom': '0px', '--dock-pad': '0px' });
});

test('nothing reaches the laptop before the first channel up', async ({ page, appHost }) => {
  await openApp(page, appHost, { channel: 'down' });
  await expect(app(page).locator('[data-state="loading"]')).toBeVisible();
  // Long enough for a request made at start to have reached the laptop, had the channel let it.
  await page.waitForTimeout(500);
  expect(await hostRequests(page)).toEqual([]);

  await hostCall(page, 'setChannel', true);
  await expect.poll(() => hostRequests(page)).toEqual([
    { requestID: expect.any(String), method: 'sessions.subscribe', params: {} },
  ]);
  await expectRows(page);
});

test('a dropped channel resubscribes from the last seq it saw, and takes the events it missed', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await expectRows(page);
  const row = MOCK.rows.find((/** @type {any} */ r) => r.name === 'main');
  const renamed = (/** @type {string} */ name) => MOCK_NAMES.map((n) => (n === 'main' ? name : n));
  for (const name of ['main, renamed once', 'main, renamed twice']) {
    await hostCall(page, 'emit', 'sessions.changed', { rows: [{ ...row, name }], removedRowIDs: [] });
  }
  await expectRows(page, renamed('main, renamed twice'));
  const seen = await laptopSeq(page);
  expect(seen).toBe(2);

  await hostCall(page, 'setChannel', false);
  await hostCall(page, 'emit', 'sessions.changed', { rows: [{ ...row, name: 'main, renamed while away' }], removedRowIDs: [] });
  await hostCall(page, 'setChannel', true);
  await expect.poll(async () => (await subscribes(page)).map((r) => r.params)).toEqual([{}, { stream: 's1', sinceSeq: seen }]);
  // The laptop replays the event the phone missed, and the list takes it.
  await expectRows(page, renamed('main, renamed while away'));
});

test('the dark scheme reaches the app', async ({ page, appHost }) => {
  await page.emulateMedia({ colorScheme: 'light' });
  await openApp(page, appHost);
  const root = app(page).locator('#app');
  await expect(app(page).locator('html[data-theme="light"]')).toBeAttached();
  const background = () => root.evaluate((el) => getComputedStyle(el).backgroundColor);
  const light = await background();

  await page.emulateMedia({ colorScheme: 'dark' });
  await expect(app(page).locator('html[data-theme="dark"]')).toBeAttached();
  // The app's own colours follow, not just the attribute.
  await expect.poll(background).not.toBe(light);

  await page.emulateMedia({ colorScheme: 'light' });
  await expect(app(page).locator('html[data-theme="light"]')).toBeAttached();
  await expect.poll(background).toBe(light);
});

test('a refused subscribe shows its message, and Try again subscribes again', async ({ page, appHost }) => {
  await openApp(page, appHost, { channel: 'down' });
  await hostCall(page, 'setReply', 'sessions.subscribe', { error: { code: 'phone_control_off', message: TEXT.phoneControlOff } });
  await hostCall(page, 'setChannel', true);

  const refused = app(page).locator('[data-state="app-error"]');
  await expect(refused).toBeVisible();
  await expect(refused.locator('p')).toHaveText(TEXT.phoneControlOff);
  expect((await hostRequests(page)).map((r) => r.method)).toEqual(['sessions.subscribe']);

  await hostCall(page, 'setReply', 'sessions.subscribe', null);
  await refused.getByRole('button', { name: 'Try again' }).click();
  await expectRows(page);
  await expect(refused).toHaveCount(0);
  const sent = await hostRequests(page);
  expect(sent).toEqual([
    { requestID: expect.any(String), method: 'sessions.subscribe', params: {} },
    { requestID: expect.any(String), method: 'sessions.subscribe', params: {} },
  ]);
  expect(sent[1].requestID).not.toBe(sent[0].requestID);
});
