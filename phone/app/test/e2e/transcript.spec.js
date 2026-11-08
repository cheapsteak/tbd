// The transcript's rows end to end (spec section 7), in WebKit as an iPhone and in Chromium as
// an Android phone: each item kind draws as the mock draws it, a session whose laptop offers no
// transcript shows the laptop's reason, and a row's detail opens through `transcript.detail`:
// a tool's input and result, "Show more", a subagent's items, a detail too large for the phone,
// one the laptop no longer holds, and a collapse while the chunks load. Then the list: it opens
// at the newest rows and draws only the rows near the screen, new rows keep a view at the bottom
// there, and below a view scrolled up they show the "New messages" pill instead. Then the older
// pages of a 2,000-item transcript: one at a time, each holding the reader's place as it goes
// in, a failed one shown as nothing, a reset back to the newest rows, and the scroll back ending
// at the first item. Then the "Working…" line and its elapsed time, and the "Show details"
// switch, which opens the transcript again with thinking and system notes. Last, links: each
// leaves only through the loader's `openLink`, with the URL its item holds now, a link in a
// subagent's nest included, and links the app does not offer, and raw HTML, stay text.
//
// mock.json has no slash item and no running tool, and its fake laptop leaves out thinking and
// system notes unless "Show details" is on, so the first test has those arrive through `emit`,
// which the fake forwards as the laptop would. The Show details tests turn the switch on instead.
// mock.json's details are all small, so a test that needs a large one loads a scenario object.
//
// Playwright has neither a wheel nor a swipe in mobile WebKit, so a test scrolls the transcript
// by setting `.tx`'s `scrollTop` (`scrollTx`), which is the document's scroll position and none
// of the app's state: the browser fires the same `scroll` event a swipe does.

import { readFileSync } from 'node:fs';

import { chunkText, DETAIL_CHUNK_BYTES, FIRST_PAGE_MESSAGES, OLDER_PAGE_MESSAGES, startBefore, TEXT } from './fake-laptop-app.js';
import { app, expect, frameURL, hostCall, hostLinks, hostRequests, openApp, openSessionByName, test } from './fixtures.js';

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

test('a running tool opened to its input shows its result too once it stops running', async ({ page, appHost }) => {
  const scenario = structuredClone(MOCK);
  const items = scenario.transcripts['local:' + LOGIN_REF.terminalID];
  const bashItem = items.find((/** @type {{ id: string }} */ it) => it.id === BASH_ID);
  bashItem.toolStatus = 'running';
  await openApp(page, appHost, { scenario });
  const { tx, bash } = await openLogin(page);
  await expect(bash.locator('.dots')).toHaveCount(1);
  await bash.click();
  const detail = tx.locator('.detail');
  await expect(detail.locator('.dl')).toHaveText(['Input']);
  await expect(detail.locator('pre')).toHaveText([MOCK.details[BASH_ID].input]);
  expect(await detailRequests(page)).toEqual([[BASH_ID, 'input', 0]]);

  await hostCall(page, 'emit', 'transcript.update', { session: LOGIN_REF, items: [{ ...bashItem, toolStatus: 'ok' }] });
  await expect(detail.locator('.dl')).toHaveText(['Input', 'Result']);
  await expect(detail.locator('pre')).toHaveText([MOCK.details[BASH_ID].input, MOCK.details[BASH_ID].result]);
  await expect(bash).toHaveAttribute('aria-expanded', 'true');
  expect(await detailRequests(page)).toEqual([[BASH_ID, 'input', 0], [BASH_ID, 'result', 0]]);
});

test('a running tool’s Input stays on screen while its result loads', async ({ page, appHost }) => {
  const scenario = structuredClone(MOCK);
  const items = scenario.transcripts['local:' + LOGIN_REF.terminalID];
  const bashItem = items.find((/** @type {{ id: string }} */ it) => it.id === BASH_ID);
  bashItem.toolStatus = 'running';
  await openApp(page, appHost, { scenario });
  const { tx, bash } = await openLogin(page);
  await bash.click();
  const detail = tx.locator('.detail');
  await expect(detail.locator('pre')).toHaveText([MOCK.details[BASH_ID].input]);

  await hostCall(page, 'hold', 'transcript.detail');
  await hostCall(page, 'emit', 'transcript.update', { session: LOGIN_REF, items: [{ ...bashItem, toolStatus: 'ok' }] });
  await expect(detail.locator('.loading')).toHaveText('Loading from the laptop…');
  expect(await detail.locator('.dl, pre, .loading').evaluateAll((els) => els.map((el) => el.className || el.tagName))).toEqual(
    ['dl', 'PRE', 'loading'],
  );
  await expect(detail.locator('.dl')).toHaveText(['Input']);
  await expect(detail.locator('pre')).toHaveText([MOCK.details[BASH_ID].input]);

  await hostCall(page, 'release', 'transcript.detail');
  await expect(detail.locator('.dl')).toHaveText(['Input', 'Result']);
  await expect(detail.locator('pre')).toHaveText([MOCK.details[BASH_ID].input, MOCK.details[BASH_ID].result]);
  await expect(detail.locator('.loading')).toHaveCount(0);
});

test('a message shown in full through Show more shows its new cut text and Show more again once its text changes', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  const tx = app(page).locator('.tx');
  const say = tx.locator('.say').last();
  await say.locator('.morebtn').click();
  await expect(say).toContainText('Both cases have a line in isLocalPath with a comment that says why.');
  await expect(tx.locator('.morebtn')).toHaveCount(0);

  const cut = 'Fixed, and checked once more. Here is what changed:';
  await hostCall(page, 'emit', 'transcript.update', {
    session: LOGIN_REF, items: [{ id: 'login-10', kind: 'assistant', text: cut, truncated: true }],
  });
  await expect(say).toContainText(cut);
  await expect(say).not.toContainText('Both cases have a line');
  await expect(say.locator('.morebtn')).toHaveText('Show more');
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

  // A tap on the failed detail collapses it, and asks for nothing.
  await hostCall(page, 'setReply', 'transcript.detail', null);
  await bash.click();
  await expect(bash).toHaveAttribute('aria-expanded', 'false');
  await expect(detail).toHaveCount(0);
  expect(await detailRequests(page)).toEqual([[BASH_ID, 'input', 0]]);

  // The next tap starts over.
  await bash.click();
  await expect(detail.locator('.dl')).toHaveText(['Input', 'Result']);
  await expect(detail).not.toContainText(TEXT.detailNotFound);
  await expect(bash).toHaveAttribute('aria-expanded', 'true');
});

test('a failed Show more brings its button back, and a tap on it starts over', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  const tx = app(page).locator('.tx');
  const say = tx.locator('.say').last();
  await hostCall(page, 'setReply', 'transcript.detail', { error: { code: 'not_found', message: TEXT.detailNotFound } });
  await say.locator('.morebtn').click();
  await expect(tx.locator('.detail')).toHaveText(TEXT.detailNotFound);
  await expect(say.locator('.morebtn')).toHaveText('Show more');

  await hostCall(page, 'setReply', 'transcript.detail', null);
  await say.locator('.morebtn').click();
  await expect(say).toContainText('Both cases have a line in isLocalPath with a comment that says why.');
  await expect(tx.locator('.morebtn')).toHaveCount(0);
  await expect(tx.locator('.detail')).toHaveCount(0);
  expect(await detailRequests(page)).toEqual([['login-10', 'text', 0], ['login-10', 'text', 0]]);
});

test('Show more stays while its text loads, and a tap on it cancels the load', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  const tx = app(page).locator('.tx');
  const say = tx.locator('.say', { hasText: 'Fixed. Here is what changed:' });
  const more = say.locator('.morebtn');
  await hostCall(page, 'hold', 'transcript.detail');
  await more.click();
  await expect(tx.locator('.detail .loading')).toHaveText('Loading from the laptop…');
  await expect(more).toHaveText('Show more');
  await expect(more).toHaveAttribute('aria-busy', 'true');
  await expect.poll(() => detailRequests(page)).toEqual([['login-10', 'text', 0]]);

  // A tap cancels: the loading line goes, and the row keeps its cut text and Show more.
  await more.click();
  await expect(tx.locator('.detail')).toHaveCount(0);
  await expect(more).toHaveText('Show more');
  await expect(more).not.toHaveAttribute('aria-busy');

  // The held reply, then an event behind it on the same channel: once the event's row shows,
  // the app has taken the reply, and it changed nothing.
  await hostCall(page, 'release', 'transcript.detail');
  await hostCall(page, 'emit', 'transcript.append', {
    session: LOGIN_REF, items: [{ id: 'x-cancel', kind: 'assistant', text: 'Here after the cancelled text.', truncated: false }],
  });
  await expect(tx.locator('.say', { hasText: 'Here after the cancelled text.' })).toBeVisible();
  await expect(say).not.toContainText('Both cases have a line');
  await expect(more).toHaveText('Show more');
  await expect(tx.locator('.detail')).toHaveCount(0);
  expect(await detailRequests(page)).toEqual([['login-10', 'text', 0]]);

  // The next tap loads the whole text.
  await more.click();
  await expect(say).toContainText('Both cases have a line in isLocalPath with a comment that says why.');
  await expect(more).toHaveCount(0);
  expect(await detailRequests(page)).toEqual([['login-10', 'text', 0], ['login-10', 'text', 0]]);
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

// --- the list: the bottom it keeps to, and the pill -------------------------------------------

/** @typedef {import('@playwright/test').Locator} Locator */
/** @typedef {import('./server.js').AppHost} AppHost */

/** Checkout v2's Claude transcript in a scenario. */
const CHECKOUT_KEY = 'local:00000000-0000-4000-8000-000000000103';
/** The rows Checkout v2's Claude tab shows from mock.json: its 14 items but the thinking. */
const CHECKOUT_ROWS = 13;
/** The Bash rows `tallCheckout` adds. */
const TALL_ROWS = 40;

/**
 * `n` finished Bash rows, `npm run <name>-0` on, for a scenario or an `emit`.
 * @param {string} name
 * @param {number} n
 */
function bashRows(name, n) {
  return Array.from({ length: n }, (_, i) => ({
    id: `${name}-${i}`, kind: 'tool', truncated: false, toolName: 'Bash', target: `npm run ${name}-${i}`, toolStatus: 'ok',
  }));
}

/**
 * mock.json with Checkout v2's Claude transcript several screens tall. It still holds three
 * messages, so its first page reaches the start and no older page is asked for.
 */
function tallCheckout() {
  const scenario = structuredClone(MOCK);
  scenario.transcripts[CHECKOUT_KEY].push(...bashRows('step', TALL_ROWS));
  return scenario;
}

/**
 * `.tx`'s scroll metrics.
 * @param {Locator} tx
 */
function metricsOf(tx) {
  return tx.evaluate((el) => ({ scrollTop: el.scrollTop, scrollHeight: el.scrollHeight, clientHeight: el.clientHeight }));
}

/**
 * How far `.tx` is above its bottom.
 * @param {Locator} tx
 */
async function fromBottom(tx) {
  const m = await metricsOf(tx);
  return m.scrollHeight - m.scrollTop - m.clientHeight;
}

/**
 * Scrolls `.tx` to `top`, or to its bottom, as a swipe would leave it (this file's header), and
 * waits two frames, by which time the browser has fired the scroll event and the app has taken
 * it.
 * @param {Locator} tx
 * @param {number | 'bottom'} top
 */
function scrollTx(tx, top) {
  return tx.evaluate(async (el, to) => {
    el.scrollTop = to === 'bottom' ? el.scrollHeight : to;
    await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  }, top);
}

/**
 * Drags `.tx` up slowly from where it is, `step` px a frame for `n` frames, as a slow finger
 * moves it, then waits two frames (this file's header). The finger's place is kept unrounded, so
 * the browser rounds a fractional step as it would round a finger's, and it moves with the view
 * when the app moves it, as when a page goes in above.
 * @param {Locator} tx
 * @param {number} step
 * @param {number} n
 */
function slowDrag(tx, step, n) {
  return tx.evaluate(async (el, { step, n }) => {
    const frame = () => new Promise((resolve) => requestAnimationFrame(resolve));
    let finger = el.scrollTop;
    for (let i = 0; i < n; i++) {
      finger -= step;
      el.scrollTop = finger;
      const wrote = el.scrollTop;
      await frame();
      finger += el.scrollTop - wrote;
    }
    await frame();
    await frame();
  }, { step, n });
}

/**
 * The top of `row` on the screen.
 * @param {Locator} row
 */
async function topOf(row) {
  const box = await row.boundingBox();
  if (box === null) throw new Error('the row is not drawn');
  return box.y;
}

/**
 * The widest seam, gap or overlap, between one drawn row's bottom and the next row's top. Each
 * row is placed at the end of the one before it, so it stays under a pixel once every row is
 * measured.
 * @param {Locator} tx
 */
function widestSeam(tx) {
  return tx.locator('[data-tx-row]').evaluateAll((els) => {
    const boxes = els.map((el) => el.getBoundingClientRect()).sort((a, b) => a.top - b.top);
    let widest = 0;
    for (let i = 1; i < boxes.length; i++) widest = Math.max(widest, Math.abs(boxes[i].top - boxes[i - 1].bottom));
    return widest;
  });
}

/**
 * Opens Checkout v2's Claude tab from `tallCheckout`, and returns its transcript once its
 * newest row shows at the bottom.
 * @param {Page} page
 * @param {AppHost} appHost
 */
async function openTall(page, appHost) {
  await openApp(page, appHost, { scenario: tallCheckout() });
  await openSessionByName(page, 'Checkout v2', 'Claude');
  const tx = app(page).locator('.tx');
  await expect(tx.locator('button.tool', { hasText: `npm run step-${TALL_ROWS - 1}` })).toBeInViewport();
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
  const m = await metricsOf(tx);
  expect(m.scrollHeight).toBeGreaterThan(2 * m.clientHeight);
  return tx;
}

/**
 * The laptop appends `items` to Checkout v2's Claude transcript.
 * @param {Page} page
 * @param {object[]} items
 */
function appendToCheckout(page, items) {
  return hostCall(page, 'emit', 'transcript.append', { session: CHECKOUT_REF, items });
}

/**
 * Scrolls the tall transcript to its top, where its first message shows, and has a row arrive
 * below. Returns the first message and the pill.
 * @param {Page} page
 * @param {Locator} tx
 */
async function pillAfterScrollingUp(page, tx) {
  await scrollTx(tx, 0);
  const first = tx.locator('.me', { hasText: 'Split the checkout form' });
  await expect(first).toBeInViewport();
  const before = await topOf(first);
  await appendToCheckout(page, bashRows('new', 1));
  const pill = app(page).locator('.pill');
  await expect(pill).toBeVisible();
  expect(await topOf(first)).toBe(before);
  expect((await metricsOf(tx)).scrollTop).toBe(0);
  return { first, pill };
}

test('a transcript opens at its newest row, and draws only the rows near the screen', async ({ page, appHost }) => {
  const tx = await openTall(page, appHost);
  expect(await tx.locator('[data-tx-row]').count()).toBeLessThan(CHECKOUT_ROWS + TALL_ROWS);
  await expect(tx.locator('.me')).toHaveCount(0);
  expect(await widestSeam(tx)).toBeLessThanOrEqual(1);
  await expect(app(page).locator('.pill')).toHaveCount(0);
});

test('new items keep the view at the bottom', async ({ page, appHost }) => {
  const tx = await openTall(page, appHost);
  await appendToCheckout(page, bashRows('more', 3));
  await expect(tx.locator('button.tool', { hasText: 'npm run more-2' })).toBeInViewport();
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);

  // A message taller than the rows the virtualizer guessed for it.
  const text = Array.from({ length: 12 }, (_, i) => `Step ${i + 1} moves one part of the form into its own file.`).join('\n\n');
  await appendToCheckout(page, [{ id: 'long-1', kind: 'assistant', text, truncated: false }]);
  await expect(tx.locator('.say', { hasText: 'Step 12 moves' })).toBeInViewport();
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
  expect(await widestSeam(tx)).toBeLessThanOrEqual(1);
  await expect(app(page).locator('.pill')).toHaveCount(0);
});

test('within 30 px of the bottom new items keep the view there, and further up they show the pill', async ({ page, appHost }) => {
  const tx = await openTall(page, appHost);
  let m = await metricsOf(tx);
  await scrollTx(tx, m.scrollHeight - m.clientHeight - 20);
  await appendToCheckout(page, bashRows('near', 1));
  await expect(tx.locator('button.tool', { hasText: 'npm run near-0' })).toBeInViewport();
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
  await expect(app(page).locator('.pill')).toHaveCount(0);

  m = await metricsOf(tx);
  await scrollTx(tx, m.scrollHeight - m.clientHeight - 80);
  const shown = tx.locator('button.tool', { hasText: `npm run step-${TALL_ROWS - 3}` });
  await expect(shown).toBeInViewport();
  const before = await topOf(shown);
  await appendToCheckout(page, bashRows('far', 1));
  await expect(app(page).locator('.pill')).toBeVisible();
  expect(await topOf(shown)).toBe(before);
  expect(await fromBottom(tx)).toBeGreaterThan(30);
});

test('scrolled up, an append shows the pill and does not move the view', async ({ page, appHost }) => {
  const tx = await openTall(page, appHost);
  const { first, pill } = await pillAfterScrollingUp(page, tx);
  await expect(pill).toHaveText('New messages');
  await expect(pill.locator('svg')).toHaveCount(1);
  // More rows below leave it in place too.
  const before = await topOf(first);
  await appendToCheckout(page, bashRows('also', 2));
  await expect.poll(async () => (await metricsOf(tx)).scrollHeight).toBeGreaterThan(0);
  expect(await topOf(first)).toBe(before);
  await expect(pill).toBeVisible();
});

test('the pill scrolls to the newest item and goes away', async ({ page, appHost }) => {
  const tx = await openTall(page, appHost);
  const { pill } = await pillAfterScrollingUp(page, tx);
  await pill.click();
  await expect(pill).toHaveCount(0);
  await expect(tx.locator('button.tool', { hasText: 'npm run new-0' })).toBeInViewport();
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
  expect(await widestSeam(tx)).toBeLessThanOrEqual(1);

  // From then on the view keeps to the bottom.
  await appendToCheckout(page, bashRows('after', 1));
  await expect(tx.locator('button.tool', { hasText: 'npm run after-0' })).toBeInViewport();
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
  await expect(pill).toHaveCount(0);
});

test('scrolling to the bottom takes the pill away', async ({ page, appHost }) => {
  const tx = await openTall(page, appHost);
  const { pill } = await pillAfterScrollingUp(page, tx);
  await scrollTx(tx, 'bottom');
  await expect(pill).toHaveCount(0);
  await appendToCheckout(page, bashRows('after', 1));
  await expect(tx.locator('button.tool', { hasText: 'npm run after-0' })).toBeInViewport();
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
  await expect(pill).toHaveCount(0);
});

// A finger that moves a pixel or less a frame, as a slow drag does, and in fractional steps on a
// 3x screen, moves the view all the same: once it is more than 30 px from the bottom, new rows
// show the pill and leave it where the reader put it.
for (const [what, step, n] of /** @type {const} */ ([['a pixel', 1, 60], ['a third of a pixel', 1 / 3, 180]])) {
  test(`a slow drag up of ${what} a frame stops keeping to the bottom`, async ({ page, appHost }) => {
    const tx = await openTall(page, appHost);
    await slowDrag(tx, step, n);
    expect(await fromBottom(tx)).toBeGreaterThan(30);
    const { row, top: before } = await firstWholeRow(tx);
    await appendToCheckout(page, bashRows('slow', 1));
    await expect(app(page).locator('.pill')).toBeVisible();
    expect(await topOf(row)).toBe(before);
    expect(await fromBottom(tx)).toBeGreaterThan(30);
  });
}

/**
 * The transcript's live region, and the lines it says now.
 * @param {Page} page
 */
function liveRegion(page) {
  const region = app(page).locator('.tx-wrap > [aria-live="polite"]');
  return { region, lines: region.locator(':scope > div > div') };
}

test('the live region says the rows that arrive at the bottom in their own words, a few at most', async ({ page, appHost }) => {
  const tx = await openTall(page, appHost);
  const { region, lines } = liveRegion(page);
  // The list is no live region, and the rows of the open are not said.
  expect(await tx.getAttribute('aria-live')).toBeNull();
  expect(await app(page).locator('[aria-live]').count()).toBe(1);
  await expect(region).toHaveText('');
  const box = await region.boundingBox();
  expect(box === null || (box.width <= 1 && box.height <= 1)).toBe(true);

  // Rows the virtualizer draws as the reader scrolls are not said.
  await scrollTx(tx, 0);
  await frames(tx, 3);
  await scrollTx(tx, 'bottom');
  await frames(tx, 3);
  await expect(region).toHaveText('');

  const item = (/** @type {object} */ x) => ({ truncated: false, ...x });
  await appendToCheckout(page, [
    item({ id: 'say-1', kind: 'user', text: 'Run the *auth* tests' }),
    item({ id: 'say-2', kind: 'tool', toolName: 'Bash', target: 'npm test -- auth', toolStatus: 'running' }),
    item({ id: 'say-3', kind: 'thinking', text: 'Check the lockfile first.' }),
    item({ id: 'say-4', kind: 'assistant', text: 'Both **pass**.\n\n- `isLocalPath` refuses [other sites](https://acme.example).' }),
  ]);
  await expect(lines).toHaveText(['Run the auth tests', 'Bash npm test -- auth', 'Both pass. isLocalPath refuses other sites.']);

  // A burst says its last three rows, each cut to 500 characters.
  const long = 'word '.repeat(400);
  await appendToCheckout(page, Array.from({ length: 10 }, (_, i) => item({ id: `burst-${i}`, kind: 'assistant', text: `${i} ${long}` })));
  await expect(lines).toHaveCount(3);
  const said = await lines.allTextContents();
  expect(said.map((l) => l.slice(0, 2))).toEqual(['7 ', '8 ', '9 ']);
  expect(said.every((l) => l.length === 500)).toBe(true);

  // An update in place is not an arrival; a page in place of the rows empties the region.
  await hostCall(page, 'emit', 'transcript.update', { session: CHECKOUT_REF, items: [item({ id: 'burst-9', kind: 'assistant', text: 'Changed.' })] });
  await expect(tx.locator('.say', { hasText: 'Changed.' })).toHaveCount(1);
  expect(await lines.allTextContents()).toEqual(said);
  await hostCall(page, 'emit', 'transcript.reset', {
    session: CHECKOUT_REF, reason: 'rollover', page: { items: bashRows('reset', 5), reachedStart: true, omittedItems: 0 },
  });
  await expect(tx.locator('button.tool', { hasText: 'npm run reset-4' })).toBeVisible();
  await expect(region).toHaveText('');
});

test('the rows of an older page are not said', async ({ page, appHost }) => {
  await openApp(page, appHost, { scenario: checkoutWith(shortItems()) });
  await openSessionByName(page, 'Checkout v2', 'Claude');
  const tx = app(page).locator('.tx');
  const { region } = liveRegion(page);
  await expect(tx.locator('.say', { hasText: 'Short message 199.' })).toBeInViewport();
  await expect.poll(async () => (await pageCursors(page)).length).toBe(1);
  await expect.poll(async () => { const m = await metricsOf(tx); return m.scrollHeight > m.clientHeight; }).toBe(true);
  await frames(tx, 3);
  await expect(region).toHaveText('');
});

test('a page in place of the rows starts at the bottom and takes the pill away', async ({ page, appHost }) => {
  const tx = await openTall(page, appHost);
  const { pill } = await pillAfterScrollingUp(page, tx);
  await hostCall(page, 'emit', 'transcript.reset', {
    session: CHECKOUT_REF, reason: 'rollover', page: { items: bashRows('reset', 40), reachedStart: true, omittedItems: 0 },
  });
  await expect(tx.locator('button.tool', { hasText: 'npm run reset-39' })).toBeInViewport();
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
  await expect(pill).toHaveCount(0);
  await expect(tx.locator('.me')).toHaveCount(0);
});

test('a row that grows moves the rows below it, and keeps a view at the bottom there', async ({ page, appHost }) => {
  // Short enough that Login redirect fix's rows outgrow the transcript on either phone.
  await page.setViewportSize({ width: 390, height: 600 });
  await openApp(page, appHost);
  const { tx, bash } = await openLogin(page);
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
  await bash.click();
  await expect(tx.locator('.detail pre')).toHaveText([MOCK.details[BASH_ID].input, MOCK.details[BASH_ID].result]);
  await expect.poll(() => widestSeam(tx)).toBeLessThanOrEqual(1);
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);

  const say = tx.locator('.say').last();
  await say.locator('.morebtn').click();
  await expect(say).toContainText('Both cases have a line in isLocalPath with a comment that says why.');
  const m = await metricsOf(tx);
  expect(m.scrollHeight).toBeGreaterThan(m.clientHeight + 100);
  await expect.poll(() => widestSeam(tx)).toBeLessThanOrEqual(1);
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
});

test('a shorter or turned screen keeps a view at the bottom there', async ({ page, appHost }) => {
  const tx = await openTall(page, appHost);
  const size = page.viewportSize();
  if (size === null) throw new Error('the page has no viewport size');
  const tall = (await metricsOf(tx)).clientHeight;
  // As the keyboard opening takes the bottom of the screen.
  await page.setViewportSize({ width: size.width, height: size.height - 250 });
  await expect.poll(async () => (await metricsOf(tx)).clientHeight).toBeLessThan(tall - 200);
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
  // Turned.
  await page.setViewportSize({ width: size.height, height: size.width });
  await expect.poll(async () => (await metricsOf(tx)).clientHeight).toBeLessThan(size.width);
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
  await expect(tx.locator('button.tool', { hasText: `npm run step-${TALL_ROWS - 1}` })).toBeInViewport();
});

// --- older pages: one at a time, holding the reader's place -----------------------------------

/** The items of the long transcript. */
const LONG_ITEMS = 2_000;
/** The turn of the long transcript's newest item, which is that turn's answer. */
const LAST_TURN = Math.floor((LONG_ITEMS - 1) / 3);
/** Spec section 7's caps: a first page of 16 KB, and an older page that fits one frame. */
const FIRST_PAGE_CAP = 16_384;
const OLDER_PAGE_CAP = 61_440;
/** What 4b says when a remote session's earlier history failed to load (`remoteRefusedReason`). */
const REMOTE_REFUSED = 'The remote provider refused this. Check the laptop.';

/**
 * `LONG_ITEMS` items alternating user, assistant and tool, the assistant's text one to six lines
 * long, the oldest first.
 */
function longItems() {
  return Array.from({ length: LONG_ITEMS }, (_, i) => {
    const turn = Math.floor(i / 3);
    const id = `long-${i}`;
    if (i % 3 === 0) return { id, kind: 'user', text: `Question ${turn}: what does step ${turn} change?`, truncated: false };
    if (i % 3 === 1) {
      const lines = Array.from({ length: 1 + (turn % 6) }, (_, k) => `Answer ${turn}, line ${k + 1}: step ${turn} moves part ${k + 1} of the form.`);
      return { id, kind: 'assistant', text: lines.join('\n\n'), truncated: false };
    }
    return { id, kind: 'tool', toolName: 'Bash', target: `npm test -- step-${turn}`, toolStatus: 'ok', truncated: false };
  });
}

/**
 * How many older pages the fake laptop serves for `items` before the start, the way 4b's daemon
 * pages them: the first page back to the 4th-last message, each older page back 20 messages more.
 * Throws when a page would be over spec section 7's caps, which the daemon would cut and the
 * fake does not: then the fake would not page like the daemon.
 * @param {any[]} items
 */
function olderPages(items) {
  const bytes = (/** @type {any[]} */ shown) => new TextEncoder().encode(JSON.stringify({ items: shown, cursor: '0', reachedStart: false, omittedItems: 0 })).length;
  let start = startBefore(items, items.length, FIRST_PAGE_MESSAGES);
  if (bytes(items.slice(start)) > FIRST_PAGE_CAP) throw new Error('the first page is over 16 KB');
  let pages = 0;
  while (start > 0) {
    const end = start;
    start = startBefore(items, end, OLDER_PAGE_MESSAGES);
    if (bytes(items.slice(start, end)) > OLDER_PAGE_CAP) throw new Error(`the page before ${end} is over 61,440 bytes`);
    pages += 1;
  }
  return pages;
}

const LONG = longItems();
/** The older pages between the long transcript's first page and its start. */
const LONG_PAGES = olderPages(LONG);

/**
 * mock.json with Checkout v2's Claude transcript replaced by `items`.
 * @param {any[]} items
 */
function checkoutWith(items) {
  const scenario = structuredClone(MOCK);
  scenario.transcripts[CHECKOUT_KEY] = items;
  return scenario;
}

/**
 * The cursor of every `transcript.page` that reached the laptop, in order.
 * @param {Page} page
 */
async function pageCursors(page) {
  return (await hostRequests(page)).filter((r) => r.method === 'transcript.page').map((r) => r.params.cursor);
}

/**
 * The key of the list's first row while the list draws it, or null. A page that goes in above
 * the rows puts another row first.
 * @param {Locator} tx
 * @returns {Promise<string | null>}
 */
function firstRowKey(tx) {
  return tx.evaluate((el) => el.querySelector('[data-tx-row][data-index="0"]')?.getAttribute('data-key') ?? null);
}

/**
 * Waits until a page went in above the rows: the first row is another, or out of sight.
 * @param {Locator} tx
 * @param {string | null} before the first row's key before the page
 */
async function pageWentIn(tx, before) {
  if (before === null) throw new Error('the list does not draw its first row');
  await expect.poll(() => firstRowKey(tx)).not.toBe(before);
}

/**
 * Waits `n` animation frames in the app.
 * @param {Locator} tx
 * @param {number} n
 */
function frames(tx, n) {
  return tx.evaluate((_, count) => new Promise((resolve) => {
    let left = count;
    const step = () => {
      left -= 1;
      if (left <= 0) resolve(undefined);
      else requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }), n);
}

/**
 * The first row the view shows whole, by its row key, and its top on the screen.
 * @param {Locator} tx
 */
async function firstWholeRow(tx) {
  const found = await tx.evaluate((el) => {
    const view = el.getBoundingClientRect();
    const rows = [...el.querySelectorAll('[data-tx-row]')].map((row) => ({ key: row.getAttribute('data-key'), box: row.getBoundingClientRect() }));
    rows.sort((a, b) => a.box.top - b.box.top);
    return rows.find((r) => r.box.top >= view.top && r.box.bottom <= view.top + el.clientHeight)?.key ?? null;
  });
  if (found === null) throw new Error('the view shows no row whole');
  const row = tx.locator(`[data-tx-row][data-key="${found}"]`);
  return { key: found, row, top: await topOf(row) };
}

/**
 * Opens the long transcript and returns it once its first page shows at the bottom and nothing
 * is on its way. A first page that fits the screen asks for the page above at once; that page is
 * held until the first page shows, then let through and waited for.
 * @param {Page} page
 * @param {AppHost} appHost
 */
async function openLong(page, appHost) {
  await openApp(page, appHost, { scenario: checkoutWith(LONG) });
  await hostCall(page, 'hold', 'transcript.page');
  await openSessionByName(page, 'Checkout v2', 'Claude');
  const tx = app(page).locator('.tx');
  await expect(tx.locator('.say', { hasText: `Answer ${LAST_TURN}, line 1:` })).toBeInViewport();
  await frames(tx, 3);
  const asked = (await pageCursors(page)).length;
  expect(asked).toBeLessThanOrEqual(1);
  const first = await firstRowKey(tx);
  await hostCall(page, 'release', 'transcript.page');
  if (asked === 1) await pageWentIn(tx, first);
  await frames(tx, 3);
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
  const m = await metricsOf(tx);
  expect(m.scrollHeight).toBeGreaterThan(m.clientHeight);
  return { tx, asked };
}

/**
 * Scrolls to the top once more for each page still above the rows, waiting for each to go in,
 * then to the top, where the transcript's first item shows. At the top no row sits above the
 * view for the virtualizer to correct for, so the view leaves the top only when a page goes in
 * and the list puts the reader's row back below it.
 * @param {Locator} tx
 * @param {number} asked the pages asked for already
 */
async function scrollToStart(tx, asked) {
  for (let n = asked; n < LONG_PAGES; n++) {
    await scrollTx(tx, 0);
    await expect.poll(async () => (await metricsOf(tx)).scrollTop).toBeGreaterThan(0);
  }
  await scrollTx(tx, 0);
  await expect(tx.locator('.me', { hasText: 'Question 0:' })).toBeInViewport();
}

test('the long transcript pages as the daemon pages one', () => {
  // The first page back to the 4th-last message and each older page 20 messages back, all
  // under spec section 7's caps (`olderPages` throws otherwise).
  expect(LONG_PAGES).toBeGreaterThan(60);
});

test('scrolling up loads older pages one at a time', async ({ page, appHost }) => {
  const { tx, asked } = await openLong(page, appHost);
  await hostCall(page, 'hold', 'transcript.page');
  for (let round = 1; round <= 3; round++) {
    // A swipe's worth of scroll events, all within two screens of the top.
    for (const top of [400, 200, 100, 0, 60]) await scrollTx(tx, top);
    await expect.poll(async () => (await pageCursors(page)).length).toBe(asked + round);
    await scrollTx(tx, 0);
    await frames(tx, 3);
    expect(await pageCursors(page)).toHaveLength(asked + round);
    const first = await firstRowKey(tx);
    await hostCall(page, 'release', 'transcript.page');
    await pageWentIn(tx, first);
    await hostCall(page, 'hold', 'transcript.page');
  }
  await hostCall(page, 'release', 'transcript.page');
  // Each asked with the cursor the page before it gave, further back each time.
  const cursors = (await pageCursors(page)).map(Number);
  for (let i = 1; i < cursors.length; i++) expect(cursors[i]).toBeLessThan(cursors[i - 1]);
});

test('loading an older page keeps the top visible row in place', async ({ page, appHost }) => {
  const { tx, asked } = await openLong(page, appHost);
  await hostCall(page, 'hold', 'transcript.page');
  // Rows above the view, so the rows of the page land further up still.
  await scrollTx(tx, 150);
  await expect.poll(async () => (await pageCursors(page)).length).toBe(asked + 1);
  const { key, row, top: before } = await firstWholeRow(tx);
  const keysBefore = await tx.locator('[data-tx-row]').evaluateAll((els) => els.map((el) => Number(el.getAttribute('data-key'))));
  const first = await firstRowKey(tx);
  if (first === null) throw new Error('the list does not draw its first row');

  // The row's top in every frame from before the page goes in until ten frames after.
  const sampled = tx.evaluate((el, { rowKey, firstKey }) => new Promise((resolve) => {
    /** @type {Array<number | null>} */
    const tops = [];
    let inAt = -1;
    const step = () => {
      const r = el.querySelector(`[data-tx-row][data-key="${rowKey}"]`);
      tops.push(r === null ? null : r.getBoundingClientRect().top);
      const nowFirst = el.querySelector('[data-tx-row][data-index="0"]')?.getAttribute('data-key') ?? null;
      if (inAt < 0 && nowFirst !== firstKey) inAt = tops.length;
      if ((inAt >= 0 && tops.length - inAt >= 10) || tops.length > 600) resolve({ tops, inAt });
      else requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }), { rowKey: key, firstKey: first });
  await hostCall(page, 'release', 'transcript.page');
  const { tops, inAt } = /** @type {{ tops: Array<number | null>, inAt: number }} */ (await sampled);

  expect(inAt, 'the page went in while the frames were watched').toBeGreaterThan(0);
  const frameTop = tops[0];
  if (frameTop === null || frameTop === undefined) throw new Error('the row was not drawn');
  for (const t of tops) expect(t === null ? Infinity : Math.abs(t - frameTop)).toBeLessThanOrEqual(1);
  const after = await topOf(row);
  expect(Math.abs(after - before)).toBeLessThanOrEqual(1);
  // The virtualizer measured rows of the new page above the view, each of which it corrects
  // the view for: so the restore and its correction did not count one height twice.
  const above = await tx.locator('[data-tx-row]').evaluateAll((els, { old, rowTop }) => els.filter((el) => {
    const box = el.getBoundingClientRect();
    return !old.includes(Number(el.getAttribute('data-key'))) && box.bottom <= rowTop && Math.round(box.height) !== 48;
  }).length, { old: keysBefore, rowTop: frameTop });
  expect(above).toBeGreaterThan(0);
});

test('a page that lands after the reader scrolled on holds where they are then', async ({ page, appHost }) => {
  const { tx, asked } = await openLong(page, appHost);
  await hostCall(page, 'hold', 'transcript.page');
  await scrollTx(tx, 600);
  await expect.poll(async () => (await pageCursors(page)).length).toBe(asked + 1);
  // The reader goes on up while the page is on its way, as a fling does.
  for (const top of [450, 300, 150]) await scrollTx(tx, top);
  expect(await pageCursors(page)).toHaveLength(asked + 1);
  const { row, top: before } = await firstWholeRow(tx);
  const first = await firstRowKey(tx);
  await hostCall(page, 'release', 'transcript.page');
  await pageWentIn(tx, first);
  await frames(tx, 4);
  expect(Math.abs((await topOf(row)) - before)).toBeLessThanOrEqual(1);
});

test('a scroll the reader makes as the page goes in is kept, not pulled back', async ({ page, appHost }) => {
  const { tx, asked } = await openLong(page, appHost);
  await hostCall(page, 'hold', 'transcript.page');
  await scrollTx(tx, 150);
  await expect.poll(async () => (await pageCursors(page)).length).toBe(asked + 1);
  const { row, top: before } = await firstWholeRow(tx);
  const first = await firstRowKey(tx);
  // As a fling goes on: the reader's next 40 px up land right after the commit that puts the
  // page in, before the frame in which the list puts the anchor back once more.
  await tx.evaluate((el, firstKey) => {
    const list = /** @type {HTMLElement} */ (el.querySelector('.tx-list'));
    const watch = new MutationObserver(() => {
      if ((el.querySelector('[data-tx-row][data-index="0"]')?.getAttribute('data-key') ?? null) === firstKey) return;
      watch.disconnect();
      el.scrollTop -= 40;
    });
    watch.observe(list, { attributes: true, childList: true, subtree: true });
  }, first);
  await hostCall(page, 'release', 'transcript.page');
  // Any page that scroll asks for waits, so only the one page goes in.
  await hostCall(page, 'hold', 'transcript.page');
  await pageWentIn(tx, first);
  await frames(tx, 6);
  expect(Math.abs((await topOf(row)) - (before + 40))).toBeLessThanOrEqual(1);
});

test('only rows near the screen are in the page', async ({ page, appHost }) => {
  test.setTimeout(90_000);
  const { tx, asked } = await openLong(page, appHost);
  await scrollToStart(tx, asked);
  // Every page is in: the list is many screens tall.
  const m = await metricsOf(tx);
  expect(m.scrollHeight).toBeGreaterThan(50 * m.clientHeight);
  expect(await tx.locator('[data-tx-row]').count()).toBeLessThan(80);
  await scrollTx(tx, Math.round(m.scrollHeight / 2));
  await frames(tx, 3);
  expect(await tx.locator('[data-tx-row]').count()).toBeLessThan(80);
  await scrollTx(tx, 'bottom');
  await frames(tx, 3);
  expect(await tx.locator('[data-tx-row]').count()).toBeLessThan(80);
  await expect(tx.locator('.say', { hasText: `Answer ${LAST_TURN}, line 1:` })).toBeInViewport();
});

test('scrolling back through all 2,000 items reaches the first, and asks for nothing past the start', async ({ page, appHost }) => {
  test.setTimeout(90_000);
  const { tx, asked } = await openLong(page, appHost);
  await scrollToStart(tx, asked);
  const cursors = await pageCursors(page);
  expect(cursors).toHaveLength(LONG_PAGES);
  // The last page reached the start, so no scroll asks again.
  for (const top of [300, 0, 100, 0]) await scrollTx(tx, top);
  await frames(tx, 3);
  expect(await pageCursors(page)).toEqual(cursors);
  await expect(tx.locator('.me').first()).toContainText('Question 0:');
});

test('a failed older page shows nothing, and loads on the next scroll', async ({ page, appHost }) => {
  const { tx, asked } = await openLong(page, appHost);
  await hostCall(page, 'setReply', 'transcript.page', { error: { code: 'refused', message: REMOTE_REFUSED } });
  await scrollTx(tx, 150);
  await expect.poll(async () => (await pageCursors(page)).length).toBe(asked + 1);
  const first = await firstRowKey(tx);
  // Nothing shows, and nothing more is asked while the reader does not scroll.
  await frames(tx, 6);
  await expect(app(page).getByText(REMOTE_REFUSED)).toHaveCount(0);
  expect(await firstRowKey(tx)).toBe(first);
  expect(await pageCursors(page)).toHaveLength(asked + 1);

  // The next scroll asks again, for the same page, and this time it goes in.
  await hostCall(page, 'setReply', 'transcript.page', null);
  await scrollTx(tx, 100);
  await expect.poll(async () => (await pageCursors(page)).length).toBe(asked + 2);
  const cursors = await pageCursors(page);
  expect(cursors[asked + 1]).toBe(cursors[asked]);
  await pageWentIn(tx, first);
  await expect(app(page).getByText(REMOTE_REFUSED)).toHaveCount(0);
});

test('a slow drag is the reader’s scroll, so a failed older page loads again on it', async ({ page, appHost }) => {
  const { tx, asked } = await openLong(page, appHost);
  await hostCall(page, 'setReply', 'transcript.page', { error: { code: 'refused', message: REMOTE_REFUSED } });
  await scrollTx(tx, 150);
  await expect.poll(async () => (await pageCursors(page)).length).toBe(asked + 1);
  await frames(tx, 3);
  const first = await firstRowKey(tx);
  await hostCall(page, 'setReply', 'transcript.page', null);
  // A pixel a frame: no one scroll event moves the view more than a pixel. It asks again, for
  // the same page.
  await slowDrag(tx, 1, 20);
  await expect.poll(async () => (await pageCursors(page)).length).toBeGreaterThanOrEqual(asked + 2);
  const cursors = await pageCursors(page);
  expect(cursors[asked + 1]).toBe(cursors[asked]);
  await pageWentIn(tx, first);
});

test('a reset starts over at the newest items', async ({ page, appHost }) => {
  const { tx, asked } = await openLong(page, appHost);
  await hostCall(page, 'hold', 'transcript.page');
  await scrollTx(tx, 0);
  await expect.poll(async () => (await pageCursors(page)).length).toBe(asked + 1);
  const first = await firstRowKey(tx);
  await hostCall(page, 'release', 'transcript.page');
  await pageWentIn(tx, first);
  // Scrolled up, with the next page on its way.
  await hostCall(page, 'hold', 'transcript.page');
  await scrollTx(tx, 0);
  await expect.poll(async () => (await pageCursors(page)).length).toBe(asked + 2);

  await hostCall(page, 'emit', 'transcript.reset', {
    session: CHECKOUT_REF, reason: 'rollover', page: { items: bashRows('reset', 40), reachedStart: true, omittedItems: 0 },
  });
  await expect(tx.locator('button.tool', { hasText: 'npm run reset-39' })).toBeInViewport();
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
  await expect(tx.locator('.me, .say')).toHaveCount(0);

  // The page that was on its way changes nothing when it lands: once an event behind it on the
  // same channel shows, the app has taken it.
  await hostCall(page, 'release', 'transcript.page');
  await appendToCheckout(page, bashRows('after', 1));
  await expect(tx.locator('button.tool', { hasText: 'npm run after-0' })).toBeInViewport();
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
  await expect(tx.locator('.me, .say')).toHaveCount(0);
  await expect(app(page).locator('.pill')).toHaveCount(0);
  // The reset's page reached the start, so a scroll up asks for nothing.
  await scrollTx(tx, 0);
  await frames(tx, 3);
  expect(await pageCursors(page)).toHaveLength(asked + 2);
});

/** 200 short messages, alternating yours and the assistant's: a first page of them fits the screen. */
function shortItems() {
  return Array.from({ length: 200 }, (_, i) => ({
    id: `short-${i}`, kind: i % 2 === 0 ? 'user' : 'assistant', text: `Short message ${i}.`, truncated: false,
  }));
}

test('a first page that fits the screen asks for the page above without a scroll', async ({ page, appHost }) => {
  const items = shortItems();
  await openApp(page, appHost, { scenario: checkoutWith(items) });
  await openSessionByName(page, 'Checkout v2', 'Claude');
  const tx = app(page).locator('.tx');
  await expect(tx.locator('.say', { hasText: 'Short message 199.' })).toBeInViewport();
  await expect.poll(() => pageCursors(page)).toEqual([String(items.length - FIRST_PAGE_MESSAGES)]);
  // The page went in above, and the view stayed at the newest row.
  await expect.poll(async () => { const m = await metricsOf(tx); return m.scrollHeight > m.clientHeight; }).toBe(true);
  await frames(tx, 3);
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
  await expect(tx.locator('.say', { hasText: 'Short message 199.' })).toBeInViewport();
  // Now the reader can scroll, so nothing more is asked until they do.
  expect(await pageCursors(page)).toHaveLength(1);
  await scrollTx(tx, 0);
  await expect.poll(async () => (await pageCursors(page)).length).toBe(2);
});

test('a failed older page above rows that fit the screen loads again on a tap, and never by itself', async ({ page, appHost }) => {
  const items = shortItems();
  await openApp(page, appHost, { scenario: checkoutWith(items) });
  await hostCall(page, 'setReply', 'transcript.page', { error: { code: 'refused', message: REMOTE_REFUSED } });
  await openSessionByName(page, 'Checkout v2', 'Claude');
  const tx = app(page).locator('.tx');
  await expect(tx.locator('.say', { hasText: 'Short message 199.' })).toBeInViewport();
  await expect.poll(async () => (await pageCursors(page)).length).toBe(1);
  // The rows fit, so no scroll can follow, and nothing asks again by itself.
  await frames(tx, 6);
  const m = await metricsOf(tx);
  expect(m.scrollHeight).toBeLessThanOrEqual(m.clientHeight);
  expect(await pageCursors(page)).toHaveLength(1);
  await expect(app(page).getByText(REMOTE_REFUSED)).toHaveCount(0);

  // A tap on the transcript, above its rows, is the reader's next scroll: it asks once more, and
  // only once while the page still fails.
  const above = { position: { x: 20, y: 20 } };
  await tx.tap(above);
  await expect.poll(async () => (await pageCursors(page)).length).toBe(2);
  await frames(tx, 6);
  expect(await pageCursors(page)).toHaveLength(2);

  await hostCall(page, 'setReply', 'transcript.page', null);
  await tx.tap(above);
  await expect.poll(async () => (await pageCursors(page)).length).toBe(3);
  expect(new Set(await pageCursors(page)).size).toBe(1);
  await expect.poll(async () => { const now = await metricsOf(tx); return now.scrollHeight > now.clientHeight; }).toBe(true);
  await expect(tx.locator('.say', { hasText: 'Short message 199.' })).toBeInViewport();
});

test('an older page made stale by a reopen lets the reopened rows ask for theirs once it settles', async ({ page, appHost }) => {
  const items = shortItems();
  await openApp(page, appHost, { scenario: checkoutWith(items) });
  await hostCall(page, 'hold', 'transcript.page');
  await openSessionByName(page, 'Checkout v2', 'Claude');
  const tx = app(page).locator('.tx');
  await expect(tx.locator('.say', { hasText: 'Short message 199.' })).toBeInViewport();
  await expect.poll(async () => (await pageCursors(page)).length).toBe(1);

  // "Show details" opens the transcript again while the page is on its way. The new rows fit the
  // screen too, and their page waits for the one on the wire.
  const opens = async () => (await hostRequests(page)).filter((r) => r.method === 'transcript.open').length;
  await app(page).locator('.s-head .tg').click();
  await expect.poll(opens).toBe(2);
  await expect(tx.locator('.say', { hasText: 'Short message 199.' })).toBeInViewport();
  await frames(tx, 6);
  expect(await pageCursors(page)).toHaveLength(1);

  // The stale page lands and changes no row, and the new rows ask for their page, once.
  await hostCall(page, 'release', 'transcript.page');
  await expect.poll(async () => (await pageCursors(page)).length).toBe(2);
  await expect.poll(async () => { const m = await metricsOf(tx); return m.scrollHeight > m.clientHeight; }).toBe(true);
  await frames(tx, 6);
  expect(await pageCursors(page)).toHaveLength(2);
  await expect(tx.locator('.say', { hasText: 'Short message 199.' })).toBeInViewport();
});

// --- the "Working…" line and Show details -----------------------------------------------------

/** Checkout v2's row in mock.json. */
const CHECKOUT_ROW = MOCK.rows.find((/** @type {any} */ r) => r.name === 'Checkout v2');

/**
 * The laptop says Checkout v2's Claude session has `status` now, its other sessions unchanged.
 * @param {Page} page
 * @param {object} status
 */
function setCheckoutStatus(page, status) {
  const sessions = CHECKOUT_ROW.sessions.map((/** @type {any} */ s) => (s.ref.terminalID === CHECKOUT_REF.terminalID ? { ...s, status } : s));
  return hostCall(page, 'emit', 'sessions.changed', { rows: [{ ...CHECKOUT_ROW, sessions }], removedRowIDs: [] });
}

/**
 * The seconds an elapsed time such as `1m 12s` or `9s` stands for.
 * @param {string | null} text
 */
function secondsOf(text) {
  const m = /^(?:(\d+)m )?(\d+)s$/.exec(text ?? '');
  if (m === null) throw new Error(`not an elapsed time: ${JSON.stringify(text)}`);
  return Number(m[1] ?? 0) * 60 + Number(m[2]);
}

/**
 * When Checkout v2's Claude session's chip last changed, as the laptop sent it.
 * @param {Page} page
 * @returns {Promise<number>}
 */
function checkoutChangedAt(page) {
  return page.evaluate((id) => {
    const rows = /** @type {any} */ (window).__host.state.rows;
    return rows.flatMap((/** @type {any} */ r) => r.sessions).find((/** @type {any} */ s) => s.ref.terminalID === id).status.changedAt;
  }, CHECKOUT_REF.terminalID);
}

test('a working session shows Working… with its elapsed time, read every second', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Checkout v2', 'Claude');
  const working = app(page).locator('.tx .working');
  await expect(working).toBeVisible();
  await expect(working).toHaveText(/^Working… (\d+m )?\d+s$/);
  await expect(working.locator('.dots')).toHaveCount(1);
  // Under the rows, in .tx and outside the virtual list.
  expect(await working.evaluate((el) => [el.parentElement?.id, el.previousElementSibling?.className, el.closest('[data-tx-row]')])).toEqual(
    ['tx', 'tx-list', null],
  );

  // The time since the chip turned Working, read again every second.
  const elapsed = working.locator('span:not(.dots)');
  const changedAt = await checkoutChangedAt(page);
  const before = Date.now();
  const shown = secondsOf(await elapsed.textContent());
  const after = Date.now();
  expect(shown).toBeGreaterThanOrEqual(Math.floor((before - changedAt) / 1000) - 1);
  expect(shown).toBeLessThanOrEqual(Math.floor((after - changedAt) / 1000));
  await expect.poll(async () => secondsOf(await elapsed.textContent()), { timeout: 3_000 }).toBeGreaterThan(shown);
});

test('a session that is not working shows no Working… line', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  await expect(app(page).locator('.tx .say').first()).toBeVisible();
  await expect(app(page).locator('.working')).toHaveCount(0);
});

test('Working… goes when the session stops and comes back when it works, and a view at the bottom stays there', async ({ page, appHost }) => {
  const tx = await openTall(page, appHost);
  const working = app(page).locator('.tx .working');
  const last = tx.locator('button.tool', { hasText: `npm run step-${TALL_ROWS - 1}` });
  await expect(working).toBeInViewport();
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);

  await setCheckoutStatus(page, { chip: 'idle', changedAt: Date.now() });
  await expect(working).toHaveCount(0);
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
  await expect(last).toBeInViewport();

  // A new turn: the line comes back below the rows, counting from the chip's new change.
  await setCheckoutStatus(page, { chip: 'working', changedAt: Date.now() });
  await expect(working).toBeInViewport();
  await expect.poll(() => fromBottom(tx)).toBeLessThanOrEqual(1);
  expect(secondsOf(await working.locator('span:not(.dots)').textContent())).toBeLessThan(5);
  await expect(app(page).locator('.pill')).toHaveCount(0);
});

test('Show details reopens the transcript with thinking and system notes, and off takes them away', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await openSessionByName(page, 'Login redirect fix');
  const tx = app(page).locator('.tx');
  await expect(tx.locator('.say').first()).toBeVisible();
  await expect(tx.locator('.extra')).toHaveCount(0);
  const opens = async () => (await hostRequests(page)).filter((r) => r.method === 'transcript.open').map((r) => r.params);
  expect(await opens()).toEqual([{ session: LOGIN_REF, showDetails: false, resume: false }]);

  // The switch in the session header, tapped as a reader taps it.
  const head = app(page).locator('.s-head');
  const toggle = head.getByRole('switch', { name: 'Show details' });
  await head.locator('.tg').click();
  await expect(toggle).toBeChecked();
  await expect.poll(opens).toEqual([
    { session: LOGIN_REF, showDetails: false, resume: false }, { session: LOGIN_REF, showDetails: true, resume: false },
  ]);
  const extra = tx.locator('.extra');
  await expect(extra.locator('.dl')).toHaveText(['Thinking', 'System']);
  await expect(extra.nth(0)).toContainText('The redirect target is probably lost in the sign-in callback. Look at finishLogin first.');
  await expect(extra.nth(1)).toContainText('PostToolUse: eslint src/auth passed.');
  // Each where the laptop put it: the thinking after your message, the note after the Bash call.
  const order = await tx.locator('[data-tx-row]').evaluateAll((els) => els
    .sort((a, b) => Number(a.getAttribute('data-index')) - Number(b.getAttribute('data-index')))
    .map((el) => el.firstElementChild?.className ?? ''));
  expect(order.indexOf('extra')).toBe(order.indexOf('me') + 1);
  expect(order.lastIndexOf('extra')).toBe(order.length - 2);

  await head.locator('.tg').click();
  await expect(toggle).not.toBeChecked();
  await expect.poll(async () => (await opens()).map((p) => p.showDetails)).toEqual([false, true, false]);
  await expect(extra).toHaveCount(0);
  await expect(tx.locator('.say').first()).toBeVisible();
});

// --- links: they leave only through the loader ------------------------------------------------
//
// A link is a `.lnk` that the app hands to the loader as `openLink` (`__host.links`), never an
// element that could navigate the frame, so the frame stays on the runner after a click. Links
// the app does not offer (another scheme, a user name or password) and raw HTML stay text.

/** The scheme that runs script, built in pieces, as the app's source policy asks of its own files. */
const SCRIPT_SCHEME = 'java' + 'script:';
const DOCS = 'https://acme.example/docs';
const GUIDE = 'https://acme.example/guide';
const IMG_TAG = `<img src=x onerror="console.error('img-ran')">`;
const ANCHOR_TAG = '<a href="https://acme.example">x</a>';

/**
 * mock.json with Checkout v2's Claude transcript holding links: one in your message, one in a
 * message, three the app does not offer, and raw HTML with a markdown image. Four messages, so
 * the first page holds them all.
 */
function linkScenario() {
  return checkoutWith([
    { id: 'link-1', kind: 'user', text: `Read [the guide](${GUIDE}) before the docs.`, truncated: false },
    { id: 'link-2', kind: 'assistant', text: `See [docs](${DOCS}).`, truncated: false },
    {
      id: 'link-3', kind: 'assistant', truncated: false,
      text: `Not links: [run](${SCRIPT_SCHEME}alert(1)), [sign in](https://u:p@acme.example) and [inline](data:text/html,hi).`,
    },
    { id: 'link-4', kind: 'assistant', text: `Raw: ${ANCHOR_TAG} and ${IMG_TAG} and ![logo](https://acme.example/logo.png).`, truncated: false },
  ]);
}

/**
 * Opens Checkout v2's Claude tab from `linkScenario`, and returns its transcript once its last
 * message shows.
 * @param {Page} page
 * @param {AppHost} appHost
 */
async function openLinks(page, appHost) {
  await openApp(page, appHost, { scenario: linkScenario() });
  await openSessionByName(page, 'Checkout v2', 'Claude');
  const tx = app(page).locator('.tx');
  await expect(tx.locator('.say', { hasText: 'Raw:' })).toBeVisible();
  return tx;
}

test('a link in a message reaches the loader as openLink and never navigates the frame', async ({ page, appHost }) => {
  const tx = await openLinks(page, appHost);
  const docs = tx.locator('.say .lnk');
  await expect(docs).toHaveText('docs');
  await expect(docs).toHaveAttribute('role', 'link');
  await docs.click();
  await expect.poll(() => hostLinks(page)).toEqual([DOCS]);
  expect(await frameURL(page)).toContain('/runner.html');
  await expect(app(page).locator('#app')).toBeAttached();

  // Each link is a span with its class, role and tab stop, and nothing built from its URL.
  const attrs = await tx.locator('.lnk').evaluateAll((els) => els.map((el) => [...el.attributes].map((a) => [a.name, a.value])));
  expect(attrs).toHaveLength(2);
  for (const list of attrs) expect(list.map(([name]) => name).sort()).toEqual(['class', 'role', 'tabindex']);
  expect(JSON.stringify(attrs)).not.toContain('acme.example');
  await expect(tx.locator('a, [href]')).toHaveCount(0);
});

test('Enter on a focused link opens it once, and a held Enter does not open it again', async ({ page, appHost }) => {
  const tx = await openLinks(page, appHost);
  const docs = tx.locator('.say .lnk');
  await docs.focus();
  await expect(docs).toBeFocused();
  await page.keyboard.press('Enter');
  await expect.poll(() => hostLinks(page)).toEqual([DOCS]);
  // Held: the first keydown opens it, and the repeats after it do not.
  await page.keyboard.down('Enter');
  await page.keyboard.down('Enter');
  await page.keyboard.down('Enter');
  await page.keyboard.up('Enter');
  // A click behind the keys, on the same port: once its URL arrives, every key's has.
  await tx.locator('.me .lnk').click();
  await expect.poll(() => hostLinks(page)).toEqual([DOCS, DOCS, GUIDE]);
  expect(await frameURL(page)).toContain('/runner.html');
});

test('a script, data or credentials link is plain text, and opens nothing', async ({ page, appHost }) => {
  const tx = await openLinks(page, appHost);
  const say = tx.locator('.say', { hasText: 'Not links:' });
  await expect(say).toHaveText('Not links: run, sign in and inline.');
  await expect(say.locator('.lnk, [role="link"], [tabindex]')).toHaveCount(0);
  await say.click();
  // A link behind the click, on the same port: once its URL arrives, the click's would have.
  await tx.locator('.say .lnk').click();
  await expect.poll(() => hostLinks(page)).toEqual([DOCS]);
  expect(await frameURL(page)).toContain('/runner.html');
  const html = await tx.evaluate((el) => [...el.querySelectorAll('*')].flatMap((node) => [...node.attributes].map((a) => a.value)).join(' '));
  expect(html).not.toContain(SCRIPT_SCHEME);
  expect(html).not.toContain('u:p@');
  expect(html).not.toContain('data:');
});

test('raw HTML in a message shows as its text, makes no element and runs nothing', async ({ page, appHost }) => {
  const tx = await openLinks(page, appHost);
  const say = tx.locator('.say', { hasText: 'Raw:' });
  // The image's markdown shows its alt text. A run of the handler would log a console error,
  // and a load the runner's policy refused would report a violation: the fixture fails on both.
  await expect(say).toHaveText(`Raw: ${ANCHOR_TAG} and ${IMG_TAG} and logo.`);
  await expect(tx.locator('a, img')).toHaveCount(0);
  await expect(say.locator('.lnk')).toHaveCount(0);
  await say.click();
  expect(await hostLinks(page)).toEqual([]);
});

test('a link in your message opens through the loader too', async ({ page, appHost }) => {
  const tx = await openLinks(page, appHost);
  const guide = tx.locator('.me .lnk');
  await expect(guide).toHaveText('the guide');
  await expect(tx.locator('.me')).toHaveText('YouRead the guide before the docs.');
  await guide.click();
  await expect.poll(() => hostLinks(page)).toEqual([GUIDE]);
  expect(await frameURL(page)).toContain('/runner.html');
});

test('a link in a message shown in full through Show more opens through the loader too', async ({ page, appHost }) => {
  const notes = 'https://acme.example/redirects';
  const scenario = structuredClone(MOCK);
  scenario.details['login-10'].text += `\n\nSee [the redirect notes](${notes}).`;
  await openApp(page, appHost, { scenario });
  await openSessionByName(page, 'Login redirect fix');
  const say = app(page).locator('.tx .say').last();
  await say.locator('.morebtn').click();
  const link = say.locator('.lnk', { hasText: 'the redirect notes' });
  await expect(link).toBeVisible();
  await link.click();
  await expect.poll(() => hostLinks(page)).toEqual([notes]);
  expect(await frameURL(page)).toContain('/runner.html');
});

test('a link whose URL an update changes in place opens the new URL', async ({ page, appHost }) => {
  const moved = 'https://acme.example/docs/v2';
  const tx = await openLinks(page, appHost);
  const say = tx.locator('.say', { hasText: 'See docs' });
  await say.locator('.lnk').click();
  await expect.poll(() => hostLinks(page)).toEqual([DOCS]);

  // The same item, its link in the same place with the same text, and only its URL and the
  // words after it changed: the row and its link are drawn again, not made anew.
  await hostCall(page, 'emit', 'transcript.update', {
    session: CHECKOUT_REF, items: [{ id: 'link-2', kind: 'assistant', text: `See [docs](${moved}), moved.`, truncated: false }],
  });
  await expect(say).toHaveText('See docs, moved.');
  await say.locator('.lnk').click();
  await expect.poll(() => hostLinks(page)).toEqual([DOCS, moved]);
  expect(await frameURL(page)).toContain('/runner.html');
});

test('a link in a subagent’s nest opens its own URL, and sits in no button', async ({ page, appHost }) => {
  const callback = 'https://acme.example/callback';
  const rules = 'https://acme.example/redirect-rules';
  const scenario = structuredClone(MOCK);
  scenario.details['login-3'].subagent.push({
    id: 'login-3-4', kind: 'assistant', truncated: false,
    text: `See [the callback notes](${callback}) and [the redirect rules](${rules}).`,
  });
  await openApp(page, appHost, { scenario });
  await openSessionByName(page, 'Login redirect fix');
  const tx = app(page).locator('.tx');
  const agent = tx.locator('button.tool', { hasText: 'Explore agent' });
  await agent.click();
  const links = tx.locator('.nest .lnk');
  await expect(links).toHaveText(['the callback notes', 'the redirect rules']);
  expect(await links.evaluateAll((els) => els.map((el) => el.closest('button') === null))).toEqual([true, true]);

  await links.last().click();
  await expect.poll(() => hostLinks(page)).toEqual([rules]);
  await links.first().click();
  await expect.poll(() => hostLinks(page)).toEqual([rules, callback]);
  // The taps opened links and nothing else: the subagent row stays open and asked once.
  await expect(agent).toHaveAttribute('aria-expanded', 'true');
  expect(await detailRequests(page)).toEqual([['login-3', 'subagent', 0]]);
  expect(await frameURL(page)).toContain('/runner.html');
});
