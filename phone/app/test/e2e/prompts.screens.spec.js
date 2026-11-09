// A screenshot of each state the prompt card draws, light and dark, for review beside the mocks'
// (docs/design/phone-control/screenshots/<scheme>/<state>.webp) with pairs.mjs. WebKit only, at
// the mocks' size: 390 × 844 points at 2× pixels. Each test drives the app into one state and
// saves screenshots/<light|dark>/<state>.png through `capture`. Each opens the session the
// mock's state shows (mock 1314-1338), with the transcript read at its bottom.
//
// - `q1`: Login redirect fix's question.
// - `q-other`: the same with "Other answer…" open and "Only if it takes under ten minutes."
//   typed, the textarea then left, as the mock draws it with no focus.
// - `qm`: Settings screen's multi-select question, nothing picked.
// - `q3`: Onboarding copy's first of three questions.
// - `q3-review`: the same after 'Friendly and short', '4 steps' and 'Yes, show a Skip button'.
// - `card-hidden`: Login redirect fix's question hidden to its strip.
// - `perm`: SSE reconnect's permission.
// - `deny-msg`: the same with No tapped and "Run only the unit tests for now." typed, the
//   textarea then left, as the mock draws it with no focus.
// - `answered`: Login redirect fix's question answered 'Yes, add the test', the laptop replying
//   `delivered` with no resolution after it, so the card stays "Answered".
// - `elsewhere`: Login redirect fix's question closed by the laptop (`answeredBy: laptop`). The
//   transcript ends with its receipt, "Answered on the laptop", which the mock's state does not
//   draw until its OK.
//
// A state reached by a change of the card's view is captured once the dock's tap guard lets its
// buttons go, since the mocks draw them enabled.

import { app, capture, expect, hostCall, openApp, openSessionByName, test } from './fixtures.js';

/** @typedef {import('@playwright/test').Page} Page */

test.skip(({ browserName }) => browserName !== 'webkit', 'the screenshots are taken in WebKit only');
test.use({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });

/**
 * Opens the session of the row named `rowName` and waits until its transcript is read at its
 * bottom, with the dock under it.
 * @param {Page} page
 * @param {string} rowName
 */
async function openAtBottom(page, rowName) {
  await openSessionByName(page, rowName);
  const tx = app(page).locator('.tx');
  await expect(tx.locator('[data-tx-row]').first()).toBeVisible();
  await expect(app(page).locator('.dock .card')).toBeVisible();
  await expect.poll(() => tx.evaluate((el) => el.scrollHeight - el.scrollTop - el.clientHeight)).toBeLessThanOrEqual(1);
}

/**
 * The dock's card.
 * @param {Page} page
 */
function card(page) {
  return app(page).locator('.dock .card');
}

test('q1', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openAtBottom(page, 'Login redirect fix');
  await capture(page, 'q1', card(page).getByRole('button', { name: 'Other answer…' }));
});

test('q-other', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openAtBottom(page, 'Login redirect fix');
  await card(page).getByRole('button', { name: 'Other answer…' }).click();
  const text = card(page).getByRole('textbox', { name: 'Type your answer' });
  await text.fill('Only if it takes under ten minutes.');
  await text.blur();
  await expect(card(page).getByRole('button', { name: 'Send answer' })).toBeEnabled();
  await capture(page, 'q-other', card(page).getByRole('button', { name: 'Send answer' }));
});

test('qm', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openAtBottom(page, 'Settings screen');
  await capture(page, 'qm', card(page).getByRole('button', { name: 'Send answer' }));
});

test('q3', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openAtBottom(page, 'Onboarding copy');
  await capture(page, 'q3', card(page).getByRole('button', { name: 'Match the current app' }));
});

test('q3-review', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openAtBottom(page, 'Onboarding copy');
  for (const label of ['Friendly and short', '4 steps', 'Yes, show a Skip button']) {
    await card(page).getByRole('button', { name: label }).click();
  }
  await expect(card(page).getByRole('button', { name: 'Send answers' })).toBeEnabled();
  await capture(page, 'q3-review', card(page).getByRole('button', { name: 'Send answers' }));
});

test('card-hidden', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openAtBottom(page, 'Login redirect fix');
  await card(page).getByRole('button', { name: 'Hide' }).click();
  await capture(page, 'card-hidden', app(page).locator('.dock .card-strip'));
});

test('perm', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openAtBottom(page, 'SSE reconnect');
  await capture(page, 'perm', card(page).getByRole('button', { name: 'No' }));
});

test('deny-msg', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openAtBottom(page, 'SSE reconnect');
  await card(page).getByRole('button', { name: 'No' }).click();
  const text = card(page).getByLabel('Tell Claude what to do instead (optional)');
  await text.fill('Run only the unit tests for now.');
  await text.blur();
  await expect(card(page).getByRole('button', { name: 'Deny' })).toBeEnabled();
  await capture(page, 'deny-msg', card(page).getByRole('button', { name: 'Deny' }));
});

test('answered', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openAtBottom(page, 'Login redirect fix');
  await hostCall(page, 'setReply', 'prompt.answer', { result: { outcome: 'delivered' } });
  await card(page).getByRole('button', { name: 'Yes, add the test' }).click();
  await capture(page, 'answered', app(page).locator('.dock .card.done', { hasText: 'Answered' }));
});

test('elsewhere', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openAtBottom(page, 'Login redirect fix');
  await hostCall(page, 'emit', 'prompt.changed', {
    session: { kind: 'local', terminalID: '00000000-0000-4000-8000-000000000102' },
    prompts: [],
    resolved: [{ promptID: '00000000-0000-4000-8000-0000000000E1', answeredBy: 'laptop' }],
  });
  await expect(app(page).locator('.tx .receipt')).toHaveText('Answered on the laptop');
  await expect(app(page).locator('.dock .card.done').getByRole('button', { name: 'OK' })).toBeEnabled();
  await capture(page, 'elsewhere', app(page).locator('.dock .card.done').getByRole('button', { name: 'OK' }));
});
