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

/**
 * A page that is always visible: the default where no document's visibility is passed in.
 * @type {Visibility}
 */
export const alwaysVisible = Object.freeze({
  isVisible: () => true,
  onChange: () => () => {},
});

/** What `withVisibleTimeout` rejects with when time runs out first. */
export class TimeoutError extends Error {
  /** @param {number} ms */
  constructor(ms) {
    super(`no answer within ${ms} ms of the page being visible`);
    this.name = 'TimeoutError';
  }
}

/**
 * Calls `onExpire` once the page has been visible for `ms` on end, on `clock`. iOS freezes a
 * hidden page, so time while hidden never counts: the timer stops when the page is hidden, a
 * timer that fires while it is hidden (before its `visibilitychange` arrives) does nothing,
 * and each return to visible starts a fresh `ms`. The timer and the listener go when it
 * expires or is cancelled, whichever comes first.
 * @param {number} ms
 * @param {Visibility} visibility
 * @param {() => void} onExpire called at most once, and never after `cancel`
 * @param {Clock} [clock]
 * @returns {() => void} cancel: idempotent
 */
export function startVisibleTimer(ms, visibility, onExpire, clock = systemClock) {
  /** @type {unknown} */
  let timer = null;
  let done = false;
  const disarm = () => {
    if (timer !== null) clock.clearTimeout(timer);
    timer = null;
  };
  // On every change: hidden stops the timer, visible starts a fresh one.
  const rearm = () => {
    disarm();
    if (!done && visibility.isVisible()) timer = clock.setTimeout(expire, ms);
  };
  const expire = () => {
    timer = null;
    // Hidden without word of it yet: the change to visible that follows re-arms.
    if (done || !visibility.isVisible()) return;
    cancel();
    onExpire();
  };
  const stopWatching = visibility.onChange(rearm);
  const cancel = () => {
    if (done) return;
    done = true;
    stopWatching();
    disarm();
  };
  rearm();
  return cancel;
}

/**
 * Whether `now` is less than `ms` after `then`, on the same clock. A clock that went back
 * reads as not soon, so a caller that would skip work as just done does it after all.
 * @param {number} then
 * @param {number} now
 * @param {number} ms
 */
export function isSoonAfter(then, now, ms) {
  const elapsed = now - then;
  return elapsed >= 0 && elapsed < ms;
}

/**
 * Settles as `promise` does, or rejects with a TimeoutError once the page has been visible for
 * `ms` on end, on `clock`, without an answer: `startVisibleTimer` counts the time. The timer
 * and the listener go as soon as either settles. `promise` itself is not cancelled: a late
 * answer is ignored.
 * @template T
 * @param {Promise<T>} promise
 * @param {number} ms
 * @param {Visibility} visibility
 * @param {Clock} [clock]
 * @returns {Promise<T>}
 */
export function withVisibleTimeout(promise, ms, visibility, clock = systemClock) {
  return new Promise((resolve, reject) => {
    const cancel = startVisibleTimer(ms, visibility, () => reject(new TimeoutError(ms)), clock);
    promise.then((value) => {
      cancel();
      resolve(value);
    }, (error) => {
      cancel();
      reject(error);
    });
  });
}
