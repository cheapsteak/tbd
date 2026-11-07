import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import { NoiseError, createInitiator, phonePrologue } from '../../channel/noise.js';
import { createResponder } from './noise-responder.js';
import { generatePair, importPair } from './x25519.js';

const file = JSON.parse(readFileSync(new URL('../../../test-vectors/noise-cacophony.json', import.meta.url), 'utf8'));
/** @type {Array<any>} */
const vectors = file.vectors;
const subtle = globalThis.crypto.subtle;

/** @param {string} text */
const hex = (text) => new Uint8Array(Buffer.from(text, 'hex'));
/** @param {unknown} value */
const utf8 = (value) => new TextEncoder().encode(JSON.stringify(value));
/** @param {Uint8Array} bytes */
const json = (bytes) => JSON.parse(new TextDecoder().decode(bytes));
/** @param {number} length */
const random = (length) => crypto.getRandomValues(new Uint8Array(length));

/**
 * @param {Promise<unknown>} promise
 * @param {string} code
 */
const rejectsWith = (promise, code) =>
  assert.rejects(promise, (/** @type {any} */ error) => {
    assert.ok(error instanceof NoiseError, `expected a NoiseError, got ${error}`);
    assert.equal(error.code, code);
    return true;
  });

/**
 * A phone and a laptop for one live handshake: the phone's key pair comes from generateKey,
 * as the loader makes it, and the laptop's from x25519.js.
 * @param {'IK' | 'IKpsk2'} pattern
 * @param {{ responderPSK?: Uint8Array, responderRoom?: Uint8Array }} [overrides]
 */
async function liveHandshake(pattern, overrides = {}) {
  const room = random(32);
  const psk = pattern === 'IKpsk2' ? random(32) : null;
  const laptop = await generatePair();
  const phonePair = /** @type {CryptoKeyPair} */ (
    await subtle.generateKey({ name: 'X25519' }, false, ['deriveBits']));
  const phoneRaw = new Uint8Array(await subtle.exportKey('raw', phonePair.publicKey));
  const initiator = await createInitiator({
    pattern, localStatic: phonePair, remoteStatic: laptop.publicRaw, psk, prologue: phonePrologue(room),
  });
  const responder = await createResponder({
    pattern,
    localStatic: laptop,
    psk: pattern === 'IKpsk2' ? overrides.responderPSK ?? psk : null,
    prologue: phonePrologue(overrides.responderRoom ?? room),
  });
  return { initiator, responder, phoneRaw };
}

test('responder matches every IK and IKpsk2 cacophony vector', async () => {
  assert.deepEqual(vectors.map((v) => v.protocol_name).sort(),
    ['Noise_IK_25519_AESGCM_SHA256', 'Noise_IKpsk2_25519_AESGCM_SHA256']);
  for (const v of vectors) {
    const r = await createResponder({
      pattern: v.protocol_name.includes('psk2') ? 'IKpsk2' : 'IK',
      localStatic: await importPair(hex(v.resp_static)),
      psk: v.resp_psks ? hex(v.resp_psks[0]) : null,
      prologue: hex(v.resp_prologue),
      ephemeral: await importPair(hex(v.resp_ephemeral)),
    });
    const m1 = await r.readMessage1(hex(v.messages[0].ciphertext));
    assert.deepEqual(m1.payload, hex(v.messages[0].payload), v.protocol_name);
    assert.deepEqual(m1.remoteStatic, (await importPair(hex(v.init_static))).publicRaw, v.protocol_name);
    const m2 = await r.writeMessage2(hex(v.messages[1].payload));
    assert.deepEqual(m2.message, hex(v.messages[1].ciphertext), v.protocol_name);
    assert.deepEqual(m2.handshakeHash, hex(v.handshake_hash), v.protocol_name);
    assert.ok(v.messages.length > 2);
    for (let i = 2; i < v.messages.length; i++) { // even: initiator → responder
      const { payload, ciphertext } = v.messages[i];
      if (i % 2 === 0) assert.deepEqual(await m2.transport.decrypt(hex(ciphertext)), hex(payload), `${v.protocol_name} ${i}`);
      else assert.deepEqual(await m2.transport.encrypt(hex(payload)), hex(ciphertext), `${v.protocol_name} ${i}`);
    }
  }
});

for (const pattern of /** @type {const} */ (['IKpsk2', 'IK'])) {
  test(`round trip with the production initiator, ${pattern}`, async () => {
    const { initiator, responder, phoneRaw } = await liveHandshake(pattern);
    const m1 = await responder.readMessage1(await initiator.writeMessage1(utf8({ deviceName: 'iPhone' })));
    assert.deepEqual(json(m1.payload), { deviceName: 'iPhone' });
    assert.deepEqual(m1.remoteStatic, phoneRaw);
    const m2 = await responder.writeMessage2(utf8({ laptopName: 'acme-mbp' }));
    const phone = await initiator.readMessage2(m2.message);
    assert.deepEqual(json(phone.payload), { laptopName: 'acme-mbp' });
    assert.deepEqual(phone.handshakeHash, m2.handshakeHash);
    for (let i = 0; i < 3; i++) {
      assert.deepEqual(json(await m2.transport.decrypt(await phone.transport.encrypt(utf8({ type: 'hello', i })))), { type: 'hello', i });
      assert.deepEqual(json(await phone.transport.decrypt(await m2.transport.encrypt(utf8({ type: 'welcome', i })))), { type: 'welcome', i });
    }
  });
}

test('a wrong PSK makes the initiator reject message 2 with decryptFailed', async () => {
  const { initiator, responder } = await liveHandshake('IKpsk2', { responderPSK: random(32) });
  // The PSK enters only at message 2's psk token, so message 1 still reads.
  await responder.readMessage1(await initiator.writeMessage1(utf8({ deviceName: 'iPhone' })));
  const m2 = await responder.writeMessage2(utf8({ laptopName: 'acme-mbp' }));
  await rejectsWith(initiator.readMessage2(m2.message), 'decryptFailed');
});

test('a flipped byte in message 1 rejects decryptFailed', async () => {
  for (const pattern of /** @type {const} */ (['IKpsk2', 'IK'])) {
    const { initiator, responder } = await liveHandshake(pattern);
    const message = await initiator.writeMessage1(utf8({ deviceName: 'iPhone' }));
    // In e, in the sealed s and its tag, and in the sealed payload and its tag.
    for (const index of [0, 31, 32, 63, 79, 80, message.length - 1]) {
      const bad = message.slice();
      bad[index] ^= 0x01;
      await rejectsWith(responder.readMessage1(bad), 'decryptFailed');
    }
    await rejectsWith(responder.readMessage1(message.slice(0, 95)), 'decryptFailed');
  }
});

test('another room\'s prologue rejects decryptFailed', async () => {
  for (const pattern of /** @type {const} */ (['IKpsk2', 'IK'])) {
    const { initiator, responder } = await liveHandshake(pattern, { responderRoom: random(32) });
    await rejectsWith(responder.readMessage1(await initiator.writeMessage1(utf8({}))), 'decryptFailed');
  }
});

test('a message 1 that fails leaves the state unchanged, so a later valid one still reads', async () => {
  for (const pattern of /** @type {const} */ (['IKpsk2', 'IK'])) {
    const { initiator, responder } = await liveHandshake(pattern);
    const message = await initiator.writeMessage1(utf8({ deviceName: 'iPhone' }));
    const flipped = message.slice();
    flipped[message.length - 1] ^= 0x80;
    await rejectsWith(responder.readMessage1(random(64)), 'decryptFailed');
    await rejectsWith(responder.readMessage1(flipped), 'decryptFailed');
    await rejectsWith(responder.writeMessage2(utf8({})), 'invalidState');
    const m1 = await responder.readMessage1(message);
    assert.deepEqual(json(m1.payload), { deviceName: 'iPhone' });
    const m2 = await responder.writeMessage2(utf8({ laptopName: 'acme-mbp' }));
    const phone = await initiator.readMessage2(m2.message);
    assert.deepEqual(phone.handshakeHash, m2.handshakeHash);
  }
});

test('calls out of order reject invalidState', async () => {
  const { initiator, responder } = await liveHandshake('IK');
  await rejectsWith(responder.writeMessage2(utf8({})), 'invalidState');
  const message = await initiator.writeMessage1(utf8({}));
  await responder.readMessage1(message);
  await rejectsWith(responder.readMessage1(message), 'invalidState');
  await responder.writeMessage2(utf8({}));
  await rejectsWith(responder.writeMessage2(utf8({})), 'invalidState');
  await rejectsWith(responder.readMessage1(message), 'invalidState');
});

test('a low-order ephemeral key rejects invalidPublicKey and changes nothing', async () => {
  const { initiator, responder } = await liveHandshake('IKpsk2');
  const message = await initiator.writeMessage1(utf8({ deviceName: 'iPhone' }));
  const zeroKey = message.slice();
  zeroKey.fill(0, 0, 32);
  await rejectsWith(responder.readMessage1(zeroKey), 'invalidPublicKey');
  await responder.readMessage1(message);
});

test('a PSK that does not fit the pattern is refused', async () => {
  const laptop = await generatePair();
  const prologue = phonePrologue(random(32));
  await rejectsWith(createResponder({ pattern: 'IKpsk2', localStatic: laptop, psk: null, prologue }), 'invalidPSK');
  await rejectsWith(createResponder({ pattern: 'IKpsk2', localStatic: laptop, psk: random(31), prologue }), 'invalidPSK');
  await rejectsWith(createResponder({ pattern: 'IK', localStatic: laptop, psk: random(32), prologue }), 'invalidPSK');
});
