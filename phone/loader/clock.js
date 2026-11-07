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

/** What `withTimeout` rejects with when time runs out first. */
export class TimeoutError extends Error {
  /** @param {number} ms */
  constructor(ms) {
    super(`no answer within ${ms} ms`);
    this.name = 'TimeoutError';
  }
}

/**
 * Settles as `promise` does, or rejects with a TimeoutError once `ms` pass on `clock` first.
 * The timer is cleared as soon as either happens. `promise` itself is not cancelled: a late
 * answer is ignored.
 * @template T
 * @param {Promise<T>} promise
 * @param {number} ms
 * @param {Clock} [clock]
 * @returns {Promise<T>}
 */
export function withTimeout(promise, ms, clock = systemClock) {
  return new Promise((resolve, reject) => {
    const timer = clock.setTimeout(() => reject(new TimeoutError(ms)), ms);
    promise.then((value) => {
      clock.clearTimeout(timer);
      resolve(value);
    }, (error) => {
      clock.clearTimeout(timer);
      reject(error);
    });
  });
}
