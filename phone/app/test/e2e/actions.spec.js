// The session header's menus and the session menu's sheets end to end (spec sections 4.4 and
// 8.3), in WebKit as an iPhone and in Chromium as an Android phone. The account menu: its
// profiles, the ask that a pick opens, Restart, "Fork into a new tab" and the new tab that opens
// only once the list shows it, a fork the user moved away from, a refused switch, the profiles
// loading and failing. The model menu: a pick, another name typed, a session that works. Both: one
// request per gesture, no double tap landing on an acting button the user has not seen, and a tap
// outside or Escape closing them. Then the session menu sheet, with a remote and a parked
// session's unavailable rows, and its Switch account, "Restart under X?", Fork and Model sheets:
// what each sends, one request per gesture, no double tap landing on an acting button, a sheet
// closing when an event takes its session off the list, focus, and errors. Then what a closing
// menu or sheet uncovers: no second tap of a double tap lands on Send or on a card's choice under
// it. And buttons that cannot act: a parked session's Fork, and Restart once the session runs
// under that profile already, disabled with the reason, and the Fork sheet's rows waiting when
// an event reorders them. Then New, from a repo's "+": the repo it sends, the new session
// opening once its row appears, a create the user moved away from or closed, the providers and
// their forms, what remote.create carries, refusals, one create per gesture, the tap guard, what
// closing the sheet uncovers, and the keyboard.
//
// Every test that acts checks the exact params the fake laptop got. Checkout v2's Review tab is
// the mock's `s-co-rev`: acme-work, opus, idle. Its Claude tab is working, on Personal and
// sonnet. A scenario variation is built here from mock.json and loaded as an object, never
// written into mock.json.

import { readFileSync } from 'node:fs';

import { app, expect, hostCall, hostRequests, openApp, openSessionByName, rowButtons, test } from './fixtures.js';

/** @typedef {import('@playwright/test').Page} Page */
/** @typedef {import('@playwright/test').Locator} Locator */

const MOCK = JSON.parse(readFileSync(new URL('scenarios/mock.json', import.meta.url), 'utf8'));

/** Checkout v2's tabs. */
const REVIEW_REF = { kind: 'local', terminalID: '00000000-0000-4000-8000-000000000104' };
const CHECKOUT_REF = { kind: 'local', terminalID: '00000000-0000-4000-8000-000000000103' };
/** Docs refresh's session: parked, on Personal, so it cannot fork. */
const DOCS_REF = MOCK.rows.find((/** @type {any} */ r) => r.name === 'Docs refresh').sessions[0].ref;
/** mock.json's profiles. */
const PERSONAL = '00000000-0000-4000-8000-0000000000F1';
const WORK = '00000000-0000-4000-8000-0000000000F2';
const BEDROCK = '00000000-0000-4000-8000-0000000000F3';
/** `TAP_GUARD_MS` in `src/ui/tapGuard.ts`. */
const TAP_GUARD_MS = 500;
const ACTING = new Set(['session.switchProfile', 'session.fork', 'session.setModel']);

/**
 * Every switch, fork and model change that reached the fake laptop, in order.
 * @param {Page} page
 */
async function acting(page) {
  return (await hostRequests(page)).filter((r) => ACTING.has(r.method)).map((r) => ({ method: r.method, params: r.params }));
}

/**
 * How many requests of `method` reached the fake laptop.
 * @param {Page} page
 * @param {string} method
 */
async function count(page, method) {
  return (await hostRequests(page)).filter((r) => r.method === method).length;
}

/**
 * Opens Checkout v2's tab named `tab`, its transcript shown.
 * @param {Page} page
 * @param {string} [tab]
 */
async function openCheckout(page, tab = 'Review') {
  await openSessionByName(page, 'Checkout v2', tab);
  await expect(app(page).locator('.tx [data-tx-row]').first()).toBeVisible();
}

/**
 * The header's button that opens the account menu, for the account `name`.
 * @param {Page} page
 * @param {string} name
 */
function accountButton(page, name) {
  return app(page).getByRole('button', { name: `Account: ${name}. Switch account` });
}

/**
 * The header's button that opens the model menu, for the model `name`.
 * @param {Page} page
 * @param {string} name
 */
function modelButton(page, name) {
  return app(page).getByRole('button', { name: `Model: ${name}. Change model` });
}

/** @param {Page} page */
function accountMenu(page) {
  return app(page).getByRole('menu', { name: 'Account for this session' });
}

/** @param {Page} page */
function modelMenu(page) {
  return app(page).getByRole('menu', { name: 'Model for this session' });
}

/**
 * The menu row whose name starts with `name`.
 * @param {Locator} menu
 * @param {string} name
 */
function row(menu, name) {
  return menu.getByRole('menuitemradio', { name: new RegExp(`^${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`) });
}

/**
 * The centre of `locator`'s box.
 * @param {Locator} locator
 */
async function centre(locator) {
  const box = await locator.boundingBox();
  if (box === null) throw new Error('no box');
  return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
}

/**
 * Whether the point `at` lies inside `locator`'s box.
 * @param {Locator} locator
 * @param {{ x: number, y: number }} at
 */
async function covers(locator, at) {
  const box = await locator.boundingBox();
  return box !== null && at.x >= box.x && at.x <= box.x + box.width && at.y >= box.y && at.y <= box.y + box.height;
}

/**
 * A double tap at the centre of `locator`, as a finger gives it, returning where it landed.
 * @param {Page} page
 * @param {Locator} locator
 */
async function doubleTap(page, locator) {
  const at = await centre(locator);
  await page.mouse.dblclick(at.x, at.y);
  return at;
}

/**
 * mock.json with `extra` profiles after its three.
 * @param {number} extra
 */
function withMoreProfiles(extra) {
  const scenario = structuredClone(MOCK);
  for (let i = 1; i <= extra; i++) {
    scenario.profiles.push({ id: `00000000-0000-4000-8000-0000000001F${i}`, name: `acme-extra-${i}`, kind: 'apiKey', isDefault: false });
  }
  return scenario;
}

// MARK: - The account menu

test('the account menu lists the profiles with their kinds, and ticks the current one', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await accountButton(page, 'acme-work').click();
  const menu = accountMenu(page);
  await expect(accountButton(page, 'acme-work')).toHaveAttribute('aria-expanded', 'true');
  await expect(menu.locator('.pd-lbl')).toHaveText('Account for this session');
  const rows = menu.getByRole('menuitemradio');
  await expect(rows).toHaveCount(3);
  await expect(rows.locator('small')).toHaveText(['Claude subscription · default', 'Claude subscription', 'Amazon Bedrock']);
  expect(await rows.evaluateAll((els) => els.map((el) => [el.firstChild?.nextSibling?.firstChild?.textContent, el.getAttribute('aria-checked')]))).toEqual([
    ['Personal', 'false'], ['acme-work', 'true'], ['acme-bedrock', 'false'],
  ]);
  await expect(row(menu, 'acme-work').locator('.tick')).toHaveCount(1);
  await expect(menu.locator('.tick')).toHaveCount(1);
  expect(await count(page, 'profiles.list')).toBe(1);
});

test("switching sends session.switchProfile with the picked profile's ID", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await accountButton(page, 'acme-work').click();
  const menu = accountMenu(page);
  await row(menu, 'Personal').click();
  const ask = menu.locator('.pd-ask');
  await expect(ask.locator('b')).toHaveText('Restart this session under Personal?');
  await expect(ask.locator(':scope > span')).toHaveText([
    'The conversation stays. Claude restarts in this tab.',
    'To keep this session as it is, fork instead. A copy opens in a new tab under Personal.',
  ]);
  await expect(ask.getByRole('button')).toHaveText(['Restart', 'Fork into a new tab', 'Cancel']);
  await ask.getByRole('button', { name: 'Restart' }).click();
  await expect.poll(() => acting(page)).toEqual([
    { method: 'session.switchProfile', params: { session: REVIEW_REF, profileID: PERSONAL } },
  ]);
  await expect(app(page).locator('.toast')).toHaveText('Restarted under Personal');
  await expect(menu).toHaveCount(0);
  await expect(accountButton(page, 'Personal')).toBeVisible();
  expect(await acting(page)).toHaveLength(1);
});

test('the ask says a running turn stops on a working session, and Cancel goes back to the list', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page, 'Claude');
  await accountButton(page, 'Personal').click();
  const menu = accountMenu(page);
  await row(menu, 'acme-work').click();
  await expect(menu.locator('.pd-ask > span').first()).toHaveText('The conversation stays. The turn that is running now stops.');
  await menu.getByRole('button', { name: 'Cancel' }).click();
  await expect(menu.getByRole('menuitemradio')).toHaveCount(3);
  // Picking the current profile closes the menu and sends nothing.
  await row(menu, 'Personal').click();
  await expect(menu).toHaveCount(0);
  expect(await acting(page)).toEqual([]);
});

test('forking under a profile opens the new tab only once it appears in the list', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await accountButton(page, 'acme-work').click();
  const menu = accountMenu(page);
  await row(menu, 'Personal').click();
  await hostCall(page, 'hold', 'sessions.changed');
  await menu.getByRole('button', { name: 'Fork into a new tab' }).click();
  // The toast shows once the reply came.
  await expect(app(page).locator('.toast')).toHaveText('Forked into a new tab, under Personal');
  expect(await acting(page)).toEqual([{ method: 'session.fork', params: { session: REVIEW_REF, profileID: PERSONAL } }]);
  await expect(menu).toHaveCount(0);
  // The list does not show the fork yet, so the Review tab stays open.
  await page.waitForTimeout(300);
  const selected = app(page).locator('[role="tab"][aria-selected="true"]');
  await expect(selected).toContainText('Review');
  await expect(app(page).getByRole('tab')).toHaveCount(3);
  await hostCall(page, 'release', 'sessions.changed');
  await expect(app(page).getByRole('tab')).toHaveCount(4);
  await expect(selected).toContainText('Review 4');
  const made = await page.evaluate(() => /** @type {any} */ (window).__host.state.rows
    .flatMap((/** @type {any} */ r) => r.sessions).find((/** @type {any} */ s) => s.tabName === 'Review 4').ref);
  await expect.poll(async () => (await hostRequests(page)).filter((r) => r.method === 'transcript.open').at(-1)?.params)
    .toEqual({ session: made, showDetails: false, resume: false });
});

test('a fork the user moved away from while it was on its way opens nothing', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await accountButton(page, 'acme-work').click();
  const menu = accountMenu(page);
  await row(menu, 'Personal').click();
  const opens = await count(page, 'transcript.open');
  await hostCall(page, 'hold', 'session.fork');
  await menu.getByRole('button', { name: 'Fork into a new tab' }).click();
  await expect.poll(() => acting(page)).toHaveLength(1);
  // The menu stays open while the fork is on its way, and a tap outside it only closes it.
  await page.keyboard.press('Escape');
  await expect(menu).toHaveCount(0);
  await app(page).getByRole('button', { name: 'Back to sessions' }).click();
  await expect(app(page).locator('#app')).toHaveAttribute('data-screen', 'sessions');
  // The laptop lists the fork, then replies.
  await page.waitForTimeout(200);
  await hostCall(page, 'release', 'session.fork');
  await expect(app(page).locator('.toast')).toHaveText('Forked into a new tab, under Personal');
  await page.waitForTimeout(300);
  await expect(app(page).locator('#app')).toHaveAttribute('data-screen', 'sessions');
  expect(await count(page, 'transcript.open')).toBe(opens);
});

test('a refused switch shows in the composer, and the menu stays open', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  const reason = 'TBD could not restart this session. Try again on the laptop.';
  await hostCall(page, 'setReply', 'session.switchProfile', { error: { code: 'refused', message: reason } });
  await accountButton(page, 'acme-work').click();
  const menu = accountMenu(page);
  await row(menu, 'acme-bedrock').click();
  await menu.getByRole('button', { name: 'Restart' }).click();
  await expect(app(page).locator('.dock > .refusal')).toHaveText(reason);
  await expect(menu.locator('.pd-ask b')).toHaveText('Restart this session under acme-bedrock?');
  await expect(menu.getByRole('button', { name: 'Restart' })).toBeEnabled();
  await expect(app(page).locator('.toast')).toHaveCount(0);
  expect(await acting(page)).toEqual([{ method: 'session.switchProfile', params: { session: REVIEW_REF, profileID: BEDROCK } }]);
});

test('a double click on Restart posts one request, and the toast waits for the reply', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await accountButton(page, 'acme-work').click();
  const menu = accountMenu(page);
  await row(menu, 'Personal').click();
  const restart = menu.getByRole('button', { name: 'Restart' });
  await expect(restart).toBeEnabled();
  await hostCall(page, 'hold', 'session.switchProfile');
  await restart.dblclick();
  await expect.poll(() => acting(page)).toHaveLength(1);
  await expect(restart).toBeDisabled();
  await expect(menu.getByRole('button', { name: 'Fork into a new tab' })).toBeDisabled();
  await page.waitForTimeout(300);
  await expect(app(page).locator('.toast')).toHaveCount(0);
  await hostCall(page, 'release', 'session.switchProfile');
  await expect(app(page).locator('.toast')).toHaveText('Restarted under Personal');
  expect(await acting(page)).toEqual([{ method: 'session.switchProfile', params: { session: REVIEW_REF, profileID: PERSONAL } }]);
});

test('a double tap on a profile row lands on the ask, whose Restart and Fork wait', async ({ page, appHost }) => {
  await openApp(page, appHost, { scenario: withMoreProfiles(3) });
  await openCheckout(page);
  for (const [profile, button] of [['acme-extra-1', 'Restart'], ['acme-extra-2', 'Fork into a new tab']]) {
    await accountButton(page, 'acme-work').click();
    const menu = accountMenu(page);
    await expect(menu.getByRole('menuitemradio')).toHaveCount(6);
    // The ask puts the button where the row was: the second tap lands on it, held.
    const at = await doubleTap(page, row(menu, profile));
    const target = menu.getByRole('button', { name: button });
    await expect(target).toBeVisible();
    expect(await covers(target, at), `${button} lies under the double tap on ${profile}`).toBe(true);
    await page.waitForTimeout(TAP_GUARD_MS + 200);
    expect(await acting(page)).toEqual([]);
    await expect(target).toBeEnabled();
    await page.keyboard.press('Escape');
    await expect(menu).toHaveCount(0);
  }
});

test('the profiles show a spinner while they load, and the error if the load fails', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await hostCall(page, 'hold', 'profiles.list');
  await accountButton(page, 'acme-work').click();
  const menu = accountMenu(page);
  await expect(menu.locator('[data-state="profiles-loading"] .spin')).toBeVisible();
  await expect(menu.getByRole('menuitemradio')).toHaveCount(0);
  await hostCall(page, 'release', 'profiles.list');
  await expect(menu.getByRole('menuitemradio')).toHaveCount(3);
  await page.keyboard.press('Escape');
  await expect(menu).toHaveCount(0);
  await hostCall(page, 'setReply', 'profiles.list', { error: { code: 'internal', message: 'TBD could not read its profiles.' } });
  await accountButton(page, 'acme-work').click();
  await expect(menu.locator('.refusal')).toHaveText('TBD could not read its profiles.');
  // Reopening tries again.
  await page.keyboard.press('Escape');
  await hostCall(page, 'setReply', 'profiles.list', null);
  await accountButton(page, 'acme-work').click();
  await expect(menu.getByRole('menuitemradio')).toHaveCount(3);
  expect(await count(page, 'profiles.list')).toBe(3);
});

// MARK: - The model menu

test('a model pick sends session.setModel and toasts', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await modelButton(page, 'opus').click();
  const menu = modelMenu(page);
  const rows = menu.getByRole('menuitemradio');
  await expect(rows).toHaveText(['default', 'opus', 'sonnet', 'haiku']);
  expect(await rows.evaluateAll((els) => els.map((el) => el.getAttribute('aria-checked')))).toEqual(['false', 'true', 'false', 'false']);
  await expect(row(menu, 'opus').locator('.tick')).toHaveCount(1);
  await row(menu, 'sonnet').click();
  await expect.poll(() => acting(page)).toEqual([{ method: 'session.setModel', params: { session: REVIEW_REF, model: 'sonnet' } }]);
  await expect(app(page).locator('.toast')).toHaveText('Model set to sonnet');
  await expect(menu).toHaveCount(0);
  await expect(modelButton(page, 'sonnet')).toBeVisible();
});

test('another model name is sent as typed, trimmed of the white space around it', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await modelButton(page, 'opus').click();
  const menu = modelMenu(page);
  const set = menu.getByRole('button', { name: 'Set' });
  await expect(set).toBeDisabled();
  const field = menu.getByRole('textbox', { name: 'Other model name' });
  await field.fill('   ');
  await expect(set).toBeDisabled();
  await field.fill('  claude-opus-5-5 ');
  await set.click();
  await expect.poll(() => acting(page)).toEqual([{ method: 'session.setModel', params: { session: REVIEW_REF, model: 'claude-opus-5-5' } }]);
  await expect(app(page).locator('.toast')).toHaveText('Model set to claude-opus-5-5');
  await expect(menu).toHaveCount(0);
});

test('the model menu works while the session is working, and a refusal shows in the composer', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page, 'Claude');
  const reason = 'Not sent. Claude is still working. Change the model when it stops.';
  await hostCall(page, 'setReply', 'session.setModel', { error: { code: 'refused', message: reason } });
  await modelButton(page, 'sonnet').click();
  const menu = modelMenu(page);
  await row(menu, 'opus').click();
  await expect(app(page).locator('.dock > .refusal')).toHaveText(reason);
  await expect(menu).toBeVisible();
  expect(await acting(page)).toEqual([{ method: 'session.setModel', params: { session: CHECKOUT_REF, model: 'opus' } }]);
});

test('a model row tapped as the menu opens does nothing', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await modelButton(page, 'opus').click();
  const menu = modelMenu(page);
  const sonnet = row(menu, 'sonnet');
  await expect(sonnet).toBeDisabled();
  // A tap at once, as a finger gives it: no wait for the row to be enabled.
  const at = await centre(sonnet);
  await page.mouse.click(at.x, at.y);
  for (const r of await menu.getByRole('menuitemradio').all()) await expect(r).toBeDisabled();
  await page.waitForTimeout(TAP_GUARD_MS + 200);
  for (const r of await menu.getByRole('menuitemradio').all()) await expect(r).toBeEnabled();
  await expect(menu.getByRole('button', { name: 'Set' })).toBeDisabled();
  expect(await acting(page)).toEqual([]);
});

test('a double tap on the model button opens the menu and closes it again, picking nothing', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await doubleTap(page, modelButton(page, 'opus'));
  await page.waitForTimeout(300);
  await expect(modelMenu(page)).toHaveCount(0);
  expect(await acting(page)).toEqual([]);
});

// MARK: - Closing a menu

test('Escape, a tap outside and the menu\'s own button close a menu; the other button opens the other menu', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await modelButton(page, 'opus').click();
  await expect(modelMenu(page)).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(modelMenu(page)).toHaveCount(0);
  // A tap outside closes the menu and does nothing else: the tool row under it stays shut.
  await accountButton(page, 'acme-work').click();
  await expect(accountMenu(page).getByRole('menuitemradio')).toHaveCount(3);
  const tool = app(page).locator('.tx button.tool').first();
  await tool.click();
  await expect(accountMenu(page)).toHaveCount(0);
  await expect(tool).toHaveAttribute('aria-expanded', 'false');
  expect(await count(page, 'transcript.detail')).toBe(0);
  // The open menu's own button closes it; the other one opens its menu.
  await accountButton(page, 'acme-work').click();
  await expect(accountMenu(page)).toBeVisible();
  await modelButton(page, 'opus').click();
  await expect(modelMenu(page)).toBeVisible();
  await expect(accountMenu(page)).toHaveCount(0);
  await modelButton(page, 'opus').click();
  await expect(modelMenu(page)).toHaveCount(0);
  expect(await acting(page)).toEqual([]);
});

// MARK: - The session menu and its sheets

/** @param {Page} page */
function sheet(page) {
  return app(page).getByRole('dialog');
}

/**
 * Opens the session menu sheet from the header.
 * @param {Page} page
 */
async function openMenuSheet(page) {
  await app(page).getByRole('button', { name: 'Session menu' }).click();
  await expect(sheet(page)).toBeVisible();
}

test('the session menu names the row, and the tab when the row has several', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  await openMenuSheet(page);
  const dialog = sheet(page);
  await expect(dialog).toHaveAttribute('aria-modal', 'true');
  await expect(dialog).toHaveAccessibleName('Login redirect fix');
  await expect(dialog.locator('.sh-title')).toHaveText('Login redirect fix');
  const rows = dialog.locator('button.mi');
  await expect(rows.locator('small')).toHaveText(['Now Personal. Restarts in this tab.', 'Copy this conversation into a new tab', 'Now opus']);
  for (const r of await rows.all()) await expect(r).toBeEnabled();
  await expect(dialog.getByRole('button', { name: 'Cancel' })).toBeVisible();
  await dialog.getByRole('button', { name: 'Cancel' }).click();
  await expect(sheet(page)).toHaveCount(0);
  await app(page).getByRole('button', { name: 'Back to sessions' }).click();
  await openCheckout(page);
  await openMenuSheet(page);
  await expect(sheet(page).locator('.sh-title')).toHaveText('Checkout v2 · Review');
});

test("a remote session's Switch and Fork rows are disabled with the laptop's reason", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Triage flaky test');
  await openMenuSheet(page);
  const rows = sheet(page).locator('button.mi');
  await expect(rows.locator('small')).toHaveText(['Not available for remote sessions.', 'Not available for remote sessions.', 'Now opus']);
  await expect(rows.nth(0)).toBeDisabled();
  await expect(rows.nth(1)).toBeDisabled();
  await expect(rows.nth(2)).toBeEnabled();
});

test("a parked session's Fork row is disabled with the laptop's reason", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Docs refresh');
  await openMenuSheet(page);
  const rows = sheet(page).locator('button.mi');
  await expect(rows.nth(1).locator('small')).toHaveText('This session is parked. Send it a message to wake it, then fork it.');
  await expect(rows.nth(1)).toBeDisabled();
  await expect(rows.nth(0)).toBeEnabled();
  await expect(rows.nth(2)).toBeEnabled();
});

test('switch-confirm Restart sends switchProfile', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await openMenuSheet(page);
  await sheet(page).locator('button.mi').nth(0).click();
  const dialog = sheet(page);
  await expect(dialog.locator('.sh-title')).toHaveText('Switch account');
  await expect(dialog.locator('.sh-sub')).toHaveText('Restarts this session under another profile, in the same tab. The conversation stays.');
  const rows = dialog.locator('button.mi');
  await expect(rows).toHaveCount(3);
  await expect(rows.locator('small')).toHaveText(['Claude subscription · default', 'Claude subscription', 'Amazon Bedrock']);
  await expect(rows.nth(1)).toBeDisabled();
  await expect(rows.nth(1).locator('.cur')).toHaveText('Current');
  await rows.nth(0).click();
  await expect(dialog).toHaveAccessibleName('Restart this session under Personal?');
  await expect(dialog.locator('.confirm p')).toHaveText([
    'The conversation stays. Claude restarts in this tab.',
    'To keep this session as it is, fork instead. A copy opens in a new tab under Personal.',
  ]);
  await expect(dialog.locator('.confirm button')).toHaveText(['Restart', 'Fork into a new tab', 'Cancel']);
  await dialog.getByRole('button', { name: 'Restart' }).click();
  await expect.poll(() => acting(page)).toEqual([
    { method: 'session.switchProfile', params: { session: REVIEW_REF, profileID: PERSONAL } },
  ]);
  await expect(app(page).locator('.toast')).toHaveText('Restarted under Personal');
  await expect(sheet(page)).toHaveCount(0);
  expect(await acting(page)).toHaveLength(1);
});

test('Fork from the sheet opens the new tab', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await openMenuSheet(page);
  await sheet(page).locator('button.mi').nth(1).click();
  const dialog = sheet(page);
  await expect(dialog.locator('.sh-title')).toHaveText('Fork');
  await expect(dialog.locator('.sh-sub')).toHaveText('Copies this conversation into a new tab, under the account you pick. The phone switches to the new tab.');
  const rows = dialog.locator('button.mi');
  await expect(rows).toHaveCount(3);
  expect(await rows.evaluateAll((els) => els.map((el) => el.querySelector('span')?.firstChild?.textContent))).toEqual(['acme-work', 'Personal', 'acme-bedrock']);
  await expect(rows.locator('small')).toHaveText(['Same account as now', 'Claude subscription', 'Amazon Bedrock']);
  await hostCall(page, 'hold', 'sessions.changed');
  await rows.nth(1).click();
  await expect(app(page).locator('.toast')).toHaveText('Forked into a new tab, under Personal');
  expect(await acting(page)).toEqual([{ method: 'session.fork', params: { session: REVIEW_REF, profileID: PERSONAL } }]);
  await expect(sheet(page)).toHaveCount(0);
  await page.waitForTimeout(300);
  await expect(app(page).getByRole('tab')).toHaveCount(3);
  await hostCall(page, 'release', 'sessions.changed');
  await expect(app(page).locator('[role="tab"][aria-selected="true"]')).toContainText('Review 4');
});

test('"Same account as now" forks with no profileID', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await openMenuSheet(page);
  await sheet(page).locator('button.mi').nth(1).click();
  await sheet(page).locator('button.mi').filter({ hasText: 'Same account as now' }).click();
  await expect(app(page).locator('.toast')).toHaveText('Forked into a new tab, under acme-work');
  expect(await acting(page)).toEqual([{ method: 'session.fork', params: { session: REVIEW_REF } }]);
});

test('a double click on a Fork sheet row posts one request', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await openMenuSheet(page);
  await sheet(page).locator('button.mi').nth(1).click();
  const personal = sheet(page).locator('button.mi').nth(1);
  await expect(personal).toBeEnabled();
  await hostCall(page, 'hold', 'session.fork');
  await personal.dblclick();
  await expect.poll(() => acting(page)).toHaveLength(1);
  for (const r of await sheet(page).locator('button.mi').all()) await expect(r).toBeDisabled();
  await page.waitForTimeout(300);
  await hostCall(page, 'release', 'session.fork');
  await expect(app(page).locator('.toast')).toHaveText('Forked into a new tab, under Personal');
  expect(await acting(page)).toEqual([{ method: 'session.fork', params: { session: REVIEW_REF, profileID: PERSONAL } }]);
});

test("a double tap on the session menu's Fork row never forks, and the Fork sheet's rows wait as they appear", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await openMenuSheet(page);
  await hostCall(page, 'hold', 'profiles.list');
  const at = await doubleTap(page, sheet(page).locator('button.mi').nth(1));
  await expect(sheet(page).locator('.sh-title')).toHaveText('Fork');
  await expect(sheet(page).locator('[data-state="profiles-loading"] .spin')).toBeVisible();
  // The profiles arrive, and a tap lands where a row has just appeared.
  await hostCall(page, 'release', 'profiles.list');
  const first = sheet(page).locator('button.mi').first();
  await expect(first).toBeVisible();
  expect(await covers(first, at), "a fork row lies under the double tap on the menu's Fork").toBe(true);
  await page.mouse.click(at.x, at.y);
  await page.waitForTimeout(TAP_GUARD_MS + 200);
  expect(await acting(page)).toEqual([]);
  await expect(first).toBeEnabled();
});

test("a double tap on a Switch account profile lands on its question, whose Restart waits", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await openMenuSheet(page);
  await sheet(page).locator('button.mi').nth(0).click();
  const personal = sheet(page).locator('button.mi').nth(0);
  await expect(personal).toBeEnabled();
  const at = await doubleTap(page, personal);
  const restart = sheet(page).getByRole('button', { name: 'Restart' });
  await expect(restart).toBeVisible();
  expect(await covers(restart, at), 'Restart lies under the double tap on Personal').toBe(true);
  await page.waitForTimeout(TAP_GUARD_MS + 200);
  expect(await acting(page)).toEqual([]);
  await expect(restart).toBeEnabled();
});

test('an event that takes the session off the list closes its sheet, and nothing is sent', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await openMenuSheet(page);
  await sheet(page).locator('button.mi').nth(0).click();
  await sheet(page).locator('button.mi').nth(0).click();
  await expect(sheet(page).getByRole('button', { name: 'Restart' })).toBeEnabled();
  const checkout = '00000000-0000-4000-8000-0000000000C3';
  const layout = MOCK.layout.map((/** @type {any} */ g) => ({ ...g, rows: g.rows.filter((/** @type {any} */ r) => r.id !== checkout) }));
  await hostCall(page, 'emit', 'sessions.changed', { layout, rows: [], removedRowIDs: [checkout] });
  await expect(app(page).locator('#app')).toHaveAttribute('data-screen', 'sessions');
  await expect(sheet(page)).toHaveCount(0);
  expect(await acting(page)).toEqual([]);
});

test('focus moves into the sheet when it opens and back to its opener when it closes', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  const opener = app(page).getByRole('button', { name: 'Session menu' });
  await opener.focus();
  await page.keyboard.press('Enter');
  await expect(sheet(page)).toBeVisible();
  await expect(sheet(page)).toBeFocused();
  // Another sheet takes the focus too, as the row that opened it is gone.
  await sheet(page).locator('button.mi').nth(2).focus();
  await page.keyboard.press('Enter');
  await expect(sheet(page).locator('.sh-title')).toHaveText('Model');
  await expect(sheet(page)).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(sheet(page)).toHaveCount(0);
  await expect(opener).toBeFocused();
  // The scrim closes it as well.
  await opener.focus();
  await page.keyboard.press('Enter');
  await expect(sheet(page)).toBeVisible();
  await app(page).locator('.scrim').click({ position: { x: 20, y: 20 } });
  await expect(sheet(page)).toHaveCount(0);
  await expect(opener).toBeFocused();
});

test("a fork's error shows in the sheet, which stays open", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  const reason = 'TBD could not copy this conversation. Try again on the laptop.';
  await hostCall(page, 'setReply', 'session.fork', { error: { code: 'refused', message: reason } });
  await openMenuSheet(page);
  await sheet(page).locator('button.mi').nth(1).click();
  await sheet(page).locator('button.mi').nth(2).click();
  await expect(sheet(page).locator('.refusal')).toHaveText(reason);
  await expect(sheet(page).locator('.sh-title')).toHaveText('Fork');
  await expect(app(page).locator('.toast')).toHaveCount(0);
  await expect(app(page).locator('.dock > .refusal')).toHaveCount(0);
  expect(await acting(page)).toEqual([{ method: 'session.fork', params: { session: REVIEW_REF, profileID: BEDROCK } }]);
  // The rows wait once more as the refusal moves them.
  await expect(sheet(page).locator('button.mi').first()).toBeEnabled();
});

test('the Model sheet sends the pick, or the typed name trimmed', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await openMenuSheet(page);
  await sheet(page).locator('button.mi').nth(2).click();
  const dialog = sheet(page);
  await expect(dialog.locator('.sh-title')).toHaveText('Model');
  await expect(dialog.locator('.sh-sub')).toHaveText('Sends /model to the session.');
  const rows = dialog.locator('button.mi');
  await expect(rows).toHaveText(['default', 'opusCurrent', 'sonnet', 'haiku']);
  await expect(rows.nth(1).locator('.tick')).toHaveCount(1);
  const set = dialog.getByRole('button', { name: 'Set' });
  await expect(set).toBeDisabled();
  await rows.nth(2).click();
  await expect(rows.nth(2).locator('.tick')).toHaveCount(1);
  await expect(dialog.locator('.tick')).toHaveCount(1);
  await set.click();
  await expect.poll(() => acting(page)).toEqual([{ method: 'session.setModel', params: { session: REVIEW_REF, model: 'sonnet' } }]);
  await expect(app(page).locator('.toast')).toHaveText('Model set to sonnet');
  await expect(sheet(page)).toHaveCount(0);
  await openMenuSheet(page);
  await sheet(page).locator('button.mi').nth(2).click();
  const field = sheet(page).getByLabel('Other model name');
  await expect(field).toHaveAttribute('placeholder', 'for example claude-opus-5-5');
  await field.fill('  claude-opus-5-5 ');
  await expect(sheet(page).locator('.tick')).toHaveCount(0);
  await sheet(page).getByRole('button', { name: 'Set' }).click();
  await expect.poll(async () => (await acting(page)).at(-1)).toEqual({ method: 'session.setModel', params: { session: REVIEW_REF, model: 'claude-opus-5-5' } });
  await expect(app(page).locator('.toast')).toHaveText('Model set to claude-opus-5-5');
});

test('a model change refused from the sheet shows there, and in the composer once the sheet closes', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await hostCall(page, 'setReply', 'session.setModel', { error: { code: 'bad_request', message: 'That is not a model name.' } });
  await openMenuSheet(page);
  await sheet(page).locator('button.mi').nth(2).click();
  await sheet(page).getByLabel('Other model name').fill('opus-9');
  await sheet(page).getByRole('button', { name: 'Set' }).click();
  await expect(sheet(page).locator('.refusal')).toHaveText('That is not a model name.');
  await app(page).locator('.scrim').click({ position: { x: 20, y: 20 } });
  await expect(sheet(page)).toHaveCount(0);
  await expect(app(page).locator('.dock > .refusal')).toHaveText('That is not a model name.');
  expect(await acting(page)).toEqual([{ method: 'session.setModel', params: { session: REVIEW_REF, model: 'opus-9' } }]);
});

// MARK: - What a closing menu or sheet uncovers

/** @param {Page} page */
function sendButton(page) {
  return app(page).locator('.dock .comp button.send');
}

/**
 * How many messages reached the fake laptop.
 * @param {Page} page
 */
async function sends(page) {
  return count(page, 'message.send');
}

test("a double tap on the session menu's Cancel never sends the draft under it", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await app(page).getByRole('textbox', { name: 'Message' }).fill('rm -rf build');
  const send = sendButton(page);
  await expect(send).toBeEnabled();
  const at = await centre(send);
  await openMenuSheet(page);
  const cancel = sheet(page).getByRole('button', { name: 'Cancel' });
  expect(await covers(cancel, at), 'Cancel lies over Send').toBe(true);
  await page.mouse.dblclick(at.x, at.y);
  await expect(sheet(page)).toHaveCount(0);
  await page.waitForTimeout(TAP_GUARD_MS + 200);
  expect(await sends(page)).toBe(0);
  await expect(app(page).getByRole('textbox', { name: 'Message' })).toHaveValue('rm -rf build');
  await expect(send).toBeEnabled();
});

test('a double tap outside the account menu never sends the draft under it', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await app(page).getByRole('textbox', { name: 'Message' }).fill('rm -rf build');
  const send = sendButton(page);
  await expect(send).toBeEnabled();
  await accountButton(page, 'acme-work').click();
  await expect(row(accountMenu(page), 'Personal')).toBeVisible();
  const at = await centre(send);
  await page.mouse.dblclick(at.x, at.y);
  await expect(accountMenu(page)).toHaveCount(0);
  await page.waitForTimeout(TAP_GUARD_MS + 200);
  expect(await sends(page)).toBe(0);
  await expect(send).toBeEnabled();
});

test('a double tap outside the model menu never answers the question under it', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  const option = app(page).locator('.dock .card button.opt', { hasText: 'No, this is enough' });
  await expect(option).toBeEnabled();
  await modelButton(page, 'opus').click();
  const menu = modelMenu(page);
  await expect(menu).toBeVisible();
  const at = await centre(option);
  expect(await covers(menu, at), 'the option lies outside the menu').toBe(false);
  await page.mouse.dblclick(at.x, at.y);
  await expect(menu).toHaveCount(0);
  await page.waitForTimeout(TAP_GUARD_MS + 200);
  expect(await count(page, 'prompt.answer')).toBe(0);
  await expect(option).toBeEnabled();
});

test("closing a menu by Escape or by its own button holds Send for a moment", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await app(page).getByRole('textbox', { name: 'Message' }).fill('rm -rf build');
  const send = sendButton(page);
  await expect(send).toBeEnabled();
  await accountButton(page, 'acme-work').click();
  await expect(accountMenu(page)).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(accountMenu(page)).toHaveCount(0);
  await expect(send).toBeDisabled();
  await expect(send).toBeEnabled();
  await modelButton(page, 'opus').click();
  await expect(modelMenu(page)).toBeVisible();
  await modelButton(page, 'opus').click();
  await expect(modelMenu(page)).toHaveCount(0);
  await expect(send).toBeDisabled();
  await expect(send).toBeEnabled();
  expect(await sends(page)).toBe(0);
});

// MARK: - Buttons that cannot act

const PARKED_FORK = 'This session is parked. Send it a message to wake it, then fork it.';

test("a parked session's ask and switch-confirm disable Fork with the laptop's reason, and Restart still works", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Docs refresh');
  await accountButton(page, 'Personal').click();
  const menu = accountMenu(page);
  await row(menu, 'acme-work').click();
  const fork = menu.getByRole('button', { name: 'Fork into a new tab' });
  await expect(menu.getByRole('button', { name: 'Restart' })).toBeEnabled();
  await expect(fork).toBeDisabled();
  await expect(menu.locator('.pd-ask div span')).toHaveText(PARKED_FORK);
  await page.keyboard.press('Escape');
  await openMenuSheet(page);
  await sheet(page).locator('button.mi').nth(0).click();
  await sheet(page).locator('button.mi', { hasText: 'acme-work' }).click();
  const dialog = sheet(page);
  const restart = dialog.getByRole('button', { name: 'Restart' });
  await expect(restart).toBeEnabled();
  await expect(dialog.getByRole('button', { name: 'Fork into a new tab' })).toBeDisabled();
  await expect(dialog.locator('.confirm > p').last()).toHaveText(PARKED_FORK);
  expect(await acting(page)).toEqual([]);
  await restart.click();
  await expect.poll(() => acting(page)).toEqual([
    { method: 'session.switchProfile', params: { session: DOCS_REF, profileID: WORK } },
  ]);
});

/**
 * Checkout v2's row in mock.json with its Review tab moved to Personal, as a sessions.changed
 * reports a switch made on the laptop.
 */
function reviewOnPersonal() {
  const moved = structuredClone(MOCK.rows.find((/** @type {any} */ r) => r.name === 'Checkout v2'));
  const review = moved.sessions.find((/** @type {any} */ s) => s.ref.terminalID === REVIEW_REF.terminalID);
  review.profileID = PERSONAL;
  review.profileName = 'Personal';
  return moved;
}

test('switch-confirm disables Restart with a reason once an event says the session runs under that profile', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await openMenuSheet(page);
  await sheet(page).locator('button.mi').nth(0).click();
  await sheet(page).locator('button.mi', { hasText: 'Personal' }).click();
  const restart = sheet(page).getByRole('button', { name: 'Restart' });
  await expect(restart).toBeEnabled();
  await hostCall(page, 'emit', 'sessions.changed', { rows: [reviewOnPersonal()], removedRowIDs: [] });
  await expect(restart).toBeDisabled();
  await expect(sheet(page).locator('.confirm > p').last()).toHaveText('This session already runs under Personal.');
  await page.waitForTimeout(TAP_GUARD_MS + 200);
  await expect(restart).toBeDisabled();
  expect(await acting(page)).toEqual([]);
});

test("the Fork sheet's rows wait when an event changes the current profile and reorders them", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openCheckout(page);
  await openMenuSheet(page);
  await sheet(page).locator('button.mi').nth(1).click();
  const first = sheet(page).locator('button.mi').first();
  await expect(first.locator('small')).toHaveText('Same account as now');
  await expect(first).toContainText('acme-work');
  await expect(first).toBeEnabled();
  await hostCall(page, 'emit', 'sessions.changed', { rows: [reviewOnPersonal()], removedRowIDs: [] });
  await expect(first).toContainText('Personal');
  await expect(first).toBeDisabled();
  await expect(first).toBeEnabled();
  expect(await acting(page)).toEqual([]);
});

// MARK: - New

const WEB_REPO = '00000000-0000-4000-8000-0000000000A1';
const API_REPO = '00000000-0000-4000-8000-0000000000A2';
/** The mock's first messages (mock 1356-1357). */
const LOCAL_MESSAGE = 'Add a dark mode toggle to the settings screen.';
const REMOTE_MESSAGE = 'Profile the slow orders query and suggest an index.';
const WORKTREE_REFUSED = 'The worktree could not be created. Check the laptop.';
const REMOTE_REFUSED = 'The remote provider refused this. Check the laptop.';
const SIGN_IN = 'Sign in to this provider on your laptop.';
const CREATES = new Set(['worktree.create', 'remote.create']);

/**
 * Every create that reached the fake laptop, in order.
 * @param {Page} page
 */
async function creates(page) {
  return (await hostRequests(page)).filter((r) => CREATES.has(r.method)).map((r) => ({ method: r.method, params: r.params }));
}

/**
 * The "+" on `repo`'s header in the sessions list.
 * @param {Page} page
 * @param {string} repo
 */
function plus(page, repo) {
  return app(page).getByRole('button', { name: `New session in ${repo}` });
}

/**
 * Opens `repo`'s New sheet from its "+".
 * @param {Page} page
 * @param {string} repo
 */
async function openNew(page, repo) {
  await plus(page, repo).click();
  await expect(sheet(page).locator('.sh-title')).toHaveText(`New in ${repo}`);
}

/** @param {Page} page */
function createButton(page) {
  return sheet(page).getByRole('button', { name: 'Create', exact: true });
}

/** @param {Page} page */
function firstMessage(page) {
  return sheet(page).getByRole('textbox', { name: 'First message' });
}

/**
 * The provider row named `name`.
 * @param {Page} page
 * @param {string} name
 */
function provider(page, name) {
  return sheet(page).locator('button.mi', { hasText: name });
}

/**
 * Chooses Remote session and picks `name` once the providers load.
 * @param {Page} page
 * @param {string} name
 */
async function pickProvider(page, name) {
  await sheet(page).getByRole('button', { name: 'Remote session' }).click();
  const row = provider(page, name);
  await expect(row).toBeEnabled();
  await row.click();
  await expect(row).toHaveAttribute('aria-pressed', 'true');
}

/**
 * mock.json with its providers changed by `edit`.
 * @param {(providers: any[]) => void} edit
 */
function withProviders(edit) {
  const scenario = structuredClone(MOCK);
  edit(scenario.providers);
  return scenario;
}

/** @param {Page} page */
function screenName(page) {
  return app(page).locator('#app');
}

test('"+" on acme-web opens "New in acme-web" and Create sends that repo\'s ID', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openNew(page, 'acme-web');
  await expect(sheet(page).getByRole('button', { name: 'Local worktree' })).toHaveAttribute('aria-pressed', 'true');
  await expect(sheet(page).locator('.sh-sub')).toHaveText('TBD picks the branch, the worktree name and everything else from its defaults.');
  await expect(createButton(page)).toBeDisabled();
  await firstMessage(page).fill(LOCAL_MESSAGE);
  await createButton(page).click();
  await expect.poll(() => creates(page)).toEqual([{ method: 'worktree.create', params: { repoID: WEB_REPO, message: LOCAL_MESSAGE } }]);
});

test('Create waits for a first message that is not blank, and sends it as typed', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openNew(page, 'acme-api');
  const create = createButton(page);
  for (const blank of [' ', ' \n\t ', '​']) {
    await firstMessage(page).fill(blank);
    await page.waitForTimeout(100);
    await expect(create).toBeDisabled();
  }
  await firstMessage(page).fill(`  ${LOCAL_MESSAGE}\n`);
  await create.click();
  await expect.poll(() => creates(page)).toEqual([{ method: 'worktree.create', params: { repoID: API_REPO, message: `  ${LOCAL_MESSAGE}\n` } }]);
});

test('the new session opens once its row appears, with "Created new-worktree-1"', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openNew(page, 'acme-web');
  await firstMessage(page).fill(LOCAL_MESSAGE);
  await hostCall(page, 'hold', 'sessions.changed');
  await hostCall(page, 'hold', 'worktree.create');
  await createButton(page).click();
  // While the create is on its way, the sheet shows only that.
  await expect(sheet(page).locator('.creating')).toContainText('Creating the worktree…');
  await expect(sheet(page).locator('.creating')).toContainText('The session opens when it is ready.');
  await expect(createButton(page)).toHaveCount(0);
  await hostCall(page, 'release', 'worktree.create');
  // The reply closes the sheet, but the list does not show the row yet.
  await expect(sheet(page)).toHaveCount(0);
  await page.waitForTimeout(300);
  await expect(screenName(page)).toHaveAttribute('data-screen', 'sessions');
  await expect(app(page).locator('.toast')).toHaveCount(0);
  await hostCall(page, 'release', 'sessions.changed');
  await expect(screenName(page)).toHaveAttribute('data-screen', 'session');
  await expect(app(page).locator('.toast')).toHaveText('Created new-worktree-1');
  const made = await page.evaluate(() => /** @type {any} */ (window).__host.state.rows
    .find((/** @type {any} */ r) => r.name === 'new-worktree-1').sessions[0].ref);
  await expect.poll(async () => (await hostRequests(page)).filter((r) => r.method === 'transcript.open').at(-1)?.params)
    .toEqual({ session: made, showDetails: false, resume: false });
  expect(await creates(page)).toEqual([{ method: 'worktree.create', params: { repoID: WEB_REPO, message: LOCAL_MESSAGE } }]);
});

test('a create the user moved away from while it was on its way opens nothing', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openNew(page, 'acme-web');
  await firstMessage(page).fill(LOCAL_MESSAGE);
  await hostCall(page, 'hold', 'worktree.create');
  await createButton(page).click();
  await expect(sheet(page).locator('.creating')).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(sheet(page)).toHaveCount(0);
  await openSessionByName(page, 'Login redirect fix');
  await expect(app(page).locator('.tx [data-tx-row]').first()).toBeVisible();
  const opens = await count(page, 'transcript.open');
  await hostCall(page, 'release', 'worktree.create');
  await expect.poll(() => page.evaluate(() => /** @type {any} */ (window).__host.state.rows.some((/** @type {any} */ r) => r.name === 'new-worktree-1')))
    .toBe(true);
  await page.waitForTimeout(500);
  await expect(app(page).locator('.s-title .t1')).toHaveText('Login redirect fix');
  expect(await count(page, 'transcript.open')).toBe(opens);
  await expect(app(page).locator('.toast')).toHaveCount(0);
});

test('a sheet closed while its create is on its way still opens the new session', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openNew(page, 'acme-web');
  await firstMessage(page).fill(LOCAL_MESSAGE);
  await hostCall(page, 'hold', 'worktree.create');
  await createButton(page).click();
  await expect(sheet(page).locator('.creating')).toBeVisible();
  // A tap on the scrim above the sheet closes it.
  const box = await sheet(page).boundingBox();
  if (box === null) throw new Error('no sheet');
  await page.mouse.click(box.x + 20, box.y - 10);
  await expect(sheet(page)).toHaveCount(0);
  await hostCall(page, 'release', 'worktree.create');
  await expect(screenName(page)).toHaveAttribute('data-screen', 'session');
  await expect(app(page).locator('.toast')).toHaveText('Created new-worktree-1');
});

test("a refused create shows the laptop's reason in the sheet, and keeps the message", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await hostCall(page, 'setReply', 'worktree.create', { error: { code: 'refused', message: WORKTREE_REFUSED } });
  await openNew(page, 'acme-web');
  await firstMessage(page).fill(LOCAL_MESSAGE);
  await createButton(page).click();
  await expect(sheet(page).getByRole('alert')).toHaveText(WORKTREE_REFUSED);
  await expect(firstMessage(page)).toHaveValue(LOCAL_MESSAGE);
  await expect(createButton(page)).toBeEnabled();
  await expect(app(page).locator('.toast')).toHaveCount(0);
  await expect(screenName(page)).toHaveAttribute('data-screen', 'sessions');
  expect(await creates(page)).toEqual([{ method: 'worktree.create', params: { repoID: WEB_REPO, message: LOCAL_MESSAGE } }]);
});

test('a create that fails after its sheet closed toasts nothing, and the next New sheet of its repo shows why', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await hostCall(page, 'setReply', 'worktree.create', { error: { code: 'refused', message: WORKTREE_REFUSED } });
  await hostCall(page, 'hold', 'worktree.create');
  await openNew(page, 'acme-web');
  await firstMessage(page).fill(LOCAL_MESSAGE);
  await createButton(page).click();
  await expect(sheet(page).locator('.creating')).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(sheet(page)).toHaveCount(0);
  await hostCall(page, 'release', 'worktree.create');
  await page.waitForTimeout(500);
  await expect(app(page).locator('.toast')).toHaveCount(0);
  // Another repo's sheet does not show it.
  await openNew(page, 'acme-api');
  await expect(sheet(page).getByRole('alert')).toHaveCount(0);
  await page.keyboard.press('Escape');
  // The repo's next sheet does, once.
  await openNew(page, 'acme-web');
  await expect(sheet(page).getByRole('alert')).toHaveText(WORKTREE_REFUSED);
  await page.keyboard.press('Escape');
  await openNew(page, 'acme-web');
  await expect(createButton(page)).toBeVisible();
  await expect(sheet(page).getByRole('alert')).toHaveCount(0);
});

test('while a create is on its way, a New sheet for its repo shows it, and one for another repo cannot create', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await hostCall(page, 'hold', 'worktree.create');
  await openNew(page, 'acme-web');
  await firstMessage(page).fill(LOCAL_MESSAGE);
  await createButton(page).click();
  await expect(sheet(page).locator('.creating')).toBeVisible();
  await page.keyboard.press('Escape');
  await openNew(page, 'acme-api');
  await firstMessage(page).fill(LOCAL_MESSAGE);
  await expect(sheet(page).locator('.sh-sub').first()).toHaveText('Create waits for the new session already on its way.');
  await page.waitForTimeout(TAP_GUARD_MS + 100);
  await expect(createButton(page)).toBeDisabled();
  await page.keyboard.press('Escape');
  await expect(sheet(page)).toHaveCount(0);
  await plus(page, 'acme-web').click();
  await expect(sheet(page).locator('.creating')).toContainText('Creating the worktree…');
  await hostCall(page, 'release', 'worktree.create');
  await expect(sheet(page)).toHaveCount(0);
  await expect(screenName(page)).toHaveAttribute('data-screen', 'session');
  expect(await creates(page)).toHaveLength(1);
});

test('a double click on Create posts one worktree.create', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openNew(page, 'acme-web');
  await firstMessage(page).fill(LOCAL_MESSAGE);
  await expect(createButton(page)).toBeEnabled();
  await hostCall(page, 'hold', 'worktree.create');
  await doubleTap(page, createButton(page));
  await expect.poll(() => creates(page)).toHaveLength(1);
  await page.waitForTimeout(300);
  expect(await creates(page)).toHaveLength(1);
  await hostCall(page, 'release', 'worktree.create');
  await expect(screenName(page)).toHaveAttribute('data-screen', 'session');
  expect(await creates(page)).toHaveLength(1);
});

test('a double click on Create posts one remote.create, with the form as the laptop filled it', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openNew(page, 'acme-api');
  await pickProvider(page, 'acme-cloud');
  await firstMessage(page).fill(REMOTE_MESSAGE);
  await expect(createButton(page)).toBeEnabled();
  await hostCall(page, 'hold', 'remote.create');
  await doubleTap(page, createButton(page));
  await expect(sheet(page).locator('.creating')).toContainText('Starting the remote session…');
  await page.waitForTimeout(300);
  await hostCall(page, 'release', 'remote.create');
  await expect(app(page).locator('.toast')).toHaveText('Remote session started on acme-cloud');
  await expect(screenName(page)).toHaveAttribute('data-screen', 'session');
  expect(await creates(page)).toEqual([{
    method: 'remote.create',
    params: {
      provider: 'acme-cloud', repoID: API_REPO, message: REMOTE_MESSAGE,
      strings: { branch: 'main', size: 'Medium', hours: '4' }, bools: { setup: true },
    },
  }]);
});

test('remote.create carries strings and bools by field type', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openNew(page, 'acme-api');
  await pickProvider(page, 'acme-cloud');
  const s = sheet(page);
  await expect(provider(page, 'acme-cloud').locator('small')).toHaveText('5 more fields');
  await expect(provider(page, 'acme-sandbox').locator('small')).toHaveText('Needs nothing else');
  await expect(s.locator('.lbl').last()).toHaveText('acme-cloud needs');
  // Each field by its type, with its prefill; the required ones say so.
  const branch = s.getByLabel(/^Branch/);
  await expect(branch).toHaveAttribute('type', 'text');
  await expect(branch).toHaveValue('main');
  await expect(s.locator('.frow label', { hasText: 'Branch' }).locator('.req')).toHaveText('required');
  const size = s.getByLabel(/^Machine size/);
  await expect(size).toHaveValue('Medium');
  await expect(size.locator('option')).toHaveText(['Small', 'Medium', 'Large']);
  await expect(s.locator('.frow label', { hasText: 'Machine size' }).locator('.req')).toHaveText('required');
  const setup = s.getByRole('switch', { name: 'Run the setup script' });
  await expect(setup).toBeChecked();
  await expect(s.locator('.frow.sw')).toHaveCount(1);
  const hours = s.getByLabel('Time limit, hours');
  await expect(hours).toHaveAttribute('type', 'number');
  await expect(hours).toHaveAttribute('inputmode', 'numeric');
  await expect(hours).toHaveValue('4');
  const notes = s.getByLabel('Notes for the agent');
  await expect(notes).toHaveJSProperty('tagName', 'TEXTAREA');
  await expect(notes).toHaveValue('');
  await expect(s.locator('.req')).toHaveCount(2);
  // A required field left blank holds Create.
  await firstMessage(page).fill(REMOTE_MESSAGE);
  await branch.fill('  ');
  await page.waitForTimeout(TAP_GUARD_MS + 100);
  await expect(createButton(page)).toBeDisabled();
  await branch.fill('  release/1.2  ');
  await size.selectOption('Large');
  await s.locator('.frow.sw label.tg').click();
  await expect(setup).not.toBeChecked();
  await hours.fill('');
  await notes.fill('  Use the staging data.\n');
  await createButton(page).click();
  await expect.poll(() => creates(page)).toEqual([{
    method: 'remote.create',
    params: {
      provider: 'acme-cloud', repoID: API_REPO, message: REMOTE_MESSAGE,
      strings: { branch: 'release/1.2', size: 'Large', notes: 'Use the staging data.' }, bools: { setup: false },
    },
  }]);
});

test('an unavailable provider is disabled with its reason', async ({ page, appHost }) => {
  await openApp(page, appHost, {
    scenario: withProviders((providers) => {
      providers[1] = { name: 'acme-sandbox', available: false, reason: SIGN_IN, acceptsPrompt: true, fields: [] };
    }),
  });
  await openNew(page, 'acme-api');
  await sheet(page).getByRole('button', { name: 'Remote session' }).click();
  const sandbox = provider(page, 'acme-sandbox');
  await expect(sandbox.locator('small')).toHaveText(SIGN_IN);
  await expect(provider(page, 'acme-cloud')).toBeEnabled();
  await expect(sandbox).toBeDisabled();
  await firstMessage(page).fill(REMOTE_MESSAGE);
  await expect(createButton(page)).toBeDisabled();
  expect(await creates(page)).toEqual([]);
});

test('a provider that takes no first message hides the field', async ({ page, appHost }) => {
  await openApp(page, appHost, {
    scenario: withProviders((providers) => {
      providers[1].acceptsPrompt = false;
    }),
  });
  await openNew(page, 'acme-api');
  await pickProvider(page, 'acme-cloud');
  await firstMessage(page).fill(REMOTE_MESSAGE);
  await provider(page, 'acme-sandbox').click();
  await expect(provider(page, 'acme-sandbox')).toHaveAttribute('aria-pressed', 'true');
  await expect(firstMessage(page)).toHaveCount(0);
  await expect(sheet(page).getByText('First message')).toHaveCount(0);
  await createButton(page).click();
  await expect.poll(() => creates(page)).toEqual([{
    method: 'remote.create', params: { provider: 'acme-sandbox', repoID: API_REPO, message: '', strings: {}, bools: {} },
  }]);
});

test("a remote refusal shows TBD's fixed words as they come", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await hostCall(page, 'setReply', 'remote.create', { error: { code: 'refused', message: REMOTE_REFUSED } });
  await openNew(page, 'acme-api');
  await pickProvider(page, 'acme-sandbox');
  await firstMessage(page).fill(REMOTE_MESSAGE);
  await createButton(page).click();
  await expect(sheet(page).getByRole('alert')).toHaveText(REMOTE_REFUSED);
  await expect(provider(page, 'acme-sandbox')).toHaveAttribute('aria-pressed', 'true');
  await expect(firstMessage(page)).toHaveValue(REMOTE_MESSAGE);
  await expect(app(page).locator('.toast')).toHaveCount(0);
});

test('the providers show a spinner while they load, and the error if the load fails', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openNew(page, 'acme-api');
  await hostCall(page, 'hold', 'remote.providers');
  await sheet(page).getByRole('button', { name: 'Remote session' }).click();
  await expect(sheet(page).locator('[data-state="providers-loading"] .spin')).toBeVisible();
  await hostCall(page, 'release', 'remote.providers');
  await expect(provider(page, 'acme-cloud')).toBeVisible();
  expect((await hostRequests(page)).filter((r) => r.method === 'remote.providers').map((r) => r.params)).toEqual([{ repoID: API_REPO }]);
  const failed = 'TBD could not read the remote providers. Try again.';
  await hostCall(page, 'setReply', 'remote.providers', { error: { code: 'internal', message: failed } });
  await sheet(page).getByRole('button', { name: 'Local worktree' }).click();
  await sheet(page).getByRole('button', { name: 'Remote session' }).click();
  await expect(sheet(page).getByRole('alert')).toHaveText(failed);
  await expect(provider(page, 'acme-cloud')).toHaveCount(0);
});

test('a list that loads again with the picked provider unavailable unpicks it', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openNew(page, 'acme-api');
  await pickProvider(page, 'acme-cloud');
  await firstMessage(page).fill(REMOTE_MESSAGE);
  await expect(createButton(page)).toBeEnabled();
  const providers = structuredClone(MOCK.providers);
  providers[0] = { name: 'acme-cloud', available: false, reason: SIGN_IN, acceptsPrompt: true, fields: [] };
  await hostCall(page, 'setReply', 'remote.providers', { result: { providers } });
  await sheet(page).getByRole('button', { name: 'Local worktree' }).click();
  await sheet(page).getByRole('button', { name: 'Remote session' }).click();
  await expect(provider(page, 'acme-cloud').locator('small')).toHaveText(SIGN_IN);
  await expect(provider(page, 'acme-cloud')).toHaveAttribute('aria-pressed', 'false');
  await expect(sheet(page).getByText('acme-cloud needs')).toHaveCount(0);
  await page.waitForTimeout(TAP_GUARD_MS + 100);
  await expect(createButton(page)).toBeDisabled();
  expect(await creates(page)).toEqual([]);
});

test('Create and the provider rows wait a moment after the view changes under them', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openNew(page, 'acme-api');
  await firstMessage(page).fill(LOCAL_MESSAGE);
  const create = createButton(page);
  await expect(create).toBeEnabled();
  await hostCall(page, 'hold', 'remote.providers');
  await sheet(page).getByRole('button', { name: 'Remote session' }).click();
  await expect(sheet(page).locator('[data-state="providers-loading"]')).toBeVisible();
  await hostCall(page, 'release', 'remote.providers');
  // The rows land where the spinner was: a tap aimed at it a moment ago picks nothing.
  await expect(provider(page, 'acme-sandbox')).toBeVisible();
  await expect(provider(page, 'acme-sandbox')).toBeDisabled();
  await expect(provider(page, 'acme-sandbox')).toBeEnabled();
  await provider(page, 'acme-sandbox').click();
  await expect(create).toBeDisabled();
  await expect(create).toBeEnabled();
  await sheet(page).getByRole('button', { name: 'Local worktree' }).click();
  await expect(create).toBeDisabled();
  await expect(create).toBeEnabled();
  expect(await creates(page)).toEqual([]);
});

test('Cancel closes the sheet and sends nothing, and a double tap on it opens no session', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openNew(page, 'acme-web');
  await firstMessage(page).fill(LOCAL_MESSAGE);
  const cancel = sheet(page).getByRole('button', { name: 'Cancel' });
  const at = await centre(cancel);
  // The sheet covers a row of the list where Cancel is.
  await page.keyboard.press('Escape');
  await expect(sheet(page)).toHaveCount(0);
  const under = rowButtons(page);
  let covered = false;
  for (const r of await under.all()) if (await covers(r, at)) covered = true;
  expect(covered, 'a row lies under Cancel').toBe(true);
  await page.waitForTimeout(TAP_GUARD_MS + 100);
  await openNew(page, 'acme-web');
  const opens = await count(page, 'transcript.open');
  await page.mouse.dblclick(at.x, at.y);
  await expect(sheet(page)).toHaveCount(0);
  await page.waitForTimeout(TAP_GUARD_MS + 200);
  await expect(screenName(page)).toHaveAttribute('data-screen', 'sessions');
  expect(await count(page, 'transcript.open')).toBe(opens);
  expect(await creates(page)).toEqual([]);
  // The list takes taps again.
  await openSessionByName(page, 'main');
  await expect(screenName(page)).toHaveAttribute('data-screen', 'session');
});

test('a double tap on the scrim over a "+" opens no second New sheet', async ({ page, appHost }) => {
  await openApp(page, appHost);
  const add = plus(page, 'acme-web');
  await openNew(page, 'acme-web');
  const box = await sheet(page).boundingBox();
  if (box === null) throw new Error('no sheet');
  // Just above the sheet, the scrim lies over the "+".
  const at = { x: (await centre(add)).x, y: box.y - 4 };
  expect(await covers(add, at), 'the "+" lies under the scrim just above the sheet').toBe(true);
  await page.mouse.dblclick(at.x, at.y);
  await expect(sheet(page)).toHaveCount(0);
  await page.waitForTimeout(TAP_GUARD_MS + 200);
  await expect(sheet(page)).toHaveCount(0);
  await expect(screenName(page)).toHaveAttribute('data-screen', 'sessions');
});

test('the focused field stays above the keyboard', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openNew(page, 'acme-api');
  await pickProvider(page, 'acme-cloud');
  const { width, height } = /** @type {{ width: number, height: number }} */ (page.viewportSize());
  const keyboardTop = height - 336;
  const above = (/** @type {Locator} */ el) => el.evaluate((node, top) => node.getBoundingClientRect().bottom <= top, keyboardTop);
  const inView = (/** @type {Locator} */ el) => el.evaluate((node) => {
    const box = /** @type {Element} */ (node.closest('.sheet')).getBoundingClientRect();
    const r = node.getBoundingClientRect();
    return r.top >= box.top && r.bottom <= box.bottom;
  });
  // The last field takes focus with the keyboard down, where the keyboard will cover it.
  const notes = sheet(page).getByLabel('Notes for the agent');
  await notes.focus();
  expect(await above(notes)).toBe(false);
  // The keyboard comes up under it: the sheet moves it above.
  await hostCall(page, 'sendEnv', {
    safeArea: { top: 0, right: 0, bottom: 0, left: 0 },
    viewport: { width, height: keyboardTop, offsetTop: 0, offsetLeft: 0, scale: 1 },
    layout: { width, height },
  });
  await expect(notes).toBeFocused();
  await expect.poll(() => above(notes)).toBe(true);
  await expect.poll(() => inView(notes)).toBe(true);
  // So does a field further up, as it takes focus.
  const text = firstMessage(page);
  await text.focus();
  await expect.poll(() => above(text)).toBe(true);
  await expect.poll(() => inView(text)).toBe(true);
  await hostCall(page, 'sendEnv', null);
});
