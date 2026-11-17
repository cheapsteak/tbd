// The browser's back and forward end to end, in WebKit as an iPhone and in Chromium as an
// Android phone. The test host keeps the tab's history entries for the app as the loader page
// does, with the loader's own history.js (host.js): the app asks for an entry for each worktree
// the user moves to, a tap on another tab of one worktree rewrites its entry, and the back
// chevron asks the page to go back. Back and forward come from the top page, as a phone's back
// button, edge swipe or system back does, and the page tells the app the screen of the entry it
// lands on. No move reloads the frame: the loader's fault for a second `load` never fires, the
// frame stays on the runner, the app subscribes once per frame, and a draft typed in the
// composer, which the app keeps in memory alone, is still there.
//
// `back` and `forward` are `page.goBack()` and `page.goForward()`, which settle on a move
// within the page's document as on one that loads a page. The app's screen follows once the
// page's `route` message reaches it, so each step waits for the screen. The other way round, the
// app shows a screen as it asks the page for its entry, and the page acts when the request
// arrives; a browser move made sooner wins over the request, as it does on a phone. So each
// check of a screen also waits for the entry the browser is on to name that screen.

import { readFileSync } from 'node:fs';

import {
  app, expect, frameURL, hostCall, hostRequests, openApp, openSessionByName, rowNames, takeProblems, test,
} from './fixtures.js';

/** @typedef {import('@playwright/test').Page} Page */

const MOCK = JSON.parse(readFileSync(new URL('scenarios/mock.json', import.meta.url), 'utf8'));
/** @type {string[]} */
const MOCK_NAMES = MOCK.rows.map((/** @type {any} */ r) => r.name);
/** Main's one session, which the fork below opens. */
const MAIN_REF = MOCK.rows.find((/** @type {any} */ r) => r.name === 'main').sessions[0].ref;
const DRAFT = 'A draft kept in memory.';

/**
 * Waits until the app shows the sessions list, and the entry the browser is on names it.
 * @param {Page} page
 */
async function expectList(page) {
  await expect(app(page).locator('#app')).toHaveAttribute('data-screen', 'sessions');
  await expect.poll(() => rowNames(page)).toEqual([...MOCK_NAMES].sort());
  await expect.poll(() => entryRef(page), 'the entry names the list').toBeNull();
}

/**
 * Waits until the app shows the session of the row named `name`, on the tab named `tab` when
 * the row has tabs, and the entry the browser is on names that session.
 * @param {Page} page
 * @param {string} name
 * @param {string} [tab]
 */
async function expectSession(page, name, tab) {
  await expect(app(page).locator('#app')).toHaveAttribute('data-screen', 'session');
  await expect(app(page).locator('.s-head .t1 > span').first()).toHaveText(name);
  if (tab !== undefined) await expect(app(page).getByRole('tab', { selected: true })).toContainText(tab);
  await expect.poll(() => entryRef(page), 'the entry names the session').toEqual(mockRef(name, tab));
}

/**
 * The ref of the mock's session in the row named `name`: the one on the tab named `tab`, or the
 * row's only one.
 * @param {string} name
 * @param {string} [tab]
 */
function mockRef(name, tab) {
  const row = MOCK.rows.find((/** @type {any} */ r) => r.name === name);
  const sessions = row?.sessions.filter((/** @type {any} */ s) => tab === undefined || s.tabName === tab) ?? [];
  if (sessions.length !== 1) throw new RangeError(`no one session for ${name}, ${tab}`);
  return sessions[0].ref;
}

/**
 * The session ref the entry the browser is on names, or null for the list. It reads the app's
 * route string (`encodeRoute` in app/src/state/routeState.ts), which the loader never reads.
 * @param {Page} page
 */
function entryRef(page) {
  return page.evaluate(() => {
    const route = history.state?.tbdPhone?.app;
    return typeof route === 'string' ? JSON.parse(route).ref : null;
  });
}

/**
 * The browser's back button: one step back through the tab's history.
 * @param {Page} page
 */
async function back(page) {
  await page.goBack();
}

/**
 * The browser's forward button.
 * @param {Page} page
 */
async function forward(page) {
  await page.goForward();
}

/**
 * The app's back chevron, tapped.
 * @param {Page} page
 */
async function chevron(page) {
  await app(page).getByRole('button', { name: 'Back to sessions' }).click();
}

/**
 * Forks the session that shows, Checkout v2's Review tab, into main. The phone moves from one
 * worktree's session to another's only through a pending open, so a fork that the laptop opens
 * in another worktree stands in for one.
 * @param {Page} page
 */
async function forkIntoMain(page) {
  await hostCall(page, 'setReply', 'session.fork', { result: { session: MAIN_REF } });
  await app(page).getByRole('button', { name: 'Account: acme-work. Switch account' }).click();
  const menu = app(page).getByRole('menu', { name: 'Account for this session' });
  await menu.getByRole('menuitemradio', { name: /^Personal\b/ }).click();
  await menu.getByRole('button', { name: 'Fork into a new tab' }).click();
  await expectSession(page, 'main');
}

/** @param {Page} page */
function composer(page) {
  return app(page).locator('.dock .comp textarea.field');
}

/**
 * How many entries the tab's history holds.
 * @param {Page} page
 */
function historyLength(page) {
  return page.evaluate(() => history.length);
}

/**
 * The page load that made the current history entry (`doc` in phone/loader/history.js).
 * @param {Page} page
 * @returns {Promise<string>}
 */
function entryDoc(page) {
  return page.evaluate(() => history.state.tbdPhone.doc);
}

/**
 * Marks the page's window, so `isMarked` can tell whether the page has loaded since.
 * @param {Page} page
 */
async function markPage(page) {
  await page.evaluate(() => Object.defineProperty(window, '__historyTestMark', { value: true }));
}

/** @param {Page} page */
function isMarked(page) {
  return page.evaluate(() => Object.hasOwn(window, '__historyTestMark'));
}

/**
 * Fails unless no frame reloaded: no frame fault, one frame and it on the runner, one
 * `sessions.subscribe` for each frame the page has started, and the page's address as it was
 * when the app opened, since no history entry carries a URL.
 * @param {Page} page
 * @param {string} address the page's URL when the app opened
 * @param {number} [frames] how many frames the page has started
 */
async function expectNoReload(page, address, frames = 1) {
  expect(await page.evaluate(() => /** @type {any} */ (window).__host.faults)).toEqual([]);
  await expect(page.locator('#frame-host iframe')).toHaveCount(1);
  expect(new URL(await frameURL(page)).pathname).toBe('/runner.html');
  expect((await hostRequests(page)).filter((r) => r.method === 'sessions.subscribe')).toHaveLength(frames);
  expect(page.url()).toBe(address);
}

test('back and forward step between the list and a worktree, and the chevron is a back that forward undoes', async ({ page, appHost }) => {
  await openApp(page, appHost);
  const address = page.url();
  await expectList(page);
  const start = await historyLength(page);
  await openSessionByName(page, 'Login redirect fix');
  await expectSession(page, 'Login redirect fix');
  expect(await historyLength(page)).toBe(start + 1);
  await composer(page).fill(DRAFT);

  await back(page);
  await expectList(page);
  await forward(page);
  await expectSession(page, 'Login redirect fix');
  await expect(composer(page)).toHaveValue(DRAFT);

  // The chevron goes back through the same history, so forward returns to the worktree it left.
  await chevron(page);
  await expectList(page);
  await forward(page);
  await expectSession(page, 'Login redirect fix');
  await expect(composer(page)).toHaveValue(DRAFT);
  expect(await historyLength(page)).toBe(start + 1);
  await expectNoReload(page, address);
});

test('a move from one worktree to another adds an entry: back returns to the first, then the list, and forward to the first', async ({ page, appHost }) => {
  await openApp(page, appHost);
  const address = page.url();
  await openSessionByName(page, 'Checkout v2', 'Review');
  await expectSession(page, 'Checkout v2', 'Review');
  await composer(page).fill(DRAFT);
  await forkIntoMain(page);

  await back(page);
  await expectSession(page, 'Checkout v2', 'Review');
  await expect(composer(page)).toHaveValue(DRAFT);
  await back(page);
  await expectList(page);
  await forward(page);
  await expectSession(page, 'Checkout v2', 'Review');
  await expect(composer(page)).toHaveValue(DRAFT);
  await forward(page);
  await expectSession(page, 'main');
  // The chevron goes back one entry too, to the worktree the move left.
  await chevron(page);
  await expectSession(page, 'Checkout v2', 'Review');
  await expect(composer(page)).toHaveValue(DRAFT);
  await expectNoReload(page, address);
});

test("a tap on another tab rewrites the worktree's entry, so back goes to the list", async ({ page, appHost }) => {
  await openApp(page, appHost);
  const address = page.url();
  const start = await historyLength(page);
  await openSessionByName(page, 'Checkout v2', 'Review');
  await app(page).getByRole('tab', { name: /^Claude/ }).click();
  await expectSession(page, 'Checkout v2', 'Claude');
  expect(await historyLength(page)).toBe(start + 1);
  await composer(page).fill(DRAFT);
  await back(page);
  await expectList(page);
  // Forward reaches the tab that showed last.
  await forward(page);
  await expectSession(page, 'Checkout v2', 'Claude');
  await expect(composer(page)).toHaveValue(DRAFT);
  await expectNoReload(page, address);
});

test('back closes an open sheet or menu as it leaves the session, and forward brings neither back', async ({ page, appHost }) => {
  await openApp(page, appHost);
  const address = page.url();
  await openSessionByName(page, 'Checkout v2', 'Review');
  await expectSession(page, 'Checkout v2', 'Review');
  await composer(page).fill(DRAFT);
  await app(page).getByRole('button', { name: 'Session menu' }).click();
  await expect(app(page).locator('[role="dialog"]')).toBeVisible();
  await back(page);
  await expectList(page);
  await expect(app(page).locator('[role="dialog"]')).toHaveCount(0);
  await forward(page);
  await expectSession(page, 'Checkout v2', 'Review');
  await expect(app(page).locator('[role="dialog"]')).toHaveCount(0);
  await expect(composer(page)).toHaveValue(DRAFT);

  await app(page).getByRole('button', { name: 'Account: acme-work. Switch account' }).click();
  await expect(app(page).getByRole('menu')).toBeVisible();
  await back(page);
  await expectList(page);
  await expect(app(page).getByRole('menu')).toHaveCount(0);
  await forward(page);
  await expectSession(page, 'Checkout v2', 'Review');
  await expect(app(page).getByRole('menu')).toHaveCount(0);
  await expectNoReload(page, address);
});

test('back from the list leaves the page', async ({ page, appHost }) => {
  // A page of the host's origin before the app, so back from the list has somewhere to go.
  const before = `${appHost.origin}/__app/scenarios/mock.json`;
  await page.goto(before);
  await openApp(page, appHost);
  await openSessionByName(page, 'Docs refresh');
  await expectSession(page, 'Docs refresh');
  await back(page);
  await expectList(page);
  await back(page);
  expect(page.url()).toBe(before);
});

test('a new frame opens on the entry the browser is on, and back and forward step through the entries the old frame made', async ({ page, appHost }) => {
  // A new bundle replaces the frame (`#onBundle` in phone/loader/main.js). The entries the old
  // frame asked for stay this page's own, so the new frame opens on the one the browser is on,
  // and back and forward go on through them.
  await openApp(page, appHost);
  const address = page.url();
  await openSessionByName(page, 'Login redirect fix');
  await expectSession(page, 'Login redirect fix');
  await hostCall(page, 'replaceFrame');
  await expectSession(page, 'Login redirect fix');
  await expectNoReload(page, address, 2);
  await composer(page).fill(DRAFT);

  await back(page);
  await expectList(page);
  await forward(page);
  await expectSession(page, 'Login redirect fix');
  await expect(composer(page)).toHaveValue(DRAFT);
  await chevron(page);
  await expectList(page);
  await expectNoReload(page, address, 2);
});

test('a reload on a session’s entry opens that session again, and back onto an entry from before the reload shows its screen in the same page', async ({ page, appHost }) => {
  // Two worktrees' entries before the reload: Checkout v2 on its Review tab, then main.
  await openApp(page, appHost);
  const address = page.url();
  await openSessionByName(page, 'Checkout v2', 'Review');
  await expectSession(page, 'Checkout v2', 'Review');
  await forkIntoMain(page);

  await page.reload();
  await page.waitForFunction(() => /** @type {any} */ (window).__host?.ready === true);
  await expectSession(page, 'main');
  await expectNoReload(page, address);
  await markPage(page);

  // The entry before is the earlier page load's, so the chevron shows the list in place: it
  // neither leaves this page load nor adds an entry.
  const length = await historyLength(page);
  await chevron(page);
  await expectList(page);
  expect(await historyLength(page)).toBe(length);
  await openSessionByName(page, 'Login redirect fix');
  await expectSession(page, 'Login redirect fix');
  await composer(page).fill(DRAFT);
  await back(page);
  await expectList(page);
  await forward(page);
  await expectSession(page, 'Login redirect fix');
  await expect(composer(page)).toHaveValue(DRAFT);
  await back(page);
  await expectList(page);
  const reloadDoc = await entryDoc(page);
  expect(await isMarked(page), 'the same page load').toBe(true);
  await expectNoReload(page, address);

  // Back onto the entry the earlier page load made for Checkout v2's Review tab. A load of the
  // page would show that screen too, since a new frame opens on the entry's screen, so only the
  // mark on the window tells a popstate from a load: both engines stay in this page load.
  await back(page);
  await expectSession(page, 'Checkout v2', 'Review');
  expect(await entryDoc(page), "the earlier page load's entry").not.toBe(reloadDoc);
  expect(await isMarked(page), 'a popstate in this page load, not a load of the page').toBe(true);
  await expectNoReload(page, address);
});

/**
 * Each part of a loader from before this design, as the staged file with one change. The page
 * (frame.js) loads once per tab and the runner once per frame, so either can be the old one.
 * @type {Array<[string, string, string, string]>} what it is, the file, and the change
 */
const OLD_LOADER_PARTS = [
  // An old page's bundle message says nothing of history, so the new runner hands the app none.
  ['an old loader page, whose bundle message carries no history,', 'frame.js',
    'sha256: this.#sha256, history: 1 }', 'sha256: this.#sha256 }'],
  // An old runner never sets the field, whatever the page says.
  ['an old runner, which never hands the app history,', 'runner.js', 'if (keepsHistory) host.history = 1;', ''],
];

for (const [what, file, from, to] of OLD_LOADER_PARTS) {
  test(`${what} makes the app fail at start, as a script fault`, async ({ page, appHost, pageProblems }) => {
    const staged = await (await page.request.get(`${appHost.origin}/${file}`)).text();
    const old = staged.replace(from, to);
    expect(old, `the staged ${file}`).not.toBe(staged);
    await page.route(`**/${file}`, (route) => route.fulfill({ contentType: 'text/javascript; charset=utf-8', body: old }));
    await page.goto(`${appHost.origin}/__app/host.html?scenario=mock`);
    await page.waitForFunction(() => /** @type {any} */ (window).__host?.ready === true);
    await expect.poll(() => page.evaluate(() => /** @type {any} */ (window).__host.faults)).toEqual(['script']);
    await expect(page.locator('#frame-host iframe')).toHaveCount(0);
    // The app's throw, and the host's report of the fault: expected here, and nowhere else.
    expect(await takeProblems(pageProblems, /tbdHost has no history 1/)).toHaveLength(1);
    expect(await takeProblems(pageProblems, /the app frame failed: script/)).toHaveLength(1);
  });
}
