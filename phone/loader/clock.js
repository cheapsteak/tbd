/**
 * @typedef {object} Clock
 * @property {() => number} now Milliseconds since the epoch.
 * @property {(fn: () => void, ms: number) => unknown} setTimeout
 * @property {(id: unknown) => void} clearTimeout
 */

/** @type {Clock} */
export const systemClock = {
  now: () => Date.now(),
  setTimeout: (fn, ms) => globalThis.setTimeout(fn, ms),
  clearTimeout: (id) => globalThis.clearTimeout(/** @type {any} */ (id)),
};
