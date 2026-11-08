// One promise chain that runs tasks one at a time, in the order they were queued, and timers
// whose work joins that chain. connection.js and pairing.js each run every relay event and
// every timer through one, so asynchronous work (decrypting, say) never lets a later event
// overtake an earlier one.

import { alwaysVisible, startVisibleTimer, systemClock } from './clock.js';

/** @typedef {import('./clock.js').Clock} Clock */
/** @typedef {import('./clock.js').Visibility} Visibility */

/**
 * One timer, armed through the clock. When it fires, its work is queued on the chain, and
 * `cancelled` stops work that was queued but has not run yet. `stop` cancels the clock's
 * timer (and, for a visible-time timer, its visibility listener); it is idempotent.
 * @typedef {{ cancelled: boolean, stop: () => void }} Timer
 */

/**
 * @typedef {object} TaskChainOptions
 * @property {() => boolean} isEnded Once true, queued tasks no longer run.
 * @property {(error: unknown) => void} onError Gets whatever a task throws or rejects with.
 * @property {Visibility} [visibility] The page's visibility, for `armVisible`. Default:
 *   always visible.
 * @property {Clock} [clock]
 */

export class TaskChain {
  /** @type {Promise<void>} */
  #tail = Promise.resolve();
  #isEnded;
  #onError;
  #visibility;
  #clock;

  /** @param {TaskChainOptions} options */
  constructor({ isEnded, onError, visibility = alwaysVisible, clock = systemClock }) {
    this.#isEnded = isEnded;
    this.#onError = onError;
    this.#visibility = visibility;
    this.#clock = clock;
  }

  /**
   * Runs `task` after every task queued before it, unless the owner has ended by then.
   * @param {() => void | Promise<void>} task
   */
  enqueue(task) {
    this.#tail = this.#tail.then(async () => {
      if (this.#isEnded()) return;
      try {
        await task();
      } catch (error) {
        this.#onError(error);
      }
    });
  }

  /**
   * @param {number} ms
   * @param {() => void | Promise<void>} fn runs on the chain
   * @returns {Timer}
   */
  arm(ms, fn) {
    /** @type {Timer} */
    const timer = { cancelled: false, stop: () => {} };
    const id = this.#clock.setTimeout(() => this.#run(timer, fn), ms);
    timer.stop = () => this.#clock.clearTimeout(id);
    return timer;
  }

  /**
   * Like `arm`, but only time while the page is visible counts (`startVisibleTimer`): iOS
   * freezes a hidden page, so a timer that falls due while it is hidden does nothing, and each
   * return to the page starts a fresh `ms`. For a wait on the network, which a frozen page
   * cannot hear back from.
   * @param {number} ms
   * @param {() => void | Promise<void>} fn runs on the chain
   * @returns {Timer}
   */
  armVisible(ms, fn) {
    /** @type {Timer} */
    const timer = { cancelled: false, stop: () => {} };
    timer.stop = startVisibleTimer(ms, this.#visibility, () => this.#run(timer, fn), this.#clock);
    return timer;
  }

  /**
   * @param {Timer | null} timer
   * @returns {null}
   */
  disarm(timer) {
    if (timer !== null) {
      timer.cancelled = true;
      timer.stop();
    }
    return null;
  }

  /**
   * Queues a fired timer's work, which `disarm` can still stop before it runs.
   * @param {Timer} timer
   * @param {() => void | Promise<void>} fn
   */
  #run(timer, fn) {
    this.enqueue(() => (timer.cancelled ? undefined : fn()));
  }
}
