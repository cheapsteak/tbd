// Tests now.ts's ticker, on mocked timers and a clock the test sets: its reading moves only on
// a beat or when a first listener arrives, never on a read, and listeners share one timer that
// stops with the last of them. `useNow` itself is React's `useSyncExternalStore` over a ticker,
// and the end-to-end tests see it work.

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
  // The first listener takes the time at once, and hears that it moved.
  assert.equal(ticker.get(), 5_000);
  assert.equal(beats, 1);
  clock = 20_000;
  assert.equal(ticker.get(), 5_000);
  t.mock.timers.tick(29_999);
  assert.equal(beats, 1);
  t.mock.timers.tick(1);
  assert.equal(beats, 2);
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

test('a read never moves the reading, even on an idle ticker a beat old', (t) => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  let clock = 0;
  const ticker = createTicker(30_000, () => clock);
  clock = 90_000;
  // Two reads in one render must agree, as useSyncExternalStore needs.
  assert.equal(ticker.get(), 0);
  clock = 120_000;
  assert.equal(ticker.get(), 0);
  // So must reads between beats while something listens.
  ticker.subscribe(() => {});
  clock = 125_000;
  assert.equal(ticker.get(), 120_000);
  assert.equal(ticker.get(), 120_000);
});

test('the first listener after an idle spell refreshes the reading and hears it moved', (t) => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  let clock = 0;
  const ticker = createTicker(30_000, () => clock);
  const heard: string[] = [];
  // A component that mounts long after the ticker last ran.
  clock = 3_600_000;
  const offA = ticker.subscribe(() => { heard.push('a'); });
  assert.equal(ticker.get(), 3_600_000);
  assert.deepEqual(heard, ['a']);
  // A second listener joins a running beat: the reading stays, and nobody hears anything.
  clock = 3_610_000;
  const offB = ticker.subscribe(() => { heard.push('b'); });
  assert.equal(ticker.get(), 3_600_000);
  assert.deepEqual(heard, ['a']);
  // Every listener leaves, and the next first one takes the time again.
  offA();
  offB();
  clock = 7_200_000;
  ticker.subscribe(() => { heard.push('c'); });
  assert.equal(ticker.get(), 7_200_000);
  assert.deepEqual(heard, ['a', 'c']);
});

test('a first listener is not called when the reading is already the time now', () => {
  const ticker = createTicker(30_000, () => 5_000);
  let heard = 0;
  const off = ticker.subscribe(() => { heard++; });
  assert.equal(ticker.get(), 5_000);
  assert.equal(heard, 0);
  off();
});
