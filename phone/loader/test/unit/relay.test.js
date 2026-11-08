import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RelaySocket, reconnectDelay } from '../../relay.js';
import { KEEPALIVE_MS, RESUME_PONG_TIMEOUT_MS } from '../../constants.js';
import { FakeClock } from '../support/fake-clock.js';
import { fakeVisibility } from '../support/helpers.js';

// A hand-driven WebSocketLike: the test plays the relay through the server* methods.
class FakeSocket {
  binaryType = 'blob';
  readyState = 0;
  /** @type {Array<string | ArrayBufferLike | ArrayBufferView>} */
  sent = [];
  /** @type {{code?: number, reason?: string} | null} */
  closedWith = null;
  onopen = null;
  onmessage = null;
  onclose = null;
  onerror = null;

  send(data) {
    if (this.readyState !== 1) throw new Error('InvalidStateError');
    this.sent.push(data);
  }

  close(code, reason) {
    this.closedWith = { code, reason };
    this.readyState = 2;
  }

  serverOpen() {
    this.readyState = 1;
    this.onopen?.({});
  }

  serverText(text) { this.onmessage?.({ data: text }); }

  serverBinary(bytes) {
    this.onmessage?.({ data: bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) });
  }

  serverClose(code) {
    this.readyState = 3;
    this.onerror?.({});
    this.onclose?.({ code, reason: '', wasClean: code !== 1006 });
  }
}

/** @param {{ visibility?: ReturnType<typeof fakeVisibility> }} [options] */
function setup({ visibility } = {}) {
  const clock = new FakeClock();
  const events = [];
  /** @type {FakeSocket[]} */
  const sockets = [];
  const urls = [];
  const relay = new RelaySocket({
    url: 'wss://relay.acme.test/v1/rooms/r/phone',
    openSocket: (url) => {
      urls.push(url);
      const ws = new FakeSocket();
      sockets.push(ws);
      return ws;
    },
    onEvent: (event) => events.push(event),
    visibility,
    clock,
  });
  return { clock, events, sockets, urls, relay };
}

/** @param {{ visibility?: ReturnType<typeof fakeVisibility> }} [options] */
function openedSetup(options = {}) {
  const s = setup(options);
  s.relay.open();
  s.sockets[0].serverOpen();
  return { ...s, ws: s.sockets[0] };
}

const pings = (ws) => ws.sent.filter((data) => data === 'ping').length;

test('open uses the URL, asks for array buffers and reports open', () => {
  const { relay, sockets, urls, events } = setup();
  relay.open();
  assert.deepEqual(urls, ['wss://relay.acme.test/v1/rooms/r/phone']);
  assert.equal(sockets[0].binaryType, 'arraybuffer');
  assert.deepEqual(events, []);
  sockets[0].serverOpen();
  assert.deepEqual(events, [{ kind: 'open' }]);
  relay.open();
  assert.equal(sockets.length, 1, 'a second open() does not open another socket');
});

test('sends ping every 30 s and a pong keeps it alive', async () => {
  const { clock, events, ws } = openedSetup();
  await clock.advance(KEEPALIVE_MS - 1);
  assert.equal(pings(ws), 0);
  await clock.advance(1);
  assert.equal(pings(ws), 1);
  ws.serverText('pong');
  await clock.advance(KEEPALIVE_MS);
  assert.equal(pings(ws), 2);
  ws.serverText('pong');
  await clock.advance(KEEPALIVE_MS);
  assert.equal(pings(ws), 3);
  assert.deepEqual(events, [{ kind: 'open' }]);
  assert.equal(ws.closedWith, null);
});

test('the keepalive starts at open, not at open()', async () => {
  const { relay, clock, sockets } = setup();
  relay.open();
  await clock.advance(KEEPALIVE_MS * 3);
  assert.deepEqual(sockets[0].sent, []);
  assert.equal(clock.pending, 0);
  sockets[0].serverOpen();
  await clock.advance(KEEPALIVE_MS);
  assert.equal(pings(sockets[0]), 1);
});

test('a missing pong by the next keepalive reports dead and closes', async () => {
  const { clock, events, ws } = openedSetup();
  await clock.advance(KEEPALIVE_MS);
  assert.equal(pings(ws), 1);
  await clock.advance(KEEPALIVE_MS);
  assert.equal(pings(ws), 1, 'no second ping while the first is unanswered');
  assert.deepEqual(events, [{ kind: 'open' }, { kind: 'dead' }]);
  assert.equal(ws.closedWith?.code, 1000);
  assert.equal(clock.pending, 0, 'every timer is cleared');

  // Nothing further after dead: not the browser's late close, nor a late frame.
  ws.serverText('peer-joined');
  ws.serverBinary(new Uint8Array([1]));
  ws.serverClose(1000);
  await clock.advance(KEEPALIVE_MS * 2);
  assert.deepEqual(events, [{ kind: 'open' }, { kind: 'dead' }]);
});

test('a keepalive ping sent just before the page hides gets a fresh window on its return', async () => {
  const visibility = fakeVisibility();
  const { clock, events, ws } = openedSetup({ visibility });
  await clock.advance(KEEPALIVE_MS);
  assert.equal(pings(ws), 1);

  // The phone locks before the pong is handled, and stays locked for many keepalives. On the
  // return the overdue keepalive runs before the pong that arrived meanwhile: no dead socket.
  visibility.hide();
  await clock.advance(KEEPALIVE_MS * 10);
  visibility.show();
  await clock.advance(KEEPALIVE_MS - 1);
  assert.deepEqual(events, [{ kind: 'open' }]);
  assert.equal(pings(ws), 1, 'no second ping while the first is out');
  ws.serverText('pong');
  assert.equal(visibility.listeners(), 0, 'the pong ends the wait and its listener');
  await clock.advance(KEEPALIVE_MS);
  assert.equal(pings(ws), 2, 'the keepalive goes on');
  ws.serverText('pong');
  await clock.advance(KEEPALIVE_MS);
  assert.equal(pings(ws), 3);
  assert.deepEqual(events, [{ kind: 'open' }]);
  assert.equal(ws.closedWith, null);
});

test('a pong that never comes ends the socket after KEEPALIVE_MS of time while visible', async () => {
  const visibility = fakeVisibility();
  const { clock, events, ws } = openedSetup({ visibility });
  await clock.advance(KEEPALIVE_MS);
  await clock.advance(KEEPALIVE_MS / 2);
  visibility.hide();
  await clock.advance(KEEPALIVE_MS * 10);
  // A timer that runs on the return before its visibilitychange does nothing either.
  visibility.show();
  visibility.freeze();
  await clock.advance(KEEPALIVE_MS);
  assert.deepEqual(events, [{ kind: 'open' }]);
  visibility.show();
  await clock.advance(KEEPALIVE_MS - 1);
  assert.deepEqual(events, [{ kind: 'open' }]);
  await clock.advance(1);
  assert.deepEqual(events, [{ kind: 'open' }, { kind: 'dead' }]);
  assert.equal(ws.closedWith?.code, 1000);
  assert.equal(clock.pending, 0);
  assert.equal(visibility.listeners(), 0);
});

test('pings go out on the clock while the page is hidden, and their pongs keep the socket', async () => {
  const visibility = fakeVisibility(false);
  const { clock, events, ws } = openedSetup({ visibility });
  for (let i = 1; i <= 3; i += 1) {
    await clock.advance(KEEPALIVE_MS);
    assert.equal(pings(ws), i);
    ws.serverText('pong');
  }
  assert.deepEqual(events, [{ kind: 'open' }]);
  assert.equal(visibility.listeners(), 0);
});

test('a probe sent just before the page hides gets a fresh window on its return', async () => {
  const visibility = fakeVisibility();
  {
    const { relay, clock, events, ws } = openedSetup({ visibility });
    relay.probe();
    await clock.advance(RESUME_PONG_TIMEOUT_MS - 1);
    visibility.hide();
    await clock.advance(RESUME_PONG_TIMEOUT_MS * 5);
    visibility.show();
    relay.probe();
    assert.equal(pings(ws), 1, 'the probe still out answers for this return too');
    await clock.advance(RESUME_PONG_TIMEOUT_MS - 1);
    ws.serverText('pong');
    await clock.advance(RESUME_PONG_TIMEOUT_MS);
    assert.deepEqual(events, [{ kind: 'open' }]);
    relay.close();
  }
  {
    const { relay, clock, events } = openedSetup({ visibility });
    relay.probe();
    visibility.hide();
    await clock.advance(RESUME_PONG_TIMEOUT_MS * 5);
    visibility.show();
    await clock.advance(RESUME_PONG_TIMEOUT_MS - 1);
    assert.deepEqual(events, [{ kind: 'open' }]);
    await clock.advance(1);
    assert.deepEqual(events, [{ kind: 'open' }, { kind: 'dead' }]);
  }
  assert.equal(visibility.listeners(), 0);
});

test('probe without a pong in 3 s reports dead; with a pong it does not', async () => {
  {
    const { relay, clock, events, ws } = openedSetup();
    relay.probe();
    assert.equal(pings(ws), 1);
    await clock.advance(RESUME_PONG_TIMEOUT_MS - 1);
    assert.deepEqual(events, [{ kind: 'open' }]);
    await clock.advance(1);
    assert.deepEqual(events, [{ kind: 'open' }, { kind: 'dead' }]);
    assert.equal(ws.closedWith?.code, 1000);
    assert.equal(clock.pending, 0);
    ws.serverClose(1006);
    assert.deepEqual(events, [{ kind: 'open' }, { kind: 'dead' }]);
  }
  {
    const { relay, clock, events, ws } = openedSetup();
    relay.probe();
    await clock.advance(RESUME_PONG_TIMEOUT_MS - 1);
    ws.serverText('pong');
    assert.equal(clock.pending, 1, 'the pong cancels the probe timer; only the keepalive remains');
    await clock.advance(RESUME_PONG_TIMEOUT_MS);
    assert.deepEqual(events, [{ kind: 'open' }]);
    assert.equal(ws.closedWith, null);
  }
});

test('a second probe while one is pending neither pings again nor moves the deadline', async () => {
  const { relay, clock, events, ws } = openedSetup();
  relay.probe();
  await clock.advance(RESUME_PONG_TIMEOUT_MS - 1);
  relay.probe();
  assert.equal(pings(ws), 1);
  await clock.advance(1);
  assert.deepEqual(events, [{ kind: 'open' }, { kind: 'dead' }]);
  assert.equal(clock.pending, 0);
});

test('probe does nothing on a socket that is not open', async () => {
  const { relay, clock, events, sockets } = setup();
  relay.probe();
  relay.open();
  relay.probe();
  assert.deepEqual(sockets[0].sent, []);
  assert.equal(clock.pending, 0);
  await clock.advance(RESUME_PONG_TIMEOUT_MS * 2);
  assert.deepEqual(events, []);
});

test('signals map; unknown text is ignored; binary becomes frame bytes', () => {
  const { events, ws } = openedSetup();
  ws.serverText('peer-joined');
  ws.serverText('peer-left');
  ws.serverText('peer-absent');
  ws.serverText('peer-something');
  ws.serverText('PEER-JOINED');
  ws.serverText('');
  ws.serverText('pong');
  ws.serverBinary(new Uint8Array([0, 1, 2, 255]));
  assert.deepEqual(events, [
    { kind: 'open' },
    { kind: 'signal', name: 'peer-joined' },
    { kind: 'signal', name: 'peer-left' },
    { kind: 'signal', name: 'peer-absent' },
    { kind: 'frame', bytes: new Uint8Array([0, 1, 2, 255]) },
  ]);
  assert.ok(events[4].bytes instanceof Uint8Array);
});

test('send returns false unless open', () => {
  const { relay, sockets } = setup();
  assert.equal(relay.send(new Uint8Array([1])), false, 'before open()');
  relay.open();
  assert.equal(relay.send(new Uint8Array([2])), false, 'while connecting');
  sockets[0].serverOpen();
  assert.equal(relay.send(new Uint8Array([3])), true);
  assert.deepEqual(sockets[0].sent, [new Uint8Array([3])]);
  relay.close();
  assert.equal(relay.send(new Uint8Array([4])), false, 'after close()');
  assert.equal(sockets[0].sent.length, 1);
});

test('send returns false after the relay closes the socket', () => {
  const { relay, ws } = openedSetup();
  ws.serverClose(1006);
  assert.equal(relay.send(new Uint8Array([1])), false);
});

test('close code 4000 reaches the event as code 4000, wasOpen true', async () => {
  const { clock, events, ws } = openedSetup();
  ws.serverClose(4000);
  assert.deepEqual(events, [{ kind: 'open' }, { kind: 'closed', code: 4000, wasOpen: true }]);
  assert.equal(clock.pending, 0, 'the keepalive is cleared');
  ws.serverText('peer-joined');
  await clock.advance(KEEPALIVE_MS * 2);
  assert.equal(events.length, 2);
});

test('close codes 1009 and 1006 pass through, with wasOpen false before open', () => {
  {
    const { events, ws } = openedSetup();
    ws.serverClose(1009);
    assert.deepEqual(events.at(-1), { kind: 'closed', code: 1009, wasOpen: true });
  }
  {
    const { relay, events, sockets } = setup();
    relay.open();
    sockets[0].serverClose(1006);
    assert.deepEqual(events, [{ kind: 'closed', code: 1006, wasOpen: false }]);
  }
});

test('a throwing constructor reports closed 1006 wasOpen false', async () => {
  const clock = new FakeClock();
  const events = [];
  const relay = new RelaySocket({
    url: 'wss://relay.acme.test/v1/rooms/r/phone',
    openSocket: () => { throw new Error('refused by policy'); },
    onEvent: (event) => events.push(event),
    clock,
  });
  relay.open();
  assert.deepEqual(events, [], 'reported on the next turn, not synchronously');
  await clock.advance(0);
  assert.deepEqual(events, [{ kind: 'closed', code: 1006, wasOpen: false }]);
  assert.equal(relay.send(new Uint8Array([1])), false);
});

test('close() after a throwing constructor reports nothing', async () => {
  const clock = new FakeClock();
  const events = [];
  const relay = new RelaySocket({
    url: 'wss://relay.acme.test/v1/rooms/r/phone',
    openSocket: () => { throw new Error('refused by policy'); },
    onEvent: (event) => events.push(event),
    clock,
  });
  relay.open();
  relay.close();
  assert.equal(clock.pending, 0, 'the pending report is cleared');
  await clock.advance(KEEPALIVE_MS);
  assert.deepEqual(events, []);
});

test('close() sends 1000, clears every timer and stops all events', async () => {
  const { relay, clock, events, ws } = openedSetup();
  relay.probe();
  assert.equal(clock.pending, 2, 'keepalive and probe');
  relay.close();
  assert.equal(ws.closedWith?.code, 1000);
  assert.equal(clock.pending, 0);
  ws.serverText('peer-joined');
  ws.serverText('pong');
  ws.serverBinary(new Uint8Array([9]));
  ws.serverClose(1000);
  await clock.advance(KEEPALIVE_MS * 3);
  assert.deepEqual(events, [{ kind: 'open' }]);
  relay.probe();
  relay.open();
  assert.equal(clock.pending, 0);
  assert.equal(ws.sent.filter((d) => d === 'ping').length, 1, 'only the probe ping before close');
});

test('close() while connecting reports nothing, even if the socket later opens', () => {
  const { relay, events, sockets } = setup();
  relay.open();
  relay.close();
  assert.equal(sockets[0].closedWith?.code, 1000);
  sockets[0].serverOpen();
  sockets[0].serverClose(1006);
  assert.deepEqual(events, []);
});

test('close() before open() means open() never opens a socket', () => {
  const { relay, events, sockets } = setup();
  relay.close();
  relay.open();
  assert.equal(sockets.length, 0);
  assert.deepEqual(events, []);
});

test('reconnectDelay', () => {
  assert.equal(reconnectDelay(0, 0), 1000);
  assert.equal(reconnectDelay(0, 1), 1250);
  assert.equal(reconnectDelay(5, 0), 32000);
  assert.equal(reconnectDelay(6, 0), 60000);
  assert.equal(reconnectDelay(20, 1), 60000);
});
