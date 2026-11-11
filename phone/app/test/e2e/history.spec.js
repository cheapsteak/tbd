// The browser's back and forward buttons end to end, in WebKit as an iPhone and in Chromium as
// an Android phone: the app keeps a history entry for each worktree the user moves to
// (`phone/app/src/state/history.ts`), in the sandboxed frame, with no URL, so the browser's back
// and forward step between the list and those worktrees as a phone's back button, edge swipe or
// system back does. A tap on another tab of one worktree rewrites its entry, and the in-app back
// goes back through the same history. No move reloads the frame: the loader's fault for a second
// `load` never fires, the frame stays on the runner, the app subscribes once, and a draft typed
// in the composer, which the app keeps in memory alone, is still there.
//
// The tests step through the history from the top page (`browserBack`), not with
// `page.goBack()`: that waits for the top page to navigate, and a move between the frame's
// entries never navigates it.

import { readFileSync } from 'node:fs';

import { app, expect, frameURL, hostCall, hostRequests, openApp, openSessionByName, rowNames, test } from './fixtures.js';

/** @typedef {import('@playwright/test').Page} Page */

const MOCK = JSON.parse(readFileSync(new URL('scenarios/mock.json', import.meta.url), 'utf8'));
/** @type {string[]} */
const MOCK_NAMES = MOCK.rows.map((/** @type {any} */ r) => r.name);
/** Main's one session, which the fork below opens. */
const MAIN_REF = MOCK.rows.find((/** @type {any} */ r) => r.name === 'main').sessions[0].ref;

/**
 * Waits until the app shows the sessions list.
 * @param {Page} page
 */
async function expectList(page) {
  await expect(app(page).locator('#app')).toHaveAttribute('data-screen', 'sessions');
  await expect.poll(() => rowNames(page)).toEqual([...MOCK_NAMES].sort());
}

/**
 * Waits until the app shows the session of the row named `name`, on the tab named `tab` when
 * the row has tabs.
 * @param {Page} page
 * @param {string} name
 * @param {string} [tab]
 */
async function expectSession(page, name, tab) {
  await expect(app(page).locator('#app')).toHaveAttribute('data-screen', 'session');
  await expect(app(page).locator('.s-head .t1 > span').first()).toHaveText(name);
  if (tab !== undefined) await expect(app(page).getByRole('tab', { selected: true })).toContainText(tab);
}

/**
 * The browser's back button: one step back through the tab's session history, which the frame
 * shares with the top page. The top page's `history.back()` takes that step as the button does.
 * @param {Page} page
 */
async function browserBack(page) {
  await page.evaluate(() => history.back());
}

/**
 * The browser's forward button, as `browserBack` takes the back button's step.
 * @param {Page} page
 */
async function browserForward(page) {
  await page.evaluate(() => history.forward());
}

/** @param {Page} page */
function composer(page) {
  return app(page).locator('.dock .comp textarea.field');
}

/**
 * Fails unless the frame never reloaded: no fault for a second `load`, the runner still in the
 * frame, and the one subscribe the app sent when it started.
 * @param {Page} page
 */
async function expectNoReload(page) {
  expect(await page.evaluate(() => /** @type {any} */ (window).__host.faults)).toEqual([]);
  expect(new URL(await frameURL(page)).pathname).toBe('/runner.html');
  expect((await hostRequests(page)).filter((r) => r.method === 'sessions.subscribe')).toHaveLength(1);
}

test('back and forward step between the list and a worktree, and the in-app back goes back through the same history', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await expectList(page);
  await openSessionByName(page, 'Login redirect fix');
  await expectSession(page, 'Login redirect fix');
  await composer(page).fill('A draft kept in memory.');

  await browserBack(page);
  await expectList(page);
  await browserForward(page);
  await expectSession(page, 'Login redirect fix');
  await expect(composer(page)).toHaveValue('A draft kept in memory.');

  // The in-app back is the browser's back: forward returns to the worktree it left.
  await app(page).getByRole('button', { name: 'Back to sessions' }).click();
  await expectList(page);
  await browserForward(page);
  await expectSession(page, 'Login redirect fix');

  // A worktree opened from the list replaces the one forward of it, so back from it is the list.
  await app(page).getByRole('button', { name: 'Back to sessions' }).click();
  await expectList(page);
  await openSessionByName(page, 'Docs refresh');
  await expectSession(page, 'Docs refresh');
  await browserBack(page);
  await expectList(page);
  await browserForward(page);
  await expectSession(page, 'Docs refresh');
  await browserBack(page);
  await openSessionByName(page, 'Login redirect fix');
  await expect(composer(page)).toHaveValue('A draft kept in memory.');
  await expectNoReload(page);
});

test('a move from one worktree to another adds an entry: back returns to the first, then the list, and forward to the first', async ({ page, appHost }) => {
  // The phone's own screens move from one worktree's session to another's only through a
  // pending open, so a fork that the laptop opens in another worktree, main, stands in for
  // one here.
  await openApp(page, appHost);
  await openSessionByName(page, 'Checkout v2', 'Review');
  await expectSession(page, 'Checkout v2', 'Review');
  await composer(page).fill('A draft kept in memory.');
  await hostCall(page, 'setReply', 'session.fork', { result: { session: MAIN_REF } });
  await app(page).getByRole('button', { name: 'Account: acme-work. Switch account' }).click();
  const menu = app(page).getByRole('menu', { name: 'Account for this session' });
  await menu.getByRole('menuitemradio', { name: /^Personal\b/ }).click();
  await menu.getByRole('button', { name: 'Fork into a new tab' }).click();
  await expectSession(page, 'main');

  await browserBack(page);
  await expectSession(page, 'Checkout v2', 'Review');
  await expect(composer(page)).toHaveValue('A draft kept in memory.');
  await browserBack(page);
  await expectList(page);
  await browserForward(page);
  await expectSession(page, 'Checkout v2', 'Review');
  await browserForward(page);
  await expectSession(page, 'main');
  // The in-app back goes back one entry too, to the worktree the move left.
  await app(page).getByRole('button', { name: 'Back to sessions' }).click();
  await expectSession(page, 'Checkout v2', 'Review');
  await expectNoReload(page);
});

test("a tap on another tab rewrites the worktree's entry, so back goes to the list", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Checkout v2', 'Review');
  await app(page).getByRole('tab', { name: /^Codex/ }).click();
  await expectSession(page, 'Checkout v2', 'Codex');
  await browserBack(page);
  await expectList(page);
  // Forward reaches the tab that showed last.
  await browserForward(page);
  await expectSession(page, 'Checkout v2', 'Codex');
  await expectNoReload(page);
});

test('back with a sheet open closes the sheet as it leaves the session', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'main');
  await app(page).getByRole('button', { name: 'Session menu' }).click();
  await expect(app(page).locator('[role="dialog"]')).toBeVisible();
  await browserBack(page);
  await expectList(page);
  await expect(app(page).locator('[role="dialog"]')).toHaveCount(0);
  await browserForward(page);
  await expectSession(page, 'main');
  await expect(app(page).locator('[role="dialog"]')).toHaveCount(0);
  await expectNoReload(page);
});

test("after the loader replaces the frame, back never loads the old frame's entries into the new one", async ({ page, appHost }) => {
  // A new bundle replaces the frame (`#onBundle` in phone/loader/main.js), and the entries the
  // old frame added can stay in the tab's history, held for a frame that is gone. A back that
  // reaches one may skip it, rest on it with nothing to change, or leave the page, but must not
  // load anything into the new frame, which the loader would take as a fault.
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  await expectSession(page, 'Login redirect fix');
  await hostCall(page, 'replaceFrame');
  await expectList(page);
  const runner = await frameURL(page);
  await openSessionByName(page, 'Docs refresh');
  await expectSession(page, 'Docs refresh');
  await browserBack(page);
  await expectList(page);
  // The back that reaches the old frame's entry may leave the page, which ends this context.
  await page.evaluate(() => history.back()).catch(() => {});
  await page.waitForTimeout(1_000);
  if (new URL(page.url()).pathname !== '/__app/host.html') return;
  expect(await page.evaluate(() => /** @type {any} */ (window).__host.faults)).toEqual([]);
  expect(await frameURL(page)).toBe(runner);
  await expectList(page);
});
