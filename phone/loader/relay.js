import {
  KEEPALIVE_MS, RESUME_PONG_TIMEOUT_MS, RECONNECT_MIN_MS, RECONNECT_MAX_MS,
} from './constants.js';
import { systemClock } from './clock.js';

/** @typedef {import('./clock.js').Clock} Clock */
/** @typedef {import('./types.js').WebSocketLike} WebSocketLike */

/** @typedef {'peer-joined' | 'peer-left' | 'peer-absent'} RelaySignal */

/**
 * What a RelaySocket reports. After `closed` or `dead`, or after the caller's `close()`, it
 * reports nothing more.
 * @typedef {{kind: 'open'}
 *   | {kind: 'frame', bytes: Uint8Array}
 *   | {kind: 'signal', name: RelaySignal}
 *   | {kind: 'closed', code: number, wasOpen: boolean}
 *   | {kind: 'dead'}} RelayEvent
 */

/**
 * @typedef {object} RelaySocketOptions
 * @property {string} url The room's WebSocket URL.
 * @property {(url: string) => WebSocketLike} openSocket Opens the socket; may throw.
 * @property {(event: RelayEvent) => void} onEvent
 * @property {Clock} [clock]
 */

/** @type {ReadonlySet<string>} */
const SIGNALS = new Set(['peer-joined', 'peer-left', 'peer-absent']);
const OPEN = 1; // WebSocket.OPEN
const ABNORMAL_CLOSURE = 1006;
const NORMAL_CLOSURE = 1000;
/** The relay's close code for a socket another socket of the same role displaced. */
export const REPLACED = 4000;

/**
 * One relay WebSocket (relay API v1): text signals, binary frames, a keepalive ping every
 * KEEPALIVE_MS, and a liveness probe for when the page returns from the background.
 * A RelaySocket opens at most once; reconnecting means a new RelaySocket.
 */
export class RelaySocket {
  #url;
  #openSocket;
  #onEvent;
  #clock;

  /** @type {WebSocketLike | null} */
  #ws = null;
  #started = false;
  #ended = false;
  #isOpen = false;
  /** A keepalive ping is out and its pong has not arrived. */
  #awaitingPong = false;
  /** @type {unknown} */
  #keepaliveTimer = null;
  /** @type {unknown} */
  #probeTimer = null;
  /** @type {unknown} */
  #failTimer = null;

  /** @param {RelaySocketOptions} options */
  constructor({ url, openSocket, onEvent, clock = systemClock }) {
    this.#url = url;
    this.#openSocket = openSocket;
    this.#onEvent = onEvent;
    this.#clock = clock;
  }

  open() {
    if (this.#started || this.#ended) return;
    this.#started = true;
    let ws;
    try {
      ws = this.#openSocket(this.#url);
    } catch {
      // Some engines refuse the URL synchronously (a connect-src policy, for one).
      this.#failTimer = this.#clock.setTimeout(() => {
        this.#failTimer = null;
        this.#end({ kind: 'closed', code: ABNORMAL_CLOSURE, wasOpen: false });
      }, 0);
      return;
    }
    this.#ws = ws;
    ws.binaryType = 'arraybuffer';
    ws.onopen = () => this.#handleOpen();
    ws.onmessage = (ev) => this.#handleMessage(ev.data);
    ws.onclose = (ev) => this.#end({
      kind: 'closed',
      code: typeof ev?.code === 'number' ? ev.code : ABNORMAL_CLOSURE,
      wasOpen: this.#isOpen,
    });
    ws.onerror = () => {}; // a close event always follows
  }

  /**
   * @param {Uint8Array} bytes
   * @returns {boolean} false unless the socket is open.
   */
  send(bytes) {
    return this.#sendRaw(bytes);
  }

  /** Checks a socket that may have died while the page was hidden. */
  probe() {
    if (this.#probeTimer !== null || !this.#sendRaw('ping')) return;
    this.#probeTimer = this.#clock.setTimeout(() => {
      this.#probeTimer = null;
      this.#die();
    }, RESUME_PONG_TIMEOUT_MS);
  }

  /** Closes with 1000. Reports nothing further. */
  close() {
    if (this.#ended) return;
    this.#ended = true;
    this.#teardown();
  }

  #handleOpen() {
    if (this.#ended) return;
    this.#isOpen = true;
    this.#scheduleKeepalive();
    this.#onEvent({ kind: 'open' });
  }

  /** @param {unknown} data */
  #handleMessage(data) {
    if (this.#ended) return;
    if (typeof data === 'string') {
      if (data === 'pong') {
        this.#awaitingPong = false;
        this.#probeTimer = this.#cancel(this.#probeTimer);
      } else if (SIGNALS.has(data)) {
        this.#onEvent({ kind: 'signal', name: /** @type {RelaySignal} */ (data) });
      }
      return;
    }
    if (data instanceof ArrayBuffer) {
      this.#onEvent({ kind: 'frame', bytes: new Uint8Array(data) });
    } else if (ArrayBuffer.isView(data)) {
      this.#onEvent({
        kind: 'frame',
        bytes: new Uint8Array(data.buffer, data.byteOffset, data.byteLength).slice(),
      });
    }
  }

  #scheduleKeepalive() {
    this.#keepaliveTimer = this.#clock.setTimeout(() => {
      this.#keepaliveTimer = null;
      if (this.#awaitingPong) {
        this.#die();
        return;
      }
      this.#awaitingPong = this.#sendRaw('ping');
      this.#scheduleKeepalive();
    }, KEEPALIVE_MS);
  }

  #die() {
    this.#end({ kind: 'dead' });
  }

  /**
   * Ends the socket and reports `event` as the last event.
   * @param {RelayEvent} event
   */
  #end(event) {
    if (this.#ended) return;
    this.#ended = true;
    this.#teardown();
    this.#onEvent(event);
  }

  #teardown() {
    this.#isOpen = false;
    this.#keepaliveTimer = this.#cancel(this.#keepaliveTimer);
    this.#probeTimer = this.#cancel(this.#probeTimer);
    this.#failTimer = this.#cancel(this.#failTimer);
    const ws = this.#ws;
    this.#ws = null;
    if (ws === null) return;
    ws.onopen = null;
    ws.onmessage = null;
    ws.onclose = null;
    ws.onerror = null;
    try {
      ws.close(NORMAL_CLOSURE);
    } catch {
      // Already closed.
    }
  }

  /**
   * @param {unknown} id A timer from this socket's clock, or null.
   * @returns {null}
   */
  #cancel(id) {
    if (id !== null) this.#clock.clearTimeout(id);
    return null;
  }

  /**
   * @param {string | Uint8Array} data
   * @returns {boolean}
   */
  #sendRaw(data) {
    const ws = this.#ws;
    if (!this.#isOpen || ws === null || ws.readyState !== OPEN) return false;
    try {
      ws.send(data);
      return true;
    } catch {
      return false;
    }
  }
}

/**
 * Backoff before reconnect attempt `attempt` (0-based): doubles from RECONNECT_MIN_MS up to
 * RECONNECT_MAX_MS, with up to 25% jitter.
 * @param {number} attempt
 * @param {number} random In [0, 1), usually Math.random().
 * @returns {number} Milliseconds.
 */
export function reconnectDelay(attempt, random) {
  return Math.min(
    RECONNECT_MAX_MS,
    Math.round(RECONNECT_MIN_MS * 2 ** attempt * (1 + 0.25 * random)),
  );
}
