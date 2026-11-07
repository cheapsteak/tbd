// Just enough DOM to drive the loader's DOM modules in Node: a window, a document, plain
// elements, text, an iframe and a script element. Each fake records what was done to it, so a
// test can check what the code did and in which order. Events are real EventTarget events.

/** An EventTarget that counts its listeners for each event type. */
export class CountingTarget extends EventTarget {
  /** @type {Map<string, Set<unknown>>} */
  #listeners = new Map();

  /**
   * @param {string} type
   * @param {any} listener
   * @param {any} [options]
   */
  addEventListener(type, listener, options) {
    super.addEventListener(type, listener, options);
    if (!listener) return;
    let set = this.#listeners.get(type);
    if (set === undefined) {
      set = new Set();
      this.#listeners.set(type, set);
    }
    set.add(listener);
  }

  /**
   * @param {string} type
   * @param {any} listener
   * @param {any} [options]
   */
  removeEventListener(type, listener, options) {
    super.removeEventListener(type, listener, options);
    this.#listeners.get(type)?.delete(listener);
  }

  /** @param {string} type */
  listenerCount(type) {
    return this.#listeners.get(type)?.size ?? 0;
  }
}

/** The page's window. */
export class FakeWindow extends CountingTarget {
  /**
   * Dispatches a window `message` event with these fields, as postMessage would.
   * @param {{data: unknown, source: unknown, origin: string}} fields
   */
  message({ data, source, origin }) {
    const event = new Event('message');
    Object.assign(event, { data, source, origin });
    this.dispatchEvent(event);
  }
}

/** The window inside a frame. It records each postMessage the page makes to it. */
export class FakeFrameWindow {
  /** @type {Array<{data: unknown, targetOrigin: string, transfer: unknown[]}>} */
  posts = [];

  /**
   * @param {unknown} data
   * @param {string} targetOrigin
   * @param {unknown[]} [transfer]
   */
  postMessage(data, targetOrigin, transfer = []) {
    this.posts.push({ data, targetOrigin, transfer });
  }
}

/** A text node, as `append` makes from a string. */
export class FakeText {
  /** @type {FakeElement | null} */
  parent = null;

  /** @param {string} data */
  constructor(data) {
    this.data = data;
  }

  get textContent() {
    return this.data;
  }

  remove() {
    detach(this);
  }

  /** Called after the node is appended. */
  attached() {}
}

/** @typedef {FakeElement | FakeText} FakeNode */

/**
 * Takes a node out of its parent's children, if it has a parent.
 * @param {FakeNode} node
 */
function detach(node) {
  if (node.parent === null) return;
  const siblings = node.parent.children;
  siblings.splice(siblings.indexOf(node), 1);
  node.parent = null;
}

export class FakeElement extends CountingTarget {
  /** @type {Map<string, string>} */
  #attributes = new Map();
  /** @type {FakeElement | null} */
  parent = null;
  /** Child elements and text nodes, in order. @type {FakeNode[]} */
  children = [];

  /**
   * @param {string} tagName
   * @param {FakeDocument} ownerDocument
   */
  constructor(tagName, ownerDocument) {
    super();
    this.tagName = tagName;
    this.ownerDocument = ownerDocument;
  }

  /**
   * @param {string} name
   * @param {unknown} value
   */
  setAttribute(name, value) {
    this.#attributes.set(name, String(value));
  }

  /** @param {string} name */
  getAttribute(name) {
    return this.#attributes.get(name) ?? null;
  }

  /** @param {...(FakeNode | string)} nodes strings become text nodes */
  append(...nodes) {
    for (const node of nodes) this.#insert(this.children.length, node);
  }

  /** @param {...(FakeNode | string)} nodes */
  prepend(...nodes) {
    nodes.forEach((node, i) => this.#insert(i, node));
  }

  /** @param {...(FakeNode | string)} nodes */
  replaceChildren(...nodes) {
    for (const child of [...this.children]) child.remove();
    this.append(...nodes);
  }

  remove() {
    detach(this);
  }

  /**
   * @param {number} index
   * @param {FakeNode | string} node
   */
  #insert(index, node) {
    const child = typeof node === 'string' ? new FakeText(node) : node;
    child.remove();
    child.parent = this;
    this.children.splice(Math.min(index, this.children.length), 0, child);
    child.attached();
  }

  /** The text of every text node inside, in document order. */
  get textContent() {
    return this.children.map((child) => child.textContent).join('');
  }

  /**
   * Whether `node` is this element or inside it.
   * @param {unknown} node
   */
  contains(node) {
    for (let at = /** @type {any} */ (node); at != null; at = at.parent) {
      if (at === this) return true;
    }
    return false;
  }

  /** Every element inside this one, depth first in document order. @returns {Generator<FakeElement>} */
  *descendants() {
    for (const child of this.children) {
      if (child instanceof FakeElement) {
        yield child;
        yield* child.descendants();
      }
    }
  }

  /** Makes this the document's active element. */
  focus() {
    this.ownerDocument.activeElement = this;
  }

  /** Called after the element is appended. */
  attached() {}
}

/**
 * An iframe. Its `contentWindow` is a FakeFrameWindow while the iframe is in a parent and
 * null otherwise, as in a browser. `atSrc` and `atAppend` record its state when `src` was
 * set and when it was appended.
 */
export class FakeIframe extends FakeElement {
  title = '';
  #src = '';
  #frameWindow = new FakeFrameWindow();
  /** @type {ReturnType<FakeIframe['snapshot']> | null} */
  atSrc = null;
  /** @type {ReturnType<FakeIframe['snapshot']> | null} */
  atAppend = null;

  /** @param {FakeDocument} ownerDocument */
  constructor(ownerDocument) {
    super('iframe', ownerDocument);
  }

  get src() {
    return this.#src;
  }

  set src(value) {
    this.#src = String(value);
    this.atSrc = this.snapshot();
  }

  get contentWindow() {
    return this.parent === null ? null : this.#frameWindow;
  }

  /** The frame window, even after the iframe is removed. */
  get frameWindow() {
    return this.#frameWindow;
  }

  attached() {
    this.atAppend = this.snapshot();
  }

  /** Fires the iframe's `load` event. */
  load() {
    this.dispatchEvent(new Event('load'));
  }

  snapshot() {
    return {
      sandbox: this.getAttribute('sandbox'),
      title: this.title,
      src: this.#src,
      loadListeners: this.listenerCount('load'),
      windowMessageListeners: this.ownerDocument.defaultView.listenerCount('message'),
      appended: this.parent !== null,
    };
  }
}

/** A script element. Its `src` keeps whatever was assigned, such as a TrustedScriptURL. */
export class FakeScript extends FakeElement {
  /** @type {unknown} */
  src = '';

  /** @param {FakeDocument} ownerDocument */
  constructor(ownerDocument) {
    super('script', ownerDocument);
  }

  /** Fires `load`, as when the script ran. */
  load() {
    this.dispatchEvent(new Event('load'));
  }

  /** Fires `error`, as when the script could not be fetched. */
  fail() {
    this.dispatchEvent(new Event('error'));
  }
}

export class FakeDocument extends CountingTarget {
  /** Every element made by createElement, in order. @type {FakeElement[]} */
  created = [];
  /** @type {FakeElement | null} */
  activeElement = null;
  /** @type {'visible' | 'hidden'} */
  visibilityState = 'visible';

  /** @param {FakeWindow} [defaultView] */
  constructor(defaultView = new FakeWindow()) {
    super();
    this.defaultView = defaultView;
    this.head = new FakeElement('head', this);
    this.body = new FakeElement('body', this);
  }

  /** @param {string} tagName */
  createElement(tagName) {
    const element = tagName === 'iframe' ? new FakeIframe(this)
      : tagName === 'script' ? new FakeScript(this)
      : new FakeElement(tagName, this);
    this.created.push(element);
    return element;
  }

  /**
   * An SVG element, made like any other element.
   * @param {string} _namespace
   * @param {string} tagName
   */
  createElementNS(_namespace, tagName) {
    return this.createElement(tagName);
  }

  /**
   * The first element in the body whose `id` attribute is `id`.
   * @param {string} id
   */
  getElementById(id) {
    for (const element of this.body.descendants()) {
      if (element.getAttribute('id') === id) return element;
    }
    return null;
  }
}
