// A screenshot of each state the transcript draws, light and dark, for review beside the mocks'
// (docs/design/phone-control/screenshots/<scheme>/<state>.webp) with pairs.mjs. WebKit only, at
// the mocks' size: 390 × 844 points at 2× pixels. Each test drives the app into one state and
// saves screenshots/<light|dark>/<state>.png through `capture`.
//
// - `tool-open`: Login redirect fix with its Bash call (`npm test -- auth`) open to its input and
//   result, read at the bottom of the transcript, as the mock's "Tool row open" shows it.
// - `agent-open`: Login redirect fix with its Explore agent open to its items, the agent's row
//   scrolled to the top of the transcript, as the mock's "Subagent open" scrolls it there, or as
//   near as the transcript's end allows.
// - `pill`: Checkout v2's Claude tab read from its top while a row arrives below, so the "New
//   messages" pill shows, as the mock's "New messages pill" shows it. The rows that arrive are
//   the mock's live stream (`LIVE`, mock 671-677). The mock's transcript just outgrows its screen
//   above the Working line and the composer, and this branch does not draw the composer (part
//   6d), so here the transcript is taller than its rows until all five of the mock's live rows
//   are in. They arrive while the view keeps to the bottom; then the view is scrolled to the top
//   and the stream's next row, its first again, arrives below.
// - `transcript-working`: Checkout v2's Claude tab at its newest rows, with the "Working…" line
//   under them, as the mock's "Working, with tabs" shows it. Part 6b saves its own `working`, so
//   this one pairs as `transcript-working=working`.
// - `details`: the same tab with "Show details" on, so its thinking shows, as the mock's "Show
//   details on" shows it. The switch is tapped, which opens the transcript again.
//
// The fields a newer laptop sends, each in a state of its own. The mocks have none of these
// states, so each pairs with no mock (`--no-mock`), except where a state names its mock.
// - `tool-failed`: Checkout v2's Claude tab with its failed Bash call (`npm run typecheck`, exit
//   2) open to its input and result, the row scrolled to the top of the transcript, or as near
//   as the transcript's end allows.
// - `slash-output`: Login redirect fix with a slash command (`/model opus`) and its output
//   arrived at the bottom of the transcript.
// - `error-row`: Rate limit retry at its newest rows, ending in the API error's row in the error
//   tone, as the mock's "Error" shows it (`error-row=error`).
// - `rate-row`: Bulk import at its newest rows, ending in the rate limit's row in the rate-limit
//   tone, as the mock's "Rate limited" shows it (`rate-row=rate`).
// - `details-note`: Login redirect fix with "Show details" on, so its hook's system note shows
//   under its label, "Hook".
// - `file-edit`: Docs refresh, whose file edits name each file by its path in the worktree
//   (`README.md`, `docs/manual-setup.md`), as the mock's "Parked" shows them
//   (`file-edit=parked`). Its folders show dimmed, before the file's name.
// - `file-edit-long`: the same, with an edit whose path is too long for its row arrived at the
//   bottom: its folders give way, cut with an ellipsis, and the file's name shows whole.

import { app, capture, expect, hostCall, openApp, openSessionByName, test } from './fixtures.js';

/** @typedef {import('@playwright/test').Locator} Locator */

test.skip(({ browserName }) => browserName !== 'webkit', 'the screenshots are taken in WebKit only');
test.use({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });

/**
 * Scrolls the transcript so `row` sits at its top, or as near as the transcript's end allows, as
 * a reader's swipe would leave it. Playwright has neither a wheel nor a swipe in mobile WebKit,
 * so this sets the scroll element's `scrollTop`, which is the document's scroll position and
 * none of the app's state: the browser fires the same `scroll` event a swipe does.
 * @param {Locator} row
 */
async function scrollToTop(row) {
  await row.evaluate((el) => {
    const scroller = /** @type {HTMLElement} */ (el.closest('.tx'));
    const pad = parseFloat(getComputedStyle(scroller).paddingTop);
    scroller.scrollTop += el.getBoundingClientRect().top - scroller.getBoundingClientRect().top - pad;
  });
}

/**
 * How far `.tx` is above its bottom.
 * @param {Locator} tx
 */
function fromBottom(tx) {
  return tx.evaluate((el) => el.scrollHeight - el.scrollTop - el.clientHeight);
}

test('tool-open', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  const bash = app(page).locator('.tx button.tool', { hasText: 'npm test -- auth' });
  await bash.click();
  await expect(bash).toHaveAttribute('aria-expanded', 'true');
  const result = app(page).locator('.tx .detail pre').nth(1);
  await expect(result).toContainText('Tests: 9 passed, 9 total');
  await scrollToTop(app(page).locator('.tx [data-tx-row]').last());
  await capture(page, 'tool-open', app(page).locator('.tx .morebtn'));
});

test('agent-open', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  const agent = app(page).locator('.tx button.tool', { hasText: 'Explore agent' });
  await agent.click();
  await expect(agent).toHaveAttribute('aria-expanded', 'true');
  await expect(app(page).locator('.tx .nest .say')).toBeVisible();
  await scrollToTop(agent);
  await capture(page, 'agent-open', app(page).locator('.tx .nest'));
});

/** Checkout v2's Claude session. */
const CHECKOUT_REF = { kind: 'local', terminalID: '00000000-0000-4000-8000-000000000103' };
/** Docs refresh's Claude session. */
const DOCS_REF = { kind: 'local', terminalID: '00000000-0000-4000-8000-000000000106' };
/** Login redirect fix's Claude session. */
const LOGIN_REF = { kind: 'local', terminalID: '00000000-0000-4000-8000-000000000102' };

/** The mock's live stream (mock 671-677) as items, with the fields the wire has. */
const LIVE = [
  { kind: 'fileEdit', toolName: 'Write', target: 'PaymentStep.tsx', path: 'src/checkout/PaymentStep.tsx', toolStatus: 'ok', added: 121, removed: 0 },
  { kind: 'tool', toolName: 'Read', target: 'src/checkout/SavedCards.tsx', toolStatus: 'ok' },
  { kind: 'assistant', text: 'The payment step now shows the saved-card list first, then the form for a new card.' },
  { kind: 'tool', toolName: 'Bash', target: 'npm test -- checkout', toolStatus: 'ok' },
  { kind: 'fileEdit', toolName: 'Edit', target: 'CheckoutSteps.tsx', path: 'src/checkout/CheckoutSteps.tsx', toolStatus: 'ok', added: 18, removed: 5 },
];

test('pill', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Checkout v2', 'Claude');
  const tx = app(page).locator('.tx');
  const live = (/** @type {number} */ i) => ({ id: `co-live-${i}`, truncated: false, ...LIVE[i % LIVE.length] });
  await hostCall(page, 'emit', 'transcript.append', { session: CHECKOUT_REF, items: LIVE.map((_, i) => live(i)) });
  await expect(tx.locator('div.tool', { hasText: 'CheckoutSteps.tsx' })).toBeInViewport();
  await tx.evaluate(async (el) => {
    el.scrollTop = 0;
    await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  });
  await expect(tx.locator('.me')).toBeInViewport();
  expect(await fromBottom(tx)).toBeGreaterThan(30);
  await hostCall(page, 'emit', 'transcript.append', { session: CHECKOUT_REF, items: [live(LIVE.length)] });
  await capture(page, 'pill', app(page).locator('.pill'));
});

test('transcript-working', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Checkout v2', 'Claude');
  const tx = app(page).locator('.tx');
  const working = tx.locator('.working');
  await expect(working).toBeInViewport();
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
  await capture(page, 'transcript-working', working);
});

test('details', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Checkout v2', 'Claude');
  const tx = app(page).locator('.tx');
  await expect(tx.locator('.working')).toBeInViewport();
  await app(page).locator('.s-head .tg').click();
  await expect(app(page).getByRole('switch', { name: 'Show details' })).toBeChecked();
  const thinking = tx.locator('.extra', { hasText: 'ShippingMethod is a union of literals.' });
  await expect(thinking).toBeInViewport();
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
  await capture(page, 'details', thinking);
});

test('tool-failed', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Checkout v2', 'Claude');
  const failed = app(page).locator('.tx button.tool:has(.fail)');
  await expect(failed.locator('.fail')).toHaveText('exit 2');
  await failed.click();
  await expect(failed).toHaveAttribute('aria-expanded', 'true');
  const result = app(page).locator('.tx .detail pre').nth(1);
  await expect(result).toContainText('Found 1 error.');
  await scrollToTop(failed);
  await capture(page, 'tool-failed', result);
});

test('slash-output', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  const tx = app(page).locator('.tx');
  await expect(tx.locator('.say').last()).toBeInViewport();
  await hostCall(page, 'emit', 'transcript.append', {
    session: LOGIN_REF,
    items: [{ id: 'login-slash', kind: 'slash', text: '/model opus', output: 'Set model to opus', truncated: false }],
  });
  const output = tx.locator('.slash span');
  await expect(output).toHaveText('Set model to opus');
  await expect(output).toBeInViewport();
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
  await capture(page, 'slash-output', output);
});

for (const [state, name, tone] of /** @type {const} */ ([['error-row', 'Rate limit retry', 'st-err'], ['rate-row', 'Bulk import', 'st-rate']])) {
  test(state, async ({ page, appHost }) => {
    await openApp(page, appHost);
    await openSessionByName(page, name);
    const row = app(page).locator('.tx .errrow');
    await expect(row).toContainClass(tone);
    await expect(row).toBeInViewport();
    await capture(page, state, row);
  });
}

test('details-note', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  const tx = app(page).locator('.tx');
  await expect(tx.locator('.say').last()).toBeInViewport();
  await app(page).locator('.s-head .tg').click();
  await expect(app(page).getByRole('switch', { name: 'Show details' })).toBeChecked();
  const note = tx.locator('.extra', { hasText: 'PostToolUse: eslint src/auth passed.' });
  await expect(note.locator('.dl')).toHaveText('Hook');
  await expect(note).toBeInViewport();
  await capture(page, 'details-note', note);
});

test('file-edit', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Docs refresh');
  const edit = app(page).locator('.tx div.tool', { hasText: 'docs/manual-setup.md' });
  await expect(edit.locator('code')).toHaveText('docs/manual-setup.md');
  await expect(edit).toBeInViewport();
  await capture(page, 'file-edit', edit);
});

test('file-edit-long', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Docs refresh');
  const tx = app(page).locator('.tx');
  await expect(tx.locator('.say').last()).toBeInViewport();
  await hostCall(page, 'emit', 'transcript.append', {
    session: DOCS_REF,
    items: [{
      id: 'docs-long', kind: 'fileEdit', toolName: 'Write', target: 'container-setup.md', toolStatus: 'ok', added: 40, removed: 0,
      path: 'docs/onboarding/dev-environment/containers/macos/container-setup.md', truncated: false,
    }],
  });
  const edit = tx.locator('div.tool', { hasText: 'container-setup.md' });
  await expect(edit.locator('code .base')).toHaveText('container-setup.md');
  await expect(edit).toBeInViewport();
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
  await capture(page, 'file-edit-long', edit);
});
