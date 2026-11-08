/**
 * The time a component shows ages and elapsed times against (spec section 8.2), read again on a
 * fixed beat: every 30 s for the ages, and every 1 s for the "Working…" line's elapsed time. The
 * sessions screens (part 6b) and the transcript (part 6c) both read it through `useNow`.
 *
 * Every component that asks for the same beat shares one ticker, so the ages on a screen move
 * together and one timer runs per beat, not one per row. A ticker runs its timer only while a
 * component listens.
 */

import { useSyncExternalStore } from 'react';

/** A clock that changes its reading only on its beat, as `useSyncExternalStore` needs. */
export interface Ticker {
  /** The reading: the same value until the next beat, never older than one beat. */
  get(): number;
  /** Calls `listener` on every beat, and returns the function that stops it. */
  subscribe(listener: () => void): () => void;
}

/** A ticker that reads `now` (Unix milliseconds) every `intervalMs`. */
export function createTicker(intervalMs: number, now: () => number = Date.now): Ticker {
  let current = now();
  const listeners = new Set<() => void>();
  let timer: ReturnType<typeof setInterval> | null = null;

  function tick(): void {
    current = now();
    // A copy, so a listener that unsubscribes does not change this round.
    for (const listener of [...listeners]) listener();
  }

  return {
    get() {
      // With no listener there is no beat, so a reading a beat old is taken afresh.
      if (listeners.size === 0 && now() - current >= intervalMs) current = now();
      return current;
    },
    subscribe(listener) {
      if (listeners.size === 0) {
        // The first listener reads the time at once; React renders again if it moved.
        current = now();
        timer = setInterval(tick, intervalMs);
      }
      listeners.add(listener);
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
