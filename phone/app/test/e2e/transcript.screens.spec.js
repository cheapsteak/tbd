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
//   above the Working line and the composer, which this branch does not draw yet (Task 6c-8 and
//   part 6d), so here the transcript is taller than its rows until all five of the mock's live
//   rows are in. They arrive while the view keeps to the bottom; then the view is scrolled to the
//   top and the stream's next row, its first again, arrives below.

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

/** The mock's live stream (mock 671-677) as items, with the fields the wire has. */
const LIVE = [
  { kind: 'fileEdit', toolName: 'Write', target: 'PaymentStep.tsx', toolStatus: 'ok', added: 121, removed: 0 },
  { kind: 'tool', toolName: 'Read', target: 'src/checkout/SavedCards.tsx', toolStatus: 'ok' },
  { kind: 'assistant', text: 'The payment step now shows the saved-card list first, then the form for a new card.' },
  { kind: 'tool', toolName: 'Bash', target: 'npm test -- checkout', toolStatus: 'ok' },
  { kind: 'fileEdit', toolName: 'Edit', target: 'CheckoutSteps.tsx', toolStatus: 'ok', added: 18, removed: 5 },
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
  expect(await tx.evaluate((el) => el.scrollHeight - el.scrollTop - el.clientHeight)).toBeGreaterThan(30);
  await hostCall(page, 'emit', 'transcript.append', { session: CHECKOUT_REF, items: [live(LIVE.length)] });
  await capture(page, 'pill', app(page).locator('.pill'));
});
