/**
 * The bundle's contract with the loader. The runner (`phone/loader/runner.js`) gives the bundle
 * one handle, `globalThis.tbdHost`, and the bundle talks to the loader only over its port:
 * `AppFrame` in `phone/loader/frame.js` is the other end. Every message in is rebuilt from its
 * known fields here, and only two shapes ever go out.
 */

import type { HostEnv } from './env.ts';

export interface TbdHost { readonly port: MessagePort; readonly protocol: 1 }

const NO_HOST = 'TBD phone app: no tbdHost with protocol 1';

/**
 * The runner's handle on `g` (the global object), checked. It throws when the handle is
 * missing, speaks another protocol, or has no usable port, so the bundle stops before it
 * draws anything it cannot connect.
 */
export function readHost(g: object): TbdHost {
  const host: unknown = (g as { tbdHost?: unknown }).tbdHost;
  if (!isObject(host) || host.protocol !== 1) throw new Error(NO_HOST);
  const port = host.port;
  if (!isPort(port)) throw new Error(NO_HOST);
  return { port, protocol: 1 };
}

export type LoaderMessage =
  | { t: 'app'; body: Record<string, unknown> }
  | { t: 'channel'; up: boolean }
  | { t: 'env'; env: HostEnv }
  | { t: 'sendFailed'; reason: 'offline' | 'tooLarge' };

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
    default:
      return null;
  }
}

export interface HostHandlers {
  onApp(body: Record<string, unknown>): void;
  onChannel(up: boolean): void;
  onEnv(env: HostEnv): void;
  onSendFailed(reason: 'offline' | 'tooLarge'): void;
}

/**
 * The app's end of the loader port. It turns loader messages into handler calls and posts the
 * only two messages the loader accepts from the app (`appPortMessage` in `frame.js`).
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
      }
    });
    port.start();
  }

  /** Asks the loader to send `body` to the laptop. The caller checks `fitsFrame` first. */
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

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

/**
 * An object literal or a null-prototype object: not an array, a Date, a Map or any other
 * built-in or class instance, which structured clone can also carry. The loader's
 * `isPlainRecord` (`phone/loader/objects.js`) is the same rule.
 */
function isPlainRecord(value: unknown): value is Record<string, unknown> {
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
