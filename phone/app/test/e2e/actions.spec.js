// The session header's menus end to end (spec sections 4.4 and 8.3), in WebKit as an iPhone and
// in Chromium as an Android phone. The account menu: its profiles, the ask that a pick opens,
// Restart, "Fork into a new tab" and the new tab that opens only once the list shows it, a fork
// the user moved away from, a refused switch, the profiles loading and failing. The model menu:
// a pick, another name typed, a session that works. Both: one request per gesture, no double tap
// landing on an acting button the user has not seen, and a tap outside or Escape closing them.
//
// Every test that acts checks the exact params the fake laptop got. Checkout v2's Review tab is
// the mock's `s-co-rev`: acme-work, opus, idle. Its Claude tab is working, on Personal and
// sonnet. A scenario variation is built here from mock.json and loaded as an object, never
// written into mock.json.

import { readFileSync } from 'node:fs';

import { app, expect, hostCall, hostRequests, openApp, openSessionByName, test } from './fixtures.js';

/** @typedef {import('@playwright/test').Page} Page */
/** @typedef {import('@playwright/test').Locator} Locator */

const MOCK = JSON.parse(readFileSync(new URL('scenarios/mock.json', import.meta.url), 'utf8'));

/** Checkout v2's tabs. */
const REVIEW_REF = { kind: 'local', terminalID: '00000000-0000-4000-8000-000000000104' };
const CHECKOUT_REF = { kind: 'local', terminalID: '00000000-0000-4000-8000-000000000103' };
/** mock.json's profiles. */
const PERSONAL = '00000000-0000-4000-8000-0000000000F1';
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
