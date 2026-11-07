// Just enough DOM to drive the loader's DOM modules in Node: a window, a document, plain
// elements, an iframe and a script element. Each fake records what was done to it, so a
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

export class FakeElement extends CountingTarget {
  /** @type {Map<string, string>} */
  #attributes = new Map();
  /** @type {FakeElement | null} */
  parent = null;
  /** @type {FakeElement[]} */
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

  /** @param {...FakeElement} nodes */
  append(...nodes) {
    for (const node of nodes) {
      node.remove();
      node.parent = this;
      this.children.push(node);
      node.attached();
    }
  }

  remove() {
    if (this.parent === null) return;
    const siblings = this.parent.children;
    siblings.splice(siblings.indexOf(this), 1);
    this.parent = null;
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

export class FakeDocument {
  /** Every element made by createElement, in order. @type {FakeElement[]} */
  created = [];

  /** @param {FakeWindow} [defaultView] */
  constructor(defaultView = new FakeWindow()) {
    this.defaultView = defaultView;
    this.head = new FakeElement('head', this);
  }

  /** @param {string} tagName */
  createElement(tagName) {
    const element = tagName === 'iframe' ? new FakeIframe(this)
      : tagName === 'script' ? new FakeScript(this)
      : new FakeElement(tagName, this);
    this.created.push(element);
    return element;
  }
}
