// The app frame as the loader hosts it, end to end: a frame that navigates away is torn down,
// links the app asks to open go through the loader's sheet, the page's environment reaches the
// app, and app messages make the round trip. WebKit as an iPhone and Chromium as an Android
// phone, with the debug bundle.

import {
  appRoundTrip, deviceRoom, expect, frameText, pairViaFragment, test, waitForAppText,
} from './fixtures.js';

/** @typedef {import('@playwright/test').Page} Page */
/** @typedef {import('./fake-laptop.js').FakeLaptopServer} FakeLaptopServer */
/** @typedef {FakeLaptopServer['laptops'][number]} ScriptedLaptop */

/**
 * Pairs and waits for the debug app's sessions.
 * @param {Page} page
 * @param {FakeLaptopServer} server
 */
async function appRunning(page, server) {
  const { laptop } = await pairViaFragment(page, server);
  await waitForAppText(page);
  return { laptop, room: deviceRoom(laptop) };
}

/**
 * Sends the debug app a laptop event.
 * @param {ScriptedLaptop} laptop
 * @param {string} event
 * @param {object} data
 */
async function sendEvent(laptop, event, data) {
  expect(await laptop.sendApp(deviceRoom(laptop), { kind: 'event', event, data })).toBe(true);
}

/**
 * The app's `debug.env` events, as the laptop got them.
 * @param {ScriptedLaptop} laptop
 * @returns {any[]}
 */
function envEvents(laptop) {
  return laptop.appBodies.filter((body) => /** @type {any} */ (body).event === 'debug.env')
    .map((body) => /** @type {any} */ (body).data);
}

/**
 * The full screen a torn-down frame leaves.
 * @param {Page} page
 */
async function expectTornDown(page) {
  await expect(page.locator('[data-state="reload"] h2')).toHaveText('Reload this page');
  await expect(page.locator('iframe')).toHaveCount(0);
}

test('a second load event tears the frame down', async ({ page, server }) => {
  const { laptop } = await appRunning(page, server);
  await sendEvent(laptop, 'debug.navigate', { url: `${server.origin}/__test/nav?x=1` });
  await expectTornDown(page);
  // The frame did load the other page: its second load is what tore it down.
  expect(server.requests).toContain('/__test/nav?x=1');
});

test('a plain link tap inside the app is caught', async ({ page, server }) => {
  await appRunning(page, server);
  await page.frameLocator('iframe').locator('#plain-link').click();
  await expectTornDown(page);
  expect(server.requests).toContain('/__test/anchor');
});

test('openLink shows the full URL and opens it with no opener', async ({ context, page, server }) => {
  const { laptop } = await appRunning(page, server);
  const url = `${server.origin}/__test/landing`;
  await sendEvent(laptop, 'debug.openLink', { url });
  const sheet = page.locator('[data-state="link"]');
  await expect(sheet.locator('.url')).toHaveText(url);
  await expect(sheet).toContainText(url);

  const opened = context.waitForEvent('page');
  await sheet.getByRole('button', { name: 'Open' }).click();
  const tab = await opened;
  await tab.waitForLoadState();
  expect(tab.url()).toBe(url);
  expect(await tab.evaluate(() => window.opener)).toBeNull();
  expect(await tab.evaluate(() => document.referrer)).toBe('');
  await expect(sheet).toHaveCount(0);
  // The app is still running.
  expect(await frameText(page)).toContain('acme-api');
});

test('openLink refuses javascript: and data: URLs', async ({ page, server }) => {
  const { laptop } = await appRunning(page, server);
  const sheet = page.locator('[data-state="link"]');
  for (const url of ['javascript:alert(1)', 'data:text/html,<p>acme</p>']) {
    await sendEvent(laptop, 'debug.openLink', { url });
    // The app posts openLink, then the event that reaches the laptop, on one port: once the
    // event is here, the loader has already handled the link.
    await expect.poll(() => laptop.appBodies.some((body) => /** @type {any} */ (body).event === 'debug.openLinkSent'
      && /** @type {any} */ (body).data?.url === url)).toBe(true);
    await expect(sheet).toHaveCount(0);
  }
  // The same path shows the sheet for an https: link.
  await appRoundTrip(page, laptop);
});

test('the color scheme and viewport are forwarded', async ({ page, server }) => {
  const { laptop } = await appRunning(page, server);
  await expect.poll(() => envEvents(laptop).at(-1)?.colorScheme).toBe('light');

  await page.emulateMedia({ colorScheme: 'dark' });
  await page.setViewportSize({ width: 390, height: 500 });
  await expect.poll(() => envEvents(laptop).at(-1)).toMatchObject({
    colorScheme: 'dark',
    layout: { width: 390, height: 500 },
  });
  expect(envEvents(laptop).at(-1).safeArea).toEqual({ top: 0, right: 0, bottom: 0, left: 0 });
});

test('the app\'s messages reach the laptop and its replies reach the app', async ({ page, server }) => {
  const { laptop } = await appRunning(page, server);
  expect(await frameText(page)).toContain('Sessions:');
  expect(laptop.appBodies[0]).toMatchObject({ kind: 'request', method: 'sessions.subscribe' });
});
