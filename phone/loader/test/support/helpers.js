// Small helpers the node:test suites share: JSON bytes, base64url, waits, and sockets that
// never connect. Node only.

import assert from 'node:assert/strict';

import { base64urlDecode } from '../../channel/pairingLink.js';

/** How long `until` waits by default, in real time. */
export const WAIT_MS = 10_000;

/**
 * UTF-8 JSON.
 * @param {unknown} value
 */
export const encode = (value) => new TextEncoder().encode(JSON.stringify(value));

/** @param {Uint8Array} bytes UTF-8 JSON */
export const decode = (bytes) => JSON.parse(new TextDecoder().decode(bytes));

/** @param {string} text base64url the test knows is valid */
export const b64 = (text) => /** @type {Uint8Array} */ (base64urlDecode(text));

/** @param {number} ms */
export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Lets in-flight socket deliveries and Web Crypto work land. */
export const quiet = () => sleep(30);

/**
 * Waits, polling every millisecond of real time, until `predicate` holds; fails the test
 * after `ms`.
 * @param {() => boolean} predicate
 * @param {string} what
 * @param {number} [ms]
 */
export async function until(predicate, what, ms = WAIT_MS) {
  const deadline = Date.now() + ms;
  while (!predicate()) {
    if (Date.now() > deadline) assert.fail(`timed out waiting for ${what}`);
    await sleep(1);
  }
}

/**
 * A socket factory whose sockets stay connecting forever, as on a network that swallows the
 * WebSocket handshake. Each socket records the codes `close()` was called with.
 */
export function hangingSockets() {
  /** @type {any[]} */
  const sockets = [];
  return {
    sockets,
    /** @param {string} url */
    factory(url) {
      const ws = {
        url,
        binaryType: 'blob',
        readyState: 0,
        onopen: null,
        onmessage: null,
        onclose: null,
        onerror: null,
        /** @type {Array<number | undefined>} */ closes: [],
        send() {
          throw new DOMException('the WebSocket is still connecting', 'InvalidStateError');
        },
        /** @param {number} [code] */
        close(code) {
          ws.closes.push(code);
          ws.readyState = 3;
        },
      };
      sockets.push(ws);
      return ws;
    },
  };
}
