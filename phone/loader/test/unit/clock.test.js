import { test } from 'node:test';
import assert from 'node:assert/strict';

import { TimeoutError, withVisibleTimeout } from '../../clock.js';
import { STORE_TIMEOUT_MS } from '../../constants.js';
import { FakeClock } from '../support/fake-clock.js';

const flush = () => new Promise((resolve) => setImmediate(resolve));

/**
 * A promise and the functions that settle it.
 * @template T
 */
function deferred() {
  /** @type {(value: T) => void} */
  let resolve = () => {};
  /** @type {(error: unknown) => void} */
  let reject = () => {};
  /** @type {Promise<T>} */
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

/**
 * Follows a promise without awaiting it.
 * @param {Promise<unknown>} promise
 */
function watch(promise) {
  /** @type {{ state: 'pending' | 'resolved' | 'rejected', value?: unknown }} */
  const seen = { state: 'pending' };
  promise.then((value) => Object.assign(seen, { state: 'resolved', value }), (value) => Object.assign(seen, { state: 'rejected', value }));
  return seen;
}

/**
 * A page's visibility that a test flips. `show()` and `hide()` change it and tell the
 * listeners, as `visibilitychange` does; `freeze()` hides it without telling them yet, as when
 * a timer runs on the page's return before its `visibilitychange` is dispatched.
 * @param {boolean} [visible]
 */
function fakeVisibility(visible = true) {
  /** @type {Set<() => void>} */
  const listeners = new Set();
  const change = (/** @type {boolean} */ next) => {
    visible = next;
    for (const listener of [...listeners]) listener();
  };
  return {
    isVisible: () => visible,
    /** @param {() => void} listener */
    onChange(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    show: () => change(true),
    hide: () => change(false),
    freeze: () => {
      visible = false;
    },
    listeners: () => listeners.size,
  };
}

test('an answer in time passes through and clears the timer and the listener', async () => {
  const clock = new FakeClock();
  const page = fakeVisibility();
  const work = deferred();
  const seen = watch(withVisibleTimeout(work.promise, 1000, page, clock));
  assert.equal(clock.pending, 1);
  assert.equal(page.listeners(), 1);
  await clock.advance(999);
  work.resolve('rows');
  await flush();
  assert.deepEqual(seen, { state: 'resolved', value: 'rows' });
  assert.equal(clock.pending, 0);
  assert.equal(page.listeners(), 0);
});

test('a failure in time passes through and clears the timer and the listener', async () => {
  const clock = new FakeClock();
  const page = fakeVisibility();
  const work = deferred();
  const seen = watch(withVisibleTimeout(work.promise, 1000, page, clock));
  const failure = new Error('the store is gone');
  work.reject(failure);
  await flush();
  assert.deepEqual(seen, { state: 'rejected', value: failure });
  assert.equal(clock.pending, 0);
  assert.equal(page.listeners(), 0);
});

test('no answer by the deadline rejects with a TimeoutError, on the clock and not before', async () => {
  const clock = new FakeClock();
  const page = fakeVisibility();
  const work = deferred();
  const seen = watch(withVisibleTimeout(work.promise, 1000, page, clock));
  await clock.advance(999);
  assert.equal(seen.state, 'pending');
  await clock.advance(1);
  assert.equal(seen.state, 'rejected');
  assert.ok(seen.value instanceof TimeoutError);
  assert.equal(page.listeners(), 0);

  // A late answer changes nothing.
  work.resolve('late');
  await flush();
  assert.equal(seen.state, 'rejected');
});

test('a timeout that elapses while the page is hidden does not reject', async () => {
  const clock = new FakeClock();
  const page = fakeVisibility();
  const work = deferred();
  const seen = watch(withVisibleTimeout(work.promise, STORE_TIMEOUT_MS, page, clock));
  await clock.advance(STORE_TIMEOUT_MS - 1);
  page.hide();
  assert.equal(clock.pending, 0, 'hidden, the timer stops');
  await clock.advance(STORE_TIMEOUT_MS * 10);
  assert.equal(seen.state, 'pending');
  assert.equal(page.listeners(), 1, 'still waiting for the page to be visible');
});

test('a timer that falls due while the page is hidden, before word of it, does not reject', async () => {
  const clock = new FakeClock();
  const hidden = fakeVisibility();
  const shown = fakeVisibility();
  const work = deferred();
  const seen = watch(withVisibleTimeout(work.promise, STORE_TIMEOUT_MS, hidden, clock));
  const control = watch(withVisibleTimeout(deferred().promise, STORE_TIMEOUT_MS, shown, clock));
  hidden.freeze();
  await clock.advance(STORE_TIMEOUT_MS);
  assert.equal(control.state, 'rejected', 'the same time on a visible page times out');
  assert.equal(seen.state, 'pending');
  assert.equal(clock.pending, 0);
  assert.equal(hidden.listeners(), 1, 'still waiting for the page to be visible');
});

test('back on the page, the request gets a fresh full window, and an answer in it resolves', async () => {
  const clock = new FakeClock();
  const page = fakeVisibility();
  const work = deferred();
  const seen = watch(withVisibleTimeout(work.promise, STORE_TIMEOUT_MS, page, clock));
  await clock.advance(STORE_TIMEOUT_MS - 1);
  page.freeze();
  await clock.advance(60_000);
  assert.equal(seen.state, 'pending');
  page.show();
  assert.equal(clock.pending, 1, 'a fresh timer from the return');
  await clock.advance(STORE_TIMEOUT_MS - 1);
  assert.equal(seen.state, 'pending');
  work.resolve('rows');
  await flush();
  assert.deepEqual(seen, { state: 'resolved', value: 'rows' });
  assert.equal(clock.pending, 0);
  assert.equal(page.listeners(), 0);
});

test('a request that never answers rejects after STORE_TIMEOUT_MS of visible time on end', async () => {
  const clock = new FakeClock();
  // Started while hidden: nothing counts until the page is visible.
  const page = fakeVisibility(false);
  const work = deferred();
  const seen = watch(withVisibleTimeout(work.promise, STORE_TIMEOUT_MS, page, clock));
  assert.equal(clock.pending, 0);
  await clock.advance(STORE_TIMEOUT_MS * 3);
  page.show();
  await clock.advance(STORE_TIMEOUT_MS - 2_000);
  page.hide();
  await clock.advance(STORE_TIMEOUT_MS);
  page.show();
  // Visible time before the last return does not add up.
  await clock.advance(STORE_TIMEOUT_MS - 1);
  assert.equal(seen.state, 'pending');
  await clock.advance(1);
  assert.equal(seen.state, 'rejected');
  assert.ok(seen.value instanceof TimeoutError);
  assert.equal(page.listeners(), 0);
  assert.equal(clock.pending, 0);
});
