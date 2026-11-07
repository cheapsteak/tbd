// A Clock (../../clock.js) whose time moves only when a test calls advance().

/** A macrotask turn, which runs every microtask queued before it. */
const flush = () => new Promise((resolve) => setImmediate(resolve));

export class FakeClock {
  #now;
  #nextID = 1;
  /** @type {Map<number, { due: number, fn: () => void }>} */
  #timers = new Map();

  /** @param {number} [start] Milliseconds since the epoch. */
  constructor(start = 0) {
    this.#now = start;
  }

  now() {
    return this.#now;
  }

  /**
   * @param {() => void} fn
   * @param {number} ms
   * @returns {number}
   */
  setTimeout(fn, ms) {
    const id = this.#nextID++;
    this.#timers.set(id, { due: this.#now + Math.max(0, Number(ms) || 0), fn });
    return id;
  }

  /** @param {unknown} id */
  clearTimeout(id) {
    this.#timers.delete(/** @type {number} */ (id));
  }

  /** How many timers are waiting. */
  get pending() {
    return this.#timers.size;
  }

  /**
   * Moves time forward by `ms`, running each timer that falls due on the way in time order
   * (timers due at the same moment run in the order they were set). After each timer it
   * flushes queued microtasks, so a timer set by one that ran also runs if it falls due.
   * Time ends at the target even when no timer ran.
   * @param {number} ms
   * @returns {Promise<void>}
   */
  async advance(ms) {
    const target = this.#now + ms;
    for (;;) {
      /** @type {number | null} */
      let nextID = null;
      let next = null;
      for (const [id, timer] of this.#timers) {
        if (timer.due <= target && (next === null || timer.due < next.due)) {
          nextID = id;
          next = timer;
        }
      }
      if (next === null || nextID === null) break;
      this.#timers.delete(nextID);
      this.#now = next.due;
      next.fn();
      await flush();
    }
    this.#now = target;
  }
}
