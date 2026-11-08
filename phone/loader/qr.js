// QR scanning for the pairing screen: the camera, decoded by the native BarcodeDetector
// where it reads QR codes, otherwise by the vendored jsQR, loaded only when needed.

import { QR_INTERVAL_MS, QR_MAX_EDGE } from './constants.js';
import { systemClock } from './clock.js';

/** @typedef {import('./clock.js').Clock} Clock */
/** @typedef {'native' | 'jsqr'} DecoderKind */
/** @typedef {HTMLVideoElement | HTMLImageElement | HTMLCanvasElement | ImageBitmap} ScanSource */

/** The one script URL the `loader-jsqr` policy passes. */
const JSQR_URL = new URL('vendor/jsqr/dist/jsQR.js', import.meta.url).href;
const JSQR_POLICY = 'loader-jsqr';
const HAVE_CURRENT_DATA = 2; // HTMLMediaElement.HAVE_CURRENT_DATA

/** @type {Promise<Function> | null} */
let jsQRPromise = null;
/** @type {any} */
let jsQRPolicy = null;
/** @type {any} */
let nativeDetector = null;
/** @type {HTMLCanvasElement | null} */
let canvas = null;

/**
 * `'native'` when `BarcodeDetector` exists and reads QR codes, `'jsqr'` otherwise,
 * including when asking for its formats fails.
 * @param {object} [g]
 * @returns {Promise<DecoderKind>}
 */
export async function chooseDecoder(g = globalThis) {
  const Detector = /** @type {any} */ (g).BarcodeDetector;
  if (typeof Detector !== 'function') return 'jsqr';
  try {
    const formats = await Detector.getSupportedFormats();
    return Array.isArray(formats) && formats.includes('qr_code') ? 'native' : 'jsqr';
  } catch {
    return 'jsqr';
  }
}

/**
 * Loads the vendored jsQR as one classic script, and resolves with `globalThis.jsQR`.
 * Calls while a load is pending, or after one succeeded, get the same promise. A failed load
 * is forgotten, so a later call tries again.
 * @param {Document} [doc]
 * @returns {Promise<Function>}
 */
export function loadJsQR(doc = document) {
  if (jsQRPromise === null) {
    /** @type {Promise<Function>} */
    const loading = new Promise((resolve, reject) => {
      const script = doc.createElement('script');
      script.addEventListener('load', () => {
        const jsQR = /** @type {any} */ (globalThis).jsQR;
        if (typeof jsQR === 'function') resolve(jsQR);
        else reject(new Error('jsQR did not define itself'));
      });
      script.addEventListener('error', () => {
        script.remove();
        reject(new Error('jsQR failed to load'));
      });
      script.src = jsQRScriptURL();
      doc.head.append(script);
    });
    jsQRPromise = loading;
    loading.catch(() => {
      if (jsQRPromise === loading) jsQRPromise = null;
    });
  }
  return jsQRPromise;
}

/**
 * The jsQR URL, through the `loader-jsqr` Trusted Types policy where the engine has
 * Trusted Types. The policy is created once and passes that one URL only.
 * @returns {string}
 */
function jsQRScriptURL() {
  const trustedTypes = /** @type {any} */ (globalThis).trustedTypes;
  if (!trustedTypes) return JSQR_URL;
  if (jsQRPolicy === null) {
    jsQRPolicy = trustedTypes.createPolicy(JSQR_POLICY, {
      /** @param {string} u */
      createScriptURL(u) {
        if (u === JSQR_URL) return u;
        throw new TypeError('loader-jsqr: script URL refused');
      },
    });
  }
  return jsQRPolicy.createScriptURL(JSQR_URL);
}

/**
 * Decodes one QR code in `source`, or null when there is none.
 * @param {ScanSource} source
 * @param {DecoderKind} kind
 * @returns {Promise<string | null>}
 */
export async function scanImage(source, kind) {
  if (kind === 'native') {
    if (nativeDetector === null) {
      const Detector = /** @type {any} */ (globalThis).BarcodeDetector;
      nativeDetector = new Detector({ formats: ['qr_code'] });
    }
    const codes = await nativeDetector.detect(source);
    for (const code of Array.isArray(codes) ? codes : []) {
      if (typeof code?.rawValue === 'string') return code.rawValue;
    }
    return null;
  }

  const jsQR = await loadJsQR();
  const { width, height } = sourceSize(source);
  if (!(width > 0 && height > 0)) return null;
  const scale = Math.min(1, QR_MAX_EDGE / Math.max(width, height));
  const w = Math.max(1, Math.round(width * scale));
  const h = Math.max(1, Math.round(height * scale));
  canvas ??= document.createElement('canvas');
  canvas.width = w;
  canvas.height = h;
  const context = canvas.getContext('2d', { willReadFrequently: true });
  if (context === null) return null;
  context.drawImage(source, 0, 0, w, h);
  const result = jsQR(context.getImageData(0, 0, w, h).data, w, h, { inversionAttempts: 'dontInvert' });
  return result && typeof result.data === 'string' ? result.data : null;
}

/**
 * @param {ScanSource} source
 * @returns {{width: number, height: number}}
 */
function sourceSize(source) {
  if ('videoWidth' in source) return { width: source.videoWidth, height: source.videoHeight };
  if ('naturalWidth' in source) return { width: source.naturalWidth, height: source.naturalHeight };
  return { width: source.width, height: source.height };
}

/**
 * Shows the rear camera in `video` and scans it every QR_INTERVAL_MS. The first text holding
 * a pairing fragment (`#p=`) stops the scanner and goes to `onText`. No camera, a refused
 * camera, or a decoder that cannot load stops it and calls `onError`. Neither callback runs
 * before this function returns. After `stop()`, or after either callback, nothing more is
 * called and every camera track is stopped.
 * @param {{video: HTMLVideoElement, onText: (text: string) => void,
 *   onError: (error: unknown) => void, clock?: Clock}} options
 * @returns {{stop(): void}}
 */
export function startScanner({ video, onText, onError, clock = systemClock }) {
  let stopped = false;
  /** @type {MediaStream | null} */
  let stream = null;
  /** @type {unknown} */
  let timer = null;
  /** @type {DecoderKind} */
  let kind = 'jsqr';

  function stop() {
    if (stopped) return;
    stopped = true;
    if (timer !== null) {
      clock.clearTimeout(timer);
      timer = null;
    }
    if (stream !== null) {
      stopTracks(stream);
      stream = null;
      video.srcObject = null;
    }
  }

  /** @param {unknown} error */
  function fail(error) {
    if (stopped) return;
    stop();
    onError(error);
  }

  function schedule() {
    timer = clock.setTimeout(() => {
      timer = null;
      tick();
    }, QR_INTERVAL_MS);
  }

  async function tick() {
    if (stopped) return;
    let text = null;
    if (video.readyState >= HAVE_CURRENT_DATA) {
      try {
        text = await scanImage(video, kind);
      } catch {
        // A frame that cannot be read now may be readable on the next tick.
      }
    }
    if (stopped) return;
    if (typeof text === 'string' && text.includes('#p=')) {
      stop();
      onText(text);
      return;
    }
    schedule();
  }

  async function begin() {
    // Never call back before startScanner has returned, so a callback can use its result.
    await null;
    if (stopped) return;
    const media = typeof navigator === 'undefined' ? undefined : navigator.mediaDevices;
    if (!media || typeof media.getUserMedia !== 'function') {
      fail(new Error('no camera on this page'));
      return;
    }
    /** @type {MediaStream} */
    let acquired;
    try {
      acquired = await media.getUserMedia({ video: { facingMode: 'environment' }, audio: false });
    } catch (error) {
      fail(error);
      return;
    }
    if (stopped) {
      // stop() ran while the camera prompt was up.
      stopTracks(acquired);
      return;
    }
    stream = acquired;
    video.playsInline = true;
    video.muted = true;
    video.srcObject = acquired;
    video.play().catch((error) => fail(error));

    try {
      kind = await chooseDecoder();
      if (kind === 'jsqr') await loadJsQR();
    } catch (error) {
      fail(error);
      return;
    }
    if (stopped) return;
    schedule();
  }

  begin();
  return { stop };
}

/** @param {MediaStream} stream */
function stopTracks(stream) {
  for (const track of stream.getTracks()) track.stop();
}
