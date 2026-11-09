// Tests what the "Restart this session under X?" sheet (`ConfirmSheet` in ProfileSheets.tsx)
// draws where the end-to-end tests cannot take it: while the profiles the sheet slice holds do not
// hold the profile it asks about, because no list is loaded or the one loaded lacks it. Its title
// must be there all the same, since it names the dialog (`aria-labelledby` in SheetHost.tsx).
//
// esbuild bundles the sheet for Node as CommonJS, with the store hooks it reads
// (`state/context.tsx`) swapped for a stub that reads a state the test sets, and React DOM's server
// renderer draws it as markup. React stays outside the bundle, so the sheet and the renderer share
// one React. The sheet's look is the end-to-end tests' job (app/test/e2e/actions.spec.js).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { build } from 'esbuild';
import type { Plugin } from 'esbuild';

import type { PhoneCapability, PhoneProfile, PhoneSession } from '../protocol/types.ts';
import { emptySheets } from '../state/sheets.ts';
import type { ProfilesLoad } from '../state/sheets.ts';
import { initialState } from '../state/store.ts';
import type { AppState } from '../state/store.ts';

/** `phone/app/`, the bundle's working directory. */
const APP = fileURLToPath(new URL('../../', import.meta.url));
const require = createRequire(import.meta.url);

/** What the bundle exports to the test. */
const ENTRY = `
export { createElement } from 'react';
export { renderToStaticMarkup } from 'react-dom/server';
export { ConfirmSheet } from './src/sheets/ProfileSheets.tsx';
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

const stub: Plugin = {
  name: 'stub-context',
  setup(b) {
    // React, React DOM and the JSX runtime, by absolute path, so the bundle and the renderer share one React.
    b.onResolve({ filter: /^react(?:-dom)?(?:\/|$)/ }, (args) => ({ path: require.resolve(args.path), external: true }));
    b.onResolve({ filter: /^stub:context$|\/state\/context\.tsx$/ }, () => ({ path: 'context', namespace: 'stub' }));
    b.onLoad({ filter: /.*/, namespace: 'stub' }, () => ({ contents: STUB, loader: 'js' }));
  },
};

interface Bundle {
  createElement(type: unknown, props: object): unknown;
  renderToStaticMarkup(element: unknown): string;
  ConfirmSheet: unknown;
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
