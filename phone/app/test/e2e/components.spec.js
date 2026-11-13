// The components alone in the browser, for what the fake laptop cannot bring about: a request
// that ends `superseded`. The client supersedes only a state request still unanswered at a channel
// up (`STATE_METHODS` in `src/client/client.ts`), and reads a laptop's `superseded` as
// `bad_reply`, so no profiles or providers load and no answer the fake laptop gets ends that way.
// The actions take one all the same, and these tests bring it:
// - a sheet or menu that needs the profiles, and the New sheet's remote form, whose load ends
//   superseded loads again while it shows, so its spinner always means a load on its way, and
//   only once for each load that ends so;
// - choices that come back as an answer ends superseded wait, as they do after any change.
//
// esbuild bundles the real components, store and actions for the browser, with a client in the
// page whose requests the test settles (`harness` below), and the page runs it on its own, with
// no loader, no laptop and no stylesheet: what is tested here is what the components ask for and
// when they hold, not their look.

import { fileURLToPath } from 'node:url';

import { expect, test } from '@playwright/test';
import { build } from 'esbuild';

/** @typedef {import('@playwright/test').Page} Page */

/** `phone/app/`, the bundle's working directory. */
const APP = fileURLToPath(new URL('../../', import.meta.url));
/** `TAP_GUARD_MS` (src/ui/tapGuard.ts) and Dock.tsx's `OPENING_MS`. */
const TAP_GUARD_MS = 500;
const OPENING_MS = 1000;

const REF = { kind: 'local', terminalID: 'T-R' };
const CAN = { available: true };
const PERSONAL = { id: 'P-personal', name: 'Personal', kind: 'oauth', isDefault: true };
const WORK = { id: 'P-work', name: 'acme-work', kind: 'oauth', isDefault: false };
const PROFILES = [PERSONAL, WORK];
const SESSION = {
  ref: REF, agent: 'claude', tabName: 'Claude', status: { chip: 'waitingForYou', changedAt: 1 }, profileID: WORK.id, profileName: WORK.name,
  model: 'opus', capabilities: { transcript: CAN, send: CAN, answer: CAN, switchProfile: CAN, fork: CAN, model: CAN },
};
const SNAPSHOT = {
  stream: 's1', seq: 10, replayed: false, omittedRows: 0, more: false,
  rows: [{ id: 'W1', kind: 'worktree', name: 'Checkout v2', remote: false, statusChangedAt: 1, sessions: [SESSION] }],
  layout: [{ id: 'repo:R1', kind: 'repo', name: 'acme', rows: [{ id: 'W1', depth: 0 }] }],
};
const QUESTION = {
  id: 'q1', kind: 'question', toolName: 'AskUserQuestion', targetTruncated: false, allowAlways: false,
  questions: [{ header: 'Tests', text: 'Add a test?', multiSelect: false, options: [{ label: 'Yes, add the test' }, { label: 'No, this is enough' }] }],
};

/**
 * The page's entry: `harness.start()` renders the session screen's menus, dock and sheets over
 * the real store and actions, the session open with its transcript, and the client in the page
 * keeps every request until the test settles it.
 */
const ENTRY = `
import { createRoot } from 'react-dom/client';
import { createActions } from './src/actions/index.ts';
import { AppError, SUPERSEDED_TEXT } from './src/client/client.ts';
import { Dock } from './src/dock/Dock.tsx';
import { Menus } from './src/menus/Menus.tsx';
import { SheetHost } from './src/sheets/SheetHost.tsx';
import { AppContext, useAppState } from './src/state/context.tsx';
import { findSession } from './src/state/route.ts';
import { applySnapshot } from './src/state/sessionsData.ts';
import { createStore, initialState } from './src/state/store.ts';

const sent = [];
let actions = null;

function Screen() {
  const route = useAppState((s) => s.ui.route);
  const sessions = useAppState((s) => s.sessions);
  const found = route.screen === 'session' ? findSession(sessions, route.ref) : null;
  return (
    <>
      {found !== null && <Menus session={found.session} />}
      {found !== null && <Dock session={found.session} />}
      <SheetHost />
    </>
  );
}

/** The oldest request of \`method\` still waiting for its reply. */
function waiting(method) {
  const found = sent.find((s) => s.method === method && !s.settled);
  if (found === undefined) throw new Error('no ' + method + ' is waiting');
  found.settled = true;
  return found;
}

window.harness = {
  start(snapshot, ref) {
    const client = {
      stream: null,
      lastSeq: null,
      request: (method, params) => new Promise((resolve, reject) => sent.push({ method, params, resolve, reject, settled: false })),
    };
    const store = createStore({ ...initialState(), sessions: applySnapshot(snapshot) });
    actions = createActions({ store, client, link: { openLink() {} }, routeHistory: { push() {}, replace() {}, stepBack: () => false }, now: () => Date.now() });
    actions.onChannelUp();
    waiting('sessions.subscribe').resolve({ ...snapshot, replayed: true });
    actions.openSession(ref);
    waiting('transcript.open').resolve({ resumed: false, seq: snapshot.seq, page: { items: [], reachedStart: true, omittedItems: 0 } });
    createRoot(document.getElementById('root')).render(<AppContext.Provider value={{ store, actions }}><Screen /></AppContext.Provider>);
  },
  act(name, ...args) {
    void actions[name](...args);
  },
  count(method) {
    return sent.filter((s) => s.method === method).length;
  },
  resolve(method, result) {
    waiting(method).resolve(result);
  },
  supersede(method) {
    waiting(method).reject(new AppError('superseded', SUPERSEDED_TEXT));
  },
};
`;

/** The bundle of `ENTRY`, built once. */
let bundle = '';

test.beforeAll(async () => {
  const result = await build({
    stdin: { contents: ENTRY, resolveDir: APP, loader: 'tsx', sourcefile: 'harness.tsx' },
    absWorkingDir: APP,
    bundle: true,
    format: 'iife',
    platform: 'browser',
    target: ['safari17'],
    jsx: 'automatic',
    loader: { '.css': 'text' },
    define: { 'process.env.NODE_ENV': '"production"' },
    write: false,
    logLevel: 'warning',
  });
  bundle = result.outputFiles[0].text;
});

/**
 * `page` showing the session with the harness started, and every page error kept for the test's end.
 * @param {Page} page
 * @returns {Promise<string[]>}
 */
async function started(page) {
  /** @type {string[]} */
  const problems = [];
  page.on('pageerror', (error) => problems.push(`page error: ${error.message}`));
  page.on('console', (message) => {
    if (message.type() === 'error') problems.push(`console error: ${message.text()}`);
  });
  await page.setContent('<!doctype html><html><body><div id="root"></div></body></html>');
  await page.addScriptTag({ content: bundle });
  await page.evaluate(([snapshot, ref]) => window.harness.start(snapshot, ref), [SNAPSHOT, REF]);
  return problems;
}

/**
 * How many requests of `method` the page has sent.
 * @param {Page} page
 * @param {string} method
 */
function count(page, method) {
  return page.evaluate((m) => window.harness.count(m), method);
}

/**
 * @param {Page} page
 * @param {string} name
 * @param {...unknown} args
 */
function act(page, name, ...args) {
  return page.evaluate(([n, a]) => window.harness.act(n, ...a), /** @type {const} */ ([name, args]));
}

/**
 * Ends `method`'s oldest waiting request superseded.
 * @param {Page} page
 * @param {string} method
 */
function supersede(page, method) {
  return page.evaluate((m) => window.harness.supersede(m), method);
}

/**
 * @param {Page} page
 * @param {string} method
 * @param {unknown} result
 */
function resolve(page, method, result) {
  return page.evaluate(([m, r]) => window.harness.resolve(m, r), /** @type {const} */ ([method, result]));
}

/**
 * Each opening that loads the profiles afresh, by how the test opens it.
 * @type {{ what: string, open: (page: Page) => Promise<unknown> }[]}
 */
const PROFILE_OPENINGS = [
  { what: 'the Switch account sheet', open: (page) => act(page, 'openSheet', { name: 'switch' }) },
  { what: 'the Fork sheet', open: (page) => act(page, 'openSheet', { name: 'fork' }) },
  { what: 'the account menu', open: (page) => act(page, 'openMenu', { name: 'account', askProfileID: null }) },
];

for (const { what, open } of PROFILE_OPENINGS) {
  test(`${what} loads the profiles again when its load ends superseded, once for each`, async ({ page }) => {
    const problems = await started(page);
    await open(page);
    const spinner = page.locator('[data-state="profiles-loading"]');
    await expect(spinner).toHaveCount(1);
    await expect.poll(() => count(page, 'profiles.list')).toBe(1);
    await supersede(page, 'profiles.list');
    // The spinner stays, and means a load on its way: one more, and no more than one.
    await expect.poll(() => count(page, 'profiles.list')).toBe(2);
    await expect(spinner).toHaveCount(1);
    await page.waitForTimeout(200);
    expect(await count(page, 'profiles.list')).toBe(2);
    await supersede(page, 'profiles.list');
    await expect.poll(() => count(page, 'profiles.list')).toBe(3);
    await resolve(page, 'profiles.list', { profiles: PROFILES });
    await expect(page.locator('button', { hasText: 'Personal' }).first()).toBeVisible();
    await expect(spinner).toHaveCount(0);
    await page.waitForTimeout(200);
    expect(await count(page, 'profiles.list')).toBe(3);
    expect(problems).toEqual([]);
  });
}

test('the "Restart under X?" sheet loads the profiles when the load it waits on ends superseded', async ({ page }) => {
  const problems = await started(page);
  await act(page, 'openSheet', { name: 'switch' });
  await expect.poll(() => count(page, 'profiles.list')).toBe(1);
  await resolve(page, 'profiles.list', { profiles: PROFILES });
  // It loads nothing as it opens over a loaded list.
  await act(page, 'openSheet', { name: 'switch-confirm', profileID: PERSONAL.id });
  await expect(page.getByText('Restart this session under Personal?')).toBeVisible();
  await page.waitForTimeout(200);
  expect(await count(page, 'profiles.list')).toBe(1);
  // Back on Switch account, which loads afresh, then on to the ask while that load is on its way.
  await act(page, 'openSheet', { name: 'switch' });
  await expect.poll(() => count(page, 'profiles.list')).toBe(2);
  await act(page, 'openSheet', { name: 'switch-confirm', profileID: PERSONAL.id });
  const spinner = page.locator('[data-state="profiles-loading"]');
  await expect(spinner).toHaveCount(1);
  await supersede(page, 'profiles.list');
  await expect.poll(() => count(page, 'profiles.list')).toBe(3);
  await expect(spinner).toHaveCount(1);
  await page.waitForTimeout(200);
  expect(await count(page, 'profiles.list')).toBe(3);
  await resolve(page, 'profiles.list', { profiles: PROFILES });
  await expect(page.getByText('Restart this session under Personal?')).toBeVisible();
  expect(problems).toEqual([]);
});

test("the New sheet's remote form loads the providers again when its load ends superseded, once for each", async ({ page }) => {
  const problems = await started(page);
  await act(page, 'openSheet', { name: 'new', repoID: 'R1', repoName: 'acme' });
  await page.getByRole('button', { name: 'Remote session' }).click();
  const spinner = page.locator('[data-state="providers-loading"]');
  await expect(spinner).toHaveCount(1);
  await expect.poll(() => count(page, 'remote.providers')).toBe(1);
  await supersede(page, 'remote.providers');
  await expect.poll(() => count(page, 'remote.providers')).toBe(2);
  await expect(spinner).toHaveCount(1);
  await page.waitForTimeout(200);
  expect(await count(page, 'remote.providers')).toBe(2);
  await resolve(page, 'remote.providers', { providers: [] });
  await expect(page.getByText('This laptop has no remote providers.')).toBeVisible();
  // The local form loads nothing, and the remote one loads afresh when it shows again.
  await page.getByRole('button', { name: 'Local worktree' }).click();
  await page.waitForTimeout(200);
  expect(await count(page, 'remote.providers')).toBe(2);
  await page.getByRole('button', { name: 'Remote session' }).click();
  await expect.poll(() => count(page, 'remote.providers')).toBe(3);
  // A superseded load while the local form shows starts nothing.
  await page.getByRole('button', { name: 'Local worktree' }).click();
  await supersede(page, 'remote.providers');
  await page.waitForTimeout(200);
  expect(await count(page, 'remote.providers')).toBe(3);
  expect(problems).toEqual([]);
});

test('choices that come back as an answer ends superseded wait at first, as after any change', async ({ page }) => {
  const problems = await started(page);
  await act(page, 'onEvent', { event: 'prompt.changed', seq: 11, data: { session: REF, prompts: [QUESTION] } });
  const yes = page.locator('button.opt', { hasText: 'Yes, add the test' });
  const no = page.locator('button.opt', { hasText: 'No, this is enough' });
  // Past the hold of a card that has just come.
  await page.waitForTimeout(OPENING_MS + TAP_GUARD_MS);
  await expect(yes).toBeEnabled();
  await yes.click();
  await expect.poll(() => count(page, 'prompt.answer')).toBe(1);
  await expect(no).toBeDisabled();
  // Long after the tap, so only the answer on its way holds the choices.
  await page.waitForTimeout(TAP_GUARD_MS + 200);
  // The answer ends superseded: the card is open again, with no refusal, and its choices wait.
  const after = await page.evaluate(async () => {
    window.harness.supersede('prompt.answer');
    await new Promise((done) => setTimeout(done, 100));
    const options = [...document.querySelectorAll('button.opt')];
    return { options: options.length, enabled: options.filter((b) => !(/** @type {HTMLButtonElement} */ (b).disabled)).length, refusals: document.querySelectorAll('.refusal').length };
  });
  expect(after).toEqual({ options: 3, enabled: 0, refusals: 0 });
  await expect(no).toBeEnabled();
  await no.click();
  await expect.poll(() => count(page, 'prompt.answer')).toBe(2);
  expect(problems).toEqual([]);
});
