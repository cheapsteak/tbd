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

test('a long link opens its sheet at the top, with the title and the URL\'s start in view', async ({ page, server, browserName }) => {
  // The Pixel 7 is tall enough to show the whole URL, so Chromium runs as a smaller Android
  // phone; WebKit stays the iPhone 15.
  if (browserName === 'chromium') await page.setViewportSize({ width: 360, height: 640 });
  const { laptop } = await appRunning(page, server);
  // Near the loader's 2,048-character cap, so on a phone the URL runs past the sheet's height.
  const start = 'https://acme.example/';
  const url = `${start}${'a'.repeat(1_900)}/login`;
  await sendEvent(laptop, 'debug.openLink', { url });
  const sheet = page.locator('[data-state="link"]');
  const open = sheet.getByRole('button', { name: 'Open' });
  await expect(sheet.locator('.url')).toHaveText(url);
  await expect(open).toBeFocused();

  const seen = await sheet.evaluate((el, prefix) => {
    const viewport = { top: 0, bottom: window.innerHeight };
    const box = el.getBoundingClientRect();
    /** @param {DOMRect} r */
    const shown = (r) => r.height > 0 && r.top >= Math.max(viewport.top, box.top) - 0.5
      && r.bottom <= Math.min(viewport.bottom, box.bottom) + 0.5;
    const title = /** @type {Element} */ (el.querySelector('.sh-title'));
    const text = /** @type {Text} */ (/** @type {Element} */ (el.querySelector('.url')).firstChild);
    const range = document.createRange();
    range.setStart(text, 0);
    range.setEnd(text, prefix.length);
    return {
      overflows: el.scrollHeight > el.clientHeight,
      scrollTop: el.scrollTop,
      title: shown(title.getBoundingClientRect()),
      start: [...range.getClientRects()].every(shown),
    };
  }, start);
  // The URL is long enough to push Open below the sheet's edge, so this is the case at issue.
  expect(seen.overflows).toBe(true);
  expect(seen).toMatchObject({ scrollTop: 0, title: true, start: true });

  // Open is still there for whoever scrolls down to it.
  await sheet.evaluate((el) => { el.scrollTop = el.scrollHeight; });
  await expect(open).toBeInViewport();
  await expect(open).toBeFocused();
});

test('a key held as the sheet opens does not press Open, and the next Enter does', async ({ context, page, server }) => {
  const { laptop } = await appRunning(page, server);
  const url = `${server.origin}/__test/landing`;
  let tabs = 0;
  context.on('page', () => { tabs += 1; });
  await page.evaluate(() => {
    /** @type {string[]} */
    const downs = [];
    /** @type {any} */ (window).__downs = downs;
    document.addEventListener('keydown', (event) => { downs.push(`${event.key}:${event.repeat}`); }, true);
  });
  const sheet = page.locator('[data-state="link"]');
  const open = sheet.getByRole('button', { name: 'Open' });

  // The key goes down before the sheet opens, as Enter does on the app's link, and is held:
  // the browser's auto-repeat then lands on Open, which the sheet focused. Enter presses a
  // button on its keydown, Space on its keyup after a keydown on the button.
  for (const [key, text] of [['Enter', 'Enter'], ['Space', ' ']]) {
    await page.evaluate(() => {
      /** @type {any} */ (window).__downs.length = 0;
      if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
    });
    await page.keyboard.down(key);
    await sendEvent(laptop, 'debug.openLink', { url });
    await expect(open).toBeFocused();
    for (let i = 0; i < 4; i += 1) await page.keyboard.down(key);
    await page.keyboard.up(key);
    expect(await page.evaluate(() => /** @type {any} */ (window).__downs))
      .toEqual([`${text}:false`, `${text}:true`, `${text}:true`, `${text}:true`, `${text}:true`]);
    await expect(sheet).toBeVisible();
    await expect(open).toBeFocused();
    expect(tabs).toBe(0);
  }

  // A deliberate press after the key came up opens the link.
  const opened = context.waitForEvent('page');
  await page.keyboard.press('Enter');
  const tab = await opened;
  await tab.waitForLoadState();
  expect(tab.url()).toBe(url);
  await expect(sheet).toHaveCount(0);
  expect(tabs).toBe(1);
});

test('a fresh Enter press on Open opens the link', async ({ context, page, server }) => {
  const { laptop } = await appRunning(page, server);
  const url = `${server.origin}/__test/landing`;
  await sendEvent(laptop, 'debug.openLink', { url });
  const sheet = page.locator('[data-state="link"]');
  await expect(sheet.getByRole('button', { name: 'Open' })).toBeFocused();

  const opened = context.waitForEvent('page');
  await page.keyboard.press('Enter');
  const tab = await opened;
  await tab.waitForLoadState();
  expect(tab.url()).toBe(url);
  expect(await tab.evaluate(() => window.opener)).toBeNull();
  await expect(sheet).toHaveCount(0);
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
    safeArea: { top: 0, right: 0, bottom: 0, left: 0 },
  });
});

test('the app\'s messages reach the laptop and its replies reach the app', async ({ page, server }) => {
  const { laptop } = await appRunning(page, server);
  expect(await frameText(page)).toContain('Sessions:');
  expect(laptop.appBodies[0]).toMatchObject({ kind: 'request', method: 'sessions.subscribe' });
});
