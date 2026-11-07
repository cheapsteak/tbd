import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import { NoiseError, createInitiator } from './noise.js';

const file = JSON.parse(readFileSync(new URL('../../test-vectors/noise-cacophony.json', import.meta.url), 'utf8'));
const subtle = globalThis.crypto.subtle;

/**
 * @typedef {{ payload: string, ciphertext: string }} VectorMessage
 * @typedef {{ protocol_name: string, init_prologue: string, init_psks?: string[], init_static: string,
 *             init_ephemeral: string, init_remote_static: string, handshake_hash: string,
 *             messages: VectorMessage[] }} Vector
 */

/** @type {Vector[]} */
const vectors = file.vectors;

/** @param {string} hex */
const fromHex = (hex) => new Uint8Array(Buffer.from(hex, 'hex'));
/** @param {number} length */
const randomBytes = (length) => crypto.getRandomValues(new Uint8Array(length));

/** @param {Vector} vector @returns {'IKpsk2' | 'IK'} */
function patternOf(vector) {
  switch (vector.protocol_name) {
    case 'Noise_IKpsk2_25519_AESGCM_SHA256':
      return 'IKpsk2';
    case 'Noise_IK_25519_AESGCM_SHA256':
      return 'IK';
    default:
      throw new Error(`unexpected protocol ${vector.protocol_name}`);
  }
}

const vectorIK = vectors.find((v) => patternOf(v) === 'IK');
const vectorIKpsk2 = vectors.find((v) => patternOf(v) === 'IKpsk2');
assert.ok(vectorIK && vectorIKpsk2);

/**
 * Asserts that the promise rejects with a NoiseError carrying this code.
 * @param {Promise<unknown>} promise
 * @param {string} code
 * @param {string} [message]
 */
const rejectsWith = (promise, code, message) =>
  assert.rejects(promise, (/** @type {unknown} */ error) => {
    assert.ok(error instanceof NoiseError, `expected a NoiseError, got ${error}`);
    assert.equal(error.code, code, message);
    return true;
  });

/**
 * The vector's initiator, with its raw keys injected.
 * @param {Vector} vector
 * @param {object} [overrides] options that replace the vector's
 */
const vectorInitiator = (vector, overrides = {}) =>
  createInitiator({
    pattern: patternOf(vector),
    localStatic: fromHex(vector.init_static),
    remoteStatic: fromHex(vector.init_remote_static),
    psk: vector.init_psks ? fromHex(vector.init_psks[0]) : null,
    prologue: fromHex(vector.init_prologue),
    ephemeral: fromHex(vector.init_ephemeral),
    ...overrides,
  });

/**
 * The vector's initiator after it has written message 1, checked against the
 * vector.
 * @param {Vector} vector
 */
async function afterMessage1(vector) {
  const initiator = await vectorInitiator(vector);
  const [m0] = vector.messages;
  assert.deepEqual(await initiator.writeMessage1(fromHex(m0.payload)), fromHex(m0.ciphertext), 'message 1');
  return initiator;
}

/**
 * Reads the vector's message 2 and checks the payload, the handshake hash and
 * transport messages 2 through 5 against the vector.
 * @param {Vector} vector
 * @param {{ readMessage2(message: Uint8Array): Promise<{ payload: Uint8Array, transport: any, handshakeHash: Uint8Array }> }} initiator
 * @param {Uint8Array} [message2] defaults to the vector's message 2
 */
async function assertCompletes(vector, initiator, message2 = fromHex(vector.messages[1].ciphertext)) {
  const { payload, transport, handshakeHash } = await initiator.readMessage2(message2);
  assert.deepEqual(payload, fromHex(vector.messages[1].payload), 'message 2 payload');
  assert.deepEqual(handshakeHash, fromHex(vector.handshake_hash), 'handshake hash');
  for (let n = 2; n < 6; n += 1) {
    const m = vector.messages[n];
    if (n % 2 === 0) {
      assert.deepEqual(await transport.encrypt(fromHex(m.payload)), fromHex(m.ciphertext), `transport message ${n}`);
    } else {
      assert.deepEqual(await transport.decrypt(fromHex(m.ciphertext)), fromHex(m.payload), `transport message ${n}`);
    }
  }
}

/** @param {Vector} vector */
const realMessage2 = (vector) => fromHex(vector.messages[1].ciphertext);

/**
 * The vector's message 2 with one bit flipped.
 * @param {Vector} vector
 * @param {number} offset negative counts from the end
 */
function flipped(vector, offset) {
  const message = realMessage2(vector);
  message[offset < 0 ? message.length + offset : offset] ^= 0x01;
  return message;
}

/** @param {Vector} vector the vector's message 2 with the responder's ephemeral key zeroed */
function zeroEphemeral(vector) {
  const message = realMessage2(vector);
  message.fill(0, 0, 32);
  return message;
}

test('handshake vectors: the file holds IK and IKpsk2, six messages each', () => {
  assert.deepEqual(vectors.map((v) => v.protocol_name).sort(), [
    'Noise_IK_25519_AESGCM_SHA256',
    'Noise_IKpsk2_25519_AESGCM_SHA256',
  ]);
  for (const vector of vectors) {
    assert.equal(vector.messages.length, 6);
  }
});

for (const vector of vectors) {
  const name = patternOf(vector);

  test(`handshake vectors, initiator role: ${name}`, async () => {
    await assertCompletes(vector, await afterMessage1(vector));
  });

  for (const offset of [0, -1]) {
    test(`handshake: ${name} message 2 with a bit flipped at offset ${offset} fails`, async () => {
      const initiator = await afterMessage1(vector);
      await rejectsWith(initiator.readMessage2(flipped(vector, offset)), 'decryptFailed');
    });
  }

  test(`handshake: ${name} message 2 with an all-zero responder ephemeral is refused`, async () => {
    const initiator = await afterMessage1(vector);
    await rejectsWith(initiator.readMessage2(zeroEphemeral(vector)), 'invalidPublicKey');
  });

  // The relay can deliver frames meant for a replaced peer before the real
  // message 2. Each is refused and leaves the handshake state as it was.
  test(`handshake: ${name} stale frames are refused and the real message 2 still completes`, async () => {
    const initiator = await afterMessage1(vector);
    const otherVector = name === 'IK' ? vectorIKpsk2 : vectorIK;
    /** @type {[string, Uint8Array, string][]} */
    const staleFrames = [
      ['random 64 bytes', randomBytes(64), 'decryptFailed'],
      ['10 bytes', randomBytes(10), 'messageTooShort'],
      ['47 bytes', randomBytes(47), 'messageTooShort'],
      ['an empty frame', new Uint8Array(0), 'messageTooShort'],
      ['65,536 bytes', randomBytes(65536), 'messageTooLong'],
      ['message 2 with its last bit flipped', flipped(vector, -1), 'decryptFailed'],
      ['message 2 with its first bit flipped', flipped(vector, 0), 'decryptFailed'],
      ['message 2 with an all-zero ephemeral', zeroEphemeral(vector), 'invalidPublicKey'],
      ["the other pattern's message 2", realMessage2(otherVector), 'decryptFailed'],
      ['random 64 bytes again', randomBytes(64), 'decryptFailed'],
    ];
    for (const [label, frame, code] of staleFrames) {
      await rejectsWith(initiator.readMessage2(frame), code, label);
    }
    await assertCompletes(vector, initiator);
  });
}

test('handshake: the psk enters only at message 2', async () => {
  const initiator = await vectorInitiator(vectorIKpsk2, { psk: new Uint8Array(32) });
  const [m0, m1] = vectorIKpsk2.messages;
  assert.deepEqual(await initiator.writeMessage1(fromHex(m0.payload)), fromHex(m0.ciphertext));
  await rejectsWith(initiator.readMessage2(fromHex(m1.ciphertext)), 'decryptFailed');
});

test('handshake: readMessage2 before writeMessage1 is invalidState and changes nothing', async () => {
  const initiator = await vectorInitiator(vectorIKpsk2);
  await rejectsWith(initiator.readMessage2(realMessage2(vectorIKpsk2)), 'invalidState');
  const [m0] = vectorIKpsk2.messages;
  assert.deepEqual(await initiator.writeMessage1(fromHex(m0.payload)), fromHex(m0.ciphertext));
  await assertCompletes(vectorIKpsk2, initiator);
});

test('handshake: a second writeMessage1 is invalidState, and every later call is too', async () => {
  const initiator = await afterMessage1(vectorIKpsk2);
  const payload = fromHex(vectorIKpsk2.messages[0].payload);
  await rejectsWith(initiator.writeMessage1(payload), 'invalidState');
  await rejectsWith(initiator.readMessage2(realMessage2(vectorIKpsk2)), 'invalidState');
  await rejectsWith(initiator.writeMessage1(payload), 'invalidState');
});

test('handshake: a writeMessage1 started before the first resolved is invalidState and leaves the first alone', async () => {
  const initiator = await vectorInitiator(vectorIKpsk2);
  const [m0] = vectorIKpsk2.messages;
  const first = initiator.writeMessage1(fromHex(m0.payload));
  const second = initiator.writeMessage1(fromHex(m0.payload));
  // A read during the write is refused the same way.
  const read = initiator.readMessage2(realMessage2(vectorIKpsk2));
  await rejectsWith(second, 'invalidState');
  await rejectsWith(read, 'invalidState');
  assert.deepEqual(await first, fromHex(m0.ciphertext));
  await assertCompletes(vectorIKpsk2, initiator);
});

test('handshake: a refused writeMessage1 leaves every later call invalidState', async () => {
  const initiator = await vectorInitiator(vectorIK);
  await rejectsWith(initiator.writeMessage1(new Uint8Array(65440)), 'messageTooLong');
  await rejectsWith(initiator.writeMessage1(fromHex(vectorIK.messages[0].payload)), 'invalidState');
  await rejectsWith(initiator.readMessage2(realMessage2(vectorIK)), 'invalidState');
});

test('handshake: a remote static key of low order fails message 1, and the initiator stays failed', async () => {
  const initiator = await vectorInitiator(vectorIK, { remoteStatic: new Uint8Array(32) });
  await rejectsWith(initiator.writeMessage1(new Uint8Array(0)), 'invalidPublicKey');
  await rejectsWith(initiator.writeMessage1(new Uint8Array(0)), 'invalidState');
  await rejectsWith(initiator.readMessage2(realMessage2(vectorIK)), 'invalidState');
});

test('handshake: a read during another read is invalidState and leaves the first alone', async () => {
  // A stale frame in flight: the real message 2 overlapping it is refused,
  // the stale frame fails on its own, and the real message 2 then completes.
  const staleFirst = await afterMessage1(vectorIK);
  const stale = staleFirst.readMessage2(flipped(vectorIK, -1));
  const overlapping = staleFirst.readMessage2(realMessage2(vectorIK));
  await rejectsWith(overlapping, 'invalidState');
  await rejectsWith(stale, 'decryptFailed');
  await assertCompletes(vectorIK, staleFirst);

  // The real message 2 in flight: a stale frame overlapping it is refused,
  // a refused call does not free the state for the next one, and the real
  // one completes.
  const realFirst = await afterMessage1(vectorIKpsk2);
  const real = realFirst.readMessage2(realMessage2(vectorIKpsk2));
  const late = realFirst.readMessage2(flipped(vectorIKpsk2, -1));
  const again = realFirst.readMessage2(realMessage2(vectorIKpsk2));
  const write = realFirst.writeMessage1(new Uint8Array(0));
  await rejectsWith(late, 'invalidState');
  await rejectsWith(again, 'invalidState');
  await rejectsWith(write, 'invalidState');
  const { handshakeHash } = await real;
  assert.deepEqual(handshakeHash, fromHex(vectorIKpsk2.handshake_hash));
});

test('handshake: after completion, every call is invalidState', async () => {
  const initiator = await afterMessage1(vectorIK);
  await assertCompletes(vectorIK, initiator);
  await rejectsWith(initiator.readMessage2(realMessage2(vectorIK)), 'invalidState');
  await rejectsWith(initiator.writeMessage1(new Uint8Array(0)), 'invalidState');
});

test('handshake: the psk must fit the pattern', async () => {
  const cases = [
    ['IKpsk2 with null', { psk: null }, vectorIKpsk2],
    ['IKpsk2 with no psk', { psk: undefined }, vectorIKpsk2],
    ['IKpsk2 with 16 bytes', { psk: new Uint8Array(16) }, vectorIKpsk2],
    ['IKpsk2 with 33 bytes', { psk: new Uint8Array(33) }, vectorIKpsk2],
    ['IK with 32 bytes', { psk: new Uint8Array(32) }, vectorIK],
  ];
  for (const [label, overrides, vector] of /** @type {[string, object, Vector][]} */ (cases)) {
    await rejectsWith(vectorInitiator(vector, overrides), 'invalidPSK', label);
  }
});

test('handshake: refuses malformed keys, prologue and pattern', async () => {
  await rejectsWith(vectorInitiator(vectorIK, { remoteStatic: new Uint8Array(31) }), 'invalidPublicKey');
  await assert.rejects(vectorInitiator(vectorIK, { localStatic: new Uint8Array(31) }), RangeError);
  await assert.rejects(vectorInitiator(vectorIK, { ephemeral: new Uint8Array(33) }), RangeError);
  await assert.rejects(vectorInitiator(vectorIK, { pattern: 'XX' }), RangeError);
  await assert.rejects(vectorInitiator(vectorIK, { prologue: undefined }), TypeError);
  const pair = /** @type {CryptoKeyPair} */ (await subtle.generateKey({ name: 'X25519' }, false, ['deriveBits']));
  await assert.rejects(vectorInitiator(vectorIK, { localStatic: pair.privateKey }), TypeError);
  await assert.rejects(vectorInitiator(vectorIK, { remoteStatic: pair.privateKey }), TypeError);
});

test('handshake: message 1 payload size limit', async () => {
  const largest = await (await vectorInitiator(vectorIKpsk2)).writeMessage1(new Uint8Array(65439));
  assert.equal(largest.length, 65535);
  await rejectsWith((await vectorInitiator(vectorIKpsk2)).writeMessage1(new Uint8Array(65440)), 'messageTooLong');
});

test('handshake: CryptoKeyPair inputs', async () => {
  const generate = async () =>
    /** @type {CryptoKeyPair} */ (await subtle.generateKey({ name: 'X25519' }, false, ['deriveBits']));
  const localStatic = await generate();
  const ephemeral = await generate();
  const laptop = await generate();
  const initiator = await createInitiator({
    pattern: 'IKpsk2',
    localStatic,
    remoteStatic: laptop.publicKey,
    psk: randomBytes(32),
    prologue: randomBytes(43),
    ephemeral,
  });
  const message = await initiator.writeMessage1(randomBytes(22));
  assert.equal(message.length, 32 + 48 + 22 + 16);
  assert.deepEqual(message.subarray(0, 32), new Uint8Array(await subtle.exportKey('raw', ephemeral.publicKey)));
});

test('handshake: a key pair and its raw private key give the same message 1', async () => {
  const generate = async () =>
    /** @type {CryptoKeyPair} */ (await subtle.generateKey({ name: 'X25519' }, true, ['deriveBits']));
  /** @param {CryptoKeyPair} pair the 32 raw private-key bytes, the end of the PKCS#8 export */
  const rawPrivate = async (pair) => new Uint8Array(await subtle.exportKey('pkcs8', pair.privateKey)).slice(-32);
  const localStatic = await generate();
  const ephemeral = await generate();
  const laptop = await generate();
  const psk = randomBytes(32);
  const prologue = randomBytes(43);
  const payload = randomBytes(22);

  const fromPairs = await createInitiator({
    pattern: 'IKpsk2',
    localStatic,
    remoteStatic: laptop.publicKey,
    psk,
    prologue,
    ephemeral,
  });
  const fromBytes = await createInitiator({
    pattern: 'IKpsk2',
    localStatic: await rawPrivate(localStatic),
    remoteStatic: new Uint8Array(await subtle.exportKey('raw', laptop.publicKey)),
    psk,
    prologue,
    ephemeral: await rawPrivate(ephemeral),
  });
  assert.deepEqual(await fromPairs.writeMessage1(payload), await fromBytes.writeMessage1(payload));
});

test('handshake: generated ephemeral keys differ between handshakes', async () => {
  const create = () => vectorInitiator(vectorIK, { ephemeral: undefined });
  const payload = fromHex(vectorIK.messages[0].payload);
  const first = await (await create()).writeMessage1(payload);
  const second = await (await create()).writeMessage1(payload);
  assert.equal(first.length, second.length);
  assert.notDeepEqual(first.subarray(0, 32), second.subarray(0, 32));
});

test('handshake: inputs are copied at the call, and views into larger buffers work', async () => {
  const [m0, m1] = vectorIKpsk2.messages;
  const prologue = fromHex(vectorIKpsk2.init_prologue);
  const creating = vectorInitiator(vectorIKpsk2, { prologue });
  prologue.fill(0);
  const initiator = await creating;

  const payloadBacking = new Uint8Array(m0.payload.length / 2 + 2);
  payloadBacking.set(fromHex(m0.payload), 1);
  const writing = initiator.writeMessage1(payloadBacking.subarray(1, -1));
  payloadBacking.fill(0);
  assert.deepEqual(await writing, fromHex(m0.ciphertext));

  const messageBacking = new Uint8Array(m1.ciphertext.length / 2 + 2);
  messageBacking.set(fromHex(m1.ciphertext), 1);
  const reading = initiator.readMessage2(messageBacking.subarray(1, -1));
  messageBacking.fill(0);
  const { payload, handshakeHash } = await reading;
  assert.deepEqual(payload, fromHex(m1.payload));
  assert.deepEqual(handshakeHash, fromHex(vectorIKpsk2.handshake_hash));
});
