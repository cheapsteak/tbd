import { test } from 'node:test';
import assert from 'node:assert/strict';

import { TaskChain } from '../../chain.js';
import { FakeClock } from '../support/fake-clock.js';
import { fakeVisibility } from '../support/helpers.js';

const flush = () => new Promise((resolve) => setImmediate(resolve));

/** A chain whose owner a test can end, recording the errors its tasks throw. */
function makeChain() {
  const owner = { ended: false, errors: /** @type {unknown[]} */ ([]) };
  const clock = new FakeClock();
  const chain = new TaskChain({
    isEnded: () => owner.ended,
    onError: (error) => owner.errors.push(error),
    clock,
  });
  return { owner, clock, chain };
}

test('a task runs only after the one queued before it has settled', async () => {
  const { chain } = makeChain();
  /** @type {string[]} */
  const seen = [];
  chain.enqueue(async () => {
    seen.push('first starts');
    await flush();
    seen.push('first ends');
  });
  chain.enqueue(() => {
    seen.push('second');
  });
  for (let i = 0; i < 5; i += 1) await flush();
  assert.deepEqual(seen, ['first starts', 'first ends', 'second']);
});

test('tasks still queued when the owner ends never run', async () => {
  const { owner, chain } = makeChain();
  /** @type {string[]} */
  const seen = [];
  chain.enqueue(() => {
    seen.push('first');
    owner.ended = true;
  });
  chain.enqueue(() => {
    seen.push('second');
  });
  for (let i = 0; i < 5; i += 1) await flush();
  assert.deepEqual(seen, ['first']);
});

test('a task that throws or rejects goes to onError, and later tasks still run', async () => {
  const { owner, chain } = makeChain();
  const thrown = new Error('thrown');
  const rejected = new Error('rejected');
  let ran = false;
  chain.enqueue(() => {
    throw thrown;
  });
  chain.enqueue(async () => {
    throw rejected;
  });
  chain.enqueue(() => {
    ran = true;
  });
  for (let i = 0; i < 5; i += 1) await flush();
  assert.deepEqual(owner.errors, [thrown, rejected]);
  assert.equal(ran, true);
});

test('an armed timer queues its work on the chain once its time has passed on the clock', async () => {
  const { clock, chain } = makeChain();
  let fired = 0;
  chain.arm(100, () => {
    fired += 1;
  });
  await clock.advance(99);
  assert.equal(fired, 0);
  await clock.advance(1);
  await flush();
  assert.equal(fired, 1);
  assert.equal(clock.pending, 0);
});

test('disarm stops a timer before it fires, and work it already queued', async () => {
  const { clock, chain } = makeChain();
  let fired = 0;
  const early = chain.arm(100, () => {
    fired += 1;
  });
  assert.equal(chain.disarm(early), null);
  assert.equal(clock.pending, 0);

  // The timer fires behind a slow task, so its work waits in the queue; disarming then
  // still stops it.
  /** @type {() => void} */
  let release = () => {};
  chain.enqueue(() => new Promise((resolve) => {
    release = () => resolve(undefined);
  }));
  const queued = chain.arm(100, () => {
    fired += 1;
  });
  await clock.advance(100);
  chain.disarm(queued);
  release();
  for (let i = 0; i < 5; i += 1) await flush();
  assert.equal(fired, 0);
  assert.equal(chain.disarm(null), null);
});

test('armVisible counts only visible time: a timer that falls due while hidden does nothing, and the return gives a fresh window', async () => {
  const clock = new FakeClock();
  const page = fakeVisibility();
  const chain = new TaskChain({ isEnded: () => false, onError: () => {}, visibility: page, clock });
  let fired = 0;
  chain.armVisible(1000, () => {
    fired += 1;
  });
  await clock.advance(600);
  // iOS hides the page, and the timer falls due before its visibilitychange arrives.
  page.freeze();
  await clock.advance(60_000);
  await flush();
  assert.equal(fired, 0);
  page.show();
  await clock.advance(999);
  await flush();
  assert.equal(fired, 0, 'a fresh 1000 from the return');
  await clock.advance(1);
  await flush();
  assert.equal(fired, 1);
  assert.equal(page.listeners(), 0);
  assert.equal(clock.pending, 0);

  // disarm stops the timer and its listener, hidden or not.
  const timer = chain.armVisible(1000, () => {
    fired += 1;
  });
  page.hide();
  assert.equal(clock.pending, 0, 'hidden, the timer stops');
  assert.equal(chain.disarm(timer), null);
  assert.equal(page.listeners(), 0);
  page.show();
  await clock.advance(5000);
  await flush();
  assert.equal(fired, 1);
});

test('without a visibility, armVisible runs on the clock as arm does', async () => {
  const { clock, chain } = makeChain();
  let fired = 0;
  chain.armVisible(100, () => {
    fired += 1;
  });
  await clock.advance(99);
  assert.equal(fired, 0);
  await clock.advance(1);
  await flush();
  assert.equal(fired, 1);
});
