// A screenshot of each state the sessions list draws, light and dark, for review beside the
// mocks' (docs/design/phone-control/screenshots/<scheme>/<state>.webp) with pairs.mjs. WebKit
// only, at the mocks' size: 390 × 844 points at 2× pixels. Each test drives the app into one
// state and saves screenshots/<light|dark>/<state>.png through `capture`.
//
// - `sessions`: the mock scenario after its subscribe.
// - `reconnect`: the same, then the channel drops, so the loader's strip says "Reconnecting…".
// - `bump`: the last row of the last repo changes status now, as the mock's "A status changes
//   now" does, so it and its repo move to the top. The mock's toast is its demo's alone, not the
//   app's, so this shot has none.

import { readFileSync } from 'node:fs';

import { app, capture, expect, hostCall, openApp, openSessionByName, rowNames, test } from './fixtures.js';

test.skip(({ browserName }) => browserName !== 'webkit', 'the screenshots are taken in WebKit only');
test.use({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });

const MOCK = JSON.parse(readFileSync(new URL('scenarios/mock.json', import.meta.url), 'utf8'));
/** Every row of the mock scenario, by name, sorted as `rowNames` returns them. */
const MOCK_NAMES = MOCK.rows.map((/** @type {any} */ r) => r.name).sort();
/** The mock's last row of its last repo once sorted, as its "A status changes now" picks it. */
const LEGACY_PANE = MOCK.rows.find((/** @type {any} */ r) => r.name === 'Legacy pane');

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

test('bump', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await expect.poll(() => rowNames(page)).toEqual(MOCK_NAMES);
  // As the mock's bump does: the status changes now, and an Unknown one reads Idle after it.
  const sessions = LEGACY_PANE.sessions.map((/** @type {any} */ s) => ({ ...s, status: { chip: 'idle', agoMinutes: 0 } }));
  await hostCall(page, 'emit', 'sessions.changed', { rows: [{ ...LEGACY_PANE, sessions }], removedRowIDs: [] });
  await expect(app(page).locator('.repo').first()).toHaveText('acme-mobile');
  await expect(app(page).locator('.row .n').first()).toHaveText('Legacy pane');
  await capture(page, 'bump', app(page).locator('.list-foot'));
});

// --- the session screen ------------------------------------------------------------------
//
// - `remote`: a remote session (Triage flaky test), with the provider in place of the account.
// - `error`, `rate`, `gone`, `unknown`: a session with each stopped status and its band.
// - `working`: Checkout v2, with its three tabs. It has no "Working…" line or transcript until
//   part 6c; 6c saves its own as `transcript-working`.
// - `codex`: Checkout v2's Codex tab and its note.

/**
 * Opens the app, then the session of the row named `name` (and its tab `tab`), and waits for
 * the header.
 * @param {import('@playwright/test').Page} page
 * @param {any} appHost
 * @param {string} name
 * @param {string} [tab]
 */
async function openSession(page, appHost, name, tab) {
  await openApp(page, appHost);
  await expect.poll(() => rowNames(page)).toEqual(MOCK_NAMES);
  await openSessionByName(page, name, tab);
  await expect(app(page).locator('.s-head .t1')).toContainText(name);
}

test('remote', async ({ page, appHost }) => {
  await openSession(page, appHost, 'Triage flaky test');
  await expect(app(page).locator('.s-head .rb2')).toHaveText('remote');
  await capture(page, 'remote', app(page).locator('.s-head'));
});

for (const [state, name, band] of /** @type {const} */ ([
  ['error', 'Rate limit retry', 'st-err'],
  ['rate', 'Bulk import', 'st-rate'],
  ['gone', 'Schema migration', 'st-gone'],
  ['unknown', 'Legacy pane', 'st-unk'],
])) {
  test(state, async ({ page, appHost }) => {
    await openSession(page, appHost, name);
    await expect(app(page).locator(`.banner.${band}`)).toBeVisible();
    await capture(page, state, app(page).locator('.banner'));
  });
}
