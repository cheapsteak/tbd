// The transcript's rows end to end (spec section 7), in WebKit as an iPhone and in Chromium as
// an Android phone: each item kind draws as the mock draws it, and a session whose laptop
// offers no transcript shows the laptop's reason.
//
// mock.json has no slash item and no running tool, and its fake laptop leaves out thinking and
// system notes unless "Show details" is on, so those arrive through `emit`, which the fake
// forwards as the laptop would. The "Show details" filter itself is for Task 6c-8's tests.

import { readFileSync } from 'node:fs';

import { app, expect, hostCall, openApp, openSessionByName, test } from './fixtures.js';

const MOCK = JSON.parse(readFileSync(new URL('scenarios/mock.json', import.meta.url), 'utf8'));
/** Checkout v2's Claude session. */
const CHECKOUT_REF = { kind: 'local', terminalID: '00000000-0000-4000-8000-000000000103' };

test('each item kind draws as the mock draws it', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Checkout v2', 'Claude');
  const tx = app(page).locator('.tx');

  // user: .me with "You"
  const me = tx.locator('.me').first();
  await expect(me).toContainText('You');
  await expect(me).toContainText('Split the checkout form into three steps');
  // assistant: .say with markdown (the inline code is a <code>)
  await expect(tx.locator('.say').first()).toContainText('The form is one 600-line component.');
  await expect(tx.locator('.say code').first()).toHaveText('CheckoutSteps');
  // tool ok: a collapsed button.tool; Bash gets the check
  const ok = tx.locator('button.tool', { hasText: 'npm run typecheck' }).last();
  await expect(ok).toHaveAttribute('aria-expanded', 'false');
  await expect(ok.locator('b')).toHaveText('Bash');
  await expect(ok.locator('.okm')).toHaveCount(1);
  await expect(tx.locator('button.tool', { hasText: 'src/checkout/CheckoutForm.tsx' }).locator('.okm')).toHaveCount(0);
  // tool error: the failed mark
  await expect(tx.locator('button.tool .fail')).toHaveText('failed');
  // fileEdit: a div.tool with +N and −N
  const edit = tx.locator('div.tool', { hasText: 'CheckoutForm.tsx' });
  await expect(edit.locator('b')).toHaveText('Edit');
  await expect(edit.locator('.plus')).toHaveText('+9');
  await expect(edit.locator('.minus')).toHaveText('−212');
  // peer: "From …" and the text
  const peer = tx.locator('.peer');
  await expect(peer.locator('.who')).toHaveText('From Checkout v2 · Review');
  await expect(peer).toContainText('the payment step must keep the saved-card list');

  // The kinds mock.json lacks, or leaves out without "Show details", arrive as events.
  const item = (/** @type {object} */ x) => ({ truncated: false, ...x });
  await hostCall(page, 'emit', 'transcript.append', {
    session: CHECKOUT_REF,
    items: [
      item({ id: 'x-1', kind: 'slash', text: '/compact' }),
      item({ id: 'x-2', kind: 'tool', toolName: 'Bash', target: 'npm run build', toolStatus: 'running' }),
      item({ id: 'x-3', kind: 'thinking', text: 'Check the lockfile first.' }),
      item({ id: 'x-4', kind: 'systemNote', text: 'PostToolUse: lint passed.' }),
      item({ id: 'x-5', kind: 'subagent', toolName: 'Agent', target: 'Find the step wrapper', toolStatus: 'ok', agentType: 'Explore', itemCount: 14 }),
    ],
  });
  await expect(tx.locator('.slash code')).toHaveText('/compact');
  await expect(tx.locator('.slash span')).toHaveCount(0);
  const running = tx.locator('button.tool', { hasText: 'npm run build' });
  await expect(running.locator('.dots')).toHaveCount(1);
  await expect(running.locator('.okm, .fail')).toHaveCount(0);
  const think = tx.locator('.extra', { hasText: 'Check the lockfile first.' });
  await expect(think.locator('.dl')).toHaveText('Thinking');
  const note = tx.locator('.extra', { hasText: 'PostToolUse: lint passed.' });
  await expect(note.locator('.dl')).toHaveText('System');
  const agent = tx.locator('button.tool', { hasText: 'Explore agent' });
  await expect(agent.locator('b')).toHaveText('Explore agent');
  await expect(agent.locator('code')).toHaveText('Find the step wrapper');
  await expect(agent.locator('.cnt')).toHaveText('14 items');
  await expect(agent).toHaveAttribute('aria-expanded', 'false');

  // Every row has a distinct key.
  const keys = await tx.locator('[data-tx-row]').evaluateAll((els) => els.map((el) => el.getAttribute('data-key')));
  expect(keys.length).toBeGreaterThan(15);
  expect(new Set(keys).size).toBe(keys.length);
});

test('a truncated assistant message offers Show more', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  const more = app(page).locator('.say .morebtn');
  await expect(more).toHaveText('Show more');
  await expect(app(page).locator('.say .morebtn')).toHaveCount(1);
});

test('a session with no transcript shows the laptop’s reason', async ({ page, appHost }) => {
  const reason = 'This session has no transcript to show.';
  const scenario = structuredClone(MOCK);
  const row = scenario.rows.find((/** @type {any} */ r) => r.name === 'Docs refresh');
  row.sessions[0].capabilities.transcript = { available: false, reason };
  await openApp(page, appHost, { scenario });
  await openSessionByName(page, 'Docs refresh');
  const note = app(page).locator('.codex-note');
  await expect(note.locator('b')).toHaveText(reason);
  await expect(app(page).locator('.tx .me, .tx .say, .tx .tool')).toHaveCount(0);
});
