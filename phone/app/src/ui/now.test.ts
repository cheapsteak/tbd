// Tests now.ts's ticker, on mocked timers and a clock the test sets: its reading moves only on
// a beat, listeners share one timer that stops with the last of them, and an idle ticker is
// never a beat old. `useNow` itself is React's `useSyncExternalStore` over a ticker, and the
// end-to-end tests see it work.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createTicker } from './now.ts';

test('a ticker reads the time again on each beat, and only then', (t) => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  let clock = 1_000;
  const ticker = createTicker(30_000, () => clock);
  let beats = 0;
  clock = 5_000;
  ticker.subscribe(() => { beats++; });
  // The first listener takes the time at once.
  assert.equal(ticker.get(), 5_000);
  clock = 20_000;
  assert.equal(ticker.get(), 5_000);
  t.mock.timers.tick(29_999);
  assert.equal(beats, 0);
  t.mock.timers.tick(1);
  assert.equal(beats, 1);
  assert.equal(ticker.get(), 20_000);
});

test('listeners share one timer, which stops when the last one leaves', (t) => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  const ticker = createTicker(1_000, () => 0);
  const heard: string[] = [];
  const offA = ticker.subscribe(() => { heard.push('a'); });
  const offB = ticker.subscribe(() => { heard.push('b'); });
  t.mock.timers.tick(1_000);
  // One timer: each listener hears each beat once.
  assert.deepEqual(heard, ['a', 'b']);
  offA();
  t.mock.timers.tick(1_000);
  assert.deepEqual(heard, ['a', 'b', 'b']);
  offB();
  t.mock.timers.tick(5_000);
  assert.deepEqual(heard, ['a', 'b', 'b']);
  // A new listener starts the beat again.
  ticker.subscribe(() => { heard.push('c'); });
  t.mock.timers.tick(1_000);
  assert.deepEqual(heard, ['a', 'b', 'b', 'c']);
});

test('an idle ticker is never a beat old', () => {
  let clock = 0;
  const ticker = createTicker(30_000, () => clock);
  clock = 29_999;
  assert.equal(ticker.get(), 0);
  clock = 30_000;
  assert.equal(ticker.get(), 30_000);
  clock = 30_001;
  assert.equal(ticker.get(), 30_000);
});
