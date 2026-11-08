// The sessions list end to end (spec section 8.2, "Sessions"), in WebKit as an iPhone and in
// Chromium as an Android phone: the order, what a row shows, what a tap opens, collapsing a
// repo, each repo's "+", and the row opened last.
//
// A scenario variation is built here from mock.json and loaded as an object, never written
// into mock.json. Until part 6c, opening a session sends no `transcript.open`, so which session
// a tap opened is read from the screen alone (see the tap test).

import { readFileSync } from 'node:fs';

import { app, expect, hostCall, openApp, openSessionByName, rowNames, test } from './fixtures.js';

/** @typedef {import('@playwright/test').Page} Page */

const MOCK = JSON.parse(readFileSync(new URL('scenarios/mock.json', import.meta.url), 'utf8'));
/** @type {string[]} */
const MOCK_NAMES = MOCK.rows.map((/** @type {any} */ r) => r.name);

/**
 * The mock scenario's row named `name`, as mock.json writes it.
 * @param {string} name
 */
function mockRow(name) {
  const row = MOCK.rows.find((/** @type {any} */ r) => r.name === name);
  if (row === undefined) throw new Error(`mock.json has no row ${name}`);
  return row;
}

/**
 * How many minutes ago a scenario row's status changed, as the fake laptop resolves it: its own
 * `agoMinutes`, else its newest session's.
 * @param {any} row
 */
function minutesAgo(row) {
  if (row.agoMinutes !== undefined) return row.agoMinutes;
  return Math.min(...row.sessions.map((/** @type {any} */ s) => s.status.agoMinutes));
}

/**
 * The list a scenario should show, as `shownOutline` reads it: each group's name with its rows'
 * names, newest first at both levels and ties in the scenario's order. A group that shows no
 * rows comes last when it is a repo, and is left out otherwise. A row that has not arrived, or
 * has no sessions, is not shown.
 * @param {{ layout: any[], rows: any[] }} scenario
 * @returns {Array<[string, string[]]>}
 */
function expectedOutline(scenario) {
  const byID = new Map(scenario.rows.map((r) => [r.id, r]));
  const groups = scenario.layout.map((g) => {
    const rows = g.rows.map((/** @type {any} */ p) => byID.get(p.id)).filter((/** @type {any} */ r) => r !== undefined && r.sessions.length > 0);
    rows.sort((/** @type {any} */ a, /** @type {any} */ b) => minutesAgo(a) - minutesAgo(b));
    return { name: g.name, kind: g.kind, rows, newest: rows.length > 0 ? minutesAgo(rows[0]) : Infinity };
  });
  const shown = groups.filter((g) => g.rows.length > 0).sort((a, b) => a.newest - b.newest);
  const emptyRepos = groups.filter((g) => g.rows.length === 0 && g.kind === 'repo');
  return [...shown, ...emptyRepos].map((g) => [g.name, g.rows.map((/** @type {any} */ r) => r.name)]);
}

/**
 * What the list shows: each group's name with its rows' names, in screen order. A row's name
 * leaves out its count. It does not wait; poll it.
 * @param {Page} page
 * @returns {Promise<Array<[string, string[]]>>}
 */
function shownOutline(page) {
  return app(page).locator('.list').evaluate((list) => {
    /** @type {Array<[string, string[]]>} */
    const out = [];
    for (const el of list.children) {
      if (el.classList.contains('repo-row')) out.push([el.querySelector('.repo')?.textContent ?? '', []]);
      if (el.classList.contains('rows')) {
        for (const n of el.querySelectorAll('.row .n')) {
          const text = [...n.childNodes].filter((c) => c.nodeType === Node.TEXT_NODE).map((c) => c.textContent).join('');
          out[out.length - 1][1].push(text.trim());
        }
      }
    }
    return out;
  });
}

/**
 * `MOCK` with `groups` laid out before its own and `rows` added.
 * @param {{ before?: any[], after?: any[], rows?: any[] }} extra
 */
function mockWith({ before = [], after = [], rows = [] }) {
  return { ...MOCK, layout: [...before, ...MOCK.layout, ...after], rows: [...MOCK.rows, ...rows] };
}

/**
 * A copy of the mock row named `from`, with a new ID, name and session, whose status changed
 * `agoMinutes` ago.
 * @param {string} from
 * @param {{ id: string, name: string, agoMinutes: number, ref?: any }} to
 */
function rowLike(from, { id, name, agoMinutes, ref }) {
  const base = mockRow(from);
  const session = { ...base.sessions[0], status: { chip: 'idle', agoMinutes } };
  if (ref !== undefined) session.ref = ref;
  return { ...base, id, name, sessions: [session] };
}

/** @param {string} id @param {string} name @param {string} kind @param {string[]} rowIDs */
function group(id, name, kind, rowIDs) {
  return { id, kind, name, rows: rowIDs.map((rowID) => ({ id: rowID, depth: 0 })) };
}

test('repos and rows are newest first', async ({ page, appHost }) => {
  await openApp(page, appHost);
  const expected = expectedOutline(MOCK);
  // What mock.json implies, written out once so a reader sees it.
  expect(expected.map(([repo]) => repo)).toEqual(['acme-web', 'acme-api', 'acme-mobile']);
  expect(expected[0][1]).toEqual(['Checkout v2', 'Login redirect fix', 'Docs refresh', 'main']);
  await expect.poll(() => shownOutline(page)).toEqual(expected);
  await expect(app(page).locator('.l-head h1')).toHaveText('Sessions');
  await expect(app(page).locator('.list-foot')).toHaveText(
    'Newest changes first. Shell and note tabs, and archived worktrees, are not shown.');
});

test('a row shows its count, remote badge, age and the most urgent status for screen readers', async ({ page, appHost }) => {
  await openApp(page, appHost);
  const row = (/** @type {string} */ name) => app(page).locator('.row', { hasText: name });

  // Its sessions are working, idle and working: the most urgent is working.
  const co = row('Checkout v2');
  await expect(co.locator('.n small')).toHaveText('(3)');
  await expect(co.locator('.sr')).toHaveText('Working');
  await expect(co.locator('.g .dots')).toHaveCount(1);
  await expect(co).toHaveClass(/(^| )st-work( |$)/);
  await expect(co.locator('.t')).toHaveText('now');
  await expect(row('Triage flaky test').locator('.rb')).toHaveText('remote');
  // Only the remote row has the badge, and only the row with several sessions a count.
  await expect(app(page).locator('.row .rb')).toHaveCount(1);
  await expect(app(page).locator('.row .n small')).toHaveCount(1);

  for (const [name, age, word, cls] of [
    ['Login redirect fix', '2m', 'Waiting for you', 'st-wait'],
    ['Rate limit retry', '12m', 'Error', 'st-err'],
    ['Bulk import', '40m', 'Rate limited', 'st-rate'],
    ['Docs refresh', '3h', 'Parked', 'st-park'],
    ['Schema migration', '2h', 'Exited', 'st-gone'],
    ['Legacy pane', '7h', 'Unknown', 'st-unk'],
    ['main', '1d', 'Idle', 'st-idle'],
  ]) {
    await expect(row(name).locator('.t'), name).toHaveText(age);
    await expect(row(name).locator('.sr'), name).toHaveText(word);
    await expect(row(name), name).toHaveClass(new RegExp(`(^| )${cls}( |$)`));
  }
  // Idle has no symbol; the others draw one.
  await expect(row('main').locator('.g svg')).toHaveCount(0);
  await expect(row('Login redirect fix').locator('.g svg')).toHaveCount(1);

  // A session that waits for you outranks a newer one that works.
  const checkout = mockRow('Checkout v2');
  const [claude, review, codex] = checkout.sessions;
  await hostCall(page, 'emit', 'sessions.changed', {
    rows: [{ ...checkout, sessions: [claude, { ...review, status: { chip: 'waitingForYou', agoMinutes: 20 } }, codex] }],
    removedRowIDs: [],
  });
  await expect(co.locator('.sr')).toHaveText('Waiting for you');
  await expect(co).toHaveClass(/(^| )st-wait( |$)/);
  // The age is still the row's newest change, Claude's.
  await expect(co.locator('.t')).toHaveText('now');
});

test('tapping a row opens the session that shows its status', async ({ page, appHost }) => {
  await openApp(page, appHost);
  const checkout = mockRow('Checkout v2');
  const [claude, review, codex] = checkout.sessions;
  // Review waits for you, so the row shows its status, though Claude is first and changed last.
  const waiting = { ...review, status: { chip: 'waitingForYou', agoMinutes: 20 } };
  await hostCall(page, 'emit', 'sessions.changed', { rows: [{ ...checkout, sessions: [claude, waiting, codex] }], removedRowIDs: [] });
  const co = app(page).locator('.row', { hasText: 'Checkout v2' });
  await expect(co.locator('.sr')).toHaveText('Waiting for you');

  await co.click();
  const root = app(page).locator('#app');
  const header = app(page).locator('.s-head');
  await expect(root).toHaveAttribute('data-screen', 'session');
  await expect(header).toContainText('Checkout v2');

  // Which session is open shows in what the screen does when a session leaves the row: the
  // session screen goes back to the list when its own session leaves, and stays while another
  // does. Claude leaves first; the rename shows the change arrived.
  await hostCall(page, 'emit', 'sessions.changed', {
    rows: [{ ...checkout, name: 'Checkout v2, renamed', sessions: [waiting, codex] }], removedRowIDs: [],
  });
  await expect(header).toContainText('Checkout v2, renamed');
  await expect(root).toHaveAttribute('data-screen', 'session');
  // Then Review leaves, and the screen goes back to the list.
  await hostCall(page, 'emit', 'sessions.changed', { rows: [{ ...checkout, sessions: [codex] }], removedRowIDs: [] });
  await expect(root).toHaveAttribute('data-screen', 'sessions');
  await expect(app(page).locator('.list-foot')).toBeVisible();
});

test("tapping a repo's name collapses its rows", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await expect.poll(() => rowNames(page)).toEqual([...MOCK_NAMES].sort());
  const web = app(page).getByRole('button', { name: 'acme-web', exact: true });
  const webNames = expectedOutline(MOCK).find(([repo]) => repo === 'acme-web')?.[1] ?? [];
  await expect(web).toHaveAttribute('aria-expanded', 'true');

  await web.click();
  await expect(web).toHaveAttribute('aria-expanded', 'false');
  await expect.poll(() => rowNames(page)).toEqual(MOCK_NAMES.filter((n) => !webNames.includes(n)).sort());
  // The header and its "+" stay.
  await expect(app(page).getByRole('button', { name: 'New session in acme-web' })).toBeVisible();

  await web.click();
  await expect(web).toHaveAttribute('aria-expanded', 'true');
  await expect.poll(() => shownOutline(page)).toEqual(expectedOutline(MOCK));
});

test('"+" names its repo and repo groups alone have one', async ({ page, appHost }) => {
  const scratchRow = rowLike('main', { id: '00000000-0000-4000-8000-0000000000D1', name: 'Spike', agoMinutes: 30 });
  const providerRow = rowLike('Triage flaky test', {
    id: 'remote:acme-hosted/run-1', name: 'Nightly run', agoMinutes: 1,
    ref: { kind: 'remote', provider: 'acme-hosted', sessionID: 'run-1' },
  });
  const scenario = mockWith({
    before: [group('scratch', 'Scratch', 'scratch', [scratchRow.id])],
    after: [group('provider:acme-hosted', 'acme-hosted', 'provider', [providerRow.id])],
    rows: [scratchRow, providerRow],
  });
  await openApp(page, appHost, { scenario });
  await expect.poll(() => shownOutline(page)).toEqual(expectedOutline(scenario));
  expect(expectedOutline(scenario).map(([repo]) => repo)).toEqual(['acme-web', 'acme-hosted', 'acme-api', 'acme-mobile', 'Scratch']);

  const adds = app(page).locator('.repo-add');
  await expect(adds).toHaveCount(3);
  expect(await adds.evaluateAll((els) => els.map((el) => el.getAttribute('aria-label')))).toEqual([
    'New session in acme-web', 'New session in acme-api', 'New session in acme-mobile',
  ]);
  for (const name of ['Scratch', 'acme-hosted']) {
    const header = app(page).locator('.repo-row', { has: app(page).getByRole('button', { name, exact: true }) });
    await expect(header).toHaveCount(1);
    await expect(header.locator('.repo-add'), name).toHaveCount(0);
  }

  // "+" is a button of its own: it leaves the repo's rows as they are.
  await app(page).getByRole('button', { name: 'New session in acme-api' }).click();
  await expect(app(page).getByRole('button', { name: 'acme-api', exact: true })).toHaveAttribute('aria-expanded', 'true');
});

test('the row opened last is marked when you come back', async ({ page, appHost }) => {
  await openApp(page, appHost);
  const marked = app(page).locator('.row.sel');
  await expect.poll(() => rowNames(page)).toEqual([...MOCK_NAMES].sort());
  await expect(marked).toHaveCount(0);

  for (const name of ['Docs refresh', 'Triage flaky test']) {
    await openSessionByName(page, name);
    await expect(app(page).locator('#app')).toHaveAttribute('data-screen', 'session');
    await app(page).getByRole('button', { name: 'Back to sessions' }).click();
    await expect(marked).toHaveCount(1);
    await expect(marked.locator('.n')).toHaveText(name);
  }
});

test('an empty repo still shows its header and "+"', async ({ page, appHost }) => {
  // A worktree whose tabs are all shells has no sessions, so its repo shows no rows.
  const shellOnly = { ...rowLike('main', { id: '00000000-0000-4000-8000-0000000000D2', name: 'Shell only', agoMinutes: 0 }), sessions: [] };
  const scenario = mockWith({
    before: [
      group('repo:00000000-0000-4000-8000-0000000000A4', 'acme-docs', 'repo', [shellOnly.id]),
      group('scratch', 'Scratch', 'scratch', []),
    ],
    after: [group('provider:acme-hosted', 'acme-hosted', 'provider', [])],
    rows: [shellOnly],
  });
  await openApp(page, appHost, { scenario });
  // Last, after every repo with rows; the empty scratch and provider groups are not shown.
  await expect.poll(() => shownOutline(page)).toEqual([...expectedOutline(MOCK), ['acme-docs', []]]);
  await expect(app(page).getByRole('button', { name: 'acme-docs', exact: true })).toBeVisible();
  await expect(app(page).getByRole('button', { name: 'New session in acme-docs' })).toBeVisible();
});

// --- the live list ----------------------------------------------------------------------
//
// The 30 s age refresh has no test here: it would cost a real 31 s wait per run, and `useNow`
// (ui/now.ts) has its own tests.

/**
 * `scenario` with each row of `rows` in place of the row with its ID.
 * @param {{ layout: any[], rows: any[] }} scenario
 * @param {any[]} rows
 */
function withRows(scenario, rows) {
  const byID = new Map(rows.map((r) => [r.id, r]));
  return { ...scenario, rows: scenario.rows.map((r) => byID.get(r.id) ?? r) };
}

test('a status change moves the row and its repo to the top', async ({ page, appHost }) => {
  await openApp(page, appHost);
  const before = expectedOutline(MOCK);
  await expect.poll(() => shownOutline(page)).toEqual(before);
  // The last row of the last repo, as the mock's "A status changes now" picks it.
  const [lastRepo, lastRows] = before[before.length - 1];
  const last = mockRow(lastRows[lastRows.length - 1]);
  const changed = { ...last, sessions: last.sessions.map((/** @type {any} */ s) => ({ ...s, status: { chip: 'idle', agoMinutes: 0 } })) };

  await hostCall(page, 'emit', 'sessions.changed', { rows: [changed], removedRowIDs: [] });
  const after = expectedOutline(withRows(MOCK, [changed]));
  expect(after[0][0]).toBe(lastRepo);
  expect(after[0][1][0]).toBe(last.name);
  await expect.poll(() => shownOutline(page)).toEqual(after);
  const top = app(page).locator('.row').first();
  await expect(top.locator('.t')).toHaveText('now');
  await expect(top.locator('.sr')).toHaveText('Idle');
});

test('removedRowIDs removes the row', async ({ page, appHost }) => {
  await openApp(page, appHost);
  await expect.poll(() => shownOutline(page)).toEqual(expectedOutline(MOCK));
  const login = mockRow('Login redirect fix');
  await hostCall(page, 'emit', 'sessions.changed', { rows: [], removedRowIDs: [login.id] });
  await expect.poll(() => shownOutline(page)).toEqual(expectedOutline({ ...MOCK, rows: MOCK.rows.filter((/** @type {any} */ r) => r.id !== login.id) }));

  // The laptop removes the rest of acme-web's rows, and keeps its group: the repo goes last,
  // header only, with its "+".
  const web = MOCK.layout.find((/** @type {any} */ g) => g.name === 'acme-web');
  const layout = MOCK.layout.map((/** @type {any} */ g) => (g === web ? { ...g, rows: [] } : g));
  await hostCall(page, 'emit', 'sessions.changed', {
    layout, rows: [], removedRowIDs: web.rows.map((/** @type {any} */ p) => p.id).filter((/** @type {string} */ id) => id !== login.id),
  });
  const rest = expectedOutline(MOCK).filter(([repo]) => repo !== 'acme-web');
  await expect.poll(() => shownOutline(page)).toEqual([...rest, ['acme-web', []]]);
  await expect(app(page).getByRole('button', { name: 'New session in acme-web' })).toBeVisible();
});

test('rows that follow a snapshot with more appear', async ({ page, appHost }) => {
  await openApp(page, appHost, { channel: 'down' });
  // Every other row waits for a later event; the snapshot's layout places them all.
  const laterIDs = MOCK.rows.filter((/** @type {any} */ _, /** @type {number} */ i) => i % 2 === 1).map((/** @type {any} */ r) => r.id);
  await page.evaluate((later) => {
    /** @type {any} */ (window).__host.setReply('sessions.subscribe', (/** @type {any} */ _params, /** @type {any} */ state) => ({
      result: {
        stream: state.stream, seq: state.seq, replayed: false, layout: state.layout,
        rows: state.rows.filter((/** @type {any} */ r) => !later.includes(r.id)), omittedRows: 0, more: true,
      },
    }));
  }, laterIDs);
  await hostCall(page, 'setChannel', true);
  const first = { ...MOCK, rows: MOCK.rows.filter((/** @type {any} */ r) => !laterIDs.includes(r.id)) };
  await expect.poll(() => shownOutline(page)).toEqual(expectedOutline(first));

  await hostCall(page, 'emit', 'sessions.changed', {
    rows: MOCK.rows.filter((/** @type {any} */ r) => laterIDs.includes(r.id)), removedRowIDs: [],
  });
  await expect.poll(() => shownOutline(page)).toEqual(expectedOutline(MOCK));
});
