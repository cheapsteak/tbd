import { test } from 'node:test';
import assert from 'node:assert/strict';

import { createFakeRelay } from './fake-relay.js';
import { fakeSocketFactory } from './fake-websocket.js';
import { FakeClock } from './fake-clock.js';

const ROOM = 'A'.repeat(43);
const OTHER_ROOM = 'B'.repeat(42) + '_';
/** @param {string} role */
const path = (role, room = ROOM) => `/v1/rooms/${room}?role=${role}`;

/** A sink that records what the relay sends it, as [kind, value] pairs. */
function recorder() {
  /** @type {Array<[string, any]>} */
  const events = [];
  return {
    events,
    /** @param {Uint8Array} bytes */ binary: (bytes) => events.push(['binary', [...bytes]]),
    /** @param {string} text */ text: (text) => events.push(['text', text]),
    /** @param {number} code @param {string} reason */ close: (code, reason) => events.push(['close', [code, reason]]),
  };
}

/** Joins a laptop and a phone; both have had their peer-joined, which is cleared. */
function paired(relay = createFakeRelay(), room = ROOM) {
  const laptop = recorder();
  const phone = recorder();
  const laptopSocket = /** @type {NonNullable<ReturnType<typeof relay.connect>>} */ (relay.connect(path('laptop', room), laptop));
  const phoneSocket = /** @type {NonNullable<ReturnType<typeof relay.connect>>} */ (relay.connect(path('phone', room), phone));
  assert.deepEqual(laptop.events, [['text', 'peer-joined']]);
  assert.deepEqual(phone.events, [['text', 'peer-joined']]);
  laptop.events.length = 0;
  phone.events.length = 0;
  return { relay, laptop, phone, laptopSocket, phoneSocket };
}

/** One macrotask turn, enough for the fake socket to deliver one queued event. */
const turn = () => new Promise((resolve) => setImmediate(resolve));

/**
 * @param {() => boolean} predicate
 * @param {string} what
 */
async function until(predicate, what) {
  for (let i = 0; i < 200; i++) {
    if (predicate()) return;
    await turn();
  }
  assert.fail(`timed out waiting for ${what}`);
}

/** Opens a fake browser socket and records its events in order. */
function browserSocket(relay, url) {
  const ws = fakeSocketFactory(relay)(url);
  /** @type {Array<[string, any]>} */
  const events = [];
  ws.onopen = () => events.push(['open', ws.readyState]);
  ws.onmessage = (ev) => events.push(['message', ev.data]);
  ws.onerror = () => events.push(['error', ws.readyState]);
  ws.onclose = (ev) => events.push(['close', [ev.code, ws.readyState]]);
  return { ws, events };
}

// --- relay rules ----------------------------------------------------------------------------

test('a join while the other role is open sends peer-joined to both sockets, either order', () => {
  paired();
  const relay = createFakeRelay();
  const phone = recorder();
  const laptop = recorder();
  relay.connect(path('phone'), phone);
  relay.connect(path('laptop'), laptop);
  assert.deepEqual(phone.events, [['text', 'peer-absent'], ['text', 'peer-joined']]);
  assert.deepEqual(laptop.events, [['text', 'peer-joined']]);
});

test('a lone phone gets peer-absent and a lone laptop gets nothing', () => {
  const relay = createFakeRelay();
  const phone = recorder();
  const laptop = recorder();
  relay.connect(path('phone'), phone);
  relay.connect(path('laptop', OTHER_ROOM), laptop);
  assert.deepEqual(phone.events, [['text', 'peer-absent']]);
  assert.deepEqual(laptop.events, []);
  assert.equal(relay.stats.phoneJoins.get(ROOM), 1);
  assert.equal(relay.stats.laptopJoins.get(OTHER_ROOM), 1);
});

test('a new socket replaces the old one with 4000 and causes no peer-left', () => {
  for (const role of ['phone', 'laptop']) {
    const { relay, laptop, phone } = paired();
    const replacement = recorder();
    const [old, peer] = role === 'phone' ? [phone, laptop] : [laptop, phone];
    relay.connect(path(role), replacement);
    assert.deepEqual(old.events, [['close', [4000, 'replaced']]], role);
    assert.deepEqual(peer.events, [['text', 'peer-joined']], role);
    assert.deepEqual(replacement.events, [['text', 'peer-joined']], role);
  }
});

test('frames from a replaced socket are dropped', () => {
  const { relay, laptop, phoneSocket } = paired();
  relay.connect(path('phone'), recorder());
  laptop.events.length = 0;
  phoneSocket.send(new Uint8Array([5]));
  phoneSocket.close(1000);
  assert.deepEqual(laptop.events, []);
});

test('peer-left goes to the other role when the last socket of a role closes', () => {
  const { relay, laptop, phone, phoneSocket, laptopSocket } = paired();
  phoneSocket.close(1000, 'bye');
  assert.deepEqual(laptop.events, [['text', 'peer-left']]);
  phoneSocket.close(1000, '');
  assert.deepEqual(laptop.events, [['text', 'peer-left']], 'a second close is a no-op');
  const phone2 = recorder();
  relay.connect(path('phone'), phone2);
  laptopSocket.close();
  assert.deepEqual(phone2.events, [['text', 'peer-joined'], ['text', 'peer-left']]);
  // The relay answers each client's own close, once.
  assert.deepEqual(phone.events, [['close', [1000, 'bye']]]);
  assert.deepEqual(laptop.events.at(-1), ['close', [1005, '']]);
});

test('binary frames are forwarded unchanged to the other role, up to 65,536 bytes', () => {
  const { laptop, phone, laptopSocket, phoneSocket } = paired();
  phoneSocket.send(new Uint8Array([1, 2, 3]));
  laptopSocket.send(new Uint8Array([4, 5]).buffer);
  const big = new Uint8Array(65_536).fill(7);
  phoneSocket.send(big);
  assert.deepEqual(laptop.events.slice(0, 1), [['binary', [1, 2, 3]]]);
  assert.equal(laptop.events[1][1].length, 65_536);
  assert.deepEqual(phone.events, [['binary', [4, 5]]]);
});

test('a frame over 65,536 bytes closes its sender with 1009 and the peer gets peer-left', () => {
  const { relay, laptop, phone, phoneSocket } = paired();
  phoneSocket.send(new Uint8Array(65_537));
  assert.deepEqual(phone.events, [['close', [1009, 'frame too large']]]);
  assert.deepEqual(laptop.events, [['text', 'peer-left']]);
  phoneSocket.send(new Uint8Array([1]));
  assert.deepEqual(laptop.events, [['text', 'peer-left']]);
  assert.equal(relay.presence(`/v1/rooms/${ROOM}/presence`).body?.laptop, true);
});

test('client text is never forwarded', () => {
  const { laptop, phone, phoneSocket, laptopSocket } = paired();
  phoneSocket.send('peer-left');
  phoneSocket.send('hello');
  laptopSocket.send('peer-joined');
  assert.deepEqual(laptop.events, []);
  assert.deepEqual(phone.events, []);
});

test('ping gets pong, counted per room', () => {
  const { relay, laptop, phone, phoneSocket, laptopSocket } = paired();
  phoneSocket.send('ping');
  phoneSocket.send('ping');
  laptopSocket.send('ping');
  assert.deepEqual(phone.events, [['text', 'pong'], ['text', 'pong']]);
  assert.deepEqual(laptop.events, [['text', 'pong']]);
  assert.equal(relay.stats.pings.get(ROOM), 3);
});

test('frames are dropped while the other role is absent', () => {
  const relay = createFakeRelay();
  const phone = recorder();
  const phoneSocket = relay.connect(path('phone'), phone);
  phoneSocket?.send(new Uint8Array([9]));
  const laptop = recorder();
  relay.connect(path('laptop'), laptop);
  assert.deepEqual(laptop.events, [['text', 'peer-joined']]);
});

test('a black-holed room drops everything both ways, answers no ping and never closes', () => {
  const { relay, laptop, phone, phoneSocket, laptopSocket } = paired();
  relay.blackHole(ROOM, true);
  phoneSocket.send(new Uint8Array([1]));
  laptopSocket.send(new Uint8Array([2]));
  phoneSocket.send('ping');
  const phone2 = recorder();
  relay.connect(path('phone'), phone2);
  laptopSocket.send(new Uint8Array(70_000));
  const phone3 = recorder();
  relay.connect(path('phone', OTHER_ROOM), phone3);
  relay.blackHole(OTHER_ROOM, true);
  const phone4 = recorder();
  relay.connect(path('phone', OTHER_ROOM), phone4)?.close(1000);
  assert.deepEqual([laptop.events, phone.events, phone2.events, phone4.events], [[], [], [], []], 'not even the echo of a close');
  assert.deepEqual(phone3.events, [['text', 'peer-absent']], 'no 4000 for the replaced socket');
  assert.equal(relay.stats.pings.get(ROOM), undefined);
  assert.equal(relay.stats.phoneJoins.get(ROOM), 2, 'joins still count');
  relay.blackHole(ROOM, false);
  phoneSocket.send(new Uint8Array([3]));
  assert.deepEqual(laptop.events, [], 'the replaced socket stays replaced');
  laptopSocket.send(new Uint8Array([4]));
  assert.deepEqual(phone2.events, [['binary', [4]]]);
});

test('a black hole counts what it swallows, per room, and nothing from a replaced socket', () => {
  const { relay, phoneSocket, laptopSocket } = paired();
  relay.blackHole(ROOM, true);
  phoneSocket.send('ping');
  phoneSocket.send(new Uint8Array([1]));
  laptopSocket.send(new Uint8Array([2]));
  assert.equal(relay.stats.swallowed.get(ROOM), 3);
  assert.equal(relay.stats.swallowed.get(OTHER_ROOM), undefined);
  relay.connect(path('phone'), recorder());
  phoneSocket.send('ping');
  assert.equal(relay.stats.swallowed.get(ROOM), 3, 'the replaced socket sends nothing');
  relay.blackHole(ROOM, false);
  laptopSocket.send(new Uint8Array([3]));
  assert.equal(relay.stats.swallowed.get(ROOM), 3);
});

test('tamper changes, duplicates or drops laptop-to-phone frames only', () => {
  const { relay, laptop, phone, phoneSocket, laptopSocket } = paired();
  relay.tamper(ROOM, (frame) => {
    if (frame[0] === 1) return frame.map((b) => b + 10);
    if (frame[0] === 2) return [frame, frame];
    return null;
  });
  laptopSocket.send(new Uint8Array([1, 1]));
  laptopSocket.send(new Uint8Array([2]));
  laptopSocket.send(new Uint8Array([3]));
  phoneSocket.send(new Uint8Array([3]));
  assert.deepEqual(phone.events, [['binary', [11, 11]], ['binary', [2]], ['binary', [2]]]);
  assert.deepEqual(laptop.events, [['binary', [3]]]);
  relay.tamper(ROOM, null);
  laptopSocket.send(new Uint8Array([3]));
  assert.deepEqual(phone.events.at(-1), ['binary', [3]]);
});

test('a bad room path is refused', () => {
  const relay = createFakeRelay();
  for (const bad of [
    `/v1/rooms/${'A'.repeat(42)}?role=phone`,
    `/v1/rooms/${'A'.repeat(44)}?role=phone`,
    `/v1/rooms/${'A'.repeat(42)}+?role=phone`,
    `/v1/rooms/${'A'.repeat(42)}=?role=phone`,
    `/v1/rooms/${ROOM}/?role=phone`,
    `/v1/rooms/${ROOM}/x?role=phone`,
    `/v1/rooms/${ROOM}`,
    `/v1/rooms/${ROOM}?role=admin`,
    `/v1/rooms/${ROOM}?role=Laptop`,
    `/v1/rooms/${ROOM}?role=laptop&role=phone`,
    `/v2/rooms/${ROOM}?role=phone`,
  ]) {
    assert.equal(relay.connect(bad, recorder()), null, bad);
  }
  assert.equal(relay.stats.phoneJoins.size + relay.stats.laptopJoins.size, 0);
});

test('presence reports an open laptop socket and touches nothing', () => {
  const relay = createFakeRelay();
  const presence = `/v1/rooms/${ROOM}/presence`;
  assert.deepEqual(relay.presence(presence), { status: 200, body: { laptop: false } });
  const { laptop, phone, laptopSocket, phoneSocket } = paired(relay);
  const before = JSON.stringify([...Object.entries(relay.stats)].filter(([k]) => k !== 'presence').map(([k, m]) => [k, [...m]]));
  assert.deepEqual(relay.presence(presence), { status: 200, body: { laptop: true } });
  assert.deepEqual(relay.presence(`${presence}?t=1`), { status: 200, body: { laptop: true } });
  const after = JSON.stringify([...Object.entries(relay.stats)].filter(([k]) => k !== 'presence').map(([k, m]) => [k, [...m]]));
  assert.equal(after, before);
  assert.equal(relay.stats.presence.get(ROOM), 3);
  assert.deepEqual([laptop.events, phone.events], [[], []], 'nobody was displaced or signalled');
  phoneSocket.send(new Uint8Array([1]));
  assert.deepEqual(laptop.events, [['binary', [1]]], 'the phone is still connected');
  laptopSocket.close();
  assert.deepEqual(relay.presence(presence), { status: 200, body: { laptop: false } });
  for (const bad of [`/v1/rooms/${'A'.repeat(42)}/presence`, `/v1/rooms/${ROOM}`, `/v1/rooms/${ROOM}/presence/x`, '/v1/info']) {
    assert.deepEqual(relay.presence(bad), { status: 404 }, bad);
  }
});

// --- the fake browser socket ----------------------------------------------------------------

test('the fake socket connects on a later task and delivers events in order, one per task', async () => {
  const relay = createFakeRelay();
  relay.connect(path('laptop'), recorder());
  const { ws, events } = browserSocket(relay, `wss://relay.acme.test${path('phone')}`);
  ws.binaryType = 'arraybuffer';
  assert.equal(ws.readyState, 0);
  assert.throws(() => ws.send('ping'), { name: 'InvalidStateError' });
  assert.equal(relay.stats.phoneJoins.get(ROOM), undefined, 'not connected yet');
  await turn();
  assert.deepEqual(events, [['open', 1]]);
  assert.equal(ws.readyState, 1);
  assert.equal(relay.stats.phoneJoins.get(ROOM), 1);
  await turn();
  assert.deepEqual(events.at(-1), ['message', 'peer-joined']);
  ws.send('ping');
  ws.send(new Uint8Array([1, 2]));
  assert.equal(events.length, 2, 'nothing is delivered synchronously');
  await until(() => events.length === 3, 'pong');
  assert.deepEqual(events.at(-1), ['message', 'pong']);
});

test('the fake socket gives ArrayBuffer data for arraybuffer and a Blob otherwise', async () => {
  const relay = createFakeRelay();
  const laptop = relay.connect(path('laptop'), recorder());
  const a = browserSocket(relay, `ws://127.0.0.1:8787${path('phone')}`);
  a.ws.binaryType = 'arraybuffer';
  await until(() => a.events.length === 2, 'open and peer-joined');
  laptop?.send(new Uint8Array([7, 8]));
  await until(() => a.events.length === 3, 'a frame');
  assert.ok(a.events[2][1] instanceof ArrayBuffer);
  assert.deepEqual([...new Uint8Array(a.events[2][1])], [7, 8]);
  const b = browserSocket(relay, `ws://127.0.0.1:8787${path('phone')}`);
  await until(() => b.events.length === 2, 'open and peer-joined');
  laptop?.send(new Uint8Array([9]));
  await until(() => b.events.length === 3, 'a frame');
  assert.ok(b.events[2][1] instanceof Blob);
  assert.deepEqual([...new Uint8Array(await b.events[2][1].arrayBuffer())], [9]);
});

test('a socket pinned to a relay origin is refused anywhere else, like a refused path', async () => {
  const relay = createFakeRelay();
  /** @type {Array<[string, string, boolean]>} */
  const cases = [
    ['https://relay.acme.test', 'wss://relay.acme.test', true],
    ['https://relay.acme.test', 'wss://RELAY.acme.test:443', true],
    ['https://relay.acme.test', 'ws://relay.acme.test', false],
    ['https://relay.acme.test', 'wss://relay.acme.test:8443', false],
    ['https://relay.acme.test', 'wss://other.acme.test', false],
    ['http://127.0.0.1:8787', 'ws://127.0.0.1:8787', true],
    ['http://127.0.0.1:8787', 'ws://127.0.0.1', false],
    ['http://127.0.0.1:8787', 'wss://127.0.0.1:8787', false],
    ['http://127.0.0.1', 'ws://127.0.0.1:80', true],
    ['http://127.0.0.1', 'ws://localhost', false],
  ];
  for (const [origin, base, reaches] of cases) {
    const before = relay.stats.phoneJoins.get(ROOM) ?? 0;
    const ws = fakeSocketFactory(relay, { origin })(`${base}${path('phone')}`);
    /** @type {Array<[string, any]>} */
    const events = [];
    ws.onopen = () => events.push(['open', ws.readyState]);
    ws.onerror = () => events.push(['error', ws.readyState]);
    ws.onclose = (ev) => events.push(['close', [ev.code, ws.readyState]]);
    await until(() => events.length > 0 && (reaches || events.length === 2), `${base} for ${origin}`);
    const what = `${base} for ${origin}`;
    if (reaches) {
      assert.deepEqual(events, [['open', 1]], what);
      assert.equal(relay.stats.phoneJoins.get(ROOM), before + 1, what);
      ws.close(1000);
    } else {
      assert.deepEqual(events, [['error', 3], ['close', [1006, 3]]], what);
      assert.equal(relay.stats.phoneJoins.get(ROOM) ?? 0, before, what);
    }
  }
  assert.throws(() => fakeSocketFactory(relay, { origin: 'ftp://relay.acme.test' }), TypeError);
});

test('a refused path fires error, then close 1006, without open', async () => {
  const relay = createFakeRelay();
  const { ws, events } = browserSocket(relay, 'wss://relay.acme.test/v1/rooms/short?role=phone');
  await until(() => events.length === 2, 'error and close');
  assert.deepEqual(events, [['error', 3], ['close', [1006, 3]]]);
  assert.equal(ws.readyState, 3);
  assert.throws(() => fakeSocketFactory(relay)('https://relay.acme.test/'), { name: 'SyntaxError' });
});

test('a relay close reaches onclose after earlier messages, and later sends are dropped', async () => {
  const relay = createFakeRelay();
  const laptop = recorder();
  relay.connect(path('laptop'), laptop);
  const { ws, events } = browserSocket(relay, `wss://relay.acme.test${path('phone')}`);
  await until(() => events.length === 2, 'open and peer-joined');
  relay.connect(path('phone'), recorder());
  laptop.events.length = 0;
  assert.equal(ws.readyState, 1, 'still open until the close is delivered');
  ws.send(new Uint8Array([1]));
  await until(() => events.length === 3, 'the close');
  assert.deepEqual(events[2], ['close', [4000, 3]]);
  ws.send(new Uint8Array([2]));
  assert.deepEqual(laptop.events, []);
});

test('closing the fake socket goes 2 then 3, and the peer gets peer-left at once', async () => {
  const relay = createFakeRelay();
  const laptop = recorder();
  relay.connect(path('laptop'), laptop);
  const { ws, events } = browserSocket(relay, `wss://relay.acme.test${path('phone')}`);
  await until(() => events.length === 2, 'open and peer-joined');
  laptop.events.length = 0;
  assert.throws(() => ws.close(1001), { name: 'InvalidAccessError' });
  ws.close(1000);
  assert.equal(ws.readyState, 2);
  assert.deepEqual(laptop.events, [['text', 'peer-left']]);
  ws.send(new Uint8Array([1]));
  ws.close(1000);
  await until(() => events.length === 3, 'the close');
  assert.deepEqual(events[2], ['close', [1000, 3]]);
  assert.deepEqual(laptop.events, [['text', 'peer-left']]);
});

test('closing a fake socket in a black-holed room never fires onclose', async () => {
  const relay = createFakeRelay();
  const laptop = recorder();
  relay.connect(path('laptop'), laptop);
  const { ws, events } = browserSocket(relay, `wss://relay.acme.test${path('phone')}`);
  await until(() => events.length === 2, 'open and peer-joined');
  relay.blackHole(ROOM, true);
  ws.close(1000);
  assert.equal(ws.readyState, 2);
  for (let i = 0; i < 20; i++) await turn();
  relay.blackHole(ROOM, false);
  // The relay counts the socket as gone, so the next one replaces nobody (no 4000 either).
  const next = browserSocket(relay, `wss://relay.acme.test${path('phone')}`);
  await until(() => next.events.length === 2, 'the next socket');
  for (let i = 0; i < 20; i++) await turn();
  assert.deepEqual(events.slice(2), [], 'no close comes, even after the black hole lifts');
  assert.equal(ws.readyState, 2);
});

test('closing a fake socket that is still connecting fails it without joining', async () => {
  const relay = createFakeRelay();
  const { ws, events } = browserSocket(relay, `wss://relay.acme.test${path('phone')}`);
  ws.close();
  assert.equal(ws.readyState, 2);
  await until(() => events.length === 2, 'error and close');
  assert.deepEqual(events, [['error', 2], ['close', [1006, 3]]]);
  assert.equal(relay.stats.phoneJoins.get(ROOM), undefined);
});

// --- the fake clock -------------------------------------------------------------------------

test('the fake clock runs due timers in time order and flushes between them', async () => {
  const clock = new FakeClock(1_000);
  /** @type {string[]} */
  const ran = [];
  clock.setTimeout(() => ran.push(`b@${clock.now()}`), 20);
  clock.setTimeout(() => {
    ran.push(`a@${clock.now()}`);
    Promise.resolve().then(() => clock.setTimeout(() => ran.push(`c@${clock.now()}`), 5));
  }, 10);
  const cancelled = clock.setTimeout(() => ran.push('never'), 15);
  clock.clearTimeout(cancelled);
  clock.setTimeout(() => ran.push('late'), 31);
  assert.equal(clock.pending, 3);
  await clock.advance(30);
  assert.deepEqual(ran, ['a@1010', 'c@1015', 'b@1020']);
  assert.equal(clock.now(), 1_030);
  assert.equal(clock.pending, 1);
  await clock.advance(1);
  assert.deepEqual(ran.at(-1), 'late');
});
