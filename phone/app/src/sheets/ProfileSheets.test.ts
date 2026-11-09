// Tests what the session's sheets and the account menu draw, as markup, where the end-to-end tests
// cannot take them or cannot see the difference:
// - the "Restart this session under X?" sheet (`ConfirmSheet` in ProfileSheets.tsx) while the
//   profiles the sheet slice holds do not hold the profile it asks about, because no list is
//   loaded or the one loaded lacks it. Its title must be there all the same, since it names the
//   dialog (`aria-labelledby` in SheetHost.tsx);
// - the ask that sheet and the account menu share (`RestartAsk`): the same words and the same
//   buttons disabled, in every state of the session, and the failure only in the ask it was made in;
// - the session menu sheet's rows (`MenuSheet`): no empty line for a reason the laptop did not give.
//
// esbuild bundles them for Node as CommonJS, with the store hooks they read (`state/context.tsx`)
// swapped for a stub that reads a state the test sets, and the tap guard (`ui/tapGuard.ts`) for one
// that never holds, so the markup shows what the rules disable; React DOM's server renderer draws
// them. React stays outside the bundle, so the components and the renderer share one React. Their
// look, and the tap guard, are the end-to-end tests' job (app/test/e2e/actions.spec.js).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { build } from 'esbuild';
import type { Plugin } from 'esbuild';

import type { PhoneCapability, PhoneProfile, PhoneRow, PhoneSession } from '../protocol/types.ts';
import { refKey } from '../protocol/wire.ts';
import { emptySheets } from '../state/sheets.ts';
import type { ProfilesLoad, SheetsState } from '../state/sheets.ts';
import { emptyRecord, initialState } from '../state/store.ts';
import type { AppState, MenuState } from '../state/store.ts';

/** `phone/app/`, the bundle's working directory. */
const APP = fileURLToPath(new URL('../../', import.meta.url));
const require = createRequire(import.meta.url);

/** What the bundle exports to the test. */
const ENTRY = `
export { createElement } from 'react';
export { renderToStaticMarkup } from 'react-dom/server';
export { ConfirmSheet } from './src/sheets/ProfileSheets.tsx';
export { MenuSheet } from './src/sheets/MenuSheet.tsx';
export { Menus } from './src/menus/Menus.tsx';
export { setStub } from 'stub:context';
`;

/** The store hooks, reading the state and the actions `setStub` was last given. */
const STUB = `
let state = null;
let actions = null;
export const AppContext = null;
export function setStub(s, a) { state = s; actions = a; }
export function useAppState(select) { return select(state); }
export function useActions() { return actions; }
`;

/** The tap guard, never holding. */
const NO_HOLD = `
export const TAP_GUARD_MS = 500;
export function useChangeHold() { return false; }
export function useUncoverHold() { return false; }
`;

const stub: Plugin = {
  name: 'stub-context',
  setup(b) {
    // React, React DOM and the JSX runtime, by absolute path, so the bundle and the renderer share one React.
    b.onResolve({ filter: /^react(?:-dom)?(?:\/|$)/ }, (args) => ({ path: require.resolve(args.path), external: true }));
    b.onResolve({ filter: /^stub:context$|\/state\/context\.tsx$/ }, () => ({ path: 'context', namespace: 'stub' }));
    b.onResolve({ filter: /\/ui\/tapGuard\.ts$/ }, () => ({ path: 'tapGuard', namespace: 'stub' }));
    b.onLoad({ filter: /.*/, namespace: 'stub' }, (args) => ({ contents: args.path === 'tapGuard' ? NO_HOLD : STUB, loader: 'js' }));
  },
};

interface Bundle {
  createElement(type: unknown, props: object): unknown;
  renderToStaticMarkup(element: unknown): string;
  ConfirmSheet: unknown;
  MenuSheet: unknown;
  Menus: unknown;
  setStub(state: AppState, actions: object): void;
}

/** Bundles the sheet with the stub, and loads the bundle. */
async function loadBundle(): Promise<Bundle> {
  const result = await build({
    stdin: { contents: ENTRY, resolveDir: APP, loader: 'js', sourcefile: 'confirm-entry.js' },
    absWorkingDir: APP,
    bundle: true,
    platform: 'node',
    format: 'cjs',
    jsx: 'automatic',
    loader: { '.css': 'text' },
    write: false,
    plugins: [stub],
    logLevel: 'silent',
  });
  const dir = mkdtempSync(join(tmpdir(), 'tbd-phone-confirm-sheet-'));
  try {
    const file = join(dir, 'confirm.cjs');
    writeFileSync(file, result.outputFiles[0]!.text);
    return require(file) as Bundle;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const bundle = await loadBundle();

const CAN: PhoneCapability = { available: true };
const PERSONAL: PhoneProfile = { id: 'P-personal', name: 'Personal', kind: 'oauth', isDefault: true };
const WORK: PhoneProfile = { id: 'P-work', name: 'acme-work', kind: 'oauth', isDefault: false };
const SESSION: PhoneSession = {
  ref: { kind: 'local', terminalID: 'T-R' }, agent: 'claude', tabName: 'Review', status: { chip: 'idle', changedAt: 1 },
  profileID: WORK.id, profileName: WORK.name, model: 'opus',
  capabilities: { transcript: CAN, send: CAN, answer: CAN, switchProfile: CAN, fork: CAN, model: CAN },
};
const TITLE = 'sheet-title';

/** The markup of the sheet asking about `profileID`, with the slice's profiles at `profiles`. */
function draw(profiles: ProfilesLoad, profileID: string): string {
  bundle.setStub({ ...initialState(), sheets: { ...emptySheets(), profiles } }, { openSheet() {}, switchProfile() {}, fork() {} });
  return bundle.renderToStaticMarkup(
    bundle.createElement(bundle.ConfirmSheet, { session: SESSION, profileID, titleID: TITLE, held: false, failure: null }),
  );
}

/** Every element the markup gives the ID `TITLE`, as its opening tag and text. */
function titles(markup: string): string[] {
  return [...markup.matchAll(new RegExp(`<(\\w+) id="${TITLE}">([^<]*)<`, 'g'))].map((m) => `${m[1]}: ${m[2]}`);
}

test('the sheet asking about a loaded profile is named by its question', () => {
  assert.deepEqual(titles(draw({ phase: 'loaded', profiles: [PERSONAL, WORK] }, PERSONAL.id)), ['h3: Restart this session under Personal?']);
});

test('with the profile not in the slice, the sheet still has its title, whatever the load', () => {
  for (const load of [
    { phase: 'loaded', profiles: [WORK] },
    { phase: 'loading', id: 2 },
    { phase: 'failed', message: 'TBD could not read its profiles.' },
    { phase: 'idle' },
  ] satisfies ProfilesLoad[]) {
    const markup = draw(load, PERSONAL.id);
    assert.deepEqual(titles(markup), ['h3: Switch account'], load.phase);
    // Nothing to ask about: only Cancel.
    assert.equal(markup.includes('Restart'), false, load.phase);
    assert.match(markup, />Cancel<\/button>/, load.phase);
  }
});

// MARK: - The ask, in the menu and in the sheet

const ACTIONS = { openSheet() {}, openMenu() {}, closeMenu() {}, closeSheet() {}, switchProfile() {}, fork() {}, loadProfiles() {} };

/** The markup of the account menu over `session`, asking about `profileID`, with `sheets` laid over loaded profiles. */
function drawMenu(session: PhoneSession, profileID: string, sheets: Partial<SheetsState> = {}, menu?: MenuState): string {
  const shown: MenuState = menu ?? { name: 'account', askProfileID: profileID };
  const state = initialState();
  bundle.setStub(
    { ...state, sheets: { ...emptySheets(), profiles: { phase: 'loaded', profiles: [PERSONAL, WORK] }, ...sheets }, ui: { ...state.ui, menu: shown } },
    ACTIONS,
  );
  return bundle.renderToStaticMarkup(bundle.createElement(bundle.Menus, { session }));
}

/** The markup of the switch-confirm sheet over `session`, asking about `profileID`, with `sheets` laid over loaded profiles. */
function drawSheet(session: PhoneSession, profileID: string, sheets: Partial<SheetsState> = {}, failure: string | null = null): string {
  bundle.setStub({ ...initialState(), sheets: { ...emptySheets(), profiles: { phase: 'loaded', profiles: [PERSONAL, WORK] }, ...sheets } }, ACTIONS);
  return bundle.renderToStaticMarkup(
    bundle.createElement(bundle.ConfirmSheet, { session, profileID, titleID: TITLE, held: false, failure }),
  );
}

/** What an ask's markup says and gates: its text, tags aside, and each button with whether it is disabled. */
function asked(markup: string): { text: string; buttons: string[] } {
  const buttons = [...markup.matchAll(/<button[^>]*?( disabled="")?>(?:<svg.*?<\/svg>)?([^<]*)<\/button>/g)].map((m) => `${m[2]}${m[1] === undefined ? '' : ' (disabled)'}`);
  const text = markup.replace(/<button.*?<\/button>/g, ' ').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
  return { text, buttons };
}

const OFF = (reason?: string): PhoneCapability => (reason === undefined ? { available: false } : { available: false, reason });

test('the account menu and the switch-confirm sheet ask the same and disable the same buttons, whatever the session', () => {
  const states: Array<[string, PhoneSession, string, Partial<SheetsState>]> = [
    ['idle', SESSION, PERSONAL.id, {}],
    ['working', { ...SESSION, status: { chip: 'working', changedAt: 1 } }, PERSONAL.id, {}],
    ['parked', { ...SESSION, status: { chip: 'parked', changedAt: 1 } }, PERSONAL.id, {}],
    ['no fork, with a reason', { ...SESSION, capabilities: { ...SESSION.capabilities, fork: OFF('The laptop cannot fork this session.') } }, PERSONAL.id, {}],
    ['no fork, no reason', { ...SESSION, capabilities: { ...SESSION.capabilities, fork: OFF() } }, PERSONAL.id, {}],
    ['moved to the profile asked about', { ...SESSION, profileID: PERSONAL.id, profileName: PERSONAL.name }, PERSONAL.id, {}],
    ['acting', SESSION, PERSONAL.id, { acting: Object.assign(emptyRecord<'fork'>(), { [refKey(SESSION.ref)]: 'fork' as const }) }],
  ];
  // A session that cannot switch has no account menu at all (`Menus`), so that state is the sheet's alone.
  const seen = new Set<string>();
  for (const [name, session, profileID, sheets] of states) {
    const inMenu = asked(drawMenu(session, profileID, sheets));
    const inSheet = asked(drawSheet(session, profileID, sheets));
    // The menu adds its label; the rest is the ask.
    assert.equal(inMenu.text, `Account for this session ${inSheet.text}`, name);
    assert.deepEqual(inMenu.buttons, inSheet.buttons, name);
    seen.add(JSON.stringify(inSheet.buttons));
  }
  // The states cover every way the two buttons can be gated, and a parked session's Move.
  assert.deepEqual([...seen].sort(), [
    '["Move","Fork into a new tab","Cancel"]',
    '["Restart (disabled)","Fork into a new tab (disabled)","Cancel"]',
    '["Restart (disabled)","Fork into a new tab","Cancel"]',
    '["Restart","Fork into a new tab (disabled)","Cancel"]',
    '["Restart","Fork into a new tab","Cancel"]',
  ]);
});

test('for a parked session the ask asks to move it, and says it stays parked; a running one is asked to restart', () => {
  const parked: PhoneSession = { ...SESSION, status: { chip: 'parked', changedAt: 1 } };
  for (const markup of [drawMenu(parked, PERSONAL.id), drawSheet(parked, PERSONAL.id)]) {
    const { text, buttons } = asked(markup);
    assert.ok(text.includes('Move this session to Personal? The conversation stays. It stays parked, and wakes under the new profile.'), text);
    assert.equal(text.includes('Restart'), false, text);
    assert.deepEqual(buttons, ['Move', 'Fork into a new tab', 'Cancel']);
  }
  for (const markup of [drawMenu(SESSION, PERSONAL.id), drawSheet(SESSION, PERSONAL.id)]) {
    const { text, buttons } = asked(markup);
    assert.ok(text.includes('Restart this session under Personal? The conversation stays. Claude restarts in this tab.'), text);
    assert.deepEqual(buttons, ['Restart', 'Fork into a new tab', 'Cancel']);
  }
});

test("a failure shows in the account menu's ask only while that very menu shows, as in the sheet", () => {
  const menu: MenuState = { name: 'account', askProfileID: PERSONAL.id };
  const words = 'TBD could not copy this conversation.';
  const refusal = `<div class="refusal" role="alert">`;
  const here = drawMenu(SESSION, PERSONAL.id, { failed: { on: menu, text: words } }, menu);
  assert.ok(here.includes(refusal), here);
  assert.ok(here.includes(`<span>${words}</span>`));
  // Above the buttons, as the sheet has it.
  assert.ok(here.indexOf(refusal) < here.indexOf('>Restart<'));
  assert.ok(drawSheet(SESSION, PERSONAL.id, {}, words).indexOf(refusal) < drawSheet(SESSION, PERSONAL.id, {}, words).indexOf('>Restart<'));
  // An ask for the same profile opened since is another menu, and shows none of it.
  const since = drawMenu(SESSION, PERSONAL.id, { failed: { on: { ...menu }, text: words } }, menu);
  assert.equal(since.includes(refusal), false, since);
  assert.equal(drawMenu(SESSION, PERSONAL.id, {}, menu).includes(refusal), false);
});

// MARK: - The session menu sheet

const ROW: PhoneRow = { id: 'W1', kind: 'worktree', name: 'Checkout v2', remote: false, statusChangedAt: 1, sessions: [SESSION] };

/** The markup of the session menu sheet over `session`. */
function drawMenuSheet(session: PhoneSession): string {
  bundle.setStub(initialState(), ACTIONS);
  return bundle.renderToStaticMarkup(bundle.createElement(bundle.MenuSheet, { row: { ...ROW, sessions: [session] }, session, titleID: TITLE }));
}

test("a row the session cannot use shows the laptop's reason, and no empty line when it gave none", () => {
  const withReason = drawMenuSheet({ ...SESSION, capabilities: { ...SESSION.capabilities, fork: OFF('Not available for remote sessions.') } });
  assert.match(withReason, /<button class="mi" type="button" disabled="">.*?Fork<small>Not available for remote sessions\.<\/small>/);
  for (const fork of [OFF(), OFF('')]) {
    const markup = drawMenuSheet({ ...SESSION, capabilities: { ...SESSION.capabilities, fork } });
    assert.equal(markup.includes('<small></small>'), false, markup);
    assert.match(markup, /<button class="mi" type="button" disabled="">.*?<span>Fork<\/span>/);
  }
  // An available row keeps its line.
  assert.match(drawMenuSheet(SESSION), /<span>Fork<small>Copy this conversation into a new tab<\/small><\/span>/);
});

test("the Switch account row says a running session restarts in its tab and a parked one stays parked", () => {
  assert.match(drawMenuSheet(SESSION), /<span>Switch account<small>Now acme-work\. Restarts in this tab\.<\/small><\/span>/);
  const parked = drawMenuSheet({ ...SESSION, status: { chip: 'parked', changedAt: 1 } });
  assert.match(parked, /<span>Switch account<small>Now acme-work\. Stays parked\.<\/small><\/span>/);
});
