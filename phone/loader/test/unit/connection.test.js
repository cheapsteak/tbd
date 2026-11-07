import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { deflateRawSync } from 'node:zlib';

import { MAX_PLAINTEXT_LENGTH, createInitiator, phonePrologue } from '../../channel/noise.js';
import { base64urlDecode } from '../../channel/pairingLink.js';
import { LaptopConnection } from '../../connection.js';
import {
  CACHE_READ_TIMEOUT_MS, HANDSHAKE_TIMEOUT_MS, LOADER_VERSION, MAX_CHUNK_BYTES, RESUME_PONG_TIMEOUT_MS,
  SIGNAL_TIMEOUT_MS,
} from '../../constants.js';
import { createWrappedPhoneKey } from '../../keys.js';
import { relaySocketURL } from '../../links.js';
import { validateLaptopRecord } from '../../store.js';
import { FakeClock } from '../support/fake-clock.js';
import { createFakeRelay } from '../support/fake-relay.js';
import { fakeSocketFactory } from '../support/fake-websocket.js';
import { createResponder } from '../support/noise-responder.js';
import { createScriptedLaptop } from '../support/scripted-laptop.js';
import { importPair } from '../support/x25519.js';

const WAIT_MS = 10_000;
const START = 1_700_000_000_000;
const HELLO = { type: 'hello', loaderVersion: LOADER_VERSION, protocols: [1] };

/** @param {unknown} value */
const encode = (value) => new TextEncoder().encode(JSON.stringify(value));
/** @param {Uint8Array} bytes */
const decode = (bytes) => JSON.parse(new TextDecoder().decode(bytes));
/** @param {string} text */
const b64 = (text) => /** @type {Uint8Array} */ (base64urlDecode(text));
/** @param {string} text */
const sha256Hex = (text) => createHash('sha256').update(text).digest('hex');
const sleep = (/** @type {number} */ ms) => new Promise((resolve) => setTimeout(resolve, ms));
/** Lets in-flight socket deliveries and Web Crypto work land. */
const quiet = () => sleep(30);

/**
 * @param {() => boolean} predicate
 * @param {string} what
 * @param {number} [ms]
 */
async function until(predicate, what, ms = WAIT_MS) {
  const deadline = Date.now() + ms;
  while (!predicate()) {
    if (Date.now() > deadline) assert.fail(`timed out waiting for ${what}`);
    await sleep(1);
  }
}

/**
 * Wraps a socket factory to record, per test, every socket it made and a timeline of what
 * crossed them: `open`, inbound text and frames, outbound frames, `close()` calls and closes.
 * `hooks.afterOpen(ws)` runs right after the phone's open handler, and
 * `hooks.afterMessage(ev, deliver)` right after its message handler, in the same task;
 * `deliver(ev)` hands the phone another message at once.
 * @param {(url: string) => any} base
 */
function instrument(base) {
  /** @type {Array<{ dir: string, text?: string, bytes?: Uint8Array, code?: number }>} */
  const log = [];
  /** @type {any[]} */
  const sockets = [];
  /** @type {{ afterOpen: ((ws: any) => void) | null, afterMessage: ((ev: any, deliver: (ev: any) => void) => void) | null }} */
  const hooks = { afterOpen: null, afterMessage: null };
  /** @param {string} url */
  const factory = (url) => {
    const ws = base(url);
    sockets.push(ws);
    const send = ws.send.bind(ws);
    ws.send = (/** @type {any} */ data) => {
      if (typeof data !== 'string') log.push({ dir: 'out', bytes: new Uint8Array(data).slice() });
      send(data);
    };
    const close = ws.close.bind(ws);
    ws.close = (/** @type {number} */ code, /** @type {string} */ reason) => {
      log.push({ dir: 'close()', code });
      close(code, reason);
    };
    intercept(ws, 'onopen', () => log.push({ dir: 'open' }), () => hooks.afterOpen?.(ws));
    intercept(ws, 'onmessage', (ev) => log.push(typeof ev.data === 'string'
      ? { dir: 'in', text: ev.data }
      : { dir: 'in', bytes: new Uint8Array(ev.data).slice() }), (ev, deliver) => hooks.afterMessage?.(ev, deliver));
    intercept(ws, 'onclose', (ev) => log.push({ dir: 'closed', code: ev.code }));
    return ws;
  };
  return {
    factory,
    log,
    sockets,
    hooks,
    /** Outbound frames. */
    out: () => log.filter((e) => e.dir === 'out').map((e) => /** @type {Uint8Array} */ (e.bytes)),
    /** The first frame the phone sent after each `peer-joined`: its handshake message 1. */
    message1s() {
      /** @type {Uint8Array[]} */
      const found = [];
      let waiting = false;
      for (const entry of log) {
        if (entry.text === 'peer-joined') waiting = true;
        else if (waiting && entry.dir === 'out') {
          found.push(/** @type {Uint8Array} */ (entry.bytes));
          waiting = false;
        }
      }
      return found;
    },
    count: (/** @type {string} */ dir) => log.filter((e) => e.dir === dir).length,
  };
}

/**
 * Replaces an event-handler property with one that also calls `before` and `after`; `after`
 * gets the handler itself, to deliver more events in the same task.
 * @param {any} ws
 * @param {string} name
 * @param {(ev: any) => void} before
 * @param {(ev: any, handler: (ev: any) => void) => void} [after]
 */
function intercept(ws, name, before, after) {
  /** @type {((ev: any) => void) | null} */
  let handler = null;
  Object.defineProperty(ws, name, {
    configurable: true,
    get: () => (handler === null ? null : (/** @type {any} */ ev) => {
      before(ev);
      const current = /** @type {(ev: any) => void} */ (handler);
      current(ev);
      after?.(ev, current);
    }),
    set: (fn) => {
      handler = fn;
    },
  });
}

/**
 * A socket factory whose sockets stay connecting forever, as on a network that swallows the
 * WebSocket handshake. Each socket records the codes `close()` was called with.
 */
function hangingSockets() {
  /** @type {any[]} */
  const sockets = [];
  return {
    sockets,
    /** @param {string} url */
    factory(url) {
      const ws = {
        url,
        binaryType: 'blob',
        readyState: 0,
        onopen: null,
        onmessage: null,
        onclose: null,
        onerror: null,
        /** @type {Array<number | undefined>} */ closes: [],
        send() {
          throw new DOMException('the WebSocket is still connecting', 'InvalidStateError');
        },
        /** @param {number} [code] */
        close(code) {
          ws.closes.push(code);
          ws.readyState = 3;
        },
      };
      sockets.push(ws);
      return ws;
    },
  };
}

/**
 * Steps the clock through a run of reconnects and checks that each waits exactly its delay:
 * no join 1 ms early, a join on time. Call it once the first socket has failed.
 * @param {{ clock: FakeClock, joins: () => number }} env
 * @param {number[]} delays
 * @param {(n: number) => Promise<void>} failed waits until the n-th socket has failed and armed
 *   its reconnect timer
 */
async function checkBackoff(env, delays, failed) {
  const first = env.joins();
  for (const [i, delay] of delays.entries()) {
    await env.clock.advance(delay - 1);
    await quiet();
    assert.equal(env.joins(), first + i, `no join ${delay - 1} ms after failure ${first + i}`);
    await env.clock.advance(1);
    await until(() => env.joins() === first + i + 1, `join ${first + i + 1} after ${delay} ms`);
    await failed(first + i + 1);
  }
}

/** An in-memory cache with the adapter interface LaptopConnection takes. */
function memoryCache() {
  /** @type {Map<string, any>} */
  const rows = new Map();
  const calls = {
    get: 0,
    /** @type {any[]} */ put: [],
    /** @type {any[]} */ markUsed: [],
  };
  return {
    rows,
    calls,
    /** @param {string} laptopID @param {string} sha */
    async get(laptopID, sha) {
      calls.get += 1;
      const row = rows.get(`${laptopID} ${sha}`);
      return row === undefined ? undefined : { ...row };
    },
    /** @param {any} record */
    async put(record) {
      calls.put.push(record);
      rows.set(`${record.laptopID} ${record.sha256}`, { ...record });
      return true;
    },
    /** @param {string} laptopID @param {string} sha @param {number} at */
    async markUsed(laptopID, sha, at) {
      calls.markUsed.push({ laptopID, sha, at });
      const row = rows.get(`${laptopID} ${sha}`);
      if (row !== undefined) row.usedAt = at;
    },
  };
}

/**
 * A phone socket for pairing, with its events in a queue.
 * @param {(url: string) => any} factory
 * @param {string} url
 */
function pairingSocket(factory, url) {
  const ws = factory(url);
  ws.binaryType = 'arraybuffer';
  /** @type {any[]} */
  const queue = [];
  ws.onopen = () => queue.push({ kind: 'open' });
  ws.onmessage = (/** @type {any} */ ev) => queue.push(typeof ev.data === 'string'
    ? { kind: 'signal', name: ev.data }
    : { kind: 'frame', bytes: new Uint8Array(ev.data) });
  ws.onclose = () => queue.push({ kind: 'closed' });
  return {
    ws,
    async next() {
      await until(() => queue.length > 0, 'a pairing event');
      return queue.shift();
    },
  };
}

/**
 * Pairs a phone with the scripted laptop as plan 3 has it (IKpsk2, then `hello`, then
 * `paired` with a new room), and builds the device record the store would hold, with the key
 * wrapped by createWrappedPhoneKey. The record's room is the one from `paired`.
 * @param {ReturnType<typeof createFakeRelay>} relay
 * @param {any} laptop
 */
async function pairDevice(relay, laptop) {
  const offer = laptop.makeOffer();
  const keys = await createWrappedPhoneKey(crypto.subtle, offer.key);
  const phone = pairingSocket(fakeSocketFactory(relay, { origin: laptop.relayOrigin }), relaySocketURL(offer.relay, offer.room));
  assert.deepEqual(await phone.next(), { kind: 'open' });
  assert.deepEqual(await phone.next(), { kind: 'signal', name: 'peer-joined' });
  const initiator = await createInitiator({
    pattern: 'IKpsk2',
    localStatic: keys.pair,
    remoteStatic: b64(offer.key),
    psk: b64(offer.secret),
    prologue: phonePrologue(b64(offer.room)),
  });
  phone.ws.send(await initiator.writeMessage1(encode({ deviceName: 'iPhone' })));
  const message2 = await phone.next();
  const result = await initiator.readMessage2(message2.bytes);
  phone.ws.send(await result.transport.encrypt(encode(HELLO)));
  const paired = decode(await result.transport.decrypt((await phone.next()).bytes));
  assert.equal(paired.type, 'paired');
  assert.notEqual(paired.room, offer.room);
  phone.ws.close(1000);
  const record = validateLaptopRecord({
    id: offer.key,
    relay: offer.relay,
    room: paired.room,
    laptopKey: b64(offer.key),
    laptopName: decode(result.payload).laptopName,
    phoneName: 'iPhone',
    phoneKey: keys.publicRaw,
    wrapKey: keys.wrapKey,
    wrappedKey: keys.wrappedKey,
    wrapIV: keys.wrapIV,
    pairedAt: START,
    lastConnectedAt: null,
  });
  return { record, keyPair: keys.pair, room: paired.room };
}

/**
 * A relay, a scripted laptop with a known static key, a paired device and a fake clock.
 * @param {object} [laptopOptions] passed to createScriptedLaptop
 */
async function setup(laptopOptions = {}) {
  const relay = createFakeRelay();
  const staticKey = new Uint8Array(randomBytes(32));
  const laptop = await createScriptedLaptop({ relay, staticKey, ...laptopOptions });
  const device = await pairDevice(relay, laptop);
  const net = instrument(fakeSocketFactory(relay, { origin: laptop.relayOrigin }));
  const clock = new FakeClock(START);
  const cache = memoryCache();
  return {
    relay,
    laptop,
    staticKey,
    net,
    clock,
    cache,
    ...device,
    joins: () => relay.stats.phoneJoins.get(device.room) ?? 0,
  };
}

/**
 * A LaptopConnection on the test's device, recording its events. `states()` also checks
 * that no state is reported twice in a row.
 * @param {Awaited<ReturnType<typeof setup>>} env
 * @param {object} [options] overrides for the LaptopConnection options
 */
function connection(env, options = {}) {
  /** @type {any[]} */
  const events = [];
  const conn = new LaptopConnection({
    record: env.record,
    keyPair: env.keyPair,
    cache: env.cache,
    openSocket: env.net.factory,
    onEvent: (event) => events.push(event),
    random: () => 0,
    clock: env.clock,
    ...options,
  });
  const states = () => {
    const list = events.filter((e) => e.kind === 'state').map((e) => e.state);
    for (let i = 1; i < list.length; i += 1) {
      assert.notEqual(list[i], list[i - 1], `state ${list[i]} reported twice in a row: ${list.join(', ')}`);
    }
    return list;
  };
  return {
    conn,
    events,
    states,
    /** @param {string} state */
    count: (state) => states().filter((s) => s === state).length,
    /** @param {string} kind */
    of: (kind) => events.filter((e) => e.kind === kind),
  };
}

/**
 * Base64 text whose raw-deflate size needs exactly `chunks` chunks: random bytes barely
 * compress, so the size is steered by the text length.
 * @param {number} chunks
 */
function textWithChunks(chunks) {
  const target = (chunks - 0.5) * MAX_CHUNK_BYTES;
  let length = Math.round(target / 0.76);
  for (let tries = 0; tries < 20; tries += 1) {
    const text = randomBytes(Math.ceil(length * 0.75)).toString('base64').slice(0, length);
    const size = deflateRawSync(Buffer.from(text)).length;
    if (Math.ceil(size / MAX_CHUNK_BYTES) === chunks) return text;
    length = Math.round(length * (target / size));
  }
  throw new Error(`no text found for ${chunks} chunks`);
}

/**
 * Stands in for the laptop by hand on the device room (the scripted laptop leaves it), so a
 * test can send messages plan 3's laptop never would.
 * @param {Awaited<ReturnType<typeof setup>>} env
 * @param {{ message2?: unknown }} [options] message 2's payload
 */
async function manualLaptop(env, { message2 = { laptopName: 'acme-mbp' } } = {}) {
  env.laptop.leave(env.room);
  /** @type {Uint8Array[]} */
  const frames = [];
  const handle = /** @type {any} */ (env.relay.connect(`/v1/rooms/${env.room}?role=laptop`, {
    binary: (bytes) => frames.push(bytes),
    text: () => {},
    close: () => {},
  }));
  const staticPair = await importPair(env.staticKey);
  const next = async () => {
    await until(() => frames.length > 0, 'a phone frame');
    return /** @type {Uint8Array} */ (frames.shift());
  };
  return {
    frames,
    /** Answers message 1, reads `hello`, and returns a sender on the transport. */
    async accept() {
      const responder = await createResponder({ pattern: 'IK', localStatic: staticPair, prologue: phonePrologue(b64(env.room)) });
      await responder.readMessage1(await next());
      const written = await responder.writeMessage2(encode(message2));
      handle.send(written.message);
      const transport = written.transport;
      return {
        hello: async () => decode(await transport.decrypt(await next())),
        read: async () => decode(await transport.decrypt(await next())),
        /** @param {object | string} message an object, or raw text to send as is */
        send: async (message) => handle.send(await transport.encrypt(
          typeof message === 'string' ? new TextEncoder().encode(message) : encode(message))),
      };
    },
  };
}

// --- connecting -----------------------------------------------------------------------------

test('waits for peer-joined, then connects with IK, sends hello with LOADER_VERSION and protocols [1], and reports the laptop name', async () => {
  const env = await setup();
  env.laptop.leave(env.room);
  const c = connection(env);
  c.conn.start();
  await until(() => c.states().includes('offline'), 'offline');
  await quiet();
  assert.deepEqual(env.net.out(), [], 'no binary frame while the laptop is away');

  env.laptop.join(env.room);
  await until(() => c.states().includes('ready'), 'ready');
  assert.deepEqual(c.states(), ['connecting', 'offline', 'handshaking', 'loading', 'ready']);
  assert.deepEqual(c.of('connected'), [{ kind: 'connected', laptopName: 'acme-mbp' }]);
  assert.deepEqual(c.events.map((e) => e.kind), ['state', 'state', 'state', 'connected', 'state', 'bundle', 'state']);

  const joinedAt = env.net.log.findIndex((e) => e.text === 'peer-joined');
  const firstOut = env.net.log.findIndex((e) => e.dir === 'out');
  assert.ok(joinedAt >= 0 && firstOut > joinedAt, 'the first frame follows peer-joined');
  const sent = env.laptop.log.filter((/** @type {any} */ e) => e.room === env.room);
  assert.deepEqual(sent[0].message, HELLO, 'hello is the first transport message');
  assert.equal(env.laptop.counts.ikHandshakes, 1);
  assert.equal(env.joins(), 1);
  assert.deepEqual(env.laptop.errors, []);
  c.conn.stop();
});

test('IK message 1 carries the phone key and the payload {}', async () => {
  const env = await setup();
  const c = connection(env);
  c.conn.start();
  await until(() => c.states().includes('ready'), 'ready');
  const [message1] = env.net.message1s();
  const responder = await createResponder({
    pattern: 'IK', localStatic: await importPair(env.staticKey), prologue: phonePrologue(b64(env.room)),
  });
  const read = await responder.readMessage1(message1);
  assert.deepEqual(read.remoteStatic, env.record.phoneKey);
  assert.equal(new TextDecoder().decode(read.payload), '{}');
  c.conn.stop();
});

test('a junk frame before message 2 is dropped and the IK connect still succeeds', async () => {
  const env = await setup();
  env.laptop.sendJunkBeforeMessage2(true);
  const c = connection(env);
  c.conn.start();
  await until(() => c.states().includes('ready'), 'ready');
  const inbound = env.net.log.filter((e) => e.dir === 'in' && e.bytes !== undefined).map((e) => e.bytes?.length);
  assert.deepEqual(inbound.slice(0, 2), [20, 64], 'a short frame and a 64-byte one came first');
  assert.deepEqual(c.states(), ['connecting', 'handshaking', 'loading', 'ready']);
  assert.equal(env.joins(), 1);
  assert.equal(env.laptop.counts.ikHandshakes, 1);
  assert.deepEqual(c.of('fatal'), []);
  c.conn.stop();
});

test('peer-absent reads offline; peer-joined runs a new handshake with a fresh ephemeral', async () => {
  const env = await setup();
  env.laptop.leave(env.room);
  const c = connection(env);
  c.conn.start();
  await until(() => c.states().includes('offline'), 'offline');
  env.laptop.join(env.room);
  await until(() => c.count('ready') === 1, 'ready');
  env.laptop.leave(env.room);
  await until(() => c.count('offline') === 2, 'offline after peer-left');
  env.laptop.join(env.room);
  await until(() => c.count('ready') === 2, 'ready again');

  assert.deepEqual(c.states(), ['connecting', 'offline', 'handshaking', 'loading', 'ready', 'offline', 'handshaking', 'ready']);
  const message1s = env.net.message1s();
  assert.equal(message1s.length, 2);
  assert.notDeepEqual(message1s[0].slice(0, 32), message1s[1].slice(0, 32), 'a fresh ephemeral key');
  assert.equal(env.joins(), 1, 'the socket stayed open');
  assert.equal(env.laptop.counts.ikHandshakes, 2);
  c.conn.stop();
});

test('with absentGraceMs, peer-absent reads connecting until the grace ends, and a peer-joined inside it never shows offline', async () => {
  const env = await setup();
  env.laptop.leave(env.room);
  const c = connection(env, { absentGraceMs: SIGNAL_TIMEOUT_MS });
  c.conn.start();
  await until(() => env.net.log.some((e) => e.text === 'peer-absent'), 'peer-absent');
  await quiet();
  assert.deepEqual(c.states(), ['connecting']);
  await env.clock.advance(SIGNAL_TIMEOUT_MS - 1);
  await quiet();
  assert.deepEqual(c.states(), ['connecting']);
  await env.clock.advance(1);
  await until(() => c.states().includes('offline'), 'offline when the grace ends');
  assert.deepEqual(c.states(), ['connecting', 'offline']);
  c.conn.stop();

  const second = await setup();
  second.laptop.leave(second.room);
  const d = connection(second, { absentGraceMs: SIGNAL_TIMEOUT_MS });
  d.conn.start();
  await until(() => second.net.log.some((e) => e.text === 'peer-absent'), 'peer-absent');
  await second.clock.advance(SIGNAL_TIMEOUT_MS / 2);
  second.laptop.join(second.room);
  await until(() => d.states().includes('ready'), 'ready');
  await second.clock.advance(SIGNAL_TIMEOUT_MS);
  await quiet();
  assert.deepEqual(d.states(), ['connecting', 'handshaking', 'loading', 'ready']);
  d.conn.stop();
});

test('no signal within 10 s reconnects', async () => {
  const env = await setup();
  env.relay.blackHole(env.room, true);
  const c = connection(env);
  c.conn.start();
  await until(() => env.joins() === 1, 'the first join');
  await quiet();
  await env.clock.advance(SIGNAL_TIMEOUT_MS - 1);
  await quiet();
  assert.equal(env.joins(), 1);
  assert.deepEqual(c.states(), ['connecting']);

  await env.clock.advance(1);
  await until(() => c.states().includes('reconnecting'), 'reconnecting');
  assert.deepEqual(env.net.log.filter((e) => e.dir === 'close()'), [{ dir: 'close()', code: 1000 }]);
  await env.clock.advance(999);
  await quiet();
  assert.equal(env.joins(), 1);
  await env.clock.advance(1);
  await until(() => env.joins() === 2, 'a second join after 1 s');

  // The room works again: the next socket, 2 s after the second one times out, connects.
  env.relay.blackHole(env.room, false);
  await quiet();
  await env.clock.advance(SIGNAL_TIMEOUT_MS);
  await quiet();
  await env.clock.advance(2000);
  await until(() => c.states().includes('ready'), 'ready');
  assert.equal(env.joins(), 3);
  assert.deepEqual(c.states(), ['connecting', 'reconnecting', 'handshaking', 'loading', 'ready']);
  c.conn.stop();
});

test('an unknown phone key gets no answer and reads offline after 10 s', async () => {
  const env = await setup();
  env.laptop.devices.clear();
  const c = connection(env);
  c.conn.start();
  await until(() => env.laptop.counts.refused === 1, 'the laptop refusing message 1');
  await quiet();
  await env.clock.advance(HANDSHAKE_TIMEOUT_MS - 1);
  await quiet();
  assert.deepEqual(c.states(), ['connecting', 'handshaking']);
  await env.clock.advance(1);
  await until(() => c.states().includes('offline'), 'offline');
  await env.clock.advance(120_000);
  await quiet();
  assert.deepEqual(c.states(), ['connecting', 'handshaking', 'offline']);
  assert.equal(env.joins(), 1, 'the socket stays open');
  assert.deepEqual(c.of('connected'), []);
  c.conn.stop();
});

// --- the bundle -----------------------------------------------------------------------------

test('a cache miss fetches the bundle once; a second connection fetches nothing', async () => {
  const env = await setup();
  const first = connection(env);
  first.conn.start();
  await until(() => first.states().includes('ready'), 'ready');
  const [bundle] = first.of('bundle');
  assert.equal(bundle.sha256, sha256Hex(bundle.text));
  assert.equal(bundle.text, 'globalThis.tbdScriptedLaptop = true;\n');
  assert.deepEqual(env.cache.calls.put, [{
    laptopID: env.record.id,
    sha256: bundle.sha256,
    text: bundle.text,
    size: deflateRawSync(Buffer.from(bundle.text)).length,
    usedAt: START,
  }]);
  assert.deepEqual(env.laptop.log.filter((/** @type {any} */ e) => e.type === 'bundle.get').map((/** @type {any} */ e) => e.message),
    [{ type: 'bundle.get', sha256: bundle.sha256 }]);
  first.conn.stop();

  await env.clock.advance(5000);
  const second = connection(env);
  second.conn.start();
  await until(() => second.states().includes('ready'), 'ready again');
  assert.deepEqual(second.states(), ['connecting', 'handshaking', 'ready']);
  assert.equal(env.laptop.counts.bundleGet, 1);
  assert.deepEqual(second.of('bundle'), [bundle]);
  assert.deepEqual(env.cache.calls.markUsed, [{ laptopID: env.record.id, sha: bundle.sha256, at: START + 5000 }]);
  assert.equal(env.cache.calls.put.length, 1);
  second.conn.stop();
});

test('a cache that misses with null or rejects, or refuses or fails to write, never stops the bundle', async () => {
  /** @type {Array<[string, object]>} */
  const variants = [
    ['get resolves null', { get: async () => null }],
    ['get resolves a record without text', { get: async () => ({ sha256: 'x' }) }],
    ['get rejects', { get: async () => { throw new Error('acme read failed'); } }],
    ['put resolves false', { put: async () => false }],
    ['put rejects', { put: async () => { throw new Error('acme write failed'); } }],
    ['put throws', { put: () => { throw new Error('acme write failed'); } }],
  ];
  for (const [name, overrides] of variants) {
    const env = await setup();
    const c = connection(env, { cache: { ...env.cache, ...overrides } });
    c.conn.start();
    await until(() => c.states().includes('ready') || c.of('fatal').length > 0, `${name}: ready`);
    assert.deepEqual(c.states(), ['connecting', 'handshaking', 'loading', 'ready'], name);
    assert.equal(c.of('bundle').length, 1, name);
    assert.deepEqual(c.of('fatal'), [], name);
    c.conn.stop();
  }

  // A hit whose markUsed fails still runs the bundle.
  const env = await setup();
  const text = 'globalThis.tbdScriptedLaptop = true;\n';
  const sha256 = sha256Hex(text);
  const c = connection(env, {
    cache: {
      get: async () => ({ laptopID: env.record.id, sha256, text, size: 1, usedAt: 0 }),
      put: async () => true,
      markUsed: async () => { throw new Error('acme write failed'); },
    },
  });
  c.conn.start();
  await until(() => c.states().includes('ready'), 'ready from the cache');
  assert.deepEqual(c.of('bundle'), [{ kind: 'bundle', sha256, text }]);
  assert.equal(env.laptop.counts.bundleGet, 0);
  c.conn.stop();
});

test('a cache read that never answers is a miss after 3 s, a late answer is dropped, and a peer-left during the read reads offline at once', async () => {
  const env = await setup();
  const text = 'globalThis.tbdScriptedLaptop = true;\n';
  const sha256 = sha256Hex(text);
  /** @type {Array<(record: object) => void>} */
  const answers = [];
  const c = connection(env, {
    cache: { ...env.cache, get: () => new Promise((resolve) => { answers.push(resolve); }) },
  });
  c.conn.start();
  await until(() => answers.length === 1, 'the cache read');
  await quiet();
  await env.clock.advance(CACHE_READ_TIMEOUT_MS - 1);
  await quiet();
  assert.deepEqual(c.states(), ['connecting', 'handshaking']);
  assert.equal(env.laptop.counts.bundleGet, 0);
  await env.clock.advance(1);
  await until(() => c.states().includes('ready'), 'ready through bundle.get');
  assert.deepEqual(c.states(), ['connecting', 'handshaking', 'loading', 'ready']);
  assert.equal(env.laptop.counts.bundleGet, 1);
  assert.deepEqual(c.of('bundle'), [{ kind: 'bundle', sha256, text }]);
  assert.equal(env.cache.calls.put.length, 1);

  // The read answering after its timeout changes nothing.
  answers[0]({ laptopID: env.record.id, sha256, text, size: 1, usedAt: 0 });
  await quiet();
  assert.equal(c.of('bundle').length, 1);
  assert.deepEqual(env.cache.calls.markUsed, []);

  // While a read hangs, signals are still handled, and the connection ends without it.
  env.laptop.leave(env.room);
  await until(() => c.count('offline') === 1, 'offline');
  env.laptop.join(env.room);
  await until(() => answers.length === 2, 'the second cache read');
  env.laptop.leave(env.room);
  await until(() => c.count('offline') === 2, 'offline while the read hangs');
  await env.clock.advance(CACHE_READ_TIMEOUT_MS);
  await quiet();
  assert.deepEqual(c.states(), ['connecting', 'handshaking', 'loading', 'ready', 'offline', 'handshaking', 'offline']);
  assert.equal(env.laptop.counts.bundleGet, 1, 'no bundle.get for the session that ended');
  c.conn.stop();
});

test('a cached bundle whose text does not hash to its name is a miss, and the fetch replaces the row', async () => {
  const env = await setup();
  const text = 'globalThis.tbdScriptedLaptop = true;\n';
  const sha256 = sha256Hex(text);
  const key = `${env.record.id} ${sha256}`;
  env.cache.rows.set(key, { laptopID: env.record.id, sha256, text: 'globalThis.acme = "changed";\n', size: 10, usedAt: 0 });
  const c = connection(env);
  c.conn.start();
  await until(() => c.states().includes('ready'), 'ready');
  assert.deepEqual(c.states(), ['connecting', 'handshaking', 'loading', 'ready']);
  assert.deepEqual(c.of('bundle'), [{ kind: 'bundle', sha256, text }]);
  assert.equal(env.laptop.counts.bundleGet, 1);
  assert.deepEqual(env.cache.calls.markUsed, []);
  assert.equal(env.cache.rows.get(key).text, text);
  c.conn.stop();
});

test('a transfer cut by the laptop leaving caches nothing; after it rejoins the bundle completes and is cached once', async () => {
  const text = textWithChunks(2);
  const env = await setup({ bundleText: text });
  /** @type {number[]} */
  const offered = [];
  env.laptop.onChunk((/** @type {number} */ index) => {
    offered.push(index);
    return index === 1 ? 'stop' : undefined;
  });
  const c = connection(env);
  c.conn.start();
  await until(() => offered.includes(1), 'the laptop stopping at chunk 1');
  env.laptop.leave(env.room);
  await until(() => c.states().includes('offline'), 'offline');
  await quiet();
  assert.deepEqual(env.cache.calls.put, []);
  assert.deepEqual(c.of('bundle'), []);

  env.laptop.onChunk(null);
  env.laptop.join(env.room);
  await until(() => c.states().includes('ready'), 'ready');
  assert.deepEqual(c.states(), ['connecting', 'handshaking', 'loading', 'offline', 'handshaking', 'loading', 'ready']);
  assert.equal(c.of('bundle')[0].text, text);
  assert.equal(env.cache.calls.put.length, 1);
  assert.equal(env.cache.calls.put[0].text, text);
  assert.equal(env.laptop.counts.bundleGet, 2);
  assert.deepEqual(c.of('fatal'), []);
  c.conn.stop();
});

test('a damaged bundle is fatal badBundle and not cached', async () => {
  const env = await setup();
  env.laptop.setWelcome({ bundle: { sha256: 'a'.repeat(64) } });
  const c = connection(env);
  c.conn.start();
  await until(() => c.of('fatal').length > 0, 'fatal');
  assert.deepEqual(c.of('fatal'), [{ kind: 'fatal', reason: 'badBundle' }]);
  assert.equal(env.laptop.counts.bundleGet, 1);
  assert.deepEqual(c.of('bundle'), []);
  assert.deepEqual(env.cache.calls.put, []);
  assert.deepEqual(env.net.log.filter((e) => e.dir === 'close()'), [{ dir: 'close()', code: 1000 }]);
  await env.clock.advance(120_000);
  await quiet();
  assert.equal(env.joins(), 1);
});

test('sixty chunks delivered back to back assemble in order', async () => {
  const text = textWithChunks(60);
  const env = await setup({ bundleText: text });
  /** @type {number[]} */
  const offered = [];
  env.laptop.onChunk((/** @type {number} */ index) => {
    offered.push(index);
  });
  const c = connection(env);
  c.conn.start();
  await until(() => c.states().includes('ready') || c.of('fatal').length > 0, 'ready', 30_000);
  assert.deepEqual(offered, Array.from({ length: 60 }, (_, i) => i));
  assert.deepEqual(c.of('fatal'), []);
  assert.equal(c.of('bundle')[0].text, text);
  assert.equal(env.cache.calls.put.length, 1);
  assert.equal(env.laptop.counts.bundleGet, 1);
  c.conn.stop();
});

// --- fatal answers --------------------------------------------------------------------------

test('incompatible tooOld laptop is fatal incompatibleLaptop and never reconnects', async () => {
  const env = await setup();
  env.laptop.setIncompatible('laptop');
  // A grace timer is still armed when the fatal comes, so the fatal must cancel it.
  const c = connection(env, { absentGraceMs: SIGNAL_TIMEOUT_MS });
  c.conn.start();
  await until(() => c.of('fatal').length > 0, 'fatal');
  assert.deepEqual(c.of('fatal'), [{ kind: 'fatal', reason: 'incompatibleLaptop' }]);
  assert.deepEqual(env.net.log.filter((e) => e.dir === 'close()'), [{ dir: 'close()', code: 1000 }]);
  assert.equal(env.clock.pending, 0, 'no timer left');
  const seen = c.events.length;
  const joins = env.joins();
  assert.equal(joins, 1);
  c.conn.resume();
  await env.clock.advance(120_000);
  await quiet();
  assert.equal(env.joins(), joins);
  assert.equal(c.events.length, seen, 'nothing after the fatal');
});

test('incompatible tooOld loader, and a welcome with protocol 2 or minProtocol 2, are fatal incompatibleLoader', async () => {
  /** @type {Array<[string, (laptop: any) => void]>} */
  const cases = [
    ['incompatible loader', (laptop) => laptop.setIncompatible('loader')],
    ['welcome protocol 2', (laptop) => laptop.setWelcome({ protocol: 2 })],
    ['welcome minProtocol 2', (laptop) => laptop.setWelcome({ minProtocol: 2 })],
  ];
  for (const [name, arrange] of cases) {
    const env = await setup();
    arrange(env.laptop);
    const c = connection(env);
    c.conn.start();
    await until(() => c.of('fatal').length > 0, `${name}: fatal`);
    assert.deepEqual(c.of('fatal'), [{ kind: 'fatal', reason: 'incompatibleLoader' }], name);
    assert.equal(env.laptop.counts.bundleGet, 0, name);
    await env.clock.advance(120_000);
    await quiet();
    assert.equal(env.joins(), 1, name);
  }
});

test('revoked is fatal and never reconnects', async () => {
  const env = await setup();
  const c = connection(env);
  c.conn.start();
  await until(() => c.states().includes('ready'), 'ready');
  await env.laptop.revoke(env.room);
  await until(() => c.of('fatal').length > 0, 'fatal');
  assert.deepEqual(c.of('fatal'), [{ kind: 'fatal', reason: 'revoked' }]);
  const seen = c.events.length;
  await env.clock.advance(120_000);
  await quiet();
  assert.equal(env.joins(), 1);
  assert.equal(c.events.length, seen);
});

test('a malformed laptop message, a second welcome or an unasked chunk is fatal protocol', async () => {
  const text = 'globalThis.acme = 1;\n';
  const sha256 = sha256Hex(text);
  const welcome = { type: 'welcome', protocol: 1, minProtocol: 1, tbdVersion: '0.0.0-test', bundle: { sha256, size: 10 } };
  const chunk = { type: 'bundle.chunk', sha256, index: 0, count: 1, data: 'AAAA' };
  /** @type {Array<[string, Array<object | string>]>} */
  const cases = [
    ['not JSON', ['not json']],
    ['no type', [{ kind: 'welcome' }]],
    ['a welcome with a bad field', [{ ...welcome, protocol: '1' }]],
    ['a second welcome', [welcome, welcome]],
    ['a chunk before welcome', [chunk]],
    ['a chunk after a cache hit', [welcome, chunk]],
  ];
  for (const [name, messages] of cases) {
    const env = await setup();
    env.cache.rows.set(`${env.record.id} ${sha256}`, { laptopID: env.record.id, sha256, text, size: 10, usedAt: 0 });
    const laptop = await manualLaptop(env);
    const c = connection(env);
    c.conn.start();
    const peer = await laptop.accept();
    assert.deepEqual(await peer.hello(), HELLO, name);
    for (const message of messages) await peer.send(message);
    await until(() => c.of('fatal').length > 0, `${name}: fatal`);
    assert.deepEqual(c.of('fatal'), [{ kind: 'fatal', reason: 'protocol' }], name);
  }

  const env = await setup();
  const laptop = await manualLaptop(env, { message2: { name: 'acme-mbp' } });
  const c = connection(env);
  c.conn.start();
  await laptop.accept();
  await until(() => c.of('fatal').length > 0, 'message 2 without laptopName: fatal');
  assert.deepEqual(c.of('fatal'), [{ kind: 'fatal', reason: 'protocol' }]);
  assert.deepEqual(c.of('connected'), []);
});

test('paired, pairDenied, unknown types and an app before welcome are ignored', async () => {
  const env = await setup();
  const text = 'globalThis.acme = 1;\n';
  const sha256 = sha256Hex(text);
  env.cache.rows.set(`${env.record.id} ${sha256}`, { laptopID: env.record.id, sha256, text, size: 10, usedAt: 0 });
  const laptop = await manualLaptop(env);
  const c = connection(env);
  c.conn.start();
  const peer = await laptop.accept();
  await peer.hello();
  await peer.send({ type: 'app', body: { early: true } });
  await peer.send({ type: 'paired', room: env.room });
  await peer.send({ type: 'pairDenied', reason: 'denied' });
  await peer.send({ type: 'acme.future', anything: [1, 2] });
  await peer.send({ type: 'welcome', protocol: 1, minProtocol: 1, tbdVersion: '0.0.0-test', bundle: { sha256, size: 10 } });
  await until(() => c.states().includes('ready'), 'ready from the cache');
  await peer.send({ type: 'app', body: { late: true } });
  await until(() => c.of('app').length > 0, 'the app message');
  assert.deepEqual(c.of('app'), [{ kind: 'app', body: { late: true } }]);
  assert.deepEqual(c.of('bundle'), [{ kind: 'bundle', sha256, text }]);
  assert.deepEqual(c.of('fatal'), []);
  assert.deepEqual(c.states(), ['connecting', 'handshaking', 'ready']);
  assert.deepEqual(laptop.frames, [], 'no bundle.get on a cache hit');
  c.conn.stop();
});

test('an app message while the bundle loads is dropped; app messages pass once ready', async () => {
  const env = await setup();
  const text = 'globalThis.acme = 1;\n';
  const compressed = deflateRawSync(Buffer.from(text));
  const sha256 = sha256Hex(text);
  const laptop = await manualLaptop(env);
  const c = connection(env);
  c.conn.start();
  const peer = await laptop.accept();
  await peer.hello();
  await peer.send({ type: 'welcome', protocol: 1, minProtocol: 1, tbdVersion: '0.0.0-test', bundle: { sha256, size: compressed.length } });
  assert.deepEqual(await peer.read(), { type: 'bundle.get', sha256 });
  await peer.send({ type: 'app', body: { seq: 1 } });
  await peer.send({ type: 'bundle.chunk', sha256, index: 0, count: 1, data: compressed.toString('base64') });
  await until(() => c.states().includes('ready'), 'ready');
  await peer.send({ type: 'app', body: { seq: 2 } });
  await until(() => c.of('app').length > 0, 'the app message');
  await quiet();
  assert.deepEqual(c.of('app'), [{ kind: 'app', body: { seq: 2 } }]);
  assert.deepEqual(c.of('bundle'), [{ kind: 'bundle', sha256, text }]);
  assert.deepEqual(c.states(), ['connecting', 'handshaking', 'loading', 'ready']);
  assert.deepEqual(c.of('fatal'), []);
  c.conn.stop();
});

// --- the transport --------------------------------------------------------------------------

test('a flipped byte or a duplicated frame ends the connection and the next one handshakes again', async () => {
  /** @type {Array<[string, (frame: Uint8Array) => Uint8Array | Uint8Array[]]>} */
  const cases = [
    ['a flipped byte', (frame) => {
      const changed = frame.slice();
      changed[changed.length - 1] ^= 1;
      return changed;
    }],
    ['a duplicated frame', (frame) => [frame, frame]],
  ];
  for (const [name, tamper] of cases) {
    const env = await setup();
    let frames = 0;
    // Frame 1 is message 2 and frame 2 is welcome.
    env.relay.tamper(env.room, (frame) => (++frames === 2 ? tamper(frame) : frame));
    // A duplicated welcome decrypts once and starts the cache read beside the chain. Whether
    // that read's miss (bundle.get, then loading) or the duplicate's decrypt failure is handled
    // first is a race the spec leaves open, so the read is held until the connection has ended.
    /** @type {(value?: unknown) => void} */
    let release = () => {};
    const held = new Promise((resolve) => { release = resolve; });
    const cache = {
      ...env.cache,
      /** @param {string} laptopID @param {string} sha */
      get: async (laptopID, sha) => {
        await held;
        return env.cache.get(laptopID, sha);
      },
    };
    const c = connection(env, { cache });
    c.conn.start();
    await until(() => c.states().includes('reconnecting'), `${name}: reconnecting`);
    assert.deepEqual(env.net.log.filter((e) => e.dir === 'close()'), [{ dir: 'close()', code: 1000 }], name);
    // The ended connection's read answers late, and nothing comes of it.
    release();
    await quiet();
    assert.equal(env.joins(), 1, name);
    assert.deepEqual(c.states(), ['connecting', 'handshaking', 'reconnecting'], name);
    await env.clock.advance(1000);
    await until(() => c.states().includes('ready'), `${name}: ready`);
    assert.deepEqual(c.states(), ['connecting', 'handshaking', 'reconnecting', 'handshaking', 'loading', 'ready'], name);
    assert.equal(env.laptop.counts.bundleGet, 1, `${name}: no bundle.get from the connection that ended`);
    assert.equal(env.joins(), 2, name);
    assert.equal(env.laptop.counts.ikHandshakes, 2, name);
    assert.equal(c.of('connected').length, 2, name);
    assert.deepEqual(c.of('fatal'), [], name);
    c.conn.stop();
  }
});

test('app bodies pass through both ways unchanged and in order', async () => {
  const env = await setup();
  const c = connection(env);
  c.conn.start();
  await until(() => c.states().includes('ready'), 'ready');

  const bodies = Array.from({ length: 50 }, (_, i) => ({
    kind: 'event', event: 'acme.tick', seq: i, data: { text: `message ${i} é\u{1F600}`, list: [i, { deep: null }] },
  }));
  const ownProto = JSON.parse('{"__proto__":{"polluted":true},"kind":"request","requestID":"acme-1"}');
  const results = [...bodies, ownProto].map((body) => c.conn.sendApp(body));
  assert.deepEqual(results, Array(51).fill('sent'));
  await until(() => env.laptop.appBodies.length === 51, 'all 51 bodies');
  assert.deepEqual(env.laptop.appBodies, [...bodies, ownProto]);
  assert.ok(Object.hasOwn(env.laptop.appBodies[50], '__proto__'));

  const fromLaptop = [
    { kind: 'reply', requestID: 'acme-1', result: { ok: true, n: [1, 2, 3] } },
    JSON.parse('{"__proto__":{"x":1},"kind":"event","event":"acme.changed","seq":7,"data":{}}'),
  ];
  for (const body of fromLaptop) assert.equal(await env.laptop.sendApp(env.room, body), true);
  await until(() => c.of('app').length === 2, 'two app messages');
  assert.deepEqual(c.of('app'), fromLaptop.map((body) => ({ kind: 'app', body })));
  assert.ok(Object.hasOwn(c.of('app')[1].body, '__proto__'), 'an own __proto__ key passes through');
  assert.equal(Object.getPrototypeOf(c.of('app')[1].body), Object.prototype);
  c.conn.stop();
});

test('sendApp is offline before ready and tooLarge above 65,519 bytes', async () => {
  const env = await setup();
  const c = connection(env);
  assert.equal(c.conn.sendApp({ kind: 'event' }), 'offline', 'before start');
  c.conn.start();
  assert.equal(c.conn.sendApp({ kind: 'event' }), 'offline', 'while connecting');
  await until(() => c.states().includes('ready'), 'ready');

  const base = encode({ type: 'app', body: { pad: '' } }).length;
  const exact = { pad: 'x'.repeat(MAX_PLAINTEXT_LENGTH - base) };
  const over = { pad: 'x'.repeat(MAX_PLAINTEXT_LENGTH - base + 1) };
  assert.equal(encode({ type: 'app', body: exact }).length, MAX_PLAINTEXT_LENGTH);
  assert.equal(c.conn.sendApp(over), 'tooLarge');
  // Bytes, not characters: two-byte characters pass the limit at half the length.
  const wide = { pad: 'é'.repeat(Math.ceil((MAX_PLAINTEXT_LENGTH - base + 1) / 2)) };
  assert.ok(JSON.stringify({ type: 'app', body: wide }).length < MAX_PLAINTEXT_LENGTH);
  assert.equal(c.conn.sendApp(wide), 'tooLarge');
  assert.equal(c.conn.sendApp(exact), 'sent');
  await until(() => env.laptop.appBodies.length === 1, 'the exact-size body');
  assert.deepEqual(env.laptop.appBodies, [exact]);
  assert.equal(env.laptop.counts.rejoins, 0);

  env.laptop.leave(env.room);
  await until(() => c.states().includes('offline'), 'offline');
  assert.equal(c.conn.sendApp({ kind: 'event' }), 'offline', 'while the laptop is away');
  c.conn.stop();
  assert.equal(c.conn.sendApp({ kind: 'event' }), 'offline', 'after stop');
});

test('a peer-left right behind a frame is handled after the frame', async () => {
  const env = await setup();
  const c = connection(env);
  c.conn.start();
  await until(() => c.states().includes('ready'), 'ready');
  // The signal reaches the phone in the same task as the frame, while the frame is still
  // being decrypted.
  env.net.hooks.afterMessage = (ev, deliver) => {
    if (typeof ev.data === 'string') return;
    env.net.hooks.afterMessage = null;
    deliver({ type: 'message', data: 'peer-left' });
  };
  assert.equal(await env.laptop.sendApp(env.room, { kind: 'event', seq: 1 }), true);
  await until(() => c.states().includes('offline'), 'offline');
  await quiet();
  const after = c.events.slice(c.events.findIndex((e) => e.state === 'ready') + 1);
  assert.deepEqual(after, [{ kind: 'app', body: { kind: 'event', seq: 1 } }, { kind: 'state', state: 'offline' }]);
  c.conn.stop();
});

// --- sockets ending -------------------------------------------------------------------------

test('close 4000 means replaced and never reconnects', async () => {
  const env = await setup();
  const c = connection(env);
  c.conn.start();
  await until(() => c.states().includes('ready'), 'ready');
  const otherTab = fakeSocketFactory(env.relay, { origin: env.laptop.relayOrigin })(relaySocketURL(env.record.relay, env.room));
  await until(() => c.states().includes('replaced'), 'replaced');
  assert.equal(c.states().at(-1), 'replaced');
  assert.deepEqual(env.net.log.filter((e) => e.dir === 'closed'), [{ dir: 'closed', code: 4000 }]);
  const seen = c.events.length;
  c.conn.resume();
  await env.clock.advance(120_000);
  await quiet();
  assert.equal(env.joins(), 2, 'only the other tab joined');
  assert.equal(c.events.length, seen);
  assert.equal(env.clock.pending, 0);
  otherTab.close(1000);
});

test('closes back off 1 s, 2 s, 4 s … capped at 60 s', async () => {
  const env = await setup();
  env.laptop.leave(env.room);
  // Every socket closes, as if by the relay, right after it opens.
  env.net.hooks.afterOpen = (ws) => ws.close(1000);
  const c = connection(env, { random: () => 0 });
  c.conn.start();
  /** Waits until socket n has closed and its reconnect timer is the only one left. */
  const closed = (/** @type {number} */ n) => until(() => env.net.count('closed') === n && env.clock.pending === 1, `close ${n}`);
  await closed(1);
  assert.deepEqual(c.states(), ['connecting', 'reconnecting']);
  const delays = [1000, 2000, 4000, 8000, 16_000, 32_000, 60_000, 60_000];
  await checkBackoff(env, delays, closed);

  // resume() reconnects at once and starts the backoff over.
  c.conn.resume();
  await until(() => env.joins() === delays.length + 2, 'a join on resume');
  await closed(delays.length + 2);
  await env.clock.advance(999);
  await quiet();
  assert.equal(env.joins(), delays.length + 2);
  await env.clock.advance(1);
  await until(() => env.joins() === delays.length + 3, 'a join 1 s later');
  assert.deepEqual(c.states(), ['connecting', 'reconnecting']);
  c.conn.stop();
});

test('the backoff jitter adds up to a quarter, and the cap holds at 60 s', async () => {
  const env = await setup();
  env.laptop.leave(env.room);
  env.net.hooks.afterOpen = (ws) => ws.close(1000);
  const c = connection(env, { random: () => 0.99 });
  c.conn.start();
  const closed = (/** @type {number} */ n) => until(() => env.net.count('closed') === n && env.clock.pending === 1, `close ${n}`);
  await closed(1);
  // 1,000 ms × 2^attempt × 1.2475, rounded, and never above 60,000 ms.
  await checkBackoff(env, [1248, 2495, 4990, 9980, 19_960, 39_920, 60_000, 60_000], closed);
  c.conn.stop();
});

test('decrypt failures back off until a connection reaches ready', async () => {
  const env = await setup();
  /** @param {Uint8Array} frame */
  const flip = (frame) => {
    const changed = frame.slice();
    changed[changed.length - 1] ^= 1;
    return changed;
  };
  // Each connection gets message 2 and then welcome, its first transport frame, which arrives
  // changed: every handshake succeeds and every connection fails before ready.
  let frames = 0;
  env.relay.tamper(env.room, (frame) => (++frames % 2 === 0 ? flip(frame) : frame));
  const c = connection(env);
  c.conn.start();
  /** Waits until the phone has closed socket n and armed its reconnect timer. */
  const failed = (/** @type {number} */ n) => until(() => env.net.count('close()') === n && env.clock.pending === 1, `failure ${n}`);
  await failed(1);
  await checkBackoff(env, [1000, 2000, 4000, 8000], failed);
  assert.equal(c.of('connected').length, 5);
  assert.equal(c.count('ready'), 0);

  // A connection that reaches ready starts the backoff over.
  env.relay.tamper(env.room, null);
  await env.clock.advance(16_000);
  await until(() => c.states().includes('ready'), 'ready');
  env.relay.tamper(env.room, flip);
  assert.equal(await env.laptop.sendApp(env.room, { kind: 'event' }), true);
  await failed(6);
  await env.clock.advance(999);
  await quiet();
  assert.equal(env.joins(), 6);
  await env.clock.advance(1);
  await until(() => env.joins() === 7, 'a join 1 s after the failure');
  assert.deepEqual(c.of('fatal'), []);
  c.conn.stop();
});

test('a relay that refuses the first socket reads relayUnreachable', async () => {
  const env = await setup();
  let refuse = true;
  const refusing = instrument(fakeSocketFactory(env.relay, { origin: 'https://relay.acme.test' }));
  const c = connection(env, { openSocket: (/** @type {string} */ url) => (refuse ? refusing.factory(url) : env.net.factory(url)) });
  c.conn.start();
  await until(() => c.states().includes('relayUnreachable'), 'relayUnreachable');
  await until(() => env.clock.pending === 1, 'the reconnect timer');
  assert.deepEqual(c.states(), ['connecting', 'relayUnreachable']);
  assert.equal(env.joins(), 0);

  // A second refusal changes nothing; the relay answering again connects.
  await env.clock.advance(1000);
  await until(() => refusing.count('closed') === 2 && env.clock.pending === 1, 'a second refusal');
  assert.deepEqual(c.states(), ['connecting', 'relayUnreachable']);
  refuse = false;
  await env.clock.advance(2000);
  await until(() => c.states().includes('ready'), 'ready');
  assert.deepEqual(c.states(), ['connecting', 'relayUnreachable', 'handshaking', 'loading', 'ready']);

  // Once a socket has opened, a refused reconnect reads reconnecting.
  refuse = true;
  env.net.sockets[0].close(1000);
  await until(() => c.states().includes('reconnecting'), 'reconnecting');
  await until(() => env.clock.pending === 1, 'the reconnect timer');
  await env.clock.advance(1000);
  await until(() => refusing.count('closed') === 3 && env.clock.pending === 1, 'a third refusal');
  assert.deepEqual(c.states(), ['connecting', 'relayUnreachable', 'handshaking', 'loading', 'ready', 'reconnecting']);
  c.conn.stop();
});

test('a socket that never opens is closed 10 s after it was made, and the next one connects', async () => {
  const env = await setup();
  const hanging = hangingSockets();
  let hang = true;
  const c = connection(env, { openSocket: (/** @type {string} */ url) => (hang ? hanging.factory(url) : env.net.factory(url)) });
  c.conn.start();
  await quiet();
  assert.equal(hanging.sockets.length, 1);
  await env.clock.advance(SIGNAL_TIMEOUT_MS - 1);
  await quiet();
  assert.deepEqual(hanging.sockets[0].closes, []);
  assert.deepEqual(c.states(), ['connecting']);
  await env.clock.advance(1);
  await until(() => c.states().includes('relayUnreachable'), 'relayUnreachable');
  assert.deepEqual(hanging.sockets[0].closes, [1000]);
  assert.equal(env.clock.pending, 1, 'only the reconnect timer');

  hang = false;
  await env.clock.advance(1000);
  await until(() => c.states().includes('ready'), 'ready');
  assert.deepEqual(c.states(), ['connecting', 'relayUnreachable', 'handshaking', 'loading', 'ready']);
  assert.equal(hanging.sockets.length, 1);
  assert.equal(env.joins(), 1);
  c.conn.stop();
});

test('resume with a black-holed socket reconnects within 3 s', async () => {
  const env = await setup();
  const c = connection(env);
  c.conn.start();
  await until(() => c.states().includes('ready'), 'ready');
  env.relay.blackHole(env.room, true);
  c.conn.resume();
  await quiet();
  await env.clock.advance(RESUME_PONG_TIMEOUT_MS - 1);
  await quiet();
  assert.equal(env.joins(), 1);
  await env.clock.advance(1);
  await until(() => env.joins() === 2, 'a second join');
  assert.equal(c.states().at(-1), 'reconnecting');

  // resume() on a live socket only probes it.
  env.relay.blackHole(env.room, false);
  await env.clock.advance(SIGNAL_TIMEOUT_MS + 1000);
  await until(() => c.count('ready') === 2, 'ready again');
  c.conn.resume();
  await env.clock.advance(RESUME_PONG_TIMEOUT_MS * 2);
  await quiet();
  assert.equal(env.joins(), 3);
  assert.equal(c.states().at(-1), 'ready');
  c.conn.stop();
});

test('resume replaces a socket that is still connecting', async () => {
  const env = await setup();
  const hanging = hangingSockets();
  let hang = true;
  const c = connection(env, { openSocket: (/** @type {string} */ url) => (hang ? hanging.factory(url) : env.net.factory(url)) });
  c.conn.start();
  await quiet();
  assert.equal(hanging.sockets.length, 1);
  hang = false;
  c.conn.resume();
  // No time passes: the replacement is made at once.
  await until(() => c.states().includes('ready'), 'ready');
  assert.deepEqual(hanging.sockets[0].closes, [1000]);
  assert.deepEqual(c.states(), ['connecting', 'handshaking', 'loading', 'ready']);
  assert.equal(env.joins(), 1);
  await env.clock.advance(SIGNAL_TIMEOUT_MS);
  await quiet();
  assert.equal(c.states().at(-1), 'ready', 'no timer of the replaced socket fires');
  assert.equal(env.joins(), 1);
  c.conn.stop();
});

test('back-to-back resumes open one socket, and a later resume still replaces a failed one', async () => {
  const env = await setup();
  const hanging = hangingSockets();
  let hang = true;
  const c = connection(env, { openSocket: (/** @type {string} */ url) => (hang ? hanging.factory(url) : env.net.factory(url)) });
  c.conn.start();
  await quiet();
  assert.equal(hanging.sockets.length, 1);

  // visibilitychange and pageshow on one return to the page: the first replaces the socket
  // start() opened, the second finds that replacement still connecting and leaves it be.
  c.conn.resume();
  c.conn.resume();
  await quiet();
  assert.equal(hanging.sockets.length, 2, 'one replacement socket');
  assert.deepEqual(hanging.sockets[0].closes, [1000]);
  assert.deepEqual(hanging.sockets[1].closes, [], 'the second resume keeps the first one\'s socket');
  c.conn.resume();
  await quiet();
  assert.equal(hanging.sockets.length, 2, 'still one while it connects');

  // The signal timeout ends the hung socket; the next resume replaces it at once.
  await env.clock.advance(SIGNAL_TIMEOUT_MS);
  await quiet();
  assert.deepEqual(hanging.sockets[1].closes, [1000]);
  hang = false;
  c.conn.resume();
  await until(() => c.states().includes('ready'), 'ready');
  assert.equal(hanging.sockets.length, 2);
  assert.equal(env.joins(), 1);

  // Open, a resume only probes, however many come.
  c.conn.resume();
  c.conn.resume();
  await quiet();
  assert.equal(env.joins(), 1);
  assert.equal(env.net.sockets.length, 1);
  c.conn.stop();
});

test('a reconnect waits while hidden and runs on resume', async () => {
  const env = await setup();
  let visible = true;
  const c = connection(env, { isVisible: () => visible });
  c.conn.start();
  await until(() => c.states().includes('ready'), 'ready');

  // A close while hidden arms nothing.
  visible = false;
  env.net.sockets[0].close(1000);
  await until(() => c.states().includes('reconnecting'), 'reconnecting');
  await env.clock.advance(120_000);
  await quiet();
  assert.equal(env.joins(), 1);
  visible = true;
  await env.clock.advance(120_000);
  await quiet();
  assert.equal(env.joins(), 1, 'only resume() reconnects');
  c.conn.resume();
  await until(() => c.count('ready') === 2, 'ready after resume');
  assert.equal(env.joins(), 2);

  // A reconnect that falls due while hidden waits too.
  env.net.sockets[1].close(1000);
  await until(() => c.count('reconnecting') === 2 && env.clock.pending === 1, 'the reconnect timer');
  visible = false;
  await env.clock.advance(1000);
  await quiet();
  assert.equal(env.joins(), 2);
  visible = true;
  c.conn.resume();
  await until(() => c.count('ready') === 3, 'ready after the second resume');
  assert.equal(env.joins(), 3);
  c.conn.stop();
});

test('stop closes the socket, cancels its timers and reports nothing more', async () => {
  const env = await setup();
  const c = connection(env, { absentGraceMs: SIGNAL_TIMEOUT_MS });
  c.conn.start();
  await until(() => c.states().includes('ready'), 'ready');
  c.conn.stop();
  assert.deepEqual(env.net.log.filter((e) => e.dir === 'close()'), [{ dir: 'close()', code: 1000 }]);
  assert.equal(env.clock.pending, 0);
  const seen = c.events.length;
  await env.clock.advance(120_000);
  await quiet();
  assert.equal(c.events.length, seen);
  assert.equal(env.joins(), 1);

  // Stopped from inside onEvent: the event being handled is the last.
  const third = await setup();
  /** @type {LaptopConnection | null} */
  let stopping = null;
  /** @type {any[]} */
  const seenByHandler = [];
  stopping = new LaptopConnection({
    record: third.record,
    keyPair: third.keyPair,
    cache: third.cache,
    openSocket: third.net.factory,
    onEvent: (event) => {
      seenByHandler.push(event);
      if (event.kind === 'bundle') stopping?.stop();
    },
    clock: third.clock,
  });
  stopping.start();
  await until(() => seenByHandler.some((e) => e.kind === 'bundle'), 'the bundle');
  await quiet();
  assert.deepEqual(seenByHandler.map((e) => e.state ?? e.kind), ['connecting', 'handshaking', 'connected', 'loading', 'bundle']);

  // Stopped while a cache read is pending: nothing more is reported or sent.
  const second = await setup();
  /** @type {(value: null) => void} */
  let answer = () => {};
  const d = connection(second, {
    cache: { ...second.cache, get: () => new Promise((resolve) => { answer = resolve; }) },
  });
  d.conn.start();
  await until(() => second.laptop.counts.hello === 2, 'hello on the device room');
  await quiet();
  d.conn.stop();
  assert.equal(second.clock.pending, 0, 'the cache read timeout is cancelled');
  const before = d.events.length;
  answer(null);
  await quiet();
  assert.equal(d.events.length, before);
  assert.equal(second.laptop.counts.bundleGet, 0);
  assert.deepEqual(d.states(), ['connecting', 'handshaking']);
});

test('stop during a backoff wait cancels the reconnect timer', async () => {
  const env = await setup();
  const c = connection(env);
  c.conn.start();
  await until(() => c.states().includes('ready'), 'ready');
  env.net.sockets[0].close(1000);
  await until(() => c.states().includes('reconnecting') && env.clock.pending === 1, 'the reconnect timer');
  c.conn.stop();
  assert.equal(env.clock.pending, 0);
  const seen = c.events.length;
  await env.clock.advance(120_000);
  await quiet();
  assert.equal(env.joins(), 1);
  assert.equal(c.events.length, seen);
});
