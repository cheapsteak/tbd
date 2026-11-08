// One promise chain that runs tasks one at a time, in the order they were queued, and timers
// whose work joins that chain. connection.js and pairing.js each run every relay event and
// every timer through one, so asynchronous work (decrypting, say) never lets a later event
// overtake an earlier one.

import { systemClock } from './clock.js';

/** @typedef {import('./clock.js').Clock} Clock */

/**
 * One timer, armed through the clock. When it fires, its work is queued on the chain, and
 * `cancelled` stops work that was queued but has not run yet.
 * @typedef {{ id: unknown, cancelled: boolean }} Timer
 */

/**
 * @typedef {object} TaskChainOptions
 * @property {() => boolean} isEnded Once true, queued tasks no longer run.
 * @property {(error: unknown) => void} onError Gets whatever a task throws or rejects with.
 * @property {Clock} [clock]
 */

export class TaskChain {
  /** @type {Promise<void>} */
  #tail = Promise.resolve();
  #isEnded;
  #onError;
  #clock;

  /** @param {TaskChainOptions} options */
  constructor({ isEnded, onError, clock = systemClock }) {
    this.#isEnded = isEnded;
    this.#onError = onError;
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
    const timer = { id: null, cancelled: false };
    timer.id = this.#clock.setTimeout(() => {
      timer.id = null;
      this.enqueue(() => (timer.cancelled ? undefined : fn()));
    }, ms);
    return timer;
  }

  /**
   * @param {Timer | null} timer
   * @returns {null}
   */
  disarm(timer) {
    if (timer !== null) {
      timer.cancelled = true;
      if (timer.id !== null) this.#clock.clearTimeout(timer.id);
    }
    return null;
  }
}
