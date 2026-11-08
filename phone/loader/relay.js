import {
  KEEPALIVE_MS, RESUME_PONG_TIMEOUT_MS, RECONNECT_MIN_MS, RECONNECT_MAX_MS,
} from './constants.js';
import { alwaysVisible, startVisibleTimer, systemClock } from './clock.js';

/** @typedef {import('./clock.js').Clock} Clock */
/** @typedef {import('./clock.js').Visibility} Visibility */
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
 * @property {Visibility} [visibility] The page's visibility. Default: always visible. The wait
 *   for a pong counts only time while the page is visible.
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
 *
 * Pings go out on the clock alone, hidden page or not, so an idle socket stays alive wherever
 * timers still run. The wait for each pong (KEEPALIVE_MS for a keepalive ping,
 * RESUME_PONG_TIMEOUT_MS for a probe) counts only time while the page is visible
 * (`startVisibleTimer`): iOS freezes a hidden page, and on its return the overdue timer can
 * run before the pong that arrived meanwhile is handled, so a ping sent before the page hid
 * gets a fresh window on its return. A socket that died while the page was hidden is found by
 * the probe a return to the page sends.
 */
export class RelaySocket {
  #url;
  #openSocket;
  #onEvent;
  #visibility;
  #clock;

  /** @type {WebSocketLike | null} */
  #ws = null;
  #started = false;
  #ended = false;
  #isOpen = false;
  /** @type {unknown} */
  #keepaliveTimer = null;
  /** @type {(() => void) | null} Cancels the wait for a keepalive ping's pong, while one is out. */
  #pongWait = null;
  /** @type {(() => void) | null} Cancels the wait for a probe's pong, while one is out. */
  #probeWait = null;
  /** @type {unknown} */
  #failTimer = null;

  /** @param {RelaySocketOptions} options */
  constructor({ url, openSocket, onEvent, visibility = alwaysVisible, clock = systemClock }) {
    this.#url = url;
    this.#openSocket = openSocket;
    this.#onEvent = onEvent;
    this.#visibility = visibility;
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

  /**
   * Checks a socket that may have died while the page was hidden: a pong must come within
   * RESUME_PONG_TIMEOUT_MS of time while the page is visible.
   */
  probe() {
    if (this.#probeWait !== null || !this.#sendRaw('ping')) return;
    this.#probeWait = this.#waitForPong(RESUME_PONG_TIMEOUT_MS);
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
        this.#pongWait = stopWait(this.#pongWait);
        this.#probeWait = stopWait(this.#probeWait);
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
      // While a ping is out, no second one goes: its own wait decides.
      if (this.#pongWait === null && this.#sendRaw('ping')) {
        this.#pongWait = this.#waitForPong(KEEPALIVE_MS);
      }
      this.#scheduleKeepalive();
    }, KEEPALIVE_MS);
  }

  /**
   * Ends the socket as dead unless a pong arrives within `ms` of time while the page is
   * visible.
   * @param {number} ms
   * @returns {() => void} cancels the wait; idempotent
   */
  #waitForPong(ms) {
    return startVisibleTimer(ms, this.#visibility, () => this.#die(), this.#clock);
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
    this.#pongWait = stopWait(this.#pongWait);
    this.#probeWait = stopWait(this.#probeWait);
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
 * Cancels a wait for a pong, if any.
 * @param {(() => void) | null} cancel
 * @returns {null}
 */
function stopWait(cancel) {
  cancel?.();
  return null;
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
