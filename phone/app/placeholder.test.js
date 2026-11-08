// Tests the committed bundle, `Sources/TBDDaemon/Resources/phone-app/app.js`, against the
// runner's contract for a bundle (phone/loader/runner.js and runner.html): one classic script,
// UTF-8 text the loader accepts, and a script that runs with only `document` and `tbdHost`, under
// a policy that refuses code made from strings, HTML strings and injected styles. build.test.js
// shows that the committed bundle is what `npm run build:app` writes from placeholder.js.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

import { MAX_BUNDLE_TEXT } from '../loader/constants.js';

const BUNDLE = new URL('../../Sources/TBDDaemon/Resources/phone-app/app.js', import.meta.url);
const LINE = 'Connected to TBD. The phone app is not built yet.';

/**
 * Throws as a refused sink does in the runner: Trusted Types and the policy throw a TypeError.
 * @param {string} what
 * @returns {never}
 */
function refuse(what) {
  throw new TypeError(`fake runner: ${what} is refused`);
}

/** The tags the fake document makes. A script or style element, or any other, throws. */
const TAGS = new Set(['div', 'p', 'span', 'main', 'section', 'h1', 'h2', 'pre']);

/**
 * An element that offers text and children and nothing else. It cannot gain properties, so in
 * strict code a write to anything it does not offer, such as `style` or `onclick`, throws, and a
 * call to a method it does not offer, such as `setAttribute`, throws too.
 */
class FakeElement {
  /** @type {FakeElement[]} */
  #children = [];
  #text = '';

  /** @param {string} tag */
  constructor(tag) {
    this.tagName = tag.toUpperCase();
    Object.preventExtensions(this);
  }

  get children() {
    return [...this.#children];
  }

  /** @returns {string} */
  get textContent() {
    return this.#text + this.#children.map((child) => child.textContent).join('');
  }

  /** @param {unknown} value */
  set textContent(value) {
    this.#children = [];
    this.#text = String(value);
  }

  /** @param {...unknown} nodes */
  append(...nodes) {
    for (const node of nodes) this.appendChild(node);
  }

  /** @param {unknown} node */
  appendChild(node) {
    if (!(node instanceof FakeElement)) refuse('appending anything but an element (the fake has no text nodes)');
    this.#children.push(node);
    return node;
  }

  get innerHTML() {
    return refuse('innerHTML');
  }

  /** @param {unknown} _value */
  set innerHTML(_value) {
    refuse('innerHTML');
  }

  get outerHTML() {
    return refuse('outerHTML');
  }

  /** @param {unknown} _value */
  set outerHTML(_value) {
    refuse('outerHTML');
  }

  insertAdjacentHTML() {
    refuse('insertAdjacentHTML');
  }
}

class FakeDocument {
  constructor() {
    this.head = new FakeElement('head');
    this.body = new FakeElement('body');
    Object.freeze(this);
  }

  /** @param {string} tag */
  createElement(tag) {
    const name = String(tag).toLowerCase();
    if (!TAGS.has(name)) refuse(`a <${name}> element`);
    return new FakeElement(name);
  }

  write() {
    refuse('document.write');
  }
}

/** One end of a MessageChannel, recording what the app posts to the loader. */
class FakePort {
  /** @type {unknown[]} */
  posted = [];
  started = false;
  /** @type {unknown} */
  onmessage = null;

  /** @param {unknown} message */
  postMessage(message) {
    this.posted.push(message);
  }

  start() {
    this.started = true;
  }

  addEventListener() {}

  removeEventListener() {}
}

/**
 * Runs `text` as the runner starts a bundle: one classic script, with `tbdHost` defined on the
 * global as runner.js defines it, in a context that refuses code made from strings, as a policy
 * without 'unsafe-eval' does. Its only globals besides JavaScript's own are `document` and
 * `tbdHost`, so a bundle that reaches for `fetch`, `WebSocket`, `window` or storage throws.
 * @param {string} text
 */
function runInFakeRunner(text) {
  const document = new FakeDocument();
  const port = new FakePort();
  /** @type {Record<string, unknown>} */
  const global = {};
  Object.defineProperty(global, 'document', { value: document, enumerable: true });
  Object.defineProperty(global, 'tbdHost', {
    value: Object.freeze({ port, protocol: 1 }),
    writable: false,
    configurable: false,
    enumerable: false,
  });
  const context = vm.createContext(global, { codeGeneration: { strings: false, wasm: false } });
  // Copied into this realm's arrays, so `deepStrictEqual` compares only the names.
  /** @returns {string[]} */
  const names = () => Array.from(vm.runInContext('Object.getOwnPropertyNames(globalThis)', context));
  const before = new Set(names());
  new vm.Script(text, { filename: 'blob:fake-runner/app' }).runInContext(context);
  return { document, port, newGlobals: names().filter((name) => !before.has(name)) };
}

/** @returns {Buffer} */
function bundleBytes() {
  return readFileSync(BUNDLE);
}

test('the bundle is UTF-8 text within the size the loader accepts', () => {
  const bytes = bundleBytes();
  assert.ok(bytes.length > 0, 'the bundle is not empty');
  assert.ok(bytes.length <= MAX_BUNDLE_TEXT, `${bytes.length} bytes is over MAX_BUNDLE_TEXT`);
  // The loader decodes the inflated bundle exactly this way, and refuses it when this throws.
  assert.doesNotThrow(() => new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes));
});

test('the bundle parses as one classic script', () => {
  // The runner starts it from a `<script src>` with no `type="module"`, where an `import` or
  // `export` statement is a syntax error and the runner reports a `script` fault.
  assert.doesNotThrow(() => new vm.Script(bundleBytes().toString('utf8'), { filename: 'app.js' }));
});

test('the bundle shows exactly one line, and does nothing else', () => {
  const { document, port, newGlobals } = runInFakeRunner(bundleBytes().toString('utf8'));
  const shown = document.body.children;
  assert.equal(shown.length, 1);
  assert.equal(shown[0].tagName, 'P');
  assert.equal(shown[0].textContent, LINE);
  assert.equal(document.body.textContent, LINE);
  assert.deepEqual(document.head.children, [], 'no script or style added to the head');
  assert.deepEqual(port.posted, [], 'nothing sent to the loader or the laptop');
  assert.deepEqual(newGlobals, [], 'no globals defined');
});

// The run above would pass vacuously if the fake runner allowed what the real one blocks, so
// this shows that each such use fails the run. The fake throws for all of them; the real runner
// throws for most and, for an inline style or a script element, drops what it would have done.
// The fake also offers less than a browser does: it has no `style`, attributes or text nodes,
// and anything it does not offer throws as well.
test('the fake runner fails a bundle that uses what the real runner blocks', () => {
  /** @param {string} code */
  const run = (code) => runInFakeRunner(`'use strict';\n${code}`);
  /** @type {Array<[string, string]>} */
  const refused = [
    ['eval("1");', 'EvalError'],
    ['new Function("return 1");', 'EvalError'],
    ['document.body.innerHTML = "<p>x</p>";', 'TypeError'],
    ['document.createElement("p").outerHTML = "<p>x</p>";', 'TypeError'],
    ['document.body.insertAdjacentHTML("beforeend", "<p>x</p>");', 'TypeError'],
    ['document.write("<p>x</p>");', 'TypeError'],
    ['document.createElement("script");', 'TypeError'],
    ['document.createElement("style");', 'TypeError'],
    ['document.createElement("p").setAttribute("style", "color: red");', 'TypeError'],
    ['fetch("https://acme.invalid/");', 'ReferenceError'],
    ['new WebSocket("wss://acme.invalid/");', 'ReferenceError'],
    ['localStorage.getItem("acme");', 'ReferenceError'],
  ];
  for (const [code, name] of refused) {
    assert.throws(() => run(code), { name }, code);
  }

  assert.throws(() => new vm.Script('export {};'), { name: 'SyntaxError' });
  assert.throws(() => new vm.Script('import x from "./x.js";'), { name: 'SyntaxError' });

  assert.deepEqual(run('var leaked = 1;').newGlobals, ['leaked']);
  const posted = run('tbdHost.port.postMessage({ t: "app", body: {} });').port.posted;
  assert.equal(JSON.stringify(posted), '[{"t":"app","body":{}}]');
  assert.equal(run('document.body.append(document.createElement("p"));').document.body.children.length, 1);
});
