import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RESUME_COALESCE_MS, SIGNAL_TIMEOUT_MS } from '../../constants.js';
import { checkPresence, fetchPresence, readPresenceBody } from '../../presence.js';
import { FakeClock } from '../support/fake-clock.js';
import { fakeVisibility } from '../support/helpers.js';

const RELAY = 'https://acme-relay.acme.workers.dev';
const ROOM = 'A'.repeat(43);
const ROOM_B = 'E'.repeat(43);
const flush = () => new Promise((resolve) => setImmediate(resolve));

/**
 * A fetch that records each call and answers from `answer`.
 * @param {(url: string, init: RequestInit) => Promise<{ status: number, json(): Promise<unknown> }>} answer
 */
function fakeFetch(answer) {
  /** @type {Array<{ url: string, init: RequestInit }>} */
  const calls = [];
  /** @param {string} url @param {RequestInit} init */
  const fetch = (url, init) => {
    calls.push({ url, init });
    return answer(url, init);
  };
  return { fetch, calls };
}

/** @param {number} status @param {unknown} body */
const reply = (status, body) => async () => ({ status, json: async () => body });
const never = () => new Promise(() => {});

test('the body reads laptop true as online and false as offline', () => {
  assert.equal(readPresenceBody({ laptop: true }), 'online');
  assert.equal(readPresenceBody({ laptop: false }), 'offline');
  assert.equal(readPresenceBody({ laptop: false, extra: 1 }), 'offline');
});

test('any other body reads as relay', () => {
  for (const body of [null, undefined, 'online', 1, true, [], [true], {}, { laptop: 'true' }, { laptop: 1 }, { Laptop: true }]) {
    assert.equal(readPresenceBody(body), 'relay', JSON.stringify(body));
  }
});

test('asks the presence URL with no cache, no credentials, no referrer and no redirects', async () => {
  const { fetch, calls } = fakeFetch(reply(200, { laptop: true }));
  const clock = new FakeClock();
  assert.equal(await fetchPresence({ fetch, relay: RELAY, room: ROOM, visibility: fakeVisibility(), clock }), 'online');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, `${RELAY}/v1/rooms/${ROOM}/presence`);
  const { signal, ...init } = calls[0].init;
  assert.deepEqual(init, { cache: 'no-store', credentials: 'omit', referrerPolicy: 'no-referrer', redirect: 'error' });
  assert.ok(signal instanceof AbortSignal);
  assert.equal(clock.pending, 0, 'the timeout is cleared');
});

test('a loopback relay is asked over http', async () => {
  const { fetch, calls } = fakeFetch(reply(200, { laptop: false }));
  assert.equal(await fetchPresence({ fetch, relay: 'http://127.0.0.1:8787', room: ROOM, visibility: fakeVisibility(), clock: new FakeClock() }), 'offline');
  assert.equal(calls[0].url, `http://127.0.0.1:8787/v1/rooms/${ROOM}/presence`);
});

test('a status other than 200 reads as relay', async () => {
  for (const status of [204, 301, 404, 500, 503]) {
    const { fetch } = fakeFetch(reply(status, { laptop: true }));
    assert.equal(await fetchPresence({ fetch, relay: RELAY, room: ROOM, visibility: fakeVisibility(), clock: new FakeClock() }), 'relay', String(status));
  }
});

test('a network error or a body that is not JSON reads as relay', async () => {
  const refused = fakeFetch(async () => { throw new TypeError('Load failed'); });
  assert.equal(await fetchPresence({ fetch: refused.fetch, relay: RELAY, room: ROOM, visibility: fakeVisibility(), clock: new FakeClock() }), 'relay');
  const garbled = fakeFetch(async () => ({ status: 200, json: async () => { throw new SyntaxError('bad JSON'); } }));
  assert.equal(await fetchPresence({ fetch: garbled.fetch, relay: RELAY, room: ROOM, visibility: fakeVisibility(), clock: new FakeClock() }), 'relay');
});

test('a relay or room the URL builder refuses reads as relay without a request', async () => {
  const { fetch, calls } = fakeFetch(reply(200, { laptop: true }));
  for (const [relay, room] of [['http://acme.example', ROOM], ['https://acme.example/path', ROOM], [RELAY, 'short']]) {
    assert.equal(await fetchPresence({ fetch, relay, room, visibility: fakeVisibility(), clock: new FakeClock() }), 'relay');
  }
  assert.equal(calls.length, 0);
});

test('no answer within the signal timeout reads as relay, and aborts the request', async () => {
  const { fetch, calls } = fakeFetch(never);
  const clock = new FakeClock();
  /** @type {string | null} */
  let status = null;
  fetchPresence({ fetch, relay: RELAY, room: ROOM, visibility: fakeVisibility(), clock }).then((s) => { status = s; });
  await flush();
  await clock.advance(SIGNAL_TIMEOUT_MS - 1);
  await flush();
  assert.equal(status, null);
  await clock.advance(1);
  await flush();
  assert.equal(status, 'relay');
  assert.equal(calls[0].init.signal?.aborted, true);
});

test('only time while the page is visible counts toward the timeout', async () => {
  const { fetch, calls } = fakeFetch(never);
  const clock = new FakeClock();
  const visibility = fakeVisibility();
  /** @type {string | null} */
  let status = null;
  fetchPresence({ fetch, relay: RELAY, room: ROOM, visibility, clock }).then((s) => { status = s; });
  await flush();
  // The phone locks with the request out: iOS freezes the page, and the time does not count.
  await clock.advance(SIGNAL_TIMEOUT_MS - 1);
  visibility.hide();
  await clock.advance(SIGNAL_TIMEOUT_MS * 6);
  await flush();
  assert.equal(status, null);
  assert.equal(calls[0].init.signal?.aborted, false);

  // Back on the page, the request gets a fresh SIGNAL_TIMEOUT_MS.
  visibility.show();
  await clock.advance(SIGNAL_TIMEOUT_MS - 1);
  await flush();
  assert.equal(status, null);
  await clock.advance(1);
  await flush();
  assert.equal(status, 'relay');
  assert.equal(calls[0].init.signal?.aborted, true);
  assert.equal(visibility.listeners(), 0, 'the visibility listener goes with the timer');
  assert.equal(clock.pending, 0);
});

test('a body that never finishes reading also times out', async () => {
  const { fetch } = fakeFetch(async () => ({ status: 200, json: never }));
  const clock = new FakeClock();
  /** @type {string | null} */
  let status = null;
  fetchPresence({ fetch, relay: RELAY, room: ROOM, visibility: fakeVisibility(), clock }).then((s) => { status = s; });
  await flush();
  await clock.advance(SIGNAL_TIMEOUT_MS);
  await flush();
  assert.equal(status, 'relay');
});

test('checkPresence reports each laptop as its answer arrives', async () => {
  const { fetch, calls } = fakeFetch(async (url) => ({ status: 200, json: async () => ({ laptop: url.includes(ROOM) }) }));
  /** @type {Array<[string, string]>} */
  const results = [];
  checkPresence([{ id: 'a', relay: RELAY, room: ROOM }, { id: 'b', relay: RELAY, room: ROOM_B }], {
    fetch, visibility: fakeVisibility(), clock: new FakeClock(), onResult: (id, status) => results.push([id, status]),
  });
  await flush();
  assert.equal(calls.length, 2);
  assert.deepEqual(results.sort(), [['a', 'online'], ['b', 'offline']]);
});

test('abort cancels every request still out and reports nothing more', async () => {
  const { fetch, calls } = fakeFetch(never);
  const clock = new FakeClock();
  const visibility = fakeVisibility();
  /** @type {Array<[string, string]>} */
  const results = [];
  const checks = checkPresence([{ id: 'a', relay: RELAY, room: ROOM }, { id: 'b', relay: RELAY, room: ROOM_B }], {
    fetch, visibility, clock, onResult: (id, status) => results.push([id, status]),
  });
  await flush();
  checks.abort();
  await flush();
  await clock.advance(SIGNAL_TIMEOUT_MS);
  await flush();
  assert.deepEqual(results, []);
  assert.ok(calls.every((call) => call.init.signal?.aborted));
  assert.equal(clock.pending, 0, 'no timer is left');
  assert.equal(visibility.listeners(), 0, 'no visibility listener is left');
});

test('an answer after abort is dropped', async () => {
  /** @type {(value: { status: number, json(): Promise<unknown> }) => void} */
  let answer = () => {};
  const { fetch } = fakeFetch(() => new Promise((resolve) => { answer = resolve; }));
  /** @type {string[]} */
  const results = [];
  const checks = checkPresence([{ id: 'a', relay: RELAY, room: ROOM }], {
    fetch, visibility: fakeVisibility(), clock: new FakeClock(), onResult: (id) => results.push(id),
  });
  await flush();
  checks.abort();
  answer({ status: 200, json: async () => ({ laptop: true }) });
  await flush();
  assert.deepEqual(results, []);
});

test('recheck asks every laptop again, online and offline included; status keeps each answer until the new one', async () => {
  const ROOM_C = 'I'.repeat(43);
  const ROOM_D = 'M'.repeat(43);
  /** @type {Map<string, Array<(value: { status: number, json(): Promise<unknown> }) => void>>} */
  const waiting = new Map();
  /** @type {Map<string, unknown>} The next answer per room; a room without one waits for the test. */
  const answers = new Map([[ROOM, { laptop: true }], [ROOM_B, { laptop: false }], [ROOM_C, null]]);
  const { fetch, calls } = fakeFetch((url) => {
    const room = [ROOM, ROOM_B, ROOM_C, ROOM_D].find((r) => url.includes(r)) ?? '';
    if (answers.has(room)) {
      const body = answers.get(room);
      return body === null ? reply(503, null)() : reply(200, body)();
    }
    return new Promise((resolve) => waiting.set(url, [...(waiting.get(url) ?? []), resolve]));
  });
  const clock = new FakeClock();
  const visibility = fakeVisibility();
  /** @type {Array<[string, string]>} */
  const results = [];
  const checks = checkPresence([
    { id: 'a', relay: RELAY, room: ROOM }, { id: 'b', relay: RELAY, room: ROOM_B },
    { id: 'c', relay: RELAY, room: ROOM_C }, { id: 'd', relay: RELAY, room: ROOM_D },
  ], { fetch, visibility, clock, onResult: (id, status) => results.push([id, status]) });
  await flush();
  assert.deepEqual([checks.status('a'), checks.status('b'), checks.status('c'), checks.status('d')], ['online', 'offline', 'relay', undefined]);

  // A long lock, with `d`'s request out: meanwhile `a` went to sleep and `b` came back. On the
  // return every laptop is asked again, and `d`'s request is cancelled and asked again.
  answers.set(ROOM, null);
  answers.delete(ROOM_B);
  visibility.hide();
  await clock.advance(10 * 60_000);
  visibility.show();
  checks.recheck();
  assert.equal(calls.length, 8, 'one new request per laptop');
  assert.ok(calls[3].init.signal?.aborted, '`d`\'s first request is cancelled');
  await flush();
  assert.equal(checks.status('a'), 'relay', '`a` takes its new answer');
  assert.equal(checks.status('b'), 'offline', '`b` keeps its last answer while its new request is out');
  const bAgain = waiting.get(calls[5].url) ?? [];
  bAgain[0]({ status: 200, json: async () => ({ laptop: true }) });
  await flush();
  assert.equal(checks.status('b'), 'online');

  const [first, second] = waiting.get(calls[3].url) ?? [];
  first({ status: 200, json: async () => ({ laptop: true }) });
  await flush();
  assert.equal(checks.status('d'), undefined, 'a cancelled request\'s answer is dropped');
  second({ status: 200, json: async () => ({ laptop: false }) });
  await flush();
  assert.equal(checks.status('d'), 'offline');
  assert.deepEqual(results.filter(([id]) => id === 'd'), [['d', 'offline']]);
  assert.deepEqual(results.filter(([id]) => id === 'a'), [['a', 'online'], ['a', 'relay']]);
  assert.deepEqual(results.filter(([id]) => id === 'b'), [['b', 'offline'], ['b', 'online']]);
  checks.abort();
});

test('back-to-back rechecks ask once: a request asked less than RESUME_COALESCE_MS before is left running', async () => {
  const { fetch, calls } = fakeFetch(never);
  const clock = new FakeClock();
  const laptops = [{ id: 'a', relay: RELAY, room: ROOM }, { id: 'b', relay: RELAY, room: ROOM_B }];
  const checks = checkPresence(laptops, { fetch, visibility: fakeVisibility(), clock, onResult: () => {} });
  await flush();
  assert.equal(calls.length, 2);

  // A return to the page right after the screen asked leaves those requests running.
  checks.recheck();
  assert.equal(calls.length, 2);

  // A later return: visibilitychange and pageshow, back to back, ask once.
  await clock.advance(RESUME_COALESCE_MS);
  checks.recheck();
  assert.equal(calls.length, 4);
  assert.ok(calls[0].init.signal?.aborted && calls[1].init.signal?.aborted, 'the first requests are cancelled');
  await clock.advance(RESUME_COALESCE_MS - 1);
  checks.recheck();
  assert.equal(calls.length, 4, 'the second event of the pair asks nothing');
  assert.ok(!calls[2].init.signal?.aborted && !calls[3].init.signal?.aborted, 'and cancels nothing');

  // The next return asks again.
  await clock.advance(1);
  checks.recheck();
  assert.equal(calls.length, 6);
  checks.abort();
});

test('recheck after abort asks nothing', async () => {
  const { fetch, calls } = fakeFetch(reply(503, null));
  const checks = checkPresence([{ id: 'a', relay: RELAY, room: ROOM }], {
    fetch, visibility: fakeVisibility(), clock: new FakeClock(), onResult: () => {},
  });
  await flush();
  assert.equal(checks.status('a'), 'relay');
  checks.abort();
  checks.recheck();
  await flush();
  assert.equal(calls.length, 1);
});
