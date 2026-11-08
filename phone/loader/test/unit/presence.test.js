import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SIGNAL_TIMEOUT_MS } from '../../constants.js';
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
