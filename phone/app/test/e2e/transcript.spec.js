// The transcript's rows end to end (spec section 7), in WebKit as an iPhone and in Chromium as
// an Android phone: each item kind draws as the mock draws it, a session whose laptop offers no
// transcript shows the laptop's reason, and a row's detail opens through `transcript.detail`:
// a tool's input and result, "Show more", a subagent's items, a detail too large for the phone,
// one the laptop no longer holds, and a collapse while the chunks load.
//
// mock.json has no slash item and no running tool, and its fake laptop leaves out thinking and
// system notes unless "Show details" is on, so those arrive through `emit`, which the fake
// forwards as the laptop would. The "Show details" filter itself is for Task 6c-8's tests.
// mock.json's details are all small, so a test that needs a large one loads a scenario object.

import { readFileSync } from 'node:fs';

import { chunkText, DETAIL_CHUNK_BYTES, TEXT } from './fake-laptop-app.js';
import { app, expect, hostCall, hostRequests, openApp, openSessionByName, test } from './fixtures.js';

/** @typedef {import('@playwright/test').Page} Page */

const MOCK = JSON.parse(readFileSync(new URL('scenarios/mock.json', import.meta.url), 'utf8'));
/** Checkout v2's Claude session. */
const CHECKOUT_REF = { kind: 'local', terminalID: '00000000-0000-4000-8000-000000000103' };
/** Login redirect fix's Claude session. */
const LOGIN_REF = { kind: 'local', terminalID: '00000000-0000-4000-8000-000000000102' };
/** Login redirect fix's Bash call, `npm test -- auth`. */
const BASH_ID = 'login-8';
const TOO_LARGE = 'Too large for the phone. Open on the laptop.';

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

// --- details --------------------------------------------------------------------------------

/**
 * Every `transcript.detail` that reached the laptop, as `[itemID, part, chunk]`.
 * @param {Page} page
 */
async function detailRequests(page) {
  return (await hostRequests(page)).filter((r) => r.method === 'transcript.detail').map((r) => [r.params.itemID, r.params.part, r.params.chunk]);
}

/**
 * The mock scenario with Bash's input or result replaced by `text`.
 * @param {'input' | 'result'} part
 * @param {string} text
 */
function withBashPart(part, text) {
  const scenario = structuredClone(MOCK);
  scenario.details[BASH_ID][part] = text;
  return scenario;
}

/**
 * Opens Login redirect fix and returns its transcript and its Bash row.
 * @param {Page} page
 */
async function openLogin(page) {
  await openSessionByName(page, 'Login redirect fix');
  const tx = app(page).locator('.tx');
  const bash = tx.locator('button.tool', { hasText: 'npm test -- auth' });
  await expect(bash).toHaveAttribute('aria-expanded', 'false');
  return { tx, bash };
}

test('a tool row opens to its input and result', async ({ page, appHost }) => {
  await openApp(page, appHost);
  const { tx, bash } = await openLogin(page);
  await bash.click();
  await expect(bash).toHaveAttribute('aria-expanded', 'true');
  const detail = tx.locator('.detail');
  await expect(detail.locator('.dl')).toHaveText(['Input', 'Result']);
  await expect(detail.locator('pre')).toHaveText([MOCK.details[BASH_ID].input, MOCK.details[BASH_ID].result]);
  await expect(detail.locator('.toobig, .loading')).toHaveCount(0);
  expect(await detailRequests(page)).toEqual([[BASH_ID, 'input', 0], [BASH_ID, 'result', 0]]);

  // A second tap collapses it.
  await bash.click();
  await expect(bash).toHaveAttribute('aria-expanded', 'false');
  await expect(tx.locator('.detail')).toHaveCount(0);
});

test('a subagent row opens to its items, which draw but do not open', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  const tx = app(page).locator('.tx');
  const agent = tx.locator('button.tool', { hasText: 'Explore agent' });
  await agent.click();
  await expect(agent).toHaveAttribute('aria-expanded', 'true');
  const nest = tx.locator('.nest');
  await expect(nest.locator('.tool b')).toHaveText(['Grep', 'Read']);
  await expect(nest.locator('.tool code')).toHaveText(['finishLogin', 'src/auth/callback.ts']);
  await expect(nest.locator('.say')).toHaveText('finishLogin in src/auth/redirect.ts receives next but never uses it.');
  await expect(nest.locator('button')).toHaveCount(0);
  expect(await detailRequests(page)).toEqual([['login-3', 'subagent', 0]]);
});

test('Show more shows the whole message', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  const tx = app(page).locator('.tx');
  const say = tx.locator('.say').last();
  await expect(say).not.toContainText('Both cases have a line');
  await say.locator('.morebtn').click();
  await expect(say).toContainText('Both cases have a line in isLocalPath with a comment that says why.');
  await expect(say.locator('.lnk')).toHaveText('OWASP cheat sheet on open redirects');
  await expect(tx.locator('.morebtn')).toHaveCount(0);
  await expect(tx.locator('.detail')).toHaveCount(0);
  expect(await detailRequests(page)).toEqual([['login-10', 'text', 0]]);
});

test("a detail over 1 MB says 'Too large for the phone. Open on the laptop.'", async ({ page, appHost }) => {
  const line = 'PASS src/auth/redirect.test.ts\n';
  const result = line.repeat(Math.ceil(1_100_000 / line.length));
  await openApp(page, appHost, { scenario: withBashPart('result', result) });
  const { tx, bash } = await openLogin(page);
  await bash.click();
  const detail = tx.locator('.detail');
  await expect(detail.locator('.toobig')).toHaveText(TOO_LARGE);
  await expect(detail.locator('.toobig svg')).toHaveCount(1);
  await expect(detail.locator('.dl')).toHaveText(['Input', 'Result']);
  // The first chunk only: the laptop sends no more, and the phone asks for no more.
  const [first] = chunkText(result, DETAIL_CHUNK_BYTES, 1);
  expect(await detail.locator('pre').nth(1).evaluate((el) => el.textContent)).toBe(first);
  expect(await detailRequests(page)).toEqual([[BASH_ID, 'input', 0], [BASH_ID, 'result', 0]]);
});

test("a detail the laptop no longer holds shows 'That detail is not in the transcript.'", async ({ page, appHost }) => {
  await openApp(page, appHost);
  const { tx, bash } = await openLogin(page);
  await hostCall(page, 'setReply', 'transcript.detail', { error: { code: 'not_found', message: TEXT.detailNotFound } });
  await bash.click();
  const detail = tx.locator('.detail');
  await expect(detail).toHaveText(TEXT.detailNotFound);
  await expect(bash).toHaveAttribute('aria-expanded', 'true');

  // A tap after the failure starts over.
  await hostCall(page, 'setReply', 'transcript.detail', null);
  await bash.click();
  await expect(detail.locator('.dl')).toHaveText(['Input', 'Result']);
  await expect(detail).not.toContainText(TEXT.detailNotFound);
  await expect(bash).toHaveAttribute('aria-expanded', 'true');
});

test('collapsing while the chunks load asks for no more of them', async ({ page, appHost }) => {
  // About 150 KB of input: three chunks.
  const input = 'command: npm test -- auth --verbose '.repeat(4_200);
  await openApp(page, appHost, { scenario: withBashPart('input', input) });
  const { tx, bash } = await openLogin(page);
  await hostCall(page, 'hold', 'transcript.detail');
  await bash.click();
  await expect(tx.locator('.detail .loading')).toHaveText('Loading from the laptop…');
  await expect.poll(() => detailRequests(page)).toEqual([[BASH_ID, 'input', 0]]);
  await bash.click();
  await expect(bash).toHaveAttribute('aria-expanded', 'false');
  await expect(tx.locator('.detail')).toHaveCount(0);

  // The held reply, then an event behind it on the same channel: once the event's row shows,
  // the app has taken the reply, and anything it asked for in return has reached the laptop.
  await hostCall(page, 'release', 'transcript.detail');
  await hostCall(page, 'emit', 'transcript.append', {
    session: LOGIN_REF, items: [{ id: 'x-after', kind: 'assistant', text: 'Here after the dropped chunk.', truncated: false }],
  });
  await expect(tx.locator('.say', { hasText: 'Here after the dropped chunk.' })).toBeVisible();
  expect(await detailRequests(page)).toEqual([[BASH_ID, 'input', 0]]);
  await expect(tx.locator('.detail')).toHaveCount(0);

  // A tap opens it again, from its first chunk, and every chunk joins in order.
  await bash.click();
  const pre = tx.locator('.detail pre').first();
  await expect(pre).toBeVisible();
  expect(await pre.evaluate((el) => el.textContent)).toBe(input);
  expect(await detailRequests(page)).toEqual([
    [BASH_ID, 'input', 0], [BASH_ID, 'input', 0], [BASH_ID, 'input', 1], [BASH_ID, 'input', 2], [BASH_ID, 'result', 0],
  ]);
});

test('a tap while the collapsed request is unanswered sends no second request, and takes its reply', async ({ page, appHost }) => {
  await openApp(page, appHost);
  const { tx, bash } = await openLogin(page);
  await hostCall(page, 'hold', 'transcript.detail');
  await bash.click();
  await expect.poll(() => detailRequests(page)).toEqual([[BASH_ID, 'input', 0]]);
  await bash.click();
  await expect(bash).toHaveAttribute('aria-expanded', 'false');
  await bash.click();
  await expect(bash).toHaveAttribute('aria-expanded', 'true');
  await expect(tx.locator('.detail .loading')).toHaveText('Loading from the laptop…');
  // An event behind the taps on the same channel: once its row shows, every request the taps
  // made has reached the laptop.
  await hostCall(page, 'emit', 'transcript.append', {
    session: LOGIN_REF, items: [{ id: 'x-taps', kind: 'assistant', text: 'Here after the taps.', truncated: false }],
  });
  await expect(tx.locator('.say', { hasText: 'Here after the taps.' })).toBeVisible();
  expect(await detailRequests(page)).toEqual([[BASH_ID, 'input', 0]]);

  await hostCall(page, 'release', 'transcript.detail');
  await expect(tx.locator('.detail pre')).toHaveText([MOCK.details[BASH_ID].input, MOCK.details[BASH_ID].result]);
  expect(await detailRequests(page)).toEqual([[BASH_ID, 'input', 0], [BASH_ID, 'result', 0]]);
});

test('a tool input over 1 MB says so under the input, and its result still loads', async ({ page, appHost }) => {
  const line = 'file_path: src/auth/redirect.ts\n';
  const input = line.repeat(Math.ceil(1_100_000 / line.length));
  await openApp(page, appHost, { scenario: withBashPart('input', input) });
  const { tx, bash } = await openLogin(page);
  await bash.click();
  const detail = tx.locator('.detail');
  await expect(detail.locator('pre')).toHaveCount(2);
  expect(await detail.locator('.dl, pre, .toobig').evaluateAll((els) => els.map((el) => el.className || el.tagName))).toEqual(
    ['dl', 'PRE', 'toobig', 'dl', 'PRE'],
  );
  await expect(detail.locator('.toobig')).toHaveText(TOO_LARGE);
  await expect(detail.locator('pre').nth(1)).toHaveText(MOCK.details[BASH_ID].result);
  expect(await detailRequests(page)).toEqual([[BASH_ID, 'input', 0], [BASH_ID, 'result', 0]]);
});

test('a tool part of many lines draws its first 20,000 and says the rest is too large', async ({ page, appHost }) => {
  // 40,000 empty lines are 80,000 escaped bytes: two chunks, well under 1 MB.
  await openApp(page, appHost, { scenario: withBashPart('result', '\n'.repeat(40_000)) });
  const { tx, bash } = await openLogin(page);
  await bash.click();
  const detail = tx.locator('.detail');
  await expect(detail.locator('.toobig')).toHaveText(TOO_LARGE);
  const shown = await detail.locator('pre').nth(1).evaluate((el) => el.textContent ?? '');
  expect(shown.split('\n')).toHaveLength(20_000);
  expect(await detailRequests(page)).toEqual([[BASH_ID, 'input', 0], [BASH_ID, 'result', 0], [BASH_ID, 'result', 1]]);
});

/**
 * Every DOM node under the transcript's `.nest`, elements and text alike.
 * @param {import('@playwright/test').Locator} tx
 */
function nestNodes(tx) {
  return tx.evaluate((el) => {
    const nest = el.querySelector('.nest');
    if (nest === null) return 0;
    const walker = document.createTreeWalker(nest, NodeFilter.SHOW_ALL);
    let n = 0;
    while (walker.nextNode()) n += 1;
    return n;
  });
}

// One message's nodes (`NEST_NODES`, 50,000) and a few for the rows' own elements.
const NEST_DOM_BOUND = 51_000;

for (const [name, c] of Object.entries({
  'messages of short lines': { kind: 'assistant', text: 'a\n'.repeat(2_048), perChunk: 9, chunks: 19 },
  'a table of stars': { kind: 'user', text: `|a|\n|-|\n${'|*a|\n'.repeat(1_225)}`, perChunk: 8, chunks: 18 },
})) {
  test(`a hostile subagent nest of ${name} draws at most ${NEST_DOM_BOUND} nodes, and says it is too large`, async ({ page, appHost }) => {
    await openApp(page, appHost);
    await openSessionByName(page, 'Login redirect fix');
    await page.evaluate((c) => {
      /** @type {any} */ (window).__host.setReply('transcript.detail', (/** @type {any} */ params) => {
        const items = Array.from({ length: c.perChunk }, (_, i) => ({ id: `n${params.chunk}-${i}`, kind: c.kind, text: c.text, truncated: false }));
        return { result: { itemID: params.itemID, part: params.part, chunk: params.chunk, chunkCount: c.chunks, totalBytes: 0, tooLarge: false, items } };
      });
    }, c);
    const tx = app(page).locator('.tx');
    const agent = tx.locator('button.tool', { hasText: 'Explore agent' });
    await agent.click();
    await expect(tx.locator('.detail .toobig')).toHaveText(TOO_LARGE);
    const nodes = await nestNodes(tx);
    expect(nodes).toBeGreaterThan(1_000);
    expect(nodes).toBeLessThanOrEqual(NEST_DOM_BOUND);
    expect(await detailRequests(page)).toHaveLength(c.chunks);
    // And the row still answers a tap.
    await agent.click();
    await expect(tx.locator('.nest')).toHaveCount(0);
  });
}

test('nested subagents and truncated messages draw, and never open or ask the laptop', async ({ page, appHost }) => {
  const scenario = structuredClone(MOCK);
  scenario.details['login-3'].subagent.push(
    { id: 'login-3-4', kind: 'subagent', truncated: false, agentType: 'Plan', target: 'redirect fix', itemCount: 1 },
    { id: 'login-3-5', kind: 'assistant', text: 'The redirect check needs a test for', truncated: true },
  );
  // The laptop would answer both, so a nested row that asked would draw what it got.
  scenario.details['login-3-4'] = { subagent: [{ id: 'login-3-4-1', kind: 'assistant', text: 'Nested two deep.', truncated: false }] };
  scenario.details['login-3-5'] = { text: 'The redirect check needs a test for each rule it applies.' };
  await openApp(page, appHost, { scenario });
  await openSessionByName(page, 'Login redirect fix');
  const tx = app(page).locator('.tx');
  await tx.locator('button.tool', { hasText: 'Explore agent' }).click();
  const nest = tx.locator('.nest');
  await expect(nest.locator('.tool b')).toHaveText(['Grep', 'Read', 'Plan agent']);
  await expect(nest.locator('.tool .cnt')).toHaveText('1 items');
  await expect(nest.locator('.say')).toHaveText([
    'finishLogin in src/auth/redirect.ts receives next but never uses it.', 'The redirect check needs a test for',
  ]);
  await expect(nest.locator('button, [aria-expanded], .morebtn, .tri, .nest, .detail')).toHaveCount(0);

  await nest.locator('.tool', { hasText: 'Plan agent' }).click();
  await nest.locator('.say').last().click();
  await hostCall(page, 'emit', 'transcript.append', {
    session: LOGIN_REF, items: [{ id: 'x-nested', kind: 'assistant', text: 'Here after the nested taps.', truncated: false }],
  });
  await expect(tx.locator('.say', { hasText: 'Here after the nested taps.' })).toBeVisible();
  await expect(tx.locator('.nest .nest, .nest .detail')).toHaveCount(0);
  await expect(tx).not.toContainText('Nested two deep.');
  await expect(tx).not.toContainText('each rule it applies');
  expect(await detailRequests(page)).toEqual([['login-3', 'subagent', 0]]);
});
