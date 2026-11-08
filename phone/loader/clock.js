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

/**
 * Whether the page is visible, and word of each change. `main.js` builds one from the
 * document's `visibilityState` and `visibilitychange`.
 * @typedef {object} Visibility
 * @property {() => boolean} isVisible
 * @property {(listener: () => void) => () => void} onChange adds a listener called on every
 *   change, and returns what removes it
 */

/** What `withVisibleTimeout` rejects with when time runs out first. */
export class TimeoutError extends Error {
  /** @param {number} ms */
  constructor(ms) {
    super(`no answer within ${ms} ms of the page being visible`);
    this.name = 'TimeoutError';
  }
}

/**
 * Settles as `promise` does, or rejects with a TimeoutError once the page has been visible for
 * `ms` on end, on `clock`, without an answer. iOS freezes a hidden page, and a request in
 * flight then may answer only after the page is back, so time while hidden never counts: the
 * timer stops when the page is hidden, a timer that fires while it is hidden (before its
 * `visibilitychange` arrives) does nothing, and each return to visible starts a fresh `ms`.
 * The timer and the listener go as soon as either settles. `promise` itself is not cancelled:
 * a late answer is ignored.
 * @template T
 * @param {Promise<T>} promise
 * @param {number} ms
 * @param {Visibility} visibility
 * @param {Clock} [clock]
 * @returns {Promise<T>}
 */
export function withVisibleTimeout(promise, ms, visibility, clock = systemClock) {
  return new Promise((resolve, reject) => {
    /** @type {unknown} */
    let timer = null;
    const disarm = () => {
      if (timer !== null) clock.clearTimeout(timer);
      timer = null;
    };
    // On every change: hidden stops the timer, visible starts a fresh one.
    const rearm = () => {
      disarm();
      if (visibility.isVisible()) timer = clock.setTimeout(expire, ms);
    };
    const expire = () => {
      timer = null;
      // Hidden without word of it yet: the change to visible that follows re-arms.
      if (!visibility.isVisible()) return;
      stopWatching();
      reject(new TimeoutError(ms));
    };
    const stopWatching = visibility.onChange(rearm);
    rearm();
    promise.then((value) => {
      stopWatching();
      disarm();
      resolve(value);
    }, (error) => {
      stopWatching();
      disarm();
      reject(error);
    });
  });
}
