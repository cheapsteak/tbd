import { test } from 'node:test';
import assert from 'node:assert/strict';

import { createInitiator, phonePrologue } from '../../channel/noise.js';
import { base64urlEncode } from '../../channel/pairingLink.js';
import {
  KeyMissingError, createPhoneKeyPair, createWrapKey, createWrappedPhoneKey, isWrapKey, unwrapPhoneKeyPair, wrapPrivateKey,
} from '../../keys.js';
import { laptopIDFromKey } from '../../store.js';
import { createResponder } from '../support/noise-responder.js';
import { generatePair } from '../support/x25519.js';

const subtle = globalThis.crypto.subtle;
/** @param {number} length */
const random = (length) => crypto.getRandomValues(new Uint8Array(length));
/** @param {unknown} value */
const json = (value) => new TextEncoder().encode(JSON.stringify(value));
const ID = laptopIDFromKey(random(32));

/**
 * The X25519 shared secret of a private key and a raw public key.
 * @param {CryptoKey} privateKey
 * @param {Uint8Array} publicRaw
 */
async function dhBits(privateKey, publicRaw) {
  const publicKey = await subtle.importKey('raw', /** @type {Uint8Array<ArrayBuffer>} */ (publicRaw), { name: 'X25519' }, false, []);
  return new Uint8Array(await subtle.deriveBits({ name: 'X25519', public: publicKey }, privateKey, 256));
}

/** A phone key pair wrapped for ID, and the record fields `unwrapPhoneKeyPair` reads. */
async function wrappedPhone() {
  const wrapKey = await createWrapKey(subtle);
  const phone = await createPhoneKeyPair(subtle);
  const { wrappedKey, wrapIV } = await wrapPrivateKey(subtle, wrapKey, phone.pair.privateKey, ID, phone.publicRaw);
  return { wrapKey, phone, record: { id: ID, phoneKey: phone.publicRaw, wrappedKey, wrapIV } };
}

/** @param {Promise<unknown>} promise */
const rejectsKeyMissing = (promise) => assert.rejects(promise, (error) => {
  assert.ok(error instanceof KeyMissingError, String(error));
  assert.equal(error.name, 'KeyMissingError');
  assert.notEqual(error.cause, undefined);
  return true;
});

test('a wrapped key comes back as a CryptoKeyPair with a non-extractable private half and the same DH', async () => {
  const wk = await createWrapKey(subtle);
  const phone = await createPhoneKeyPair(subtle), peer = await createPhoneKeyPair(subtle);
  const { wrappedKey, wrapIV } = await wrapPrivateKey(subtle, wk, phone.pair.privateKey, ID, phone.publicRaw);
  const pair = await unwrapPhoneKeyPair(subtle, wk, { id: ID, phoneKey: phone.publicRaw, wrappedKey, wrapIV });
  assert.equal(pair.privateKey.extractable, false);
  await assert.rejects(subtle.exportKey('pkcs8', pair.privateKey));
  await assert.rejects(subtle.exportKey('jwk', pair.privateKey));
  assert.deepEqual(new Uint8Array(await subtle.exportKey('raw', pair.publicKey)), phone.publicRaw);
  assert.deepEqual(await dhBits(pair.privateKey, peer.publicRaw), await dhBits(phone.pair.privateKey, peer.publicRaw));
  assert.equal(phone.publicRaw.length, 32);
  assert.equal(wrapIV.length, 12);
});

test('the unwrapped pair has exactly the algorithm, extractability and usages createInitiator needs', async () => {
  const { wrapKey, record } = await wrappedPhone();
  const pair = await unwrapPhoneKeyPair(subtle, wrapKey, record);
  assert.equal(pair.privateKey.type, 'private');
  assert.equal(pair.privateKey.algorithm.name, 'X25519');
  assert.deepEqual(pair.privateKey.usages, ['deriveBits']);
  assert.equal(pair.publicKey.type, 'public');
  assert.equal(pair.publicKey.algorithm.name, 'X25519');
  assert.equal(pair.publicKey.extractable, true);
  assert.deepEqual(pair.publicKey.usages, []);
});

test('the unwrapped pair works as createInitiator localStatic', async () => {
  const { wrapKey, phone, record } = await wrappedPhone();
  const pair = await unwrapPhoneKeyPair(subtle, wrapKey, record);
  const laptop = await generatePair();
  const room = random(32);
  const initiator = await createInitiator({
    pattern: 'IK', localStatic: pair, remoteStatic: laptop.publicRaw, psk: null, prologue: phonePrologue(room),
  });
  const responder = await createResponder({ pattern: 'IK', localStatic: laptop, prologue: phonePrologue(room) });
  const m1 = await responder.readMessage1(await initiator.writeMessage1(json({})));
  assert.deepEqual(m1.remoteStatic, phone.publicRaw);
  assert.deepEqual(JSON.parse(new TextDecoder().decode(m1.payload)), {});
  const m2 = await responder.writeMessage2(json({ laptopName: 'acme-laptop' }));
  const done = await initiator.readMessage2(m2.message);
  assert.deepEqual(done.handshakeHash, m2.handshakeHash);
  assert.deepEqual(JSON.parse(new TextDecoder().decode(done.payload)), { laptopName: 'acme-laptop' });
  const hello = json({ type: 'hello' });
  assert.deepEqual(await m2.transport.decrypt(await done.transport.encrypt(hello)), hello);
  assert.deepEqual(await done.transport.decrypt(await m2.transport.encrypt(hello)), hello);
});

test('another laptopID cannot unwrap', async () => {
  const { wrapKey, record } = await wrappedPhone();
  await rejectsKeyMissing(unwrapPhoneKeyPair(subtle, wrapKey, { ...record, id: laptopIDFromKey(random(32)) }));
  await rejectsKeyMissing(unwrapPhoneKeyPair(subtle, wrapKey, { ...record, id: `${ID} ` }));
  await rejectsKeyMissing(unwrapPhoneKeyPair(subtle, wrapKey, { ...record, id: '' }));
});

test('another wrap key cannot unwrap', async () => {
  const { record } = await wrappedPhone();
  await rejectsKeyMissing(unwrapPhoneKeyPair(subtle, await createWrapKey(subtle), record));
});

test('a damaged record cannot unwrap', async () => {
  const { wrapKey, record } = await wrappedPhone();
  /** @param {Uint8Array} bytes @param {number} at */
  const flip = (bytes, at) => { const copy = bytes.slice(); copy[at] ^= 1; return copy; };
  const other = await createPhoneKeyPair(subtle);
  for (const damaged of [
    { ...record, wrappedKey: flip(record.wrappedKey, 0) },
    { ...record, wrappedKey: flip(record.wrappedKey, record.wrappedKey.length - 1) },
    { ...record, wrappedKey: record.wrappedKey.subarray(0, record.wrappedKey.length - 1) },
    { ...record, wrappedKey: new Uint8Array(0) },
    { ...record, wrapIV: flip(record.wrapIV, 11) },
    { ...record, wrapIV: new Uint8Array(16) },
    { ...record, phoneKey: other.publicRaw }, // a real key, but not the wrapped key's
    { ...record, phoneKey: record.phoneKey.subarray(0, 31) },
    { ...record, phoneKey: new Uint8Array(32) },
    { ...record, wrappedKey: /** @type {any} */ (Array.from(record.wrappedKey)) },
    { ...record, wrapIV: undefined },
    { ...record, id: undefined },
  ]) {
    await rejectsKeyMissing(unwrapPhoneKeyPair(subtle, wrapKey, /** @type {any} */ (damaged)));
  }
  await rejectsKeyMissing(unwrapPhoneKeyPair(subtle, /** @type {any} */ (undefined), record));
  // The record itself still unwraps.
  await unwrapPhoneKeyPair(subtle, wrapKey, record);
});

test('the wrap key is AES-GCM, non-extractable, wrapKey and unwrapKey only', async () => {
  const wk = await createWrapKey(subtle);
  assert.equal(wk.type, 'secret');
  assert.deepEqual(wk.algorithm, { name: 'AES-GCM', length: 256 });
  assert.equal(wk.extractable, false);
  assert.deepEqual([...wk.usages].sort(), ['unwrapKey', 'wrapKey']);
  await assert.rejects(subtle.exportKey('raw', wk));
  await assert.rejects(subtle.encrypt({ name: 'AES-GCM', iv: random(12) }, wk, random(16)));
});

test('the wrap is PKCS#8 under AES-GCM with the additional data "tbd-phone/1 key <laptopID> <base64url phoneKey>"', async () => {
  // A wrap key that may also decrypt, so the test can open the wrap by hand.
  const wk = await subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['wrapKey', 'unwrapKey', 'decrypt']);
  const phone = await createPhoneKeyPair(subtle);
  const { wrappedKey, wrapIV } = await wrapPrivateKey(subtle, wk, phone.pair.privateKey, ID, phone.publicRaw);
  const open = (/** @type {string} */ ad) => subtle.decrypt(
    { name: 'AES-GCM', iv: wrapIV, additionalData: new TextEncoder().encode(ad) }, wk, wrappedKey);
  const pkcs8 = new Uint8Array(await subtle.exportKey('pkcs8', phone.pair.privateKey));
  const phoneKey = base64urlEncode(phone.publicRaw);
  assert.equal(phoneKey.length, 43);
  assert.deepEqual(new Uint8Array(await open(`tbd-phone/1 key ${ID} ${phoneKey}`)), pkcs8);
  await assert.rejects(open(`tbd-phone/1 key ${ID}`));
  await assert.rejects(open(`tbd-phone/1 key ${ID}${phoneKey}`));
  await assert.rejects(open(`tbd-phone/1 key ${phoneKey} ${ID}`));
  await assert.rejects(open(ID));
  assert.equal(wrappedKey.length, pkcs8.length + 16);
});

test('a phoneKey with any one bit flipped cannot unwrap, the top bit included', async () => {
  const { wrapKey, record } = await wrappedPhone();
  // X25519 ignores bit 255 of a public key, so DH alone cannot tell this one apart.
  for (let bit = 0; bit < 256; bit += 1) {
    const phoneKey = record.phoneKey.slice();
    phoneKey[bit >> 3] ^= 1 << (bit & 7);
    await rejectsKeyMissing(unwrapPhoneKeyPair(subtle, wrapKey, { ...record, phoneKey }));
  }
  await unwrapPhoneKeyPair(subtle, wrapKey, record);
});

test('each wrap has a fresh IV', async () => {
  const wk = await createWrapKey(subtle);
  const phone = await createPhoneKeyPair(subtle);
  const first = await wrapPrivateKey(subtle, wk, phone.pair.privateKey, ID, phone.publicRaw);
  const second = await wrapPrivateKey(subtle, wk, phone.pair.privateKey, ID, phone.publicRaw);
  assert.equal(first.wrapIV.length, 12);
  assert.notDeepEqual(first.wrapIV, second.wrapIV);
  assert.notDeepEqual(first.wrappedKey, second.wrappedKey);
});

test('a new phone key pair is X25519 with an extractable private key, for its one wrap', async () => {
  const { pair, publicRaw } = await createPhoneKeyPair(subtle);
  assert.equal(pair.privateKey.algorithm.name, 'X25519');
  assert.equal(pair.privateKey.extractable, true);
  assert.deepEqual(pair.privateKey.usages, ['deriveBits']);
  assert.deepEqual(new Uint8Array(await subtle.exportKey('raw', pair.publicKey)), publicRaw);
  assert.notDeepEqual((await createPhoneKeyPair(subtle)).publicRaw, publicRaw);
});

test('only an X25519 private key is wrapped, and only for a laptop ID and a 32-byte public key', async () => {
  const wk = await createWrapKey(subtle);
  const phone = await createPhoneKeyPair(subtle);
  const raw = phone.publicRaw;
  const aes = await subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['encrypt']);
  await assert.rejects(wrapPrivateKey(subtle, wk, phone.pair.publicKey, ID, raw), TypeError);
  await assert.rejects(wrapPrivateKey(subtle, wk, aes, ID, raw), TypeError);
  await assert.rejects(wrapPrivateKey(subtle, wk, /** @type {any} */ (random(32)), ID, raw), TypeError);
  await assert.rejects(wrapPrivateKey(subtle, wk, phone.pair.privateKey, '', raw), TypeError);
  await assert.rejects(wrapPrivateKey(subtle, wk, phone.pair.privateKey, /** @type {any} */ (undefined), raw), TypeError);
  for (const phoneKey of [undefined, raw.subarray(0, 31), new Uint8Array(33), Array.from(raw), base64urlEncode(raw)]) {
    await assert.rejects(wrapPrivateKey(subtle, wk, phone.pair.privateKey, ID, /** @type {any} */ (phoneKey)), TypeError);
  }
  // An unwrapped key cannot be wrapped again: it is not extractable.
  const { wrapKey, record } = await wrappedPhone();
  const pair = await unwrapPhoneKeyPair(subtle, wrapKey, record);
  await assert.rejects(wrapPrivateKey(subtle, wrapKey, pair.privateKey, ID, record.phoneKey));
});

test('createWrappedPhoneKey returns a non-extractable pair and record fields that unwrap again', async () => {
  const made = await createWrappedPhoneKey(subtle, ID);
  // No extractable key comes back: only these fields, and the pair's private half is locked.
  assert.deepEqual(Object.keys(made).sort(), ['pair', 'publicRaw', 'wrapIV', 'wrapKey', 'wrappedKey']);
  assert.equal(made.pair.privateKey.extractable, false);
  assert.deepEqual(made.pair.privateKey.usages, ['deriveBits']);
  await assert.rejects(subtle.exportKey('pkcs8', made.pair.privateKey));
  assert.equal(made.pair.publicKey.extractable, true);
  assert.deepEqual(new Uint8Array(await subtle.exportKey('raw', made.pair.publicKey)), made.publicRaw);
  assert.equal(made.publicRaw.length, 32);
  assert.equal(made.wrapIV.length, 12);
  assert.ok(isWrapKey(made.wrapKey));
  // The record fields unwrap again, to the same key.
  const record = { id: ID, phoneKey: made.publicRaw, wrappedKey: made.wrappedKey, wrapIV: made.wrapIV };
  const again = await unwrapPhoneKeyPair(subtle, made.wrapKey, record);
  const peer = await createPhoneKeyPair(subtle);
  assert.deepEqual(await dhBits(again.privateKey, peer.publicRaw), await dhBits(made.pair.privateKey, peer.publicRaw));
  // Only for that laptop, and each call has its own wrap key.
  await rejectsKeyMissing(unwrapPhoneKeyPair(subtle, made.wrapKey, { ...record, id: laptopIDFromKey(random(32)) }));
  const other = await createWrappedPhoneKey(subtle, ID);
  await rejectsKeyMissing(unwrapPhoneKeyPair(subtle, other.wrapKey, record));
  assert.notDeepEqual(other.publicRaw, made.publicRaw);
});

test('createWrappedPhoneKey needs a laptop ID', async () => {
  for (const id of ['', undefined, 42]) {
    await assert.rejects(createWrappedPhoneKey(subtle, /** @type {any} */ (id)), TypeError);
  }
});

test('the pair createWrappedPhoneKey returns works as createInitiator localStatic', async () => {
  const made = await createWrappedPhoneKey(subtle, ID);
  const laptop = await generatePair();
  const room = random(32);
  const initiator = await createInitiator({
    pattern: 'IK', localStatic: made.pair, remoteStatic: laptop.publicRaw, psk: null, prologue: phonePrologue(room),
  });
  const responder = await createResponder({ pattern: 'IK', localStatic: laptop, prologue: phonePrologue(room) });
  const m1 = await responder.readMessage1(await initiator.writeMessage1(json({})));
  assert.deepEqual(m1.remoteStatic, made.publicRaw);
  const m2 = await responder.writeMessage2(json({ laptopName: 'acme-laptop' }));
  const done = await initiator.readMessage2(m2.message);
  assert.deepEqual(done.handshakeHash, m2.handshakeHash);
});

test('isWrapKey accepts only a non-extractable AES-GCM 256 key for wrapKey and unwrapKey', async () => {
  assert.equal(isWrapKey(await createWrapKey(subtle)), true);
  // Usage order does not matter.
  assert.equal(isWrapKey(await subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['unwrapKey', 'wrapKey'])), true);
  const phone = await createPhoneKeyPair(subtle);
  /** @type {Array<[string, unknown]>} */
  const bad = [
    ['extractable', await subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['wrapKey', 'unwrapKey'])],
    ['128 bits', await subtle.generateKey({ name: 'AES-GCM', length: 128 }, false, ['wrapKey', 'unwrapKey'])],
    ['wrapKey only', await subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['wrapKey'])],
    ['unwrapKey only', await subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['unwrapKey'])],
    ['an extra usage', await subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['wrapKey', 'unwrapKey', 'decrypt'])],
    ['encrypt and decrypt', await subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt'])],
    ['AES-KW', await subtle.generateKey({ name: 'AES-KW', length: 256 }, false, ['wrapKey', 'unwrapKey'])],
    ['AES-CBC', await subtle.generateKey({ name: 'AES-CBC', length: 256 }, false, ['wrapKey', 'unwrapKey'])],
    ['an X25519 private key', phone.pair.privateKey],
    ['an X25519 public key', phone.pair.publicKey],
    ['raw bytes', random(32)],
    ['a look-alike object', { type: 'secret', extractable: false, algorithm: { name: 'AES-GCM', length: 256 }, usages: ['wrapKey', 'unwrapKey'] }],
    ['undefined', undefined],
    ['null', null],
  ];
  for (const [name, value] of bad) {
    assert.equal(isWrapKey(value), false, name);
  }
});
