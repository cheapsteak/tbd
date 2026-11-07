import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import { deflateRawSync, inflateRawSync } from 'node:zlib';

import { createInitiator, phonePrologue } from '../../channel/noise.js';
import { confirmationCode } from '../../channel/confirm.js';
import { base64urlDecode, base64urlEncode } from '../../channel/pairingLink.js';
import { MAX_CHUNK_BYTES } from '../../constants.js';
import { createFakeRelay } from './fake-relay.js';
import { fakeSocketFactory } from './fake-websocket.js';
import { createScriptedLaptop } from './scripted-laptop.js';
import { importPair } from './x25519.js';

const ROOM_ID = /^[A-Za-z0-9_-]{43}$/;
const HELLO = { type: 'hello', loaderVersion: '1.0.0', protocols: [1] };
const WAIT_MS = 5_000;

/** @param {unknown} value */
const encode = (value) => new TextEncoder().encode(JSON.stringify(value));
/** @param {Uint8Array} bytes */
const decode = (bytes) => JSON.parse(new TextDecoder().decode(bytes));
/** @param {string} text */
const b64 = (text) => /** @type {Uint8Array} */ (base64urlDecode(text));
/** @param {Uint8Array | string} data */
const sha256Hex = (data) => createHash('sha256').update(data).digest('hex');
const sleep = (/** @type {number} */ ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * @param {() => boolean} predicate
 * @param {string} what
 */
async function until(predicate, what) {
  const deadline = Date.now() + WAIT_MS;
  while (!predicate()) {
    if (Date.now() > deadline) assert.fail(`timed out waiting for ${what}`);
    await sleep(1);
  }
}

/** An X25519 key pair made as the loader makes it: private half not extractable. */
async function phoneKeys() {
  const pair = /** @type {CryptoKeyPair} */ (await crypto.subtle.generateKey({ name: 'X25519' }, false, ['deriveBits']));
  return { pair, raw: new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey)) };
}

/**
 * The phone's URL for a room, built as the loader builds it from the link's `relay`.
 * @param {string} origin
 * @param {string} room
 */
function roomUrl(origin, room) {
  const url = new URL(`/v1/rooms/${room}?role=phone`, origin);
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  return url.href;
}

/**
 * A phone's socket in one room, through a fake socket pinned to the laptop's relay origin.
 * Events queue in arrival order.
 * @param {{ relay: ReturnType<typeof createFakeRelay>, laptop: { relayOrigin: string } }} env
 * @param {string} room
 * @param {string} [url]
 */
function phoneSocket({ relay, laptop }, room, url = roomUrl(laptop.relayOrigin, room)) {
  const ws = fakeSocketFactory(relay, { origin: laptop.relayOrigin })(url);
  ws.binaryType = 'arraybuffer';
  /** @type {Array<{ kind: string, name?: string, bytes?: Uint8Array, code?: number }>} */
  const queue = [];
  ws.onopen = () => queue.push({ kind: 'open' });
  ws.onmessage = (ev) => queue.push(typeof ev.data === 'string'
    ? { kind: 'signal', name: ev.data }
    : { kind: 'frame', bytes: new Uint8Array(ev.data) });
  ws.onclose = (ev) => queue.push({ kind: 'closed', code: ev.code });
  const phone = {
    ws,
    queue,
    async next() {
      await until(() => queue.length > 0, `an event in room ${room}`);
      return /** @type {(typeof queue)[number]} */ (queue.shift());
    },
    /** @param {string} name */
    async signal(name) {
      assert.deepEqual(await phone.next(), { kind: 'signal', name });
    },
    async frame() {
      const event = await phone.next();
      assert.equal(event.kind, 'frame', `expected a frame, got ${JSON.stringify(event)}`);
      return /** @type {Uint8Array} */ (event.bytes);
    },
    /** @param {Uint8Array} bytes */
    send(bytes) {
      ws.send(bytes);
    },
    /** Lets in-flight work land, then asserts that nothing arrived. */
    async quiet() {
      await sleep(30);
      assert.deepEqual(queue, []);
    },
  };
  return phone;
}

/**
 * A fresh IKpsk2 initiator for an offer, with the offer's secret unless told otherwise.
 * @param {{ pair: CryptoKeyPair }} keys
 * @param {{ key: string, secret: string, room: string }} offer
 * @param {Uint8Array} [psk]
 */
function offerInitiator(keys, offer, psk = b64(offer.secret)) {
  return createInitiator({
    pattern: 'IKpsk2', localStatic: keys.pair, remoteStatic: b64(offer.key), psk, prologue: phonePrologue(b64(offer.room)),
  });
}

/**
 * Sends message 1 and `hello` on a pairing socket and returns the laptop's answer.
 * @param {ReturnType<typeof phoneSocket>} phone
 * @param {{ pair: CryptoKeyPair }} keys
 * @param {{ key: string, secret: string, room: string }} offer
 */
async function pairOn(phone, keys, offer) {
  const initiator = await offerInitiator(keys, offer);
  phone.send(await initiator.writeMessage1(encode({ deviceName: 'iPhone' })));
  const result = await initiator.readMessage2(await phone.frame());
  phone.send(await result.transport.encrypt(encode(HELLO)));
  return { result, answer: decode(await result.transport.decrypt(await phone.frame())) };
}

/** @param {object} [options] */
async function setup(options = {}) {
  const relay = createFakeRelay();
  const laptop = await createScriptedLaptop({ relay, ...options });
  return { relay, laptop };
}

/**
 * Runs the pairing handshake and sends `hello`, as plan 3's order has the phone do.
 * @param {{ relay: any, laptop: any }} env
 * @param {{ decision?: any, deviceName?: string, pairedRoom?: string, deviceJoin?: any, hello?: boolean }} [options]
 */
async function pairUntilDecision(env, { decision = 'allow', deviceName = 'iPhone', pairedRoom, deviceJoin, hello = true } = {}) {
  const keys = await phoneKeys();
  const offer = env.laptop.makeOffer({ decision, pairedRoom, deviceJoin });
  const phone = phoneSocket(env, offer.room);
  assert.deepEqual(await phone.next(), { kind: 'open' });
  await phone.signal('peer-joined');
  const initiator = await offerInitiator(keys, offer);
  phone.send(await initiator.writeMessage1(encode({ deviceName })));
  const result = await initiator.readMessage2(await phone.frame());
  if (hello) phone.send(await result.transport.encrypt(encode(HELLO)));
  return { keys, offer, phone, result, transport: result.transport };
}

/**
 * Pairs with `allow` and returns the device room from `paired`.
 * @param {{ relay: any, laptop: any }} env
 * @param {{ deviceJoin?: any }} [options]
 */
async function pairDevice(env, options = {}) {
  const pairing = await pairUntilDecision(env, options);
  const paired = decode(await pairing.transport.decrypt(await pairing.phone.frame()));
  await pairing.phone.signal('peer-left');
  return { ...pairing, room: paired.room };
}

/**
 * Connects to a device room with IK and sends `hello` unless told not to.
 * @param {{ relay: any, laptop: any }} env
 * @param {string} room
 * @param {{ pair: CryptoKeyPair }} keys
 * @param {{ hello?: boolean }} [options]
 */
async function connect(env, room, keys, { hello = true } = {}) {
  const { laptop } = env;
  const phone = phoneSocket(env, room);
  assert.deepEqual(await phone.next(), { kind: 'open' });
  await phone.signal('peer-joined');
  const initiator = await createInitiator({
    pattern: 'IK', localStatic: keys.pair, remoteStatic: laptop.publicKey, psk: null, prologue: phonePrologue(b64(room)),
  });
  phone.send(await initiator.writeMessage1(encode({})));
  const result = await initiator.readMessage2(await phone.frame());
  const transport = result.transport;
  const read = async () => decode(await transport.decrypt(await phone.frame()));
  /** @param {object} message */
  const send = async (message) => phone.send(await transport.encrypt(encode(message)));
  let welcome = null;
  if (hello) {
    await send(HELLO);
    welcome = await read();
  }
  return { phone, result, transport, read, send, welcome };
}

// --- pairing --------------------------------------------------------------------------------

test('an IKpsk2 pairing with allow sends paired with a new room, and the codes match', async () => {
  const env = await setup();
  const { relay, laptop } = env;
  const { offer, phone, result, transport, keys } = await pairUntilDecision(env, { deviceName: '  iPhone \n' });
  assert.equal(offer.v, 1);
  assert.equal(offer.relay, 'http://127.0.0.1');
  assert.equal(offer.name, 'acme-mbp');
  assert.deepEqual(b64(offer.key), laptop.publicKey);
  assert.ok(Math.abs(offer.exp - (Date.now() / 1000 + 300)) < 5);
  assert.deepEqual(decode(result.payload), { laptopName: 'acme-mbp' });
  assert.equal(laptop.lastCode, await confirmationCode(result.handshakeHash));

  const paired = decode(await transport.decrypt(await phone.frame()));
  assert.equal(paired.type, 'paired');
  assert.match(paired.room, ROOM_ID);
  assert.equal(b64(paired.room).length, 32);
  assert.notEqual(paired.room, offer.room);
  await phone.signal('peer-left');
  await phone.quiet();

  assert.equal(laptop.counts.hello, 1);
  assert.equal(laptop.counts.pairings, 1);
  assert.equal(laptop.counts.handshakes, 1);
  assert.deepEqual([...laptop.devices.keys()], [paired.room]);
  assert.deepEqual(laptop.devices.get(paired.room), { phoneKey: keys.raw, deviceName: 'iPhone' });
  assert.deepEqual(laptop.log, [{ room: offer.room, type: 'hello', message: HELLO }], 'logged in full');

  assert.deepEqual(relay.presence(`/v1/rooms/${offer.room}/presence`).body, { laptop: false });
  assert.deepEqual(relay.presence(`/v1/rooms/${paired.room}/presence`).body, { laptop: true });
  const oldRoom = phoneSocket(env, offer.room);
  assert.deepEqual(await oldRoom.next(), { kind: 'open' });
  await oldRoom.signal('peer-absent');
  const newRoom = phoneSocket(env, paired.room);
  assert.deepEqual(await newRoom.next(), { kind: 'open' });
  await newRoom.signal('peer-joined');
  assert.deepEqual(laptop.errors, []);
});

test('the laptop waits for the first transport message before it acts on the decision', async () => {
  const env = await setup();
  const { phone, transport } = await pairUntilDecision(env, { hello: false });
  await phone.quiet();
  assert.equal(env.laptop.counts.hello, 0);
  assert.equal(env.laptop.devices.size, 0);
  phone.send(await transport.encrypt(encode(HELLO)));
  assert.equal(decode(await transport.decrypt(await phone.frame())).type, 'paired');
  assert.equal(env.laptop.counts.hello, 1);
});

test('deny and expire send pairDenied and leave; silent sends nothing and stays', async () => {
  for (const [decision, reason] of [['deny', 'denied'], ['expire', 'expired']]) {
    const env = await setup();
    const { phone, transport, offer } = await pairUntilDecision(env, { decision });
    assert.deepEqual(decode(await transport.decrypt(await phone.frame())), { type: 'pairDenied', reason });
    await phone.signal('peer-left');
    assert.equal(env.laptop.devices.size, 0);
    assert.deepEqual(env.relay.presence(`/v1/rooms/${offer.room}/presence`).body, { laptop: false });
  }
  const env = await setup();
  const { phone, offer } = await pairUntilDecision(env, { decision: 'silent' });
  await until(() => env.laptop.counts.hello === 1, 'hello');
  await phone.quiet();
  assert.deepEqual(env.relay.presence(`/v1/rooms/${offer.room}/presence`).body, { laptop: true });
  phone.ws.close(1000);
  await until(() => env.relay.presence(`/v1/rooms/${offer.room}/presence`).body?.laptop === false, 'the laptop to leave');
  assert.equal(env.laptop.devices.size, 0);
});

test('a first transport message that fails to decrypt sends the offer back to waiting', async () => {
  const env = await setup();
  const { phone, offer, keys } = await pairUntilDecision(env, { hello: false });
  phone.send(new Uint8Array(randomBytes(40)));
  await until(() => env.laptop.counts.refused === 1, 'the refusal');
  // The laptop stays in the room, and never reads the failed frame as a message 1.
  await phone.quiet();
  assert.equal(env.laptop.counts.refused, 1);
  assert.equal(env.laptop.counts.hello, 0);
  assert.equal(env.laptop.devices.size, 0);
  assert.deepEqual(env.relay.presence(`/v1/rooms/${offer.room}/presence`).body, { laptop: true });
  // A new message 1 on the same room pairs, and only that hello spends the offer.
  const { result, answer } = await pairOn(phone, keys, offer);
  assert.equal(answer.type, 'paired');
  assert.equal(env.laptop.lastCode, await confirmationCode(result.handshakeHash));
  assert.equal(env.laptop.counts.pairings, 2);
  assert.equal(env.laptop.counts.hello, 1);
  assert.deepEqual([...env.laptop.devices.keys()], [answer.room]);
  assert.deepEqual(env.laptop.errors, []);
});

test('a phone that leaves or is replaced before its hello decrypts leaves the offer open', async () => {
  for (const how of ['replaced', 'left']) {
    const env = await setup();
    const { offer, phone: first, keys } = await pairUntilDecision(env, { hello: false });
    if (how === 'left') first.ws.close(1000);
    const next = phoneSocket(env, offer.room);
    assert.deepEqual(await next.next(), { kind: 'open' }, how);
    await next.signal('peer-joined');
    const { answer } = await pairOn(next, keys, offer);
    assert.equal(answer.type, 'paired', how);
    assert.equal(env.laptop.devices.size, 1, how);
  }
});

test('a bad device name gets no message 2 and the offer stays open', async () => {
  const env = await setup();
  const { laptop } = env;
  const offer = laptop.makeOffer({});
  const phone = phoneSocket(env, offer.room);
  assert.deepEqual(await phone.next(), { kind: 'open' });
  await phone.signal('peer-joined');
  const keys = await phoneKeys();
  const initiator = () => createInitiator({
    pattern: 'IKpsk2', localStatic: keys.pair, remoteStatic: b64(offer.key), psk: b64(offer.secret),
    prologue: phonePrologue(b64(offer.room)),
  });
  const bad = [
    { deviceName: 'a'.repeat(65) },
    { deviceName: '' },
    { deviceName: ' \t\n ' },
    { deviceName: 'line\nbreak' },
    { deviceName: 'a‮b' },
    { deviceName: 'zero​width' },
    { deviceName: 'bell\u0007' },
    { deviceName: 42 },
    { name: 'iPhone' },
    ['iPhone'],
  ];
  for (const [i, payload] of bad.entries()) {
    phone.send(await (await initiator()).writeMessage1(encode(payload)));
    await until(() => laptop.counts.refused === i + 1, `refusal ${i}`);
  }
  await phone.quiet();
  assert.equal(laptop.lastCode, null);

  // 64 characters, counted as Swift counts them, still pair on the same offer.
  const name = 'é'.repeat(63) + '😀';
  const last = await initiator();
  phone.send(await last.writeMessage1(encode({ deviceName: name })));
  const result = await last.readMessage2(await phone.frame());
  phone.send(await result.transport.encrypt(encode(HELLO)));
  const paired = decode(await result.transport.decrypt(await phone.frame()));
  assert.equal(laptop.devices.get(paired.room)?.deviceName, name);
});

test('a wrong secret still gets message 2, which the phone cannot read, and the offer stays open', async () => {
  // The PSK enters at message 2's psk token, so the laptop cannot tell at message 1.
  const env = await setup();
  const offer = env.laptop.makeOffer({});
  const phone = phoneSocket(env, offer.room);
  assert.deepEqual(await phone.next(), { kind: 'open' });
  await phone.signal('peer-joined');
  const keys = await phoneKeys();
  const wrong = await offerInitiator(keys, offer, new Uint8Array(32));
  phone.send(await wrong.writeMessage1(encode({ deviceName: 'iPhone' })));
  await assert.rejects(wrong.readMessage2(await phone.frame()), { code: 'decryptFailed' });
  phone.ws.close(1000);
  // The offer is not spent: the next phone finds the laptop still there and pairs.
  const next = phoneSocket(env, offer.room);
  assert.deepEqual(await next.next(), { kind: 'open' });
  await next.signal('peer-joined');
  const { answer } = await pairOn(next, keys, offer);
  assert.equal(answer.type, 'paired');
  assert.equal(env.laptop.counts.pairings, 2);
  assert.equal(env.laptop.devices.size, 1);
});

test('a phone socket reaches the laptop only at the relay origin its offer names', async () => {
  const env = await setup();
  const offer = env.laptop.makeOffer({});
  assert.equal(offer.relay, env.laptop.relayOrigin);
  const elsewhere = phoneSocket(env, offer.room, `wss://relay.acme.test/v1/rooms/${offer.room}?role=phone`);
  assert.deepEqual(await elsewhere.next(), { kind: 'closed', code: 1006 });
  assert.equal(env.relay.stats.phoneJoins.get(offer.room), undefined);

  const custom = await setup({ relayOrigin: 'https://relay.acme.test' });
  const customOffer = custom.laptop.makeOffer({});
  assert.equal(customOffer.relay, 'https://relay.acme.test');
  const phone = phoneSocket(custom, customOffer.room);
  assert.equal(phone.ws.url, `wss://relay.acme.test/v1/rooms/${customOffer.room}?role=phone`);
  assert.deepEqual(await phone.next(), { kind: 'open' });
  await phone.signal('peer-joined');
});

test('deviceJoin manual keeps the laptop out of the new room until join, so the phone can come first', async () => {
  const env = await setup();
  assert.throws(() => env.laptop.makeOffer({ deviceJoin: 'later' }), RangeError);
  const { room, keys } = await pairDevice(env, { deviceJoin: 'manual' });
  assert.ok(env.laptop.devices.has(room));
  assert.equal(env.relay.stats.laptopJoins.get(room), undefined);
  const phone = phoneSocket(env, room);
  assert.deepEqual(await phone.next(), { kind: 'open' });
  await phone.signal('peer-absent');
  env.laptop.join(room);
  await phone.signal('peer-joined');
  const initiator = await createInitiator({
    pattern: 'IK', localStatic: keys.pair, remoteStatic: env.laptop.publicKey, psk: null, prologue: phonePrologue(b64(room)),
  });
  phone.send(await initiator.writeMessage1(encode({})));
  await initiator.readMessage2(await phone.frame());
  assert.equal(env.laptop.counts.ikHandshakes, 1);
});

// --- device link ----------------------------------------------------------------------------

test('IK on the device room ignores the payload and welcome names the bundle', async () => {
  const bundleText = 'globalThis.acme = "é";\n'.repeat(10);
  const env = await setup({ bundleText });
  const { room, keys } = await pairDevice(env);
  const { welcome, result } = await connect(env, room, keys);
  assert.deepEqual(decode(result.payload), { laptopName: 'acme-mbp' });
  assert.deepEqual(welcome, {
    type: 'welcome',
    protocol: 1,
    minProtocol: 1,
    tbdVersion: '0.0.0-test',
    bundle: { sha256: sha256Hex(Buffer.from(bundleText, 'utf8')), size: deflateRawSync(Buffer.from(bundleText, 'utf8')).length },
  });
  assert.equal(env.laptop.counts.ikHandshakes, 1);
  assert.equal(env.laptop.counts.handshakes, 2);
  assert.equal(env.laptop.counts.hello, 2);
  assert.deepEqual(env.laptop.errors, []);
});

test('an IK handshake from an unknown key, or on the pairing room, gets no message 2', async () => {
  const env = await setup();
  const { room } = await pairDevice(env);
  const stranger = await phoneKeys();
  const phone = phoneSocket(env, room);
  assert.deepEqual(await phone.next(), { kind: 'open' });
  await phone.signal('peer-joined');
  const initiator = await createInitiator({
    pattern: 'IK', localStatic: stranger.pair, remoteStatic: env.laptop.publicKey, psk: null, prologue: phonePrologue(b64(room)),
  });
  phone.send(await initiator.writeMessage1(encode({})));
  await until(() => env.laptop.counts.refused === 1, 'the refusal');
  await phone.quiet();

  const offer = env.laptop.makeOffer({});
  const pairingPhone = phoneSocket(env, offer.room);
  assert.deepEqual(await pairingPhone.next(), { kind: 'open' });
  await pairingPhone.signal('peer-joined');
  const ik = await createInitiator({
    pattern: 'IK', localStatic: stranger.pair, remoteStatic: env.laptop.publicKey, psk: null, prologue: phonePrologue(b64(offer.room)),
  });
  pairingPhone.send(await ik.writeMessage1(encode({ deviceName: 'iPhone' })));
  await until(() => env.laptop.counts.refused === 2, 'the second refusal');
  await pairingPhone.quiet();
  assert.equal(env.laptop.counts.ikHandshakes, 0);
});

test('a forgotten device gets no answer, and a new phone socket resets the link', async () => {
  const env = await setup();
  const { room, keys } = await pairDevice(env);
  const first = await connect(env, room, keys, { hello: false });
  // A replacement socket gives the laptop peer-joined, so the next message 1 is a fresh handshake.
  const second = await connect(env, room, keys);
  assert.equal(second.welcome.type, 'welcome');
  assert.deepEqual(first.phone.queue.at(-1), { kind: 'closed', code: 4000 });
  env.laptop.devices.clear();
  const phone = phoneSocket(env, room);
  assert.deepEqual(await phone.next(), { kind: 'open' });
  await phone.signal('peer-joined');
  const initiator = await createInitiator({
    pattern: 'IK', localStatic: keys.pair, remoteStatic: env.laptop.publicKey, psk: null, prologue: phonePrologue(b64(room)),
  });
  phone.send(await initiator.writeMessage1(encode({})));
  await until(() => env.laptop.counts.refused === 1, 'the refusal');
  await phone.quiet();
});

test('bundle.get yields chunks of at most 45,000 bytes that sum to welcome.bundle.size', async () => {
  const bundleText = randomBytes(112_500).toString('base64');
  const env = await setup({ bundleText });
  /** @type {number[]} */
  const hooked = [];
  env.laptop.onChunk((/** @type {number} */ index) => { hooked.push(index); });
  const { room, keys } = await pairDevice(env);
  const { welcome, read, send } = await connect(env, room, keys);
  await send({ type: 'bundle.get', sha256: welcome.bundle.sha256 });
  const first = await read();
  assert.ok(first.count >= 3, `expected several chunks, got ${first.count}`);
  const chunks = [first];
  while (chunks.length < first.count) chunks.push(await read());
  const raw = chunks.map((chunk, index) => {
    assert.equal(chunk.type, 'bundle.chunk');
    assert.equal(chunk.index, index);
    assert.equal(chunk.count, first.count);
    assert.equal(chunk.sha256, welcome.bundle.sha256);
    const bytes = Buffer.from(chunk.data, 'base64');
    assert.equal(bytes.toString('base64'), chunk.data, 'standard base64');
    assert.ok(bytes.length <= MAX_CHUNK_BYTES);
    return bytes;
  });
  const compressed = Buffer.concat(raw);
  assert.equal(compressed.length, welcome.bundle.size);
  const text = inflateRawSync(compressed).toString('utf8');
  assert.equal(text, bundleText);
  assert.equal(sha256Hex(text), welcome.bundle.sha256);
  assert.deepEqual(hooked, chunks.map((_, i) => i));
  assert.equal(env.laptop.counts.bundleGet, 1);
});

test('onChunk returning stop sends nothing more', async () => {
  const env = await setup({ bundleText: randomBytes(112_500).toString('base64') });
  env.laptop.onChunk((/** @type {number} */ index) => (index === 1 ? 'stop' : undefined));
  const { room, keys } = await pairDevice(env);
  const { welcome, read, send, phone } = await connect(env, room, keys);
  await send({ type: 'bundle.get', sha256: welcome.bundle.sha256 });
  assert.equal((await read()).index, 0);
  await phone.quiet();
  env.laptop.onChunk(null);
  await send({ type: 'bundle.get', sha256: welcome.bundle.sha256 });
  assert.equal((await read()).index, 0);
  assert.equal((await read()).index, 1);
});

test('setBundle and setWelcome change later welcomes, and the named hash is the one served', async () => {
  const env = await setup();
  const { room, keys } = await pairDevice(env);
  env.laptop.setBundle('globalThis.second = 2;\n');
  env.laptop.setWelcome({ protocol: 2, tbdVersion: undefined, bundle: { sha256: 'f'.repeat(64) } });
  const { welcome, read, send } = await connect(env, room, keys);
  assert.deepEqual(welcome, {
    type: 'welcome',
    protocol: 2,
    minProtocol: 1,
    bundle: { sha256: 'f'.repeat(64), size: deflateRawSync(Buffer.from('globalThis.second = 2;\n')).length },
  });
  await send({ type: 'bundle.get', sha256: 'f'.repeat(64) });
  const chunk = await read();
  assert.equal(chunk.sha256, 'f'.repeat(64));
  assert.equal(inflateRawSync(Buffer.from(chunk.data, 'base64')).toString(), 'globalThis.second = 2;\n');
});

test('a broken channel makes the laptop leave and rejoin the device room', async () => {
  /** @param {object} message Sent after hello and welcome. */
  const afterWelcome = (message) => async (/** @type {Awaited<ReturnType<typeof connect>>} */ c) => {
    await c.send(HELLO);
    await c.read();
    await c.send(message);
  };
  /** @type {Array<[string, (c: Awaited<ReturnType<typeof connect>>) => Promise<void>, ((laptop: any) => void)?]>} */
  const cases = [
    ['a frame that fails to decrypt', async (c) => c.phone.send(new Uint8Array(randomBytes(40)))],
    ['a first message other than hello', async (c) => c.send({ type: 'bundle.get', sha256: 'a'.repeat(64) })],
    ['a message whose type is not a string', afterWelcome({ type: 5 })],
    ['bundle.get for another hash', afterWelcome({ type: 'bundle.get', sha256: 'a'.repeat(64) })],
    ['bundle.get whose sha256 is not a string, even one welcome named',
      afterWelcome({ type: 'bundle.get', sha256: 5 }), (laptop) => laptop.setWelcome({ bundle: { sha256: 5 } })],
    ['an app message with no body', afterWelcome({ type: 'app' })],
    ...[[1], null, 'x', 5].map((body) => /** @type {[string, any]} */ ([`an app body of ${JSON.stringify(body)}`, afterWelcome({ type: 'app', body })])),
  ];
  for (const [what, breakIt, prepare] of cases) {
    const env = await setup();
    const { room, keys } = await pairDevice(env);
    prepare?.(env.laptop);
    const c = await connect(env, room, keys, { hello: false });
    await breakIt(c);
    await c.phone.signal('peer-left');
    await c.phone.signal('peer-joined');
    assert.equal(env.laptop.counts.rejoins, 1, what);
    // The laptop never reads a transport frame as a new message 1.
    assert.equal(env.laptop.counts.refused, 0, what);
    const again = await connect(env, room, keys);
    assert.equal(again.welcome.type, 'welcome', what);
    assert.deepEqual(env.laptop.appBodies, [], what);
    assert.deepEqual(env.laptop.errors, [], what);
  }
});

test('incompatible answers hello, then the laptop leaves and rejoins', async () => {
  for (const tooOld of ['laptop', 'loader']) {
    const env = await setup();
    env.laptop.setIncompatible(tooOld);
    const { room, keys } = await pairDevice(env);
    const c = await connect(env, room, keys);
    assert.deepEqual(c.welcome, { type: 'incompatible', tooOld });
    await c.phone.signal('peer-left');
    await c.phone.signal('peer-joined');
    env.laptop.setIncompatible(null);
    assert.equal((await connect(env, room, keys)).welcome.type, 'welcome');
  }
});

test('a hello whose protocols is not a list of integers ends the channel', async () => {
  const env = await setup();
  const { room, keys } = await pairDevice(env);
  const bad = [undefined, 1, '1', { 0: 1 }, null, [true], [1.5], ['1'], [1, null], [1e300]]
    .map((protocols) => ({ type: 'hello', loaderVersion: '1.0.0', protocols }));
  for (const [i, hello] of bad.entries()) {
    const c = await connect(env, room, keys, { hello: false });
    await c.send(hello);
    await c.phone.signal('peer-left');
    await c.phone.signal('peer-joined');
    assert.equal(env.laptop.counts.rejoins, i + 1, JSON.stringify(hello));
  }
  assert.deepEqual(env.laptop.log.filter((entry) => entry.room === room).map((entry) => entry.message), bad.map((hello) => JSON.parse(JSON.stringify(hello))));
  assert.deepEqual(env.laptop.errors, []);
});

test('with no protocol in common, hello gets incompatible with tooOld as LoaderHandler works it out', async () => {
  const env = await setup();
  const { room, keys } = await pairDevice(env);
  /** @type {Array<[number[], string]>} */
  const cases = [[[], 'loader'], [[0], 'loader'], [[-3, 0], 'loader'], [[2], 'laptop'], [[0, 2], 'laptop'], [[3, 2], 'laptop']];
  for (const [protocols, tooOld] of cases) {
    const c = await connect(env, room, keys, { hello: false });
    await c.send({ type: 'hello', loaderVersion: '1.0.0', protocols });
    assert.deepEqual(await c.read(), { type: 'incompatible', tooOld }, JSON.stringify(protocols));
    await c.phone.signal('peer-left');
    await c.phone.signal('peer-joined');
  }
  assert.equal(env.laptop.counts.rejoins, cases.length);
});

test('hello picks the common version and does not check loaderVersion', async () => {
  const env = await setup();
  const { room, keys } = await pairDevice(env);
  for (const hello of [
    { type: 'hello', protocols: [1] },
    { type: 'hello', loaderVersion: 7, protocols: [2, 1, 0] },
    { type: 'hello', loaderVersion: '0.0.1', protocols: [1, 1] },
  ]) {
    const c = await connect(env, room, keys, { hello: false });
    await c.send(hello);
    const welcome = await c.read();
    assert.equal(welcome.type, 'welcome', JSON.stringify(hello));
    assert.equal(welcome.protocol, 1);
  }
  assert.equal(env.laptop.counts.rejoins, 0);
});

test('app bodies: the default onApp answers sessions.subscribe, and sendApp reaches the phone', async () => {
  const env = await setup();
  const { room, keys } = await pairDevice(env);
  assert.equal(await env.laptop.sendApp(room, { kind: 'event' }), false, 'no welcomed phone yet');
  const { read, send } = await connect(env, room, keys);
  const request = { kind: 'request', requestID: 'r-1', method: 'sessions.subscribe', params: {} };
  await send({ type: 'app', body: request });
  assert.deepEqual(await read(), {
    type: 'app',
    body: {
      kind: 'reply',
      requestID: 'r-1',
      result: { repos: [{ name: 'acme-api', worktrees: [{ name: 'fix-login', sessions: [{ ref: 's1', kind: 'claude', status: 'waiting' }] }] }] },
    },
  });
  await send({ type: 'app', body: { kind: 'request', requestID: 'r-2', method: 'other', params: {} } });
  const event = { kind: 'event', event: 'debug.navigate', seq: 1, data: { url: '/x' } };
  assert.equal(await env.laptop.sendApp(room, event), true);
  assert.deepEqual(await read(), { type: 'app', body: event });
  assert.deepEqual(env.laptop.appBodies, [request, { kind: 'request', requestID: 'r-2', method: 'other', params: {} }]);
  assert.deepEqual(env.laptop.log.filter((entry) => entry.room === room).map((entry) => entry.type), ['hello', 'app', 'app']);
});

test('a custom onApp gets each body and can reply', async () => {
  /** @type {any[]} */
  const seen = [];
  const env = await setup({
    onApp: async (/** @type {any} */ body, /** @type {(b: object) => Promise<void>} */ reply) => {
      seen.push(body);
      await reply({ echo: body });
    },
  });
  const { room, keys } = await pairDevice(env);
  const { read, send } = await connect(env, room, keys);
  await send({ type: 'app', body: { n: 1 } });
  assert.deepEqual(await read(), { type: 'app', body: { echo: { n: 1 } } });
  assert.deepEqual(seen, [{ n: 1 }]);
});

test('revoke sends revoked, deletes the device and leaves', async () => {
  const env = await setup();
  const { room, keys } = await pairDevice(env);
  const { read, phone } = await connect(env, room, keys);
  await env.laptop.revoke(room);
  assert.deepEqual(await read(), { type: 'revoked' });
  await phone.signal('peer-left');
  assert.equal(env.laptop.devices.has(room), false);
  assert.deepEqual(env.relay.presence(`/v1/rooms/${room}/presence`).body, { laptop: false });
});

test('leave and join take the laptop out of a device room and back', async () => {
  const env = await setup();
  const { room, keys } = await pairDevice(env);
  env.laptop.leave(room);
  assert.deepEqual(env.relay.presence(`/v1/rooms/${room}/presence`).body, { laptop: false });
  const phone = phoneSocket(env, room);
  assert.deepEqual(await phone.next(), { kind: 'open' });
  await phone.signal('peer-absent');
  env.laptop.join(room);
  await phone.signal('peer-joined');
  phone.ws.close(1000);
  assert.equal((await connect(env, room, keys)).welcome.type, 'welcome');
  assert.equal(env.relay.stats.laptopJoins.get(room), 2);
});

test('the junk hook sends a short and a 64-byte stale frame right before each message 2', async () => {
  const env = await setup();
  env.laptop.sendJunkBeforeMessage2(true);
  const keys = await phoneKeys();
  const offer = env.laptop.makeOffer({});
  const phone = phoneSocket(env, offer.room);
  assert.deepEqual(await phone.next(), { kind: 'open' });
  await phone.signal('peer-joined');
  const initiator = await offerInitiator(keys, offer);
  phone.send(await initiator.writeMessage1(encode({ deviceName: 'iPhone' })));
  const [short, long] = [await phone.frame(), await phone.frame()];
  assert.deepEqual([short.length, long.length], [20, 64]);
  await assert.rejects(initiator.readMessage2(short), { code: 'messageTooShort' });
  await assert.rejects(initiator.readMessage2(long), { code: 'decryptFailed' });
  const result = await initiator.readMessage2(await phone.frame());
  phone.send(await result.transport.encrypt(encode(HELLO)));
  const { room } = decode(await result.transport.decrypt(await phone.frame()));

  /** @param {ReturnType<typeof phoneSocket>} socket */
  const ikOn = async (socket) => {
    assert.deepEqual(await socket.next(), { kind: 'open' });
    await socket.signal('peer-joined');
    const ik = await createInitiator({
      pattern: 'IK', localStatic: keys.pair, remoteStatic: env.laptop.publicKey, psk: null, prologue: phonePrologue(b64(room)),
    });
    return ik;
  };
  const ikPhone = phoneSocket(env, room);
  const ik = await ikOn(ikPhone);
  ikPhone.send(await ik.writeMessage1(encode({})));
  const ikJunk = [await ikPhone.frame(), await ikPhone.frame()];
  assert.deepEqual(ikJunk.map((frame) => frame.length), [20, 64]);
  await assert.rejects(ik.readMessage2(ikJunk[0]), { code: 'messageTooShort' });
  await assert.rejects(ik.readMessage2(ikJunk[1]), { code: 'decryptFailed' });
  await ik.readMessage2(await ikPhone.frame());

  // A test can pass its own frames.
  env.laptop.sendJunkBeforeMessage2([Uint8Array.of(1, 2, 3)]);
  const custom = phoneSocket(env, room);
  const customIK = await ikOn(custom);
  custom.send(await customIK.writeMessage1(encode({})));
  assert.deepEqual([...await custom.frame()], [1, 2, 3]);
  await customIK.readMessage2(await custom.frame());

  // Junk sent by the phone before its message 1 is dropped too.
  env.laptop.sendJunkBeforeMessage2(false);
  const third = phoneSocket(env, room);
  const again = await ikOn(third);
  third.send(new Uint8Array(randomBytes(64)));
  third.send(await again.writeMessage1(encode({})));
  await again.readMessage2(await third.frame());
  assert.equal(env.laptop.counts.ikHandshakes, 3);
});

test('the pairedRoom hook sends the room verbatim and joins nothing', async () => {
  const env = await setup();
  const { phone, transport, offer } = await pairUntilDecision(env, { pairedRoom: 'not-a-room' });
  assert.deepEqual(decode(await transport.decrypt(await phone.frame())), { type: 'paired', room: 'not-a-room' });
  await phone.signal('peer-left');
  assert.equal(env.relay.stats.laptopJoins.size, 1, 'only the pairing room');
  assert.equal(env.relay.stats.laptopJoins.get(offer.room), 1);
});

test('a staticKey fixes the laptop key, and the clock sets exp', async () => {
  const staticKey = new Uint8Array(32).fill(9);
  const env = await setup({ staticKey, clock: { now: () => 1_700_000_000_500, setTimeout: () => 0, clearTimeout: () => {} } });
  assert.deepEqual(env.laptop.publicKey, (await importPair(staticKey)).publicRaw);
  const offer = env.laptop.makeOffer({ expSeconds: -200 });
  assert.equal(offer.exp, 1_700_000_000 - 200);
  assert.equal(offer.key, base64urlEncode(env.laptop.publicKey));
});
