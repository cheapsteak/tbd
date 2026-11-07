import { test } from 'node:test';
import assert from 'node:assert/strict';

import { TimeoutError, withTimeout } from '../../clock.js';
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

test('an answer in time passes through and clears the timer', async () => {
  const clock = new FakeClock();
  const work = deferred();
  const seen = watch(withTimeout(work.promise, 1000, clock));
  assert.equal(clock.pending, 1);
  await clock.advance(999);
  work.resolve('rows');
  await flush();
  assert.deepEqual(seen, { state: 'resolved', value: 'rows' });
  assert.equal(clock.pending, 0);
});

test('a failure in time passes through and clears the timer', async () => {
  const clock = new FakeClock();
  const work = deferred();
  const seen = watch(withTimeout(work.promise, 1000, clock));
  const failure = new Error('the store is gone');
  work.reject(failure);
  await flush();
  assert.deepEqual(seen, { state: 'rejected', value: failure });
  assert.equal(clock.pending, 0);
});

test('no answer by the deadline rejects with a TimeoutError, on the clock and not before', async () => {
  const clock = new FakeClock();
  const work = deferred();
  const seen = watch(withTimeout(work.promise, 1000, clock));
  await clock.advance(999);
  assert.equal(seen.state, 'pending');
  await clock.advance(1);
  assert.equal(seen.state, 'rejected');
  assert.ok(seen.value instanceof TimeoutError);

  // A late answer changes nothing.
  work.resolve('late');
  await flush();
  assert.equal(seen.state, 'rejected');
});
