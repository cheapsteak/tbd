/**
 * The time a component shows ages and elapsed times against (spec section 8.2), read again on a
 * fixed beat: every 30 s for the ages, and every 1 s for the "Working…" line's elapsed time. The
 * sessions screens (part 6b) and the transcript (part 6c) both read it through `useNow`.
 *
 * Every component that asks for the same beat shares one ticker, so the ages on a screen move
 * together and one timer runs per beat, not one per row. A ticker runs its timer only while a
 * component listens. An idle ticker's reading goes stale, so the first listener to arrive takes
 * the time afresh and hears that it moved.
 */

import { useSyncExternalStore } from 'react';

/**
 * A clock whose reading changes only when it tells its listeners, as `useSyncExternalStore`
 * needs: two reads with no call to a listener between them return the same value.
 */
export interface Ticker {
  /**
   * The reading. It changes only on a beat, or when a first listener arrives, so while anything
   * listens it is never older than one beat.
   */
  get(): number;
  /**
   * Calls `listener` on every beat, and returns the function that stops it. The first listener
   * takes the time afresh, and is called at once when that moved the reading.
   */
  subscribe(listener: () => void): () => void;
}

/** A ticker that reads `now` (Unix milliseconds) every `intervalMs`. */
export function createTicker(intervalMs: number, now: () => number = Date.now): Ticker {
  let current = now();
  const listeners = new Set<() => void>();
  let timer: ReturnType<typeof setInterval> | null = null;

  function notify(): void {
    // A copy, so a listener that unsubscribes does not change this round.
    for (const listener of [...listeners]) listener();
  }

  function tick(): void {
    current = now();
    notify();
  }

  return {
    get() {
      return current;
    },
    subscribe(listener) {
      listeners.add(listener);
      if (listeners.size === 1) {
        timer = setInterval(tick, intervalMs);
        // With no listener there was no beat, so the reading may be old: a component that
        // mounts after a long idle renders again with the time now.
        const fresh = now();
        if (fresh !== current) {
          current = fresh;
          notify();
        }
      }
      return () => {
        listeners.delete(listener);
        if (listeners.size === 0 && timer !== null) {
          clearInterval(timer);
          timer = null;
        }
      };
    },
  };
}

const tickers = new Map<number, Ticker>();

/** The time now, in Unix milliseconds, read again every `intervalMs`, which renders the component again. */
export function useNow(intervalMs: number): number {
  let ticker = tickers.get(intervalMs);
  if (ticker === undefined) {
    ticker = createTicker(intervalMs);
    tickers.set(intervalMs, ticker);
  }
  return useSyncExternalStore(ticker.subscribe, ticker.get);
}
