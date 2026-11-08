// The app frame host. It opens runner.html in <iframe sandbox="allow-scripts">, hands the
// runner the bundle and one end of a MessageChannel, and from then on talks to the app only
// over that channel. The runner's half of the handshake is runner.js.

import { RUNNER_START_TIMEOUT_MS } from './constants.js';
import { startVisibleTimer, systemClock } from './clock.js';
import { base64urlEncode } from './channel/pairingLink.js';
import { isObject, isPlainRecord } from './objects.js';

/** @typedef {import('./clock.js').Clock} Clock */
/** @typedef {import('./clock.js').Visibility} Visibility */
/** @typedef {import('./types.js').EnvMessage} EnvMessage */

/** @typedef {'navigated' | 'hash' | 'script' | 'timeout'} FaultReason */
/** @typedef {{top: number, right: number, bottom: number, left: number}} Insets */

/**
 * @typedef {object} AppFrameOptions
 * @property {HTMLElement} host The element the frame is appended to.
 * @property {string} runnerURL The absolute URL of runner.html, without a fragment.
 * @property {string} text The bundle's text.
 * @property {string} sha256 The lowercase hex SHA-256 of `text`'s UTF-8 bytes.
 * @property {(body: object) => 'sent' | 'offline' | 'tooLarge'} sendApp Sends an `app` body
 *   to the laptop. A throw is reported to the app as `tooLarge`.
 * @property {(url: string) => void} onOpenLink Gets a URL that passed `openableURL`.
 * @property {(reason: FaultReason) => void} onFault Called at most once. The frame is already
 *   destroyed when it is called.
 * @property {Visibility} visibility The page's visibility. Only time while the page is visible
 *   counts toward RUNNER_START_TIMEOUT_MS: a large bundle that starts as the phone locks gets
 *   its full time once the page is back.
 * @property {Clock} [clock]
 */

/** The frame's only sandbox keyword. Its origin is therefore opaque. */
export const FRAME_SANDBOX = 'allow-scripts';

const NONCE_BYTES = 16;
const MAX_OPENABLE_URL_LENGTH = 2_048;

/** @type {ReadonlySet<string>} */
const RUNNER_FAULTS = new Set(['hash', 'script']);

/**
 * One app bundle running in a sandboxed frame. Not reusable: a new bundle needs a new frame.
 */
export class AppFrame {
  #sendApp;
  #onOpenLink;
  #onFault;
  #text;
  #sha256;
  #nonce;
  /** @type {Window} */
  #win;
  #channel;
  #iframe;

  #loadCount = 0;
  /** The bundle and port2 have been posted to the frame. */
  #bundleSent = false;
  /** The runner reported `started`. */
  #started = false;
  /** @type {boolean | null} What `setChannel` last posted, or null before it has. */
  #channelUp = null;
  #destroyed = false;
  /** @type {(() => void) | null} Cancels the start timeout, until `started` or the end. */
  #cancelStartTimer = null;

  /** @param {AppFrameOptions} options */
  constructor({
    host, runnerURL, text, sha256, sendApp, onOpenLink, onFault, visibility, clock = systemClock,
  }) {
    this.#sendApp = sendApp;
    this.#onOpenLink = onOpenLink;
    this.#onFault = onFault;
    this.#text = text;
    this.#sha256 = sha256;

    const doc = host.ownerDocument;
    const win = doc.defaultView;
    if (win === null) throw new TypeError('AppFrame: the host is not in a window');
    this.#win = win;

    const nonceBytes = new Uint8Array(NONCE_BYTES);
    crypto.getRandomValues(nonceBytes);
    this.#nonce = base64urlEncode(nonceBytes);

    this.#channel = new MessageChannel();
    this.#channel.port1.addEventListener('message', this.#handlePortMessage);
    this.#channel.port1.start();

    // The sandbox and both listeners are in place before src is set, so the frame never
    // loads unsandboxed and no load or ready can be missed.
    const iframe = doc.createElement('iframe');
    iframe.setAttribute('sandbox', FRAME_SANDBOX);
    iframe.title = 'TBD app';
    iframe.addEventListener('load', this.#handleLoad);
    win.addEventListener('message', this.#handleWindowMessage);
    iframe.src = `${runnerURL}#n=${this.#nonce}`;
    this.#iframe = iframe;

    host.append(iframe);
    this.#cancelStartTimer = startVisibleTimer(RUNNER_START_TIMEOUT_MS, visibility, () => {
      this.#cancelStartTimer = null;
      this.#fault('timeout');
    }, clock);
  }

  /**
   * Passes an `app` body from the laptop to the app, unread.
   * @param {object} body
   */
  deliver(body) {
    this.#post({ t: 'app', body });
  }

  /**
   * Tells the app whether its channel to the laptop is up. Only a change is posted: the
   * connection passes through several states while it is down (reconnecting, connecting,
   * handshaking, loading), and the app hears `down` once for all of them.
   * @param {boolean} up
   */
  setChannel(up) {
    if (up === this.#channelUp) return;
    this.#channelUp = up;
    this.#post({ t: 'channel', state: up ? 'up' : 'down' });
  }

  /** @param {EnvMessage} env */
  sendEnv(env) {
    this.#post({
      t: 'env',
      safeArea: env.safeArea,
      viewport: env.viewport,
      layout: env.layout,
      colorScheme: env.colorScheme,
    });
  }

  /** Removes the frame and every listener. Idempotent; no callback fires afterwards. */
  destroy() {
    if (this.#destroyed) return;
    this.#destroyed = true;
    this.#stopStartTimer();
    this.#win.removeEventListener('message', this.#handleWindowMessage);
    this.#iframe.removeEventListener('load', this.#handleLoad);
    this.#channel.port1.removeEventListener('message', this.#handlePortMessage);
    this.#channel.port1.close();
    if (!this.#bundleSent) this.#channel.port2.close();
    this.#iframe.remove();
    this.#text = '';
  }

  #stopStartTimer() {
    this.#cancelStartTimer?.();
    this.#cancelStartTimer = null;
  }

  /** @param {import('./types.js').PortMessage} message */
  #post(message) {
    if (this.#destroyed) return;
    this.#channel.port1.postMessage(message);
  }

  /**
   * Destroys the frame, then reports the fault. At most one fault is reported.
   * @param {FaultReason} reason
   */
  #fault(reason) {
    if (this.#destroyed) return;
    const onFault = this.#onFault;
    this.destroy();
    onFault(reason);
  }

  #handleLoad = () => {
    if (this.#destroyed) return;
    this.#loadCount += 1;
    // The runner never navigates. A second load means the frame went somewhere else.
    if (this.#loadCount > 1) this.#fault('navigated');
  };

  /** @param {MessageEvent} event */
  #handleWindowMessage = (event) => {
    if (this.#destroyed) return;
    const frameWindow = this.#iframe.contentWindow;
    const ready = isRunnerReady(event, {
      frameWindow,
      nonce: this.#nonce,
      loadCount: this.#loadCount,
      started: this.#bundleSent,
    });
    if (!ready || frameWindow === null) return;
    this.#bundleSent = true;
    this.#win.removeEventListener('message', this.#handleWindowMessage);
    // An opaque origin cannot be named, so the target is '*'. The frame's window was
    // checked by identity above, and the bundle is not secret.
    frameWindow.postMessage(
      { type: 'bundle', nonce: this.#nonce, text: this.#text, sha256: this.#sha256 },
      '*',
      [this.#channel.port2],
    );
    this.#text = '';
  };

  /** @param {MessageEvent} event */
  #handlePortMessage = (event) => {
    if (this.#destroyed) return;
    const data = event.data;
    if (isObject(data) && (data.t === 'started' || data.t === 'fault')) {
      // The runner sends exactly one of these, before the app is told anything.
      if (this.#started) return;
      if (data.t === 'started') {
        this.#started = true;
        this.#stopStartTimer();
      } else if (typeof data.reason === 'string' && RUNNER_FAULTS.has(data.reason)) {
        this.#fault(/** @type {'hash' | 'script'} */ (data.reason));
      }
      return;
    }
    const message = appPortMessage(data);
    if (message === null) return;
    if (message.t === 'app') {
      /** @type {'sent' | 'offline' | 'tooLarge'} */
      let result;
      try {
        result = this.#sendApp(message.body);
      } catch {
        // A body that cannot be encoded, such as one with a cycle or a BigInt, makes
        // JSON.stringify throw. To the app it is a message the loader cannot send.
        result = 'tooLarge';
      }
      if (result !== 'sent') this.#post({ t: 'sendFailed', reason: result });
    } else {
      const url = openableURL(message.url);
      if (url !== null) this.#onOpenLink(url);
    }
  };
}

/**
 * Whether a window `message` event is the runner's `ready` from this frame: from the frame's
 * own window, from an opaque origin (so the sandbox took effect), carrying this frame's
 * nonce, before the frame loaded a second document, and before the bundle went out. A
 * `ready` may arrive before the frame's first `load`.
 * @param {{source: unknown, origin: unknown, data: unknown}} event
 * @param {{frameWindow: unknown, nonce: string, loadCount: number, started: boolean}} state
 * @returns {boolean}
 */
export function isRunnerReady(event, { frameWindow, nonce, loadCount, started }) {
  if (frameWindow === null || frameWindow === undefined || event.source !== frameWindow) {
    return false;
  }
  // A sandboxed document without allow-same-origin posts with the origin "null".
  if (event.origin !== 'null') return false;
  if (loadCount > 1 || started) return false;
  const data = event.data;
  if (!isObject(data) || data.type !== 'ready') return false;
  return typeof nonce === 'string' && nonce !== '' && data.nonce === nonce;
}

/**
 * The part of each safe-area inset that overlaps the frame, given the frame's rectangle in
 * layout-viewport coordinates. The app pads by these values and nothing else, so an inset
 * is never padded twice. Each side is capped to [0, inset]: a rectangle read mid-resize can
 * extend past the layout viewport, and that overflow must not turn into padding.
 * @param {Insets} insets
 * @param {{top: number, right: number, bottom: number, left: number}} rect
 * @param {{width: number, height: number}} layout
 * @returns {Insets}
 */
export function frameInsets(insets, rect, layout) {
  return {
    top: overlap(insets.top, rect.top),
    right: overlap(insets.right, layout.width - rect.right),
    bottom: overlap(insets.bottom, layout.height - rect.bottom),
    left: overlap(insets.left, rect.left),
  };
}

/**
 * @param {number} inset
 * @param {number} gap The distance from the frame's edge to the viewport's edge.
 * @returns {number}
 */
function overlap(inset, gap) {
  return Math.min(inset, Math.max(0, inset - gap));
}

/**
 * The normalized href of an absolute `https:` or `http:` URL with no credentials, at most
 * 2,048 characters before and after normalizing; otherwise null.
 * @param {unknown} value
 * @returns {string | null}
 */
export function openableURL(value) {
  if (typeof value !== 'string' || value.length > MAX_OPENABLE_URL_LENGTH) return null;
  let url;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return null;
  if (url.username !== '' || url.password !== '') return null;
  const href = url.href;
  return href.length <= MAX_OPENABLE_URL_LENGTH ? href : null;
}

/**
 * The app-to-loader messages, rebuilt from only their known fields: `{t:'app', body}` with
 * a plain-object body, or `{t:'openLink', url}` with a string url. Anything else is null.
 * @param {unknown} data
 * @returns {{t: 'app', body: object} | {t: 'openLink', url: string} | null}
 */
export function appPortMessage(data) {
  if (!isObject(data)) return null;
  if (data.t === 'app') {
    const body = data.body;
    return isPlainRecord(body) ? { t: 'app', body } : null;
  }
  if (data.t === 'openLink') {
    return typeof data.url === 'string' ? { t: 'openLink', url: data.url } : null;
  }
  return null;
}

/**
 * The loader's environment for the app. Safe-area insets come from the probe element's
 * computed padding (the loader's CSS pads it with `env(safe-area-inset-*)`), cut to where
 * they overlap `frameEl`.
 * @param {Window} win
 * @param {Element} probeEl
 * @param {Element} frameEl
 * @returns {EnvMessage}
 */
export function readEnv(win, probeEl, frameEl) {
  const style = win.getComputedStyle(probeEl);
  const insets = {
    top: px(style.paddingTop),
    right: px(style.paddingRight),
    bottom: px(style.paddingBottom),
    left: px(style.paddingLeft),
  };
  const layout = { width: win.innerWidth, height: win.innerHeight };
  const vv = win.visualViewport;
  const viewport = vv
    ? {
      width: vv.width,
      height: vv.height,
      offsetTop: vv.offsetTop,
      offsetLeft: vv.offsetLeft,
      scale: vv.scale,
    }
    : { width: layout.width, height: layout.height, offsetTop: 0, offsetLeft: 0, scale: 1 };
  const r = frameEl.getBoundingClientRect();
  return {
    t: 'env',
    safeArea: frameInsets(insets, { top: r.top, right: r.right, bottom: r.bottom, left: r.left }, layout),
    viewport,
    layout,
    colorScheme: win.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light',
  };
}

/**
 * @param {string} value A computed length such as "47px".
 * @returns {number}
 */
function px(value) {
  const n = Number.parseFloat(value);
  return Number.isFinite(n) ? n : 0;
}
