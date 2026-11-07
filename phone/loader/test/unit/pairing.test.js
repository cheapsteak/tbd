import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';

import { confirmationCode } from '../../channel/confirm.js';
import { NoiseError, phonePrologue } from '../../channel/noise.js';
import { base64urlDecode, base64urlEncode } from '../../channel/pairingLink.js';
import { LaptopConnection } from '../../connection.js';
import {
  HANDSHAKE_TIMEOUT_MS, LOADER_VERSION, PAIRING_EXPIRY_GRACE_MS, RESUME_PONG_TIMEOUT_MS, SIGNAL_TIMEOUT_MS,
} from '../../constants.js';
import { isWrapKey, unwrapPhoneKeyPair } from '../../keys.js';
import { isRoomID, readPairingLink, relaySocketURL } from '../../links.js';
import { PairingError, startPairing } from '../../pairing.js';
import { ProtocolError } from '../../protocol.js';
import { validateLaptopRecord } from '../../store.js';
import { FakeClock } from '../support/fake-clock.js';
import { createFakeRelay } from '../support/fake-relay.js';
import { fakeSocketFactory } from '../support/fake-websocket.js';
import { createResponder } from '../support/noise-responder.js';
import { createScriptedLaptop } from '../support/scripted-laptop.js';
import { generatePair } from '../support/x25519.js';

const WAIT_MS = 10_000;
const START = 1_700_000_000_000;
const LOADER_URL = 'https://loader.acme.test/';
const LOCAL_RELAY = 'http://127.0.0.1';
const HELLO = { type: 'hello', loaderVersion: LOADER_VERSION, protocols: [1] };
// The longest timeout a browser runs as asked.
const MAX_TIMER_MS = 2 ** 31 - 1;

const utf8 = new TextEncoder();
/** @param {unknown} value */
const encode = (value) => utf8.encode(JSON.stringify(value));
/** @param {Uint8Array} bytes */
const decode = (bytes) => JSON.parse(new TextDecoder().decode(bytes));
/** @param {string} text */
const b64 = (text) => /** @type {Uint8Array} */ (base64urlDecode(text));
const newRoom = () => base64urlEncode(new Uint8Array(randomBytes(32)));
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
 * The link a phone reads from an offer, through the loader's own intake.
 * @param {object} offer the pairing link's JSON
 * @param {number} now
 */
function linkFrom(offer, now) {
  return readPairingLink(`${LOADER_URL}#p=${base64urlEncode(encode(offer))}`, now);
}

/**
 * Wraps a socket factory to record every socket it made and a timeline of what crossed them:
 * `openSocket`, `open`, inbound text and frames, outbound frames, `close()` calls and closes.
 * While `hooks.holdText` is set, inbound text (relay signals) is held back until `release()`.
 * `hooks.afterMessage(ev, deliver)` runs right after the phone's message handler, in the same
 * task; `deliver(ev)` hands the phone another message at once.
 * @param {(url: string) => any} base
 */
function instrument(base) {
  /** @type {Array<{ dir: string, text?: string, bytes?: Uint8Array, code?: number }>} */
  const log = [];
  /** @type {any[]} */
  const sockets = [];
  /** @type {{ holdText: boolean, afterMessage: ((ev: any, deliver: (ev: any) => void) => void) | null }} */
  const hooks = { holdText: false, afterMessage: null };
  /** @type {Array<() => void>} */
  const held = [];
  /** @param {string} url */
  const factory = (url) => {
    log.push({ dir: 'openSocket' });
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
    intercept(ws, 'onopen', (_ev, handler) => {
      log.push({ dir: 'open' });
      handler(_ev);
    });
    intercept(ws, 'onmessage', (ev, handler) => {
      /** @param {any} message */
      const deliver = (message) => {
        log.push(typeof message.data === 'string'
          ? { dir: 'in', text: message.data }
          : { dir: 'in', bytes: new Uint8Array(message.data).slice() });
        handler(message);
        hooks.afterMessage?.(message, deliver);
      };
      if (hooks.holdText && typeof ev.data === 'string') held.push(() => deliver(ev));
      else deliver(ev);
    });
    intercept(ws, 'onclose', (ev, handler) => {
      log.push({ dir: 'closed', code: ev.code });
      handler(ev);
    });
    return ws;
  };
  return {
    factory,
    log,
    sockets,
    hooks,
    held,
    /** Delivers the held text and stops holding. */
    release() {
      hooks.holdText = false;
      for (const deliver of held.splice(0)) deliver();
    },
    /** Outbound frames. */
    out: () => log.filter((e) => e.dir === 'out').map((e) => /** @type {Uint8Array} */ (e.bytes)),
    /** Inbound frames. */
    inFrames: () => log.filter((e) => e.dir === 'in' && e.bytes !== undefined).map((e) => /** @type {Uint8Array} */ (e.bytes)),
    /** The codes the phone called `close()` with. */
    closeCalls: () => log.filter((e) => e.dir === 'close()').map((e) => e.code),
    /** @param {string} text */
    gotText: (text) => log.some((e) => e.text === text),
  };
}

/**
 * Replaces an event-handler property with `wrapper`, which gets the event and the handler
 * the phone set.
 * @param {any} ws
 * @param {string} name
 * @param {(ev: any, handler: (ev: any) => void) => void} wrapper
 */
function intercept(ws, name, wrapper) {
  /** @type {((ev: any) => void) | null} */
  let handler = null;
  Object.defineProperty(ws, name, {
    configurable: true,
    get: () => (handler === null ? null : (/** @type {any} */ ev) => wrapper(ev, /** @type {(ev: any) => void} */ (handler))),
    set: (fn) => {
      handler = fn;
    },
  });
}

/**
 * A socket factory whose sockets stay connecting forever. Each records the codes `close()`
 * was called with.
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
 * The relay ends the phone's open socket with `code`, as a browser reports it.
 * @param {any} ws
 * @param {number} code
 */
function relayCloses(ws, code) {
  ws.readyState = 3;
  ws.onclose?.({ type: 'close', code, reason: '', wasClean: false });
}

/**
 * A clock whose timers run only when the test fires them. It records the delay of every timer
 * set on it.
 * @param {number} start
 */
function manualClock(start) {
  let now = start;
  let nextID = 1;
  /** @type {Map<number, { fn: () => void, ms: number, due: number }>} */
  const timers = new Map();
  /** @type {number[]} */
  const delays = [];
  return {
    timers,
    delays,
    now: () => now,
    /**
     * @param {() => void} fn
     * @param {number} ms
     */
    setTimeout(fn, ms) {
      const id = nextID++;
      timers.set(id, { fn, ms, due: now + ms });
      delays.push(ms);
      return id;
    },
    /** @param {unknown} id */
    clearTimeout(id) {
      timers.delete(/** @type {number} */ (id));
    },
    /**
     * Moves time to the latest timer's due time and runs that timer alone.
     * @returns {number} the delay it was set with
     */
    fireLatest() {
      const [id, timer] = [...timers].reduce((a, b) => (b[1].due > a[1].due ? b : a));
      timers.delete(id);
      now = timer.due;
      timer.fn();
      return timer.ms;
    },
  };
}

/**
 * A relay, a fake clock, the scripted laptop with an open offer, and the phone's link to it.
 * @param {{ offer?: object, laptop?: object, linkPatch?: object }} [options] `offer` goes to
 *   makeOffer, `laptop` to createScriptedLaptop, and `linkPatch` changes the link's JSON.
 */
async function setup({ offer: offerOptions = {}, laptop: laptopOptions = {}, linkPatch = {} } = {}) {
  const relay = createFakeRelay();
  const clock = new FakeClock(START);
  const laptop = await createScriptedLaptop({ relay, clock, ...laptopOptions });
  const offer = laptop.makeOffer(offerOptions);
  const link = linkFrom({ ...offer, ...linkPatch }, clock.now());
  const net = instrument(fakeSocketFactory(relay, { origin: laptop.relayOrigin }));
  return { relay, clock, laptop, offer, link, net, joins: () => relay.stats.phoneJoins.get(offer.room) ?? 0 };
}

/**
 * A pairing room with no scripted laptop: the test plays the laptop by hand, so it can send
 * what plan 3's laptop never would.
 * @param {{ exp?: number }} [options] the link's `exp`
 */
async function manualSetup({ exp = Math.floor(START / 1000) + 300 } = {}) {
  const relay = createFakeRelay();
  const clock = new FakeClock(START);
  const laptopPair = await generatePair();
  const room = newRoom();
  const secret = new Uint8Array(randomBytes(32));
  const offer = {
    v: 1, relay: LOCAL_RELAY, room, secret: base64urlEncode(secret), key: base64urlEncode(laptopPair.publicRaw), name: 'acme-mbp', exp,
  };
  const link = linkFrom(offer, clock.now());
  const net = instrument(fakeSocketFactory(relay, { origin: LOCAL_RELAY }));
  return { relay, clock, laptopPair, secret, offer, link, net, prologue: phonePrologue(b64(room)) };
}

/**
 * A laptop socket on the pairing room, driven by hand.
 * @param {Awaited<ReturnType<typeof manualSetup>>} env
 */
function laptopSocket(env) {
  /** @type {Uint8Array[]} */
  const frames = [];
  /** @type {string[]} */
  const signals = [];
  const handle = /** @type {import('../support/fake-relay.js').RelayHandle} */ (env.relay.connect(`/v1/rooms/${env.offer.room}?role=laptop`, {
    binary: (bytes) => frames.push(bytes),
    text: (text) => signals.push(text),
    close: () => {},
  }));
  const next = async () => {
    await until(() => frames.length > 0, 'a phone frame');
    return /** @type {Uint8Array} */ (frames.shift());
  };
  return {
    handle,
    frames,
    signals,
    next,
    /**
     * Reads message 1 and answers it with message 2.
     * @param {unknown} [payload] message 2's payload: a value to encode, or raw text
     */
    async answer(payload = { laptopName: 'acme-mbp' }) {
      const responder = await createResponder({
        pattern: 'IKpsk2', localStatic: env.laptopPair, psk: env.secret, prologue: env.prologue,
      });
      const read = await responder.readMessage1(await next());
      const written = await responder.writeMessage2(typeof payload === 'string' ? utf8.encode(payload) : encode(payload));
      handle.send(written.message);
      const { transport } = written;
      return {
        read,
        code: await confirmationCode(written.handshakeHash),
        /** The next phone message, decrypted. */
        read1: async () => decode(await transport.decrypt(await next())),
        /** @param {object | string} message an object, or raw text to send as is */
        send: async (message) => handle.send(await transport.encrypt(typeof message === 'string' ? utf8.encode(message) : encode(message))),
      };
    },
  };
}

/**
 * Starts pairing and records its codes and outcome.
 * @param {{ link: any, net: { factory: (url: string) => any }, clock: FakeClock }} env
 * @param {Partial<Parameters<typeof startPairing>[0]>} [options]
 */
function pair(env, options = {}) {
  /** @type {string[]} */
  const codes = [];
  const run = startPairing({
    link: env.link,
    deviceName: 'iPhone',
    openSocket: env.net.factory,
    onCode: (code) => codes.push(code),
    clock: env.clock,
    ...options,
  });
  /** @type {{ value?: any, error?: any } | null} */
  let settled = null;
  const outcome = run.result.then((value) => ({ value }), (error) => ({ error }));
  outcome.then((result) => {
    settled = result;
  });
  return { run, codes, outcome, settled: () => settled };
}

/**
 * The outcome, within WAIT_MS of real time. The fake clock keeps no real timer alive, so a
 * pairing that hangs would otherwise end the whole run instead of failing its test.
 * @param {ReturnType<typeof pair>} p
 * @returns {Promise<{ value?: any, error?: any }>}
 */
async function outcomeOf(p) {
  /** @type {ReturnType<typeof setTimeout> | undefined} */
  let timer;
  const timeout = new Promise((_resolve, reject) => {
    timer = setTimeout(() => reject(new Error('timed out waiting for the pairing outcome')), WAIT_MS);
  });
  try {
    return /** @type {{ value?: any, error?: any }} */ (await Promise.race([p.outcome, timeout]));
  } finally {
    clearTimeout(timer);
  }
}

/**
 * @param {ReturnType<typeof pair>} p
 * @param {string} reason
 * @returns {Promise<PairingError>}
 */
async function failsWith(p, reason) {
  const { value, error } = await outcomeOf(p);
  assert.equal(value, undefined, `pairing resolved instead of rejecting ${reason}`);
  assert.ok(error instanceof PairingError, `rejected with ${error}`);
  assert.equal(error.reason, reason);
  return error;
}

/**
 * @param {ReturnType<typeof pair>} p
 * @returns {Promise<any>}
 */
async function succeeds(p) {
  const { value, error } = await outcomeOf(p);
  assert.equal(error, undefined, `pairing rejected: ${error?.reason ?? error}`);
  return value;
}

/**
 * Every outcome closes the socket with 1000 once and leaves no timer behind.
 * @param {{ net: ReturnType<typeof instrument>, clock: FakeClock }} env
 */
function assertEnded(env) {
  assert.deepEqual(env.net.closeCalls(), env.net.sockets.length === 0 ? [] : [1000]);
  assert.equal(env.clock.pending, 0, 'no timer left');
}

// --- allow ----------------------------------------------------------------------------------

test('allow resolves with the laptop name from message 2, the code equals the laptop\'s, and the laptop stored the device name', async () => {
  // The link names the laptop differently, so the name must come from message 2.
  const env = await setup({ laptop: { laptopName: 'acme-studio' }, linkPatch: { name: 'acme-qr-name' } });
  const p = pair(env, { deviceName: 'Ada’s iPhone' });
  const result = await succeeds(p);
  assert.equal(result.laptopName, 'acme-studio');
  assert.equal(p.codes.length, 1);
  assert.match(p.codes[0], /^\d{6}$/);
  assert.equal(p.codes[0], env.laptop.lastCode);
  const device = env.laptop.devices.get(result.room);
  assert.equal(device?.deviceName, 'Ada’s iPhone');
  assert.deepEqual(device?.phoneKey, result.publicRaw);

  // After paired the phone sends nothing: message 1 and hello only.
  assert.equal(env.net.out().length, 2);
  assertEnded(env);
  assert.equal(env.joins(), 1);
  assert.deepEqual(env.laptop.errors, []);
});

test('paired carries a new room, which the result returns', async () => {
  const env = await setup();
  const result = await succeeds(pair(env));
  assert.ok(isRoomID(result.room));
  assert.notEqual(result.room, env.offer.room);
  assert.deepEqual([...env.laptop.devices.keys()], [result.room], 'the laptop stored the device under that room');
});

test('the key is made before the socket opens, the result holds it wrapped for this laptop, and no private key in it is extractable', async () => {
  const env = await setup();
  /** @type {string[]} */
  const timeline = [];
  const subtle = new Proxy(crypto.subtle, {
    get(target, name) {
      const value = Reflect.get(target, name);
      if (typeof value !== 'function') return value;
      return (/** @type {any[]} */ ...args) => {
        timeline.push(String(name));
        return value.apply(target, args);
      };
    },
  });
  const openSocket = (/** @type {string} */ url) => {
    timeline.push('openSocket');
    return env.net.factory(url);
  };
  const result = await succeeds(pair(env, { subtle, openSocket }));
  assert.ok(timeline.includes('wrapKey') && timeline.includes('unwrapKey'), timeline.join(', '));
  assert.equal(timeline.at(-1), 'openSocket', 'every key operation came before the socket');

  assert.deepEqual(Object.keys(result).sort(), ['laptopName', 'pair', 'publicRaw', 'room', 'wrapIV', 'wrapKey', 'wrappedKey']);
  assert.ok(isWrapKey(result.wrapKey));
  assert.equal(result.pair.privateKey.extractable, false);
  assert.deepEqual(new Uint8Array(await crypto.subtle.exportKey('raw', result.pair.publicKey)), result.publicRaw);
  // The handshake used this key: the laptop stored its public half.
  assert.deepEqual(env.laptop.devices.get(result.room)?.phoneKey, result.publicRaw);

  // Wrapped for this laptop's record only.
  const fields = { phoneKey: result.publicRaw, wrappedKey: result.wrappedKey, wrapIV: result.wrapIV };
  const unwrapped = await unwrapPhoneKeyPair(crypto.subtle, result.wrapKey, { id: env.offer.key, ...fields });
  assert.equal(unwrapped.privateKey.extractable, false);
  await assert.rejects(unwrapPhoneKeyPair(crypto.subtle, result.wrapKey, { id: newRoom(), ...fields }));
});

test('a key that cannot be made rejects invalid and opens no socket', async () => {
  const env = await setup();
  const failure = new Error('no X25519 here');
  const subtle = new Proxy(crypto.subtle, {
    get(target, name) {
      if (name === 'generateKey') return () => Promise.reject(failure);
      const value = Reflect.get(target, name);
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
  const p = pair(env, { subtle });
  const error = await failsWith(p, 'invalid');
  assert.equal(error.cause, failure);
  await quiet();
  assert.equal(env.net.sockets.length, 0);
  assert.deepEqual(p.codes, []);
});

test('a link the loader cannot use rejects invalid instead of throwing, and opens nothing', async () => {
  const env = await setup();
  /** @type {Array<[string, any, Function]>} */
  const cases = [
    ['a relay relaySocketURL refuses', { ...env.link, fields: { ...env.link.fields, relay: 'ftp://relay.acme.test' } }, RangeError],
    ['a room that is not 32 bytes', { ...env.link, room: new Uint8Array(31) }, NoiseError],
    ['a laptop key that is not 32 bytes', { ...env.link, laptopKey: new Uint8Array(31) }, TypeError],
  ];
  /** @type {unknown[]} */
  const unhandled = [];
  const onUnhandled = (/** @type {unknown} */ reason) => unhandled.push(reason);
  process.on('unhandledRejection', onUnhandled);
  try {
    for (const [name, link, type] of cases) {
      /** @type {string[]} */
      const codes = [];
      /** @type {any} */
      let run;
      assert.doesNotThrow(() => {
        run = startPairing({ link, deviceName: 'iPhone', openSocket: env.net.factory, onCode: (code) => codes.push(code), clock: env.clock });
      }, name);
      run.cancel();
      run.probe();
      // Long enough for Node to report a rejection nobody handled.
      await quiet();
      const error = await run.result.then(() => assert.fail(`${name}: resolved`), (/** @type {unknown} */ e) => e);
      assert.ok(error instanceof PairingError, `${name}: ${error}`);
      assert.equal(error.reason, 'invalid', name);
      assert.ok(error.cause instanceof type, `${name}: ${error.cause}`);
      assert.deepEqual(codes, [], name);
    }
  } finally {
    process.off('unhandledRejection', onUnhandled);
  }
  assert.deepEqual(unhandled, [], 'every rejection was marked handled');
  assert.equal(env.net.sockets.length, 0);
  assert.equal(env.clock.pending, 0);
});

test('message 1 is sent only after peer-joined', async () => {
  const env = await setup();
  env.net.hooks.holdText = true;
  const p = pair(env);
  await until(() => env.net.log.some((e) => e.dir === 'open') && env.net.held.length === 1, 'the open socket and a held signal');
  await quiet();
  assert.deepEqual(env.net.out(), [], 'nothing is sent on open');
  assert.equal(env.laptop.counts.pairings, 0);

  env.net.release();
  await succeeds(p);
  const joinedAt = env.net.log.findIndex((e) => e.text === 'peer-joined');
  const firstOut = env.net.log.findIndex((e) => e.dir === 'out');
  assert.ok(joinedAt >= 0 && firstOut > joinedAt, 'the first frame follows peer-joined');
});

test('the laptop sees hello before it decides, sent right after the code', async () => {
  const env = await setup({ offer: { decision: 'silent' } });
  /** @type {number[]} */
  const sentAtCode = [];
  const p = pair(env, { onCode: (code) => {
    p.codes.push(code);
    sentAtCode.push(env.net.out().length);
  } });
  await until(() => p.codes.length === 1, 'the code');
  await until(() => env.laptop.counts.hello === 1, 'hello at the laptop');
  assert.deepEqual(sentAtCode, [1], 'the code is shown once message 1 is out, before hello');
  assert.deepEqual(env.laptop.log.filter((e) => e.room === env.offer.room).map((e) => e.message), [HELLO]);
  await quiet();
  assert.equal(p.settled(), null, 'still waiting for Allow');
  p.run.cancel();
  await failsWith(p, 'cancelled');
});

// --- deny and expiry ------------------------------------------------------------------------

test('deny rejects denied; laptop expiry rejects expired', async () => {
  for (const [decision, reason] of [['deny', 'denied'], ['expire', 'expired']]) {
    const env = await setup({ offer: { decision } });
    const p = pair(env);
    await failsWith(p, reason);
    assert.equal(p.codes.length, 1, 'the code was shown first');
    assert.equal(env.laptop.counts.hello, 1);
    assert.equal(env.laptop.devices.size, 0);
    assertEnded(env);
  }
});

test('no answer after the code until exp plus 120 s rejects expired', async () => {
  const env = await setup({ offer: { decision: 'silent', expSeconds: 300 } });
  const p = pair(env);
  await until(() => env.laptop.counts.hello === 1, 'hello at the laptop');
  const wait = env.offer.exp * 1000 + PAIRING_EXPIRY_GRACE_MS - env.clock.now();
  assert.equal(wait, 420_000);
  await env.clock.advance(wait - 1);
  await quiet();
  assert.equal(p.settled(), null, 'still waiting 1 ms before the deadline');
  await env.clock.advance(1);
  await failsWith(p, 'expired');
  assertEnded(env);
});

test('the expiry deadline bounds pairing from the start, before message 2 too', async () => {
  // A link whose deadline is 5 s away when pairing starts, and a laptop that has message 1
  // but has not answered: the deadline comes before the handshake timeout.
  const env = await manualSetup({ exp: (START + 5_000 - PAIRING_EXPIRY_GRACE_MS) / 1000 });
  const laptop = laptopSocket(env);
  const p = pair(env);
  await until(() => laptop.frames.length === 1, 'message 1');
  await env.clock.advance(4_999);
  await quiet();
  assert.equal(p.settled(), null, 'still waiting 1 ms before the deadline');
  await env.clock.advance(1);
  await failsWith(p, 'expired');
  assert.deepEqual(p.codes, []);
  assertEnded(env);
});

test('a laptop socket that keeps rejoining cannot keep pairing alive past exp plus the grace', async () => {
  const env = await manualSetup();
  const deadline = env.offer.exp * 1000 + PAIRING_EXPIRY_GRACE_MS;
  let message1s = 0;
  const join = () => env.relay.connect(`/v1/rooms/${env.offer.room}?role=laptop`, {
    binary: () => {
      message1s += 1;
    },
    text: () => {},
    close: () => {},
  });
  join();
  const p = pair(env);
  await until(() => message1s === 1, 'message 1');
  // Every 9 s, inside the handshake timeout, a new laptop socket replaces the last one (no
  // answer, no peer-left), and the phone sends it a fresh message 1.
  while (env.clock.now() + 9_000 < deadline) {
    const sent = message1s;
    await env.clock.advance(9_000);
    join();
    await until(() => message1s === sent + 1, `message 1 number ${sent + 1}`);
  }
  assert.equal(message1s, 47);
  await env.clock.advance(deadline - env.clock.now() - 1);
  await quiet();
  assert.equal(p.settled(), null, 'still waiting 1 ms before the deadline');
  await env.clock.advance(1);
  await failsWith(p, 'expired');
  assert.deepEqual(p.codes, []);
  assertEnded(env);
});

test('a far-off deadline is waited for in steps of at most 2^31 - 1 ms', async () => {
  // Sixty days away. A browser runs a longer timeout at once.
  const env = await manualSetup({ exp: START / 1000 + 60 * 86_400 });
  const deadline = env.offer.exp * 1000 + PAIRING_EXPIRY_GRACE_MS;
  const clock = manualClock(START);
  const hanging = hangingSockets();
  // The socket stays connecting and its signal timer is never fired, so only the deadline
  // can end pairing.
  const p = pair({ ...env, clock: /** @type {any} */ (clock) }, { openSocket: hanging.factory });
  await until(() => hanging.sockets.length === 1, 'the socket');
  /** @type {number[]} */
  const steps = [];
  for (let i = 0; i < 5 && p.settled() === null; i += 1) {
    steps.push(clock.fireLatest());
    await quiet();
    if (clock.now() < deadline) assert.equal(p.settled(), null, `still waiting after step ${i + 1}`);
  }
  assert.deepEqual(steps, [MAX_TIMER_MS, MAX_TIMER_MS, deadline - START - 2 * MAX_TIMER_MS]);
  assert.equal(clock.now(), deadline);
  await failsWith(p, 'expired');
  assert.ok(clock.delays.every((ms) => ms <= MAX_TIMER_MS), `delays: ${clock.delays.join(', ')}`);
  assert.deepEqual(hanging.sockets[0].closes, [1000]);
  assert.equal(clock.timers.size, 0, 'no timer left');
});

// --- the laptop not answering ---------------------------------------------------------------

test('a used code (laptop silent) rejects invalid after 10 s', async () => {
  const env = await manualSetup();
  const laptop = laptopSocket(env);
  const p = pair(env);
  await until(() => laptop.frames.length === 1, 'message 1');
  await env.clock.advance(HANDSHAKE_TIMEOUT_MS - 1);
  await quiet();
  assert.equal(p.settled(), null);
  await env.clock.advance(1);
  await failsWith(p, 'invalid');
  assert.deepEqual(p.codes, []);
  assertEnded(env);
});

test('a wrong secret leaves message 2 unreadable, so pairing rejects invalid after 10 s', async () => {
  const env = await setup({ linkPatch: { secret: newRoom() } });
  const p = pair(env);
  await until(() => env.laptop.counts.pairings === 1, 'message 2 from the laptop');
  await until(() => env.net.inFrames().length === 1, 'message 2 at the phone');
  await quiet();
  await env.clock.advance(HANDSHAKE_TIMEOUT_MS - 1);
  await quiet();
  assert.equal(p.settled(), null);
  await env.clock.advance(1);
  await failsWith(p, 'invalid');
  assert.deepEqual(p.codes, []);
  assert.equal(env.laptop.counts.hello, 0);
  assert.equal(env.laptop.devices.size, 0);
});

test('the laptop leaving after the code rejects invalid', async () => {
  const env = await setup({ offer: { decision: 'silent' } });
  const p = pair(env);
  await until(() => env.laptop.counts.hello === 1, 'hello at the laptop');
  env.laptop.leave(env.offer.room);
  await failsWith(p, 'invalid');
  assert.equal(p.codes.length, 1);
  assertEnded(env);
});

test('peer-absent rejects offline; a refused socket rejects relayUnreachable', async () => {
  const absent = await setup();
  absent.laptop.leave(absent.offer.room);
  const p = pair(absent);
  await failsWith(p, 'offline');
  assert.ok(absent.net.gotText('peer-absent'));
  assert.deepEqual(absent.net.out(), [], 'no message 1 without a laptop');
  assertEnded(absent);

  const refused = await setup();
  const net = instrument(fakeSocketFactory(refused.relay, { origin: 'https://relay.acme.test' }));
  const q = pair({ ...refused, net });
  await failsWith(q, 'relayUnreachable');
  assert.equal(refused.joins(), 0);
  assert.equal(refused.clock.pending, 0);
});

test('peer-left before message 2 rejects offline', async () => {
  const env = await manualSetup();
  const laptop = laptopSocket(env);
  const p = pair(env);
  await until(() => laptop.frames.length === 1, 'message 1');
  laptop.handle.close(1000);
  await failsWith(p, 'offline');
  assertEnded(env);
});

test('no signal within 10 s rejects offline; a socket that never opens rejects relayUnreachable', async () => {
  const env = await setup();
  env.relay.blackHole(env.offer.room, true);
  const p = pair(env);
  await until(() => env.net.log.some((e) => e.dir === 'open'), 'the open socket');
  await env.clock.advance(SIGNAL_TIMEOUT_MS - 1);
  await quiet();
  assert.equal(p.settled(), null);
  await env.clock.advance(1);
  await failsWith(p, 'offline');
  assert.equal(env.clock.pending, 0);

  const second = await setup();
  const hanging = hangingSockets();
  const q = pair(second, { openSocket: hanging.factory });
  await until(() => hanging.sockets.length === 1, 'the socket');
  await second.clock.advance(SIGNAL_TIMEOUT_MS - 1);
  await quiet();
  assert.equal(q.settled(), null);
  await second.clock.advance(1);
  await failsWith(q, 'relayUnreachable');
  assert.deepEqual(hanging.sockets[0].closes, [1000]);
  assert.equal(second.clock.pending, 0);
});

// --- the pairing socket ---------------------------------------------------------------------

test('another phone socket taking the pairing room rejects invalid, before message 2 and after the code', async () => {
  /**
   * A second phone socket joins the pairing room: someone else who saw the QR code, or a
   * second tab. The relay closes the first one with 4000.
   * @param {{ relay: any, offer: any }} env
   */
  const otherPhone = (env) => env.relay.connect(`/v1/rooms/${env.offer.room}?role=phone`, { binary: () => {}, text: () => {}, close: () => {} });
  /** @param {{ relay: any, offer: any }} env */
  const phoneJoins = (env) => env.relay.stats.phoneJoins.get(env.offer.room) ?? 0;

  // Before any signal, and once message 1 is out: before message 2 either way.
  for (const when of ['before any signal', 'after message 1']) {
    const env = await manualSetup();
    const laptop = laptopSocket(env);
    env.net.hooks.holdText = when === 'before any signal';
    const p = pair(env);
    if (when === 'before any signal') {
      await until(() => env.net.held.length === 1, 'the held peer-joined');
    } else {
      await until(() => laptop.frames.length === 1, 'message 1');
    }
    otherPhone(env);
    await failsWith(p, 'invalid');
    assert.deepEqual(p.codes, [], when);
    assertEnded(env);
    await quiet();
    assert.equal(env.net.sockets.length, 1, `${when}: no new socket`);
    assert.equal(phoneJoins(env), 2, `${when}: the other socket stays`);
  }

  // After the code, while waiting for Allow.
  const env = await setup({ offer: { decision: 'silent' } });
  const p = pair(env);
  await until(() => env.laptop.counts.hello === 1, 'hello at the laptop');
  otherPhone(env);
  await failsWith(p, 'invalid');
  assert.equal(p.codes.length, 1);
  assertEnded(env);
  await quiet();
  assert.equal(env.net.sockets.length, 1, 'no new socket');
  assert.equal(phoneJoins(env), 2, 'the other socket stays');
});

test('before message 2, the relay closing the socket or a dead socket rejects relayUnreachable', async () => {
  // The relay drops the open socket with an ordinary close code.
  for (const when of ['before any signal', 'after message 1']) {
    const env = await manualSetup();
    const laptop = laptopSocket(env);
    env.net.hooks.holdText = when === 'before any signal';
    const p = pair(env);
    if (when === 'before any signal') {
      await until(() => env.net.held.length === 1, 'the held peer-joined');
    } else {
      await until(() => laptop.frames.length === 1, 'message 1');
    }
    relayCloses(env.net.sockets[0], 1011);
    await failsWith(p, 'relayUnreachable');
    assert.deepEqual(p.codes, [], when);
    assertEnded(env);
  }

  // A liveness probe whose pong never comes, once message 1 is out.
  const env = await manualSetup();
  const laptop = laptopSocket(env);
  const p = pair(env);
  await until(() => laptop.frames.length === 1, 'message 1');
  env.relay.blackHole(env.offer.room, true);
  p.run.probe();
  await env.clock.advance(RESUME_PONG_TIMEOUT_MS - 1);
  await quiet();
  assert.equal(p.settled(), null);
  await env.clock.advance(1);
  await failsWith(p, 'relayUnreachable');
  assert.deepEqual(p.codes, []);
  assertEnded(env);
});

test('probe() checks the socket: a pong keeps pairing going, and a dead socket after the code rejects invalid', async () => {
  const env = await setup({ offer: { decision: 'silent' } });
  const pings = () => env.relay.stats.pings.get(env.offer.room) ?? 0;
  const p = pair(env);
  p.run.probe(); // the key is still being made: no socket yet
  await until(() => env.laptop.counts.hello === 1, 'hello at the laptop');
  assert.equal(pings(), 0);

  p.run.probe();
  await until(() => pings() === 1, 'the probe ping');
  await quiet();
  await env.clock.advance(RESUME_PONG_TIMEOUT_MS);
  await quiet();
  assert.equal(p.settled(), null, 'the pong came: still waiting for Allow');

  env.relay.blackHole(env.offer.room, true);
  p.run.probe();
  await env.clock.advance(RESUME_PONG_TIMEOUT_MS - 1);
  await quiet();
  assert.equal(p.settled(), null);
  await env.clock.advance(1);
  await failsWith(p, 'invalid');
  assert.equal(p.codes.length, 1);
  assertEnded(env);

  env.relay.blackHole(env.offer.room, false);
  p.run.probe(); // after the outcome: nothing
  await quiet();
  assert.equal(pings(), 1);
});

// --- cancel ---------------------------------------------------------------------------------

test('cancel closes the socket and rejects cancelled', async () => {
  const env = await setup({ offer: { decision: 'silent' } });
  const p = pair(env);
  await until(() => env.laptop.counts.hello === 1, 'hello at the laptop');
  p.run.cancel();
  await failsWith(p, 'cancelled');
  assertEnded(env);
  p.run.cancel();
  await env.clock.advance(1_000_000);
  await quiet();
  assert.deepEqual(env.net.closeCalls(), [1000], 'a second cancel does nothing');
  assert.equal(p.codes.length, 1);

  // Cancelled while the key is being made: no socket ever opens.
  const early = await setup();
  const q = pair(early);
  q.run.cancel();
  await failsWith(q, 'cancelled');
  await quiet();
  assert.equal(early.net.sockets.length, 0);
  assert.equal(early.clock.pending, 0);
});

test('cancel as message 2 arrives shows no code and sends no hello', async () => {
  const env = await manualSetup();
  const laptop = laptopSocket(env);
  const p = pair(env);
  env.net.hooks.afterMessage = (ev) => {
    if (typeof ev.data === 'string') return;
    env.net.hooks.afterMessage = null;
    p.run.cancel();
  };
  await laptop.answer();
  await failsWith(p, 'cancelled');
  await quiet();
  assert.deepEqual(p.codes, []);
  assert.equal(env.net.out().length, 1, 'message 1 only');
  assertEnded(env);
});

test('cancel while message 2 is being decrypted shows no code and sends no hello', async () => {
  const env = await manualSetup();
  const laptop = laptopSocket(env);
  const p = pair(env);
  const subtle = globalThis.crypto.subtle;
  /** @type {Array<() => void>} */
  const held = [];
  // Once message 2 reaches the phone, its next AES-GCM decrypt (message 2's payload) waits
  // for the test: nothing else decrypts meanwhile, since the laptop waits for hello.
  env.net.hooks.afterMessage = (ev) => {
    if (typeof ev.data === 'string') return;
    env.net.hooks.afterMessage = null;
    Object.defineProperty(subtle, 'decrypt', {
      configurable: true,
      writable: true,
      value: (/** @type {any[]} */ ...args) => {
        delete (/** @type {any} */ (subtle)).decrypt;
        return new Promise((resolve) => held.push(resolve)).then(() => subtle.decrypt(.../** @type {[any, any, any]} */ (args)));
      },
    });
  };
  try {
    await laptop.answer();
    await until(() => held.length === 1, 'the phone decrypting message 2');
    p.run.cancel();
    held[0]();
    await failsWith(p, 'cancelled');
    await quiet();
  } finally {
    delete (/** @type {any} */ (subtle)).decrypt;
  }
  assert.deepEqual(p.codes, []);
  assert.equal(env.net.out().length, 1, 'message 1 only');
  assertEnded(env);
});

test('cancel after an outcome does nothing', async () => {
  const env = await setup();
  const p = pair(env);
  const result = await succeeds(p);
  p.run.cancel();
  assert.equal(await p.run.result, result);
  assert.deepEqual(env.net.closeCalls(), [1000]);
});

// --- stale frames and ordering --------------------------------------------------------------

test('a junk frame before message 2 is dropped and pairing still succeeds', async () => {
  const env = await setup();
  env.laptop.sendJunkBeforeMessage2(true);
  const p = pair(env);
  const result = await succeeds(p);
  assert.deepEqual(env.net.inFrames().slice(0, 2).map((frame) => frame.length), [20, 64], 'a short frame and a 64-byte one came first');
  assert.deepEqual(p.codes, [env.laptop.lastCode]);
  assert.ok(env.laptop.devices.has(result.room));
});

test('a second peer-joined before message 2 restarts the handshake with a fresh message 1', async () => {
  const env = await manualSetup();
  const first = laptopSocket(env);
  const p = pair(env);
  const message1 = await first.next();
  // The laptop's socket is replaced (4000, no peer-left); the phone gets peer-joined.
  const second = laptopSocket(env);
  const answered = await second.answer();
  await until(() => p.codes.length === 1, 'the code');
  assert.equal(p.codes[0], answered.code);
  assert.deepEqual(await answered.read1(), HELLO);
  const message1s = env.net.out().slice(0, 2);
  assert.deepEqual(message1s[0], message1);
  assert.notDeepEqual(message1s[1].slice(0, 32), message1s[0].slice(0, 32), 'a fresh ephemeral key');
  const room = newRoom();
  await answered.send({ type: 'paired', room });
  assert.equal((await succeeds(p)).room, room);
});

test('a message 2 answering an earlier message 1, arriving after a restart, is dropped and the real one wins', async () => {
  const env = await manualSetup();
  const first = laptopSocket(env);
  const p = pair(env);
  // The first laptop socket answers message 1, but its message 2 has not reached the phone.
  const old = await createResponder({ pattern: 'IKpsk2', localStatic: env.laptopPair, psk: env.secret, prologue: env.prologue });
  await old.readMessage1(await first.next());
  const stale = await old.writeMessage2(encode({ laptopName: 'acme-stale' }));
  const staleCode = await confirmationCode(stale.handshakeHash);

  // The laptop's socket is replaced; the phone restarts with a fresh message 1.
  const second = laptopSocket(env);
  await until(() => second.frames.length === 1, 'the fresh message 1');
  // Only now does the relay hand the phone the old message 2: well-formed, for the old one.
  second.handle.send(stale.message);
  await until(() => env.net.inFrames().length === 1, 'the old message 2 at the phone');
  await quiet();
  assert.deepEqual(p.codes, [], 'no code from the old message 2');
  assert.equal(p.settled(), null);

  const answered = await second.answer();
  await until(() => p.codes.length === 1, 'the code');
  assert.deepEqual(p.codes, [answered.code]);
  assert.notEqual(answered.code, staleCode);
  assert.deepEqual(await answered.read1(), HELLO, 'hello is for the new handshake');
  const room = newRoom();
  await answered.send({ type: 'paired', room });
  const result = await succeeds(p);
  assert.equal(result.room, room);
  assert.equal(result.laptopName, 'acme-mbp');
  assertEnded(env);
});

test('a peer-left right behind the paired frame does not win', async () => {
  // The scripted laptop leaves right after paired, so peer-left always follows it.
  const env = await setup();
  assert.ok((await succeeds(pair(env))).room);

  // Here the relay delivers peer-left in the same task as the paired frame, while that frame
  // is still being decrypted.
  const same = await setup();
  let frames = 0;
  same.net.hooks.afterMessage = (ev, deliver) => {
    if (typeof ev.data === 'string') return;
    frames += 1;
    if (frames !== 2) return; // message 2, then paired
    same.net.hooks.afterMessage = null;
    deliver({ type: 'message', data: 'peer-left' });
  };
  const result = await succeeds(pair(same));
  assert.ok(same.laptop.devices.has(result.room));
  assert.ok(same.net.gotText('peer-left'));
});

// --- a laptop that breaks the protocol ------------------------------------------------------

test('a malformed paired room rejects invalid', async () => {
  for (const pairedRoom of ['not-a-room', `${'A'.repeat(42)}B`, `${'A'.repeat(42)}+`, `${newRoom()}A`]) {
    const env = await setup({ offer: { pairedRoom } });
    const error = await failsWith(pair(env), 'invalid');
    assert.ok(error.cause instanceof ProtocolError, `${pairedRoom}: ${error.cause}`);
    assert.equal(/** @type {ProtocolError} */ (error.cause).reason, 'paired.room');
    assertEnded(env);
  }
});

test('a paired room equal to the pairing room rejects invalid', async () => {
  const env = await manualSetup();
  const laptop = laptopSocket(env);
  const p = pair(env);
  const answered = await laptop.answer();
  assert.deepEqual(await answered.read1(), HELLO);
  await answered.send({ type: 'paired', room: env.offer.room });
  const error = await failsWith(p, 'invalid');
  assert.ok(error.cause instanceof ProtocolError);
  assertEnded(env);
});

test('a message 2 payload that is not {"laptopName": <string>} rejects invalid', async () => {
  for (const payload of ['not json', '[]', 'null', {}, { laptopName: 5 }, { laptopName: null }, { name: 'acme-mbp' }]) {
    const env = await manualSetup();
    const laptop = laptopSocket(env);
    const p = pair(env);
    await laptop.answer(payload);
    const error = await failsWith(p, 'invalid');
    assert.ok(error.cause instanceof ProtocolError, `${JSON.stringify(payload)}: ${error.cause}`);
    assert.deepEqual(p.codes, [], 'no code for a bad message 2');
    assert.equal(env.net.out().length, 1, 'no hello');
    assertEnded(env);
  }
});

test('after message 2, laptop messages other than paired and pairDenied are ignored', async () => {
  const env = await manualSetup();
  const laptop = laptopSocket(env);
  const p = pair(env);
  const answered = await laptop.answer();
  assert.deepEqual(await answered.read1(), HELLO);
  await answered.send({
    type: 'welcome', protocol: 1, minProtocol: 1, tbdVersion: '0.0.0-test', bundle: { sha256: '0'.repeat(64), size: 1 },
  });
  await answered.send({ type: 'app', body: { kind: 'event' } });
  await answered.send({ type: 'revoked' });
  await answered.send({ type: 'from-a-newer-laptop', extra: true });
  await quiet();
  assert.equal(p.settled(), null);
  const room = newRoom();
  await answered.send({ type: 'paired', room });
  const result = await succeeds(p);
  assert.equal(result.room, room);
  assert.equal(result.laptopName, 'acme-mbp');
  assert.equal(env.net.out().length, 2, 'message 1 and hello only');
  assertEnded(env);
});

test('after message 2, a frame that fails to decrypt, a protocol error or a new laptop socket rejects invalid', async () => {
  /** @type {Array<[string, (answered: any, env: any) => Promise<unknown>, (cause: unknown) => boolean]>} */
  const cases = [
    ['a 64-byte junk frame', async (_answered, env) => env.socket.handle.send(new Uint8Array(randomBytes(64))),
      (cause) => cause instanceof NoiseError],
    ['a 20-byte junk frame', async (_answered, env) => env.socket.handle.send(new Uint8Array(randomBytes(20))),
      (cause) => cause instanceof NoiseError],
    ['text that is not JSON', (answered) => answered.send('not json'), (cause) => cause instanceof ProtocolError],
    ['a malformed welcome', (answered) => answered.send({ type: 'welcome' }), (cause) => cause instanceof ProtocolError],
    ['a pairDenied with an unknown reason', (answered) => answered.send({ type: 'pairDenied', reason: 'bored' }),
      (cause) => cause instanceof ProtocolError],
    ['a new laptop socket', async (_answered, env) => laptopSocket(env), (cause) => cause === undefined],
  ];
  for (const [name, act, causeOK] of cases) {
    const env = await manualSetup();
    const socket = laptopSocket(env);
    const p = pair(env);
    const answered = await socket.answer();
    assert.deepEqual(await answered.read1(), HELLO);
    await act(answered, { ...env, socket });
    const error = await failsWith(p, 'invalid');
    assert.ok(causeOK(error.cause), `${name}: ${error.cause}`);
    assertEnded(env);
  }
});

// --- the device link after pairing ----------------------------------------------------------

test('after allow, a LaptopConnection built from the wrapped result, with absentGraceMs, completes IK and welcome without reporting offline', async () => {
  for (const order of ['laptop first', 'phone first']) {
    const env = await setup({ offer: { deviceJoin: order === 'laptop first' ? 'immediate' : 'manual' } });
    const result = await succeeds(pair(env));
    const laptopJoins = () => env.relay.stats.laptopJoins.get(result.room) ?? 0;
    if (order === 'laptop first') {
      await until(() => laptopJoins() === 1, 'the laptop in the new room');
    } else {
      assert.equal(laptopJoins(), 0);
    }

    const record = validateLaptopRecord({
      id: env.offer.key,
      relay: env.offer.relay,
      room: result.room,
      laptopKey: b64(env.offer.key),
      laptopName: result.laptopName,
      phoneName: 'iPhone',
      phoneKey: result.publicRaw,
      wrapKey: result.wrapKey,
      wrappedKey: result.wrappedKey,
      wrapIV: result.wrapIV,
      pairedAt: env.clock.now(),
      lastConnectedAt: null,
    });
    const keyPair = await unwrapPhoneKeyPair(crypto.subtle, result.wrapKey, record);
    const net = instrument(fakeSocketFactory(env.relay, { origin: env.laptop.relayOrigin }));
    /** @type {any[]} */
    const events = [];
    const conn = new LaptopConnection({
      record,
      keyPair,
      cache: { get: async () => undefined, put: async () => true, markUsed: async () => undefined },
      openSocket: net.factory,
      onEvent: (event) => events.push(event),
      absentGraceMs: SIGNAL_TIMEOUT_MS,
      random: () => 0,
      clock: env.clock,
    });
    const states = () => events.filter((e) => e.kind === 'state').map((e) => e.state);
    conn.start();
    if (order === 'phone first') {
      await until(() => net.gotText('peer-absent'), 'peer-absent on the new room');
      await quiet();
      assert.deepEqual(states(), ['connecting']);
      env.laptop.join(result.room);
    }
    await until(() => states().includes('ready'), `ready (${order})`);
    assert.deepEqual(states(), ['connecting', 'handshaking', 'loading', 'ready'], order);
    assert.deepEqual(events.filter((e) => e.kind === 'connected'), [{ kind: 'connected', laptopName: 'acme-mbp' }]);
    assert.equal(events.filter((e) => e.kind === 'bundle').length, 1);
    assert.equal(env.laptop.counts.ikHandshakes, 1);
    assert.ok(env.laptop.log.some((e) => e.room === result.room && e.type === 'bundle.get'), 'welcome named the bundle');
    assert.ok(net.gotText(order === 'laptop first' ? 'peer-joined' : 'peer-absent'));
    conn.stop();

    // The pairing room is closed for good.
    /** @type {string[]} */
    const texts = [];
    const old = fakeSocketFactory(env.relay, { origin: env.laptop.relayOrigin })(relaySocketURL(env.offer.relay, env.offer.room));
    old.onmessage = (/** @type {any} */ ev) => texts.push(ev.data);
    await until(() => texts.length > 0, 'a signal on the old pairing room');
    assert.deepEqual(texts, ['peer-absent']);
    old.close(1000);
    assert.deepEqual(env.laptop.errors, []);
  }
});
