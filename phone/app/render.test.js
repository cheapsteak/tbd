// Tests what App (src/App.tsx) renders again when the state changes, and what the session
// screen (src/screens/SessionScreen.tsx) shows while its session's row has not arrived. esbuild
// bundles both for Node with the components they draw with swapped for probes that count their
// renders and draw nothing, and React DOM's development build runs them under `act`. React
// draws into a stand-in for the element it mounts into: its document makes elements that keep
// only their attributes and children, and it keeps the listeners React adds to it, so a test can
// deliver a click the way the browser does. App's `#app` is a stand-in that records what App
// writes to it.
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
import { basename, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { build } from 'esbuild';

const APP = fileURLToPath(new URL('.', import.meta.url));
const require = createRequire(import.meta.url);

/**
 * The components each file draws with, by the file's name, each swapped for a probe of the same
 * name where that file imports it: App's screens, and the session screen's parts.
 */
const PROBED = new Map([
  ['App.tsx', ['SessionScreen', 'SessionsList', 'SheetHost', 'Toast']],
  ['SessionScreen.tsx', ['SessionHeader', 'StatusBand', 'TabStrip', 'CodexNote', 'TranscriptView', 'Dock', 'Menus']],
]);
const PROBED_PATH = new RegExp(`/(${[...PROBED.values()].flat().join('|')})\\.tsx$`);

/** What the bundle exports to the test. */
const ENTRY = `
export { act, createElement } from 'react';
export { createRoot } from 'react-dom/client';
export { App } from './src/App.tsx';
export { SessionScreen } from './src/screens/SessionScreen.tsx';
export { createActions } from './src/actions/index.ts';
export { AppContext } from './src/state/context.tsx';
export { createStore, SESSIONS_ROUTE } from './src/state/store.ts';
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
      const name = /** @type {RegExpExecArray} */ (PROBED_PATH.exec(args.path))[1];
      if (!PROBED.get(basename(args.importer))?.includes(name)) return undefined;
      return { path: name, namespace: 'probe' };
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

const HTML = 'http://www.w3.org/1999/xhtml';

/**
 * @typedef {object} FakeElement What React DOM uses of an element, and what a test reads back.
 * @property {string} nodeName
 * @property {Map<string, string>} attributes
 * @property {FakeElement[]} childNodes
 * @property {FakeElement | null} parentNode
 * @property {Array<{ type: string, listener: (event: object) => void, capture: boolean }>} listeners
 *   The listeners added to it, which React adds to the element it mounts into.
 */

/**
 * The element React mounts into, and its document: what React DOM uses of them to draw elements
 * and to hear events. An element keeps its attributes, its children and its listeners, and
 * nothing else.
 * @returns {any}
 */
function container() {
  const ignore = () => {};
  /** @type {Record<string, unknown>} */
  const doc = { nodeType: 9, activeElement: null, body: null, addEventListener: ignore, removeEventListener: ignore };
  doc.defaultView = { document: doc, HTMLIFrameElement: class {} };
  /** @param {any} child */
  const detach = (child) => {
    const parent = child.parentNode;
    if (parent === null) return;
    parent.childNodes.splice(parent.childNodes.indexOf(child), 1);
    child.parentNode = null;
  };
  /** @param {string} nodeName @param {string} namespaceURI */
  const element = (nodeName, namespaceURI) => {
    /** @type {Map<string, string>} */
    const attributes = new Map();
    /** @type {any[]} */
    const childNodes = [];
    /** @type {FakeElement['listeners']} */
    const listeners = [];
    /** @type {any} */
    const node = {
      nodeType: 1, nodeName, tagName: nodeName, namespaceURI, ownerDocument: doc, parentNode: null, childNodes, attributes, listeners,
      textContent: '', onclick: null,
      setAttribute: (/** @type {string} */ name, /** @type {unknown} */ value) => { attributes.set(name, String(value)); },
      removeAttribute: (/** @type {string} */ name) => { attributes.delete(name); },
      getAttribute: (/** @type {string} */ name) => attributes.get(name) ?? null,
      appendChild: (/** @type {any} */ child) => node.insertBefore(child, null),
      insertBefore: (/** @type {any} */ child, /** @type {any} */ before) => {
        detach(child);
        childNodes.splice(before === null ? childNodes.length : childNodes.indexOf(before), 0, child);
        child.parentNode = node;
        return child;
      },
      removeChild: (/** @type {any} */ child) => { detach(child); return child; },
      addEventListener: (/** @type {string} */ type, /** @type {any} */ listener, /** @type {any} */ options) => {
        listeners.push({ type, listener, capture: options === true || options?.capture === true });
      },
      removeEventListener: ignore,
    };
    return node;
  };
  doc.createElement = (/** @type {string} */ tag) => element(tag.toUpperCase(), HTML);
  doc.createElementNS = (/** @type {string} */ namespaceURI, /** @type {string} */ tag) => element(tag, namespaceURI);
  return element('DIV', HTML);
}

/**
 * The first element under `node`, `node` itself included, whose attribute `name` is `value`, or null.
 * @param {FakeElement} node
 * @param {string} name
 * @param {string} value
 * @returns {FakeElement | null}
 */
function findByAttribute(node, name, value) {
  if (node.attributes.get(name) === value) return node;
  for (const child of node.childNodes) {
    const found = findByAttribute(child, name, value);
    if (found !== null) return found;
  }
  return null;
}

/**
 * Clicks `target` as the browser does, for React: the event goes to the listeners React added
 * to `root`, the capture ones first.
 * @param {FakeElement} root
 * @param {FakeElement} target
 */
function click(root, target) {
  const event = {
    type: 'click', target, button: 0, bubbles: true, cancelable: true, defaultPrevented: false, timeStamp: 0,
    preventDefault() { this.defaultPrevented = true; },
    stopPropagation() {},
  };
  for (const capture of [true, false]) {
    for (const l of root.listeners) if (l.type === 'click' && l.capture === capture) l.listener(event);
  }
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

const CAN = { available: true };

/** A worktree row with one Claude session, whose terminal is `terminalID`. */
function row(/** @type {string} */ id, /** @type {string} */ terminalID) {
  return {
    id, kind: 'worktree', name: id, remote: false, statusChangedAt: 1,
    sessions: [{
      ref: { kind: 'local', terminalID }, agent: 'claude', tabName: 'claude', status: { chip: 'idle', changedAt: 1 },
      capabilities: { transcript: CAN, send: CAN, answer: CAN, switchProfile: CAN, fork: CAN, model: CAN },
    }],
  };
}

/** Lets the promise handlers run. */
function flush() {
  return new Promise((resolve) => { setImmediate(resolve); });
}

test('a session whose row has not arrived yet shows the back button, which goes to the list', async (t) => {
  Object.assign(globalThis, { window: {}, IS_REACT_ACT_ENVIRONMENT: true });
  const errors = [];
  t.mock.method(console, 'error', (...args) => { errors.push(args.join(' ')); });
  const { act, createElement, createRoot, SessionScreen, AppContext, createActions, createStore, SESSIONS_ROUTE, renders } = await loadApp();

  // The real actions, over a client that keeps each request for the test to answer. The
  // transcript's are part 6c's, and nothing here needs them.
  const store = createStore();
  /** @type {Array<{ method: string, resolve: (result: unknown) => void }>} */
  const sent = [];
  const client = {
    stream: null, lastSeq: null,
    request: (/** @type {string} */ method) => new Promise((resolve) => { sent.push({ method, resolve }); }),
  };
  const actions = createActions({ store, client, link: { openLink: () => {} }, routeHistory: { push() {}, replace() {}, stepBack: () => false }, now: () => 0 });
  for (const name of ['openTranscript', 'closeTranscript', 'resumeTranscriptOnUp']) actions[name] = () => {};

  // The user opens W1's session. The channel drops, and the next snapshot, a new stream's, holds
  // W2 alone: W1 is placed but follows later, so the route stays on its session.
  const layout = [{ id: 'repo:R1', kind: 'repo', name: 'acme', rows: [{ id: 'W1', depth: 0 }, { id: 'W2', depth: 0 }] }];
  const ref = { kind: 'local', terminalID: 'T1' };
  actions.onChannelUp();
  sent[0].resolve({ stream: 's1', seq: 1, replayed: false, omittedRows: 0, more: false, layout, rows: [row('W1', 'T1'), row('W2', 'T2')] });
  await flush();
  actions.openSession(ref);
  actions.onChannelDown();
  actions.onChannelUp();
  sent[1].resolve({ stream: 's2', seq: 1, replayed: false, omittedRows: 0, more: true, layout, rows: [row('W2', 'T2')] });
  await flush();
  assert.deepEqual(sent.map((r) => r.method), ['sessions.subscribe', 'sessions.subscribe']);
  assert.deepEqual(store.get().ui.route, { screen: 'session', ref });

  const dom = container();
  const react = createRoot(dom);
  await act(async () => {
    react.render(createElement(AppContext.Provider, { value: { store, actions } }, createElement(SessionScreen)));
  });
  // The holding view, and none of the session screen's parts, which need the row.
  const waiting = findByAttribute(dom, 'data-state', 'session-waiting');
  assert.notEqual(waiting, null);
  assert.notEqual(findByAttribute(/** @type {FakeElement} */ (waiting), 'class', 'spin'), null);
  assert.deepEqual(renders, {});
  const back = findByAttribute(dom, 'aria-label', 'Back to sessions');
  assert.equal(back?.nodeName, 'BUTTON');

  await act(async () => { click(dom, /** @type {FakeElement} */ (back)); });
  assert.equal(store.get().ui.route, SESSIONS_ROUTE);
  assert.equal(findByAttribute(dom, 'data-state', 'session-waiting'), null);

  await act(async () => { react.unmount(); });
  assert.deepEqual(errors, []);
});
