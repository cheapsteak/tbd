/**
 * The bundle's contract with the loader. The runner (`phone/loader/runner.js`) gives the bundle
 * one handle, `globalThis.tbdHost`, and the bundle talks to the loader only over its port:
 * `AppFrame` in `phone/loader/frame.js` is the other end. Every message in is rebuilt from its
 * known fields here, and only three shapes ever go out.
 *
 * The loader keeps the browser's history for the app (`phone/loader/history.js`). The app asks
 * it to add or rewrite an entry, or to go back, with a `history` message, and the loader names
 * the entry the browser is on with a `route` message. The app never touches the History API
 * itself.
 */

import type { HostEnv } from './env.ts';
import { MAX_ROUTE_STATE_LENGTH } from './limits.ts';

/**
 * The runner's handle. `history: 1` says the loader keeps the app's history entries; a loader
 * older than this app hands no such field.
 */
export interface TbdHost { readonly port: MessagePort; readonly protocol: 1; readonly history: 1 }

const NO_HOST = 'TBD phone app: no tbdHost with protocol 1';
const NO_HISTORY = 'TBD phone app: tbdHost has no history 1, so the loader is older than this app';

/**
 * The runner's handle on `g` (the global object), checked. It throws when the handle is
 * missing, speaks another protocol, or has no usable port, so the bundle stops before it
 * draws anything it cannot connect. It throws too when the loader keeps no history for the app:
 * the loader then shows "Reload this page", and a reload fetches the current loader.
 */
export function readHost(g: object): TbdHost {
  const host: unknown = (g as { tbdHost?: unknown }).tbdHost;
  if (!isObject(host) || host.protocol !== 1) throw new Error(NO_HOST);
  const port = host.port;
  if (!isPort(port)) throw new Error(NO_HOST);
  if (host.history !== 1) throw new Error(NO_HISTORY);
  return { port, protocol: 1, history: 1 };
}

export type LoaderMessage =
  | { t: 'app'; body: Record<string, unknown> }
  | { t: 'channel'; up: boolean }
  | { t: 'env'; env: HostEnv }
  | { t: 'sendFailed'; reason: 'offline' | 'tooLarge' }
  | { t: 'route'; state: string | null; move: number };

/**
 * What the app asks of the loader's history (`HostLink.postHistory`):
 * - `push` adds an entry after the current one, for the route `state` names;
 * - `replace` rewrites the current entry to `state`'s route;
 * - `back` is the app's back chevron. The loader goes back one entry when the entry before is
 *   its own for this app, and otherwise rewrites the current entry to the list.
 *
 * `state` is the route's string (`encodeRoute` in `state/routeState.ts`), or null for the
 * sessions list. `move` is the move count of the last `route` message the app received; the
 * loader drops a request whose count is not its current one, because the browser has moved
 * since.
 */
export type HistoryRequest =
  | { op: 'push' | 'replace'; state: string | null; move: number }
  | { op: 'back'; move: number };

/**
 * One message from the loader, rebuilt from only its known fields, each checked; null for
 * anything else. The runner's own `started` and `fault`, which share the port, are null too:
 * they are the loader's business, not the app's. `app.body` is checked to be a plain record
 * and passed on unread, for the protocol decoders.
 */
export function decodeLoaderMessage(data: unknown): LoaderMessage | null {
  if (!isPlainRecord(data)) return null;
  switch (data.t) {
    case 'app': {
      const body = data.body;
      return isPlainRecord(body) ? { t: 'app', body } : null;
    }
    case 'channel': {
      const state = data.state;
      if (state === 'up') return { t: 'channel', up: true };
      if (state === 'down') return { t: 'channel', up: false };
      return null;
    }
    case 'env': {
      const env = decodeEnv(data);
      return env === null ? null : { t: 'env', env };
    }
    case 'sendFailed': {
      const reason = data.reason;
      return reason === 'offline' || reason === 'tooLarge' ? { t: 'sendFailed', reason } : null;
    }
    case 'route': {
      const { state, move } = data;
      const stateOK = state === null || (typeof state === 'string' && state.length <= MAX_ROUTE_STATE_LENGTH);
      return stateOK && isMove(move) ? { t: 'route', state, move } : null;
    }
    default:
      return null;
  }
}

export interface HostHandlers {
  onApp(body: Record<string, unknown>): void;
  onChannel(up: boolean): void;
  onEnv(env: HostEnv): void;
  onSendFailed(reason: 'offline' | 'tooLarge'): void;
  /**
   * The browser is on the history entry whose route string is `state`, null for the sessions
   * list: the frame started on it, the user went back or forward, or the loader answered `back`.
   * `move` is the loader's move count, which the app's next history request carries.
   */
  onRoute(state: string | null, move: number): void;
}

/**
 * The app's end of the loader port. It turns loader messages into handler calls and posts the
 * only three messages the loader accepts from the app (`appPortMessage` in `frame.js`).
 */
export class HostLink {
  readonly #port: MessagePort;

  /**
   * Starts the port before returning. The loader may post (a channel state, an env, an app
   * body) before the bundle runs, and a port that was never started holds those messages, so
   * the listener goes on first and `start()` follows at once.
   */
  constructor(port: MessagePort, handlers: HostHandlers) {
    this.#port = port;
    port.addEventListener('message', (event: MessageEvent) => {
      const message = decodeLoaderMessage(event.data);
      if (message === null) return;
      switch (message.t) {
        case 'app': handlers.onApp(message.body); break;
        case 'channel': handlers.onChannel(message.up); break;
        case 'env': handlers.onEnv(message.env); break;
        case 'sendFailed': handlers.onSendFailed(message.reason); break;
        case 'route': handlers.onRoute(message.state, message.move); break;
      }
    });
    port.start();
  }

  /**
   * Asks the loader to send `body` to the laptop. The caller checks `fitsFrame` first. The
   * body must be JSON-shaped plain data: the loader measures and sends the structured clone,
   * so a class instance with `toJSON` would encode differently there, and a function makes
   * this post throw.
   */
  postApp(body: Record<string, unknown>): void {
    this.#port.postMessage({ t: 'app', body });
  }

  /**
   * Asks the loader to open `url`. The loader opens only http and https URLs with no
   * credentials (`openableURL` in `frame.js`), behind its own sheet, and ignores the rest.
   */
  openLink(url: string): void {
    this.#port.postMessage({ t: 'openLink', url });
  }

  /**
   * Asks the loader's history for `request` (`HistoryRequest`). The message is built from the
   * request's known fields, so nothing else a caller's object holds reaches the loader.
   */
  postHistory(request: HistoryRequest): void {
    const { move } = request;
    this.#port.postMessage(request.op === 'back'
      ? { t: 'history', op: 'back', move }
      : { t: 'history', op: request.op, state: request.state, move });
  }
}

/**
 * The env message's three rectangles and its color scheme, every number finite. The result
 * is a fresh object, so nothing else the message carried reaches the app.
 */
function decodeEnv(data: Record<string, unknown>): HostEnv | null {
  const safeArea = numbers(data.safeArea, ['top', 'right', 'bottom', 'left']);
  const viewport = numbers(data.viewport, ['width', 'height', 'offsetTop', 'offsetLeft', 'scale']);
  const layout = numbers(data.layout, ['width', 'height']);
  const colorScheme = data.colorScheme;
  if (safeArea === null || viewport === null || layout === null) return null;
  if (colorScheme !== 'light' && colorScheme !== 'dark') return null;
  return { safeArea, viewport, layout, colorScheme };
}

/** A new record of `keys` read from `value`, or null unless `value` is a plain record and each is a finite number. */
function numbers<K extends string>(value: unknown, keys: readonly K[]): Record<K, number> | null {
  if (!isPlainRecord(value)) return null;
  const out = {} as Record<K, number>;
  for (const key of keys) {
    const n = value[key];
    if (typeof n !== 'number' || !Number.isFinite(n)) return null;
    out[key] = n;
  }
  return out;
}

/** A move count: a non-negative safe integer. */
function isMove(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

/**
 * An object literal or a null-prototype object: not an array, a Date, a Map or any other
 * built-in or class instance, which structured clone can also carry. It is the same rule as the
 * loader's `isPlainRecord` (`phone/loader/objects.js`), kept as a copy because the bundle
 * imports nothing from outside its own tree, as `runner.js` keeps its own. `host.test.ts`
 * ("isPlainRecord gives the loader's answer") checks that the two agree.
 */
export function isPlainRecord(value: unknown): value is Record<string, unknown> {
  if (!isObject(value)) return false;
  const proto: unknown = Object.getPrototypeOf(value);
  return proto === Object.prototype || proto === null;
}

/** A value with the three MessagePort methods the link calls. */
function isPort(value: unknown): value is MessagePort {
  return isObject(value)
    && typeof value.postMessage === 'function'
    && typeof value.start === 'function'
    && typeof value.addEventListener === 'function';
}
