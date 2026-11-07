// A browser-like WebSocket (WebSocketLike in ../../types.js) whose server is a fake relay.
// Like a browser it connects and delivers every event on a later task, one event per task
// and in order, and it keeps `readyState` as a browser does: 0 connecting, 1 open,
// 2 closing, 3 closed.

const CONNECTING = 0;
const OPEN = 1;
const CLOSING = 2;
const CLOSED = 3;
const ABNORMAL_CLOSURE = 1006;
const NO_STATUS = 1005;

/** @typedef {import('./fake-relay.js').FakeRelay} FakeRelay */
/** @typedef {import('./fake-relay.js').RelayHandle} RelayHandle */
/** @typedef {import('../../types.js').WebSocketLike} WebSocketLike */

/**
 * @param {FakeRelay} relay
 * @returns {(url: string) => WebSocketLike}
 */
export function fakeSocketFactory(relay) {
  return (url) => new FakeWebSocket(relay, url);
}

export class FakeWebSocket {
  static CONNECTING = CONNECTING;
  static OPEN = OPEN;
  static CLOSING = CLOSING;
  static CLOSED = CLOSED;

  binaryType = 'blob';
  readyState = CONNECTING;
  /** @type {((ev: any) => void) | null} */ onopen = null;
  /** @type {((ev: any) => void) | null} */ onmessage = null;
  /** @type {((ev: any) => void) | null} */ onclose = null;
  /** @type {((ev: any) => void) | null} */ onerror = null;

  /** @type {RelayHandle | null} */
  #handle = null;
  /** @type {Array<() => void>} */
  #queue = [];
  #draining = false;

  /**
   * @param {FakeRelay} relay
   * @param {string} url
   */
  constructor(relay, url) {
    let parsed;
    try {
      parsed = new URL(url);
    } catch {
      throw new DOMException(`invalid WebSocket URL ${url}`, 'SyntaxError');
    }
    if (parsed.protocol !== 'ws:' && parsed.protocol !== 'wss:') {
      throw new DOMException(`not a WebSocket URL: ${url}`, 'SyntaxError');
    }
    this.url = parsed.href;
    const path = parsed.pathname + parsed.search;
    this.#later(() => {
      if (this.readyState !== CONNECTING) return; // closed before it connected
      const handle = relay.connect(path, {
        binary: (bytes) => this.#later(() => this.#message(bytes)),
        text: (text) => this.#later(() => this.#message(text)),
        close: (code, reason) => this.#later(() => this.#closed(code, reason, true)),
      });
      if (handle === null) {
        this.readyState = CLOSED;
        this.onerror?.({ type: 'error' });
        this.onclose?.({ type: 'close', code: ABNORMAL_CLOSURE, reason: '', wasClean: false });
        return;
      }
      this.#handle = handle;
      this.readyState = OPEN;
      this.onopen?.({ type: 'open' });
    });
  }

  /** @param {string | ArrayBufferLike | ArrayBufferView} data */
  send(data) {
    if (this.readyState === CONNECTING) {
      throw new DOMException('the WebSocket is still connecting', 'InvalidStateError');
    }
    // A browser discards data sent while closing or closed.
    if (this.readyState !== OPEN || this.#handle === null) return;
    if (typeof data === 'string') {
      this.#handle.send(data);
    } else if (ArrayBuffer.isView(data)) {
      this.#handle.send(new Uint8Array(data.buffer, data.byteOffset, data.byteLength).slice());
    } else if (data instanceof ArrayBuffer || data instanceof SharedArrayBuffer) {
      this.#handle.send(new Uint8Array(data).slice());
    } else {
      throw new TypeError('the fake WebSocket sends strings and binary data only');
    }
  }

  /**
   * @param {number} [code]
   * @param {string} [reason]
   */
  close(code, reason = '') {
    if (code !== undefined && code !== 1000 && !(code >= 3000 && code <= 4999)) {
      throw new DOMException(`close code ${code} is not allowed`, 'InvalidAccessError');
    }
    if (this.readyState === CLOSING || this.readyState === CLOSED) return;
    if (this.readyState === CONNECTING) {
      // A browser fails a connection that is still being made.
      this.readyState = CLOSING;
      this.#later(() => {
        this.onerror?.({ type: 'error' });
        this.#closed(ABNORMAL_CLOSURE, '', false);
      });
      return;
    }
    this.readyState = CLOSING;
    const handle = this.#handle;
    this.#handle = null;
    handle?.close(code, reason);
    this.#later(() => this.#closed(code ?? NO_STATUS, reason, true));
  }

  /** @param {Uint8Array | string} data */
  #message(data) {
    if (this.readyState !== OPEN) return;
    if (typeof data === 'string') {
      this.onmessage?.({ type: 'message', data });
    } else if (this.binaryType === 'arraybuffer') {
      this.onmessage?.({ type: 'message', data: data.slice().buffer });
    } else {
      this.onmessage?.({ type: 'message', data: new Blob([data.slice()]) });
    }
  }

  /**
   * @param {number} code
   * @param {string} reason
   * @param {boolean} wasClean
   */
  #closed(code, reason, wasClean) {
    if (this.readyState === CLOSED) return;
    this.readyState = CLOSED;
    this.#handle = null;
    this.onclose?.({ type: 'close', code, reason, wasClean });
  }

  /**
   * Runs `fn` on a later task, after every event queued before it.
   * @param {() => void} fn
   */
  #later(fn) {
    this.#queue.push(fn);
    if (this.#draining) return;
    this.#draining = true;
    const step = () => {
      const next = this.#queue.shift();
      if (next === undefined) {
        this.#draining = false;
        return;
      }
      try {
        next();
      } finally {
        setImmediate(step);
      }
    };
    setImmediate(step);
  }
}
