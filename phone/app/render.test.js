// Tests what App (src/App.tsx) renders again when the state changes. esbuild bundles App for
// Node with the screen's components swapped for probes that count their renders and draw
// nothing, and React DOM's development build runs it under `act`. Since nothing draws, React
// needs no document: a stand-in for the element it mounts into is enough, and App's `#app` is
// a stand-in that records what App writes to it.
//
// React stays outside the bundle, loaded by Node from `node_modules`. Bundled, `act` cannot
// reach Node's timers and waits on a MessageChannel per call instead, whose open ports keep the
// test process from exiting.
//
// What the screens draw is the end-to-end tests' job (app/test/e2e/), which run the committed
// bundle in a browser.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { build } from 'esbuild';

const APP = fileURLToPath(new URL('.', import.meta.url));
const require = createRequire(import.meta.url);

/** The components App draws the screen with, each swapped for a probe of the same name. */
const PROBED = ['SessionScreen', 'SessionsList', 'SheetHost', 'Toast'];
const PROBED_PATH = new RegExp(`/(${PROBED.join('|')})\\.tsx$`);

/** What the bundle exports to the test. */
const ENTRY = `
export { act, createElement } from 'react';
export { createRoot } from 'react-dom/client';
export { App } from './src/App.tsx';
export { AppContext } from './src/state/context.tsx';
export { createStore } from './src/state/store.ts';
export { renders } from 'probe:renders';
`;

/** @type {import('esbuild').Plugin} */
const probes = {
  name: 'probes',
  setup(b) {
    // React, React DOM and the JSX runtime, by file URL, so the bundle and React DOM share one React.
    b.onResolve({ filter: /^react(?:-dom)?(?:\/|$)/ }, (args) => ({
      path: pathToFileURL(require.resolve(args.path)).href, external: true,
    }));
    b.onResolve({ filter: /^probe:renders$/ }, () => ({ path: 'renders', namespace: 'probe' }));
    b.onResolve({ filter: PROBED_PATH }, (args) => {
      if (!args.importer.endsWith(`${sep}App.tsx`)) return undefined;
      return { path: /** @type {RegExpExecArray} */ (PROBED_PATH.exec(args.path))[1], namespace: 'probe' };
    });
    b.onLoad({ filter: /.*/, namespace: 'probe' }, (args) => {
      if (args.path === 'renders') return { contents: 'export const renders = {};', loader: 'js' };
      const name = args.path;
      return {
        contents: `import { renders } from 'probe:renders';
export function ${name}() { renders.${name} = (renders.${name} ?? 0) + 1; return null; }`,
        loader: 'js',
      };
    });
  },
};

/** Bundles App with the probes, and imports the bundle. */
async function loadApp() {
  const result = await build({
    stdin: { contents: ENTRY, resolveDir: APP, loader: 'js', sourcefile: 'render-entry.js' },
    absWorkingDir: APP,
    bundle: true,
    platform: 'node',
    format: 'esm',
    jsx: 'automatic',
    loader: { '.css': 'text' },
    write: false,
    plugins: [probes],
    logLevel: 'silent',
  });
  const dir = mkdtempSync(join(tmpdir(), 'tbd-phone-app-render-'));
  try {
    const file = join(dir, 'render.mjs');
    writeFileSync(file, /** @type {import('esbuild').OutputFile[]} */ (result.outputFiles)[0].text);
    return await import(pathToFileURL(file).href);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/** The element React mounts into: what React DOM reads of one that never holds a node. */
function container() {
  const ignore = () => {};
  /** @type {Record<string, unknown>} */
  const doc = { nodeType: 9, activeElement: null, body: null, addEventListener: ignore, removeEventListener: ignore };
  doc.defaultView = { document: doc, HTMLIFrameElement: class {} };
  return {
    nodeType: 1, nodeName: 'DIV', tagName: 'DIV', namespaceURI: 'http://www.w3.org/1999/xhtml', ownerDocument: doc,
    textContent: '', addEventListener: ignore, removeEventListener: ignore,
  };
}

/** `#app` as App uses it: its `data-screen`, and the variables set on its style, in order. */
function appRoot() {
  /** @type {Array<[string, string]>} */
  const set = [];
  const setProperty = (/** @type {string} */ name, /** @type {string} */ value) => { set.push([name, value]); };
  return { dataset: /** @type {Record<string, string>} */ ({}), style: { setProperty }, set };
}

const ENV = {
  safeArea: { top: 47, right: 0, bottom: 34, left: 0 },
  viewport: { width: 390, height: 844, offsetTop: 0, offsetLeft: 0, scale: 1 },
  layout: { width: 390, height: 844 },
  colorScheme: 'light',
};

test('an env message sets only the layout variables it changes, and renders none of the screen', async (t) => {
  // React DOM reads `window.event` to rank an update; Node has no window.
  Object.assign(globalThis, { window: {}, IS_REACT_ACT_ENVIRONMENT: true });
  const errors = [];
  t.mock.method(console, 'error', (...args) => { errors.push(args.join(' ')); });
  const { act, createElement, createRoot, App, AppContext, createStore, renders } = await loadApp();

  const store = createStore();
  store.update((s) => ({ ...s, conn: { ...s.conn, up: true, subscribed: true } }));
  const root = appRoot();
  const react = createRoot(container());
  await act(async () => {
    react.render(createElement(AppContext.Provider, { value: { store, actions: {} } }, createElement(App, { root })));
  });
  assert.deepEqual(renders, { SessionsList: 1, SheetHost: 1, Toast: 1 });
  assert.equal(root.dataset.screen, 'sessions');
  assert.deepEqual(Object.fromEntries(root.set), {
    '--safe-top': '0px', '--safe-right': '0px', '--safe-bottom': '0px', '--safe-left': '0px', '--dock-pad': '0px',
  });

  // An env message, and one a frame later as the keyboard rises. Each writes only the variables
  // whose values it changed: the first the insets, the second the keyboard's alone.
  /** @type {Array<Array<[string, string]>>} */
  const writes = [];
  for (const height of [844, 600]) {
    const before = root.set.length;
    await act(async () => {
      store.update((s) => ({ ...s, env: { ...ENV, viewport: { ...ENV.viewport, height } } }));
    });
    writes.push(root.set.slice(before));
  }
  assert.deepEqual(renders, { SessionsList: 1, SheetHost: 1, Toast: 1 });
  assert.deepEqual(writes, [
    [['--safe-top', '47px'], ['--safe-bottom', '34px'], ['--dock-pad', '34px']],
    [['--dock-pad', '244px']],
  ]);
  // The last one lifts the dock over the keyboard.
  assert.deepEqual(Object.fromEntries(root.set), {
    '--safe-top': '47px', '--safe-right': '0px', '--safe-bottom': '34px', '--safe-left': '0px', '--dock-pad': '244px',
  });

  // A change App does read still renders the screen: the probes count.
  await act(async () => {
    store.update((s) => ({ ...s, ui: { ...s.ui, route: { screen: 'session', ref: { kind: 'local', terminalID: 'T1' } } } }));
  });
  assert.equal(root.dataset.screen, 'session');
  assert.deepEqual(renders, { SessionsList: 1, SessionScreen: 1, SheetHost: 2, Toast: 2 });

  await act(async () => { react.unmount(); });
  assert.deepEqual(errors, []);
});
