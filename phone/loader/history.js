// The browser history the phone app's screens live in. The app runs in a sandboxed frame, and
// on WebKit a back or forward onto an entry the frame pushed fires the frame's `load` again,
// which the loader reads as the frame navigating away. When the top page owns the entries,
// `popstate` fires here instead and the frame never sees a load. So the loader keeps the
// entries: the app asks for them over its port with `history` messages, and hears where the
// browser moved with `route` messages.
//
// Every History API call the loader makes for the app is in this module. The app's route is a
// string the loader never reads: it is checked for type and length, stored in the entry, and
// handed back only to an app frame for the same laptop. No call passes a URL. A call the
// browser refuses by throwing leaves the entry as it was, and any route the loader owes still
// goes out, naming the screen of the entry as it stands.

import { base64urlEncode } from './channel/pairingLink.js';
import { isObject, isPlainRecord } from './objects.js';

/** The longest app route string an entry holds, in UTF-16 code units. */
export const MAX_APP_STATE_LENGTH = 1024;

const DOC_BYTES = 16;

/**
 * The loader's part of a history entry's state, under its `tbdPhone` key.
 * - `laptop` – the ID of the laptop the entry was made for.
 * - `doc` – the page load that made it, so a later load can tell its own entries apart.
 * - `step` – how many of that page load's entries come before this one.
 * - `app` – the app's route string, or null for the sessions list.
 * @typedef {{v: 1, laptop: string, doc: string, step: number, app: string | null}} PhoneEntry
 */

/**
 * An app's history request, rebuilt from its `history` port message.
 * @typedef {{op: 'push' | 'replace', state: string | null, move: number}
 *   | {op: 'back', move: number}} HistoryRequest
 */

/**
 * The parts of the History API the loader uses for the app, so a test can hand in a fake.
 * `state` is the current entry's state. `pushState` and `replaceState` take the entry's state
 * alone, so the address never changes. `onPopState` adds a `popstate` listener and returns
 * what removes it.
 * @typedef {{
 *   readonly state: unknown,
 *   pushState(data: object): void,
 *   replaceState(data: object): void,
 *   back(): void,
 *   onPopState(listener: () => void): () => void,
 * }} HistoryPort
 */

/**
 * One app frame's hold on the page history. `apply` carries out the app's requests; after
 * `detach`, neither `apply` nor the page's moves reach the frame.
 * @typedef {{apply(request: HistoryRequest): void, detach(): void}} FrameHistory
 */

/** @typedef {{laptop: string, sendRoute: (state: string | null, move: number) => void}} Attachment */

/**
 * The window's History API, with an empty title and no URL on every write.
 * @param {Window} win
 * @returns {HistoryPort}
 */
export function windowHistory(win) {
  return {
    get state() {
      return win.history.state;
    },
    pushState: (data) => win.history.pushState(data, ''),
    replaceState: (data) => win.history.replaceState(data, ''),
    back: () => win.history.back(),
    onPopState(listener) {
      win.addEventListener('popstate', listener);
      return () => win.removeEventListener('popstate', listener);
    },
  };
}

/**
 * The loader's fields of an entry's state, or null when the entry is not one the loader wrote:
 * a plain object holding a plain-object `tbdPhone` whose own fields are `v` 1, string `laptop`
 * and `doc`, a non-negative safe-integer `step`, and an `app` that is null or a string within
 * MAX_APP_STATE_LENGTH. Returns a fresh object with those fields only.
 * @param {unknown} state
 * @returns {PhoneEntry | null}
 */
export function readEntry(state) {
  if (!isPlainRecord(state)) return null;
  const fields = own(state, 'tbdPhone');
  if (!isPlainRecord(fields)) return null;
  const v = own(fields, 'v');
  const laptop = own(fields, 'laptop');
  const doc = own(fields, 'doc');
  const step = own(fields, 'step');
  const app = own(fields, 'app');
  if (v !== 1 || typeof laptop !== 'string' || typeof doc !== 'string') return null;
  if (!isMoveCount(step) || !isAppState(app)) return null;
  return { v, laptop, doc, step, app };
}

/**
 * An app's `{t: 'history', ...}` port message, rebuilt from its known fields: `op` push or
 * replace with a `state` that is null or a string within MAX_APP_STATE_LENGTH, or `op` back
 * with no state; and a `move` that is a non-negative safe integer. Anything else is null.
 * @param {unknown} data
 * @returns {HistoryRequest | null}
 */
export function historyRequest(data) {
  if (!isObject(data) || data.t !== 'history') return null;
  const { op, state, move } = data;
  if (!isMoveCount(move)) return null;
  if (op === 'back') return { op, move };
  if (op !== 'push' && op !== 'replace') return null;
  return isAppState(state) ? { op, state, move } : null;
}

/**
 * The page's history for app frames. It counts the browser's moves (each `popstate`, and each
 * `back` it acts on) in `move`, and holds at most one frame at a time.
 */
export class PageHistory {
  #port;
  #doc;
  #move = 0;
  /** @type {Attachment | null} */
  #attached = null;

  /**
   * @param {{ port: HistoryPort, doc?: string }} options `doc` is this page load's ID; a
   *   random one by default.
   */
  constructor({ port, doc = randomDoc() }) {
    this.#port = port;
    this.#doc = doc;
    port.onPopState(() => this.#onPopState());
  }

  /** The browser moves counted so far in this page load. */
  get move() {
    return this.#move;
  }

  /**
   * Gives a frame for `laptopID` the current entry, and sends it the entry's screen. The entry
   * keeps its screen when it was made for this laptop, and its step when it was made in this
   * page load. A frame attached before is detached.
   * @param {string} laptopID
   * @param {(state: string | null, move: number) => void} sendRoute
   * @returns {FrameHistory}
   */
  attach(laptopID, sendRoute) {
    /** @type {Attachment} */
    const attachment = { laptop: laptopID, sendRoute };
    this.#attached = attachment;
    const current = readEntry(this.#port.state);
    const app = screenOf(current, laptopID);
    // The screen matches the entry even when the write throws: an entry that is not this
    // laptop's reads as its list.
    attempt(() => this.#port.replaceState(this.#entry(laptopID, this.#ownStep(current), app)));
    sendRoute(app, this.#move);
    return {
      apply: (request) => {
        if (this.#attached === attachment) this.#apply(attachment, request);
      },
      detach: () => {
        if (this.#attached === attachment) this.#attached = null;
      },
    };
  }

  /**
   * @param {Attachment} attachment
   * @param {HistoryRequest} request
   */
  #apply(attachment, request) {
    // A request made before the browser's last move is about a screen that is gone.
    if (request.move !== this.#move) return;
    const current = readEntry(this.#port.state);
    const ownStep = this.#ownStep(current);
    switch (request.op) {
      case 'push': {
        // The entry before the new one is this page load's only when the current one is.
        const step = current !== null && current.doc === this.#doc ? ownStep + 1 : 0;
        attempt(() => this.#port.pushState(this.#entry(attachment.laptop, step, request.state)));
        return;
      }
      case 'replace':
        attempt(() => this.#port.replaceState(this.#entry(attachment.laptop, ownStep, request.state)));
        return;
      case 'back':
        this.#move += 1;
        if (ownStep > 0) {
          // The entry before is this page load's own, in this document: the popstate that
          // follows sends the route. A back that throws moves nothing and brings no popstate,
          // so the route goes out here.
          if (attempt(() => this.#port.back())) return;
        } else {
          // Going back from here would leave the page or load it again. Show the list instead.
          attempt(() => this.#port.replaceState(this.#entry(attachment.laptop, ownStep, null)));
        }
        this.#sendScreen(attachment);
    }
  }

  #onPopState() {
    this.#move += 1;
    const attachment = this.#attached;
    if (attachment === null) return;
    const current = readEntry(this.#port.state);
    if (current !== null && current.laptop === attachment.laptop) {
      attachment.sendRoute(current.app, this.#move);
      return;
    }
    // Another laptop's entry, or one the loader did not write: it becomes this laptop's list,
    // so the entry matches the screen the app is sent. Left as it was by a write that throws,
    // it still reads as this laptop's list.
    attempt(() => this.#port.replaceState(this.#entry(attachment.laptop, this.#ownStep(current), null)));
    attachment.sendRoute(null, this.#move);
  }

  /**
   * Sends the frame the screen of the entry the browser is on, read after any write: the
   * entry's app string when it is this laptop's, and the list otherwise. So when a write threw
   * and left the entry as it was, the screen still matches the entry.
   * @param {Attachment} attachment
   */
  #sendScreen(attachment) {
    attachment.sendRoute(screenOf(readEntry(this.#port.state), attachment.laptop), this.#move);
  }

  /**
   * The entry's step when this page load made it, and 0 otherwise.
   * @param {PhoneEntry | null} entry
   */
  #ownStep(entry) {
    return entry !== null && entry.doc === this.#doc ? entry.step : 0;
  }

  /**
   * @param {string} laptop
   * @param {number} step
   * @param {string | null} app
   * @returns {{tbdPhone: PhoneEntry}}
   */
  #entry(laptop, step, app) {
    return { tbdPhone: { v: 1, laptop, doc: this.#doc, step, app } };
  }
}

/**
 * The screen an entry shows to a frame for `laptop`: its app string when the entry is that
 * laptop's, and the list otherwise.
 * @param {PhoneEntry | null} entry
 * @param {string} laptop
 * @returns {string | null}
 */
function screenOf(entry, laptop) {
  return entry !== null && entry.laptop === laptop ? entry.app : null;
}

/**
 * Runs one History API call, and says whether it returned. A browser can refuse one: WebKit
 * throws when a page calls `pushState` or `replaceState` too often in a short time. The entry
 * then stays as it was, and the caller goes on to send any route it owes, so the app's move
 * count stays current.
 * @param {() => void} call
 * @returns {boolean}
 */
function attempt(call) {
  try {
    call();
    return true;
  } catch {
    return false;
  }
}

/**
 * The value of an own property, or undefined.
 * @param {Record<string, unknown>} object
 * @param {string} key
 */
function own(object, key) {
  return Object.hasOwn(object, key) ? object[key] : undefined;
}

/**
 * @param {unknown} value
 * @returns {value is number}
 */
function isMoveCount(value) {
  return Number.isSafeInteger(value) && /** @type {number} */ (value) >= 0;
}

/**
 * @param {unknown} value
 * @returns {value is string | null}
 */
function isAppState(value) {
  return value === null || (typeof value === 'string' && value.length <= MAX_APP_STATE_LENGTH);
}

/** A fresh page-load ID: 16 random bytes, base64url. */
function randomDoc() {
  const bytes = new Uint8Array(DOC_BYTES);
  crypto.getRandomValues(bytes);
  return base64urlEncode(bytes);
}
