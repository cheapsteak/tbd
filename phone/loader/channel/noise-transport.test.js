import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import { MAX_MESSAGE_LENGTH, MAX_PLAINTEXT_LENGTH, NoiseError, createTransport, phonePrologue } from './noise.js';
import { base64urlDecode } from './pairingLink.js';

const file = JSON.parse(readFileSync(new URL('../../test-vectors/framing.json', import.meta.url), 'utf8'));
const encoder = new TextEncoder();
const LAST_USABLE_NONCE = 2n ** 64n - 2n;

/** @param {string} hex */
const fromHex = (hex) => new Uint8Array(Buffer.from(hex, 'hex'));
/** @param {number} length @param {number} seed */
const pattern = (length, seed) => Uint8Array.from({ length }, (_, i) => (i * 31 + seed) & 0xff);
const randomKey = () => crypto.getRandomValues(new Uint8Array(32));

/**
 * Asserts that the promise rejects with a NoiseError carrying this code.
 * @param {Promise<unknown>} promise
 * @param {string} code
 */
const rejectsWith = (promise, code) =>
  assert.rejects(promise, (/** @type {unknown} */ error) => {
    assert.ok(error instanceof NoiseError, `expected a NoiseError, got ${error}`);
    assert.equal(error.code, code);
    return true;
  });

/** Two transports facing each other: what a sends, b receives, and back. */
async function pair() {
  const k1 = randomKey();
  const k2 = randomKey();
  return {
    a: await createTransport({ sendKey: k1, receiveKey: k2 }),
    b: await createTransport({ sendKey: k2, receiveKey: k1 }),
  };
}

const p = pattern(32, 1);
const p0 = pattern(32, 2);
const p1 = pattern(32, 3);

test('transport: the size limits match the daemon', () => {
  assert.equal(MAX_MESSAGE_LENGTH, 65535);
  assert.equal(MAX_PLAINTEXT_LENGTH, 65519);
});

test('transport: shared framing vectors encrypt and decrypt', async () => {
  assert.equal(file.messages.length, 5);
  const key = fromHex(file.key);
  for (const m of file.messages) {
    const nonce = BigInt(m.nonce);
    const transport = await createTransport({ sendKey: key, receiveKey: key, sendNonce: nonce, receiveNonce: nonce });
    const plaintext = encoder.encode(m.plaintext);
    assert.deepEqual(await transport.encrypt(plaintext), fromHex(m.ciphertext), `encrypt at nonce ${m.nonce}`);
    assert.deepEqual(await transport.decrypt(fromHex(m.ciphertext)), plaintext, `decrypt at nonce ${m.nonce}`);
  }
});

test('prologue: matches the shared vector and refuses a room ID that is not 32 bytes', () => {
  const roomID = base64urlDecode(file.prologue.roomID);
  assert.ok(roomID);
  assert.deepEqual(phonePrologue(roomID), fromHex(file.prologue.prologue));
  assert.throws(() => phonePrologue(new Uint8Array(31)), { name: 'NoiseError', code: 'invalidRoomID' });
  assert.throws(() => phonePrologue(new Uint8Array(33)), { name: 'NoiseError', code: 'invalidRoomID' });
});

test('transport: a replayed message fails', async () => {
  const { a, b } = await pair();
  const m0 = await a.encrypt(p0);
  assert.deepEqual(await b.decrypt(m0), p0);
  await rejectsWith(b.decrypt(m0), 'decryptFailed');
});

test('transport: a reordered message fails, and the right order still works after it', async () => {
  const { a, b } = await pair();
  const m0 = await a.encrypt(p0);
  const m1 = await a.encrypt(p1);
  await rejectsWith(b.decrypt(m1), 'decryptFailed');
  assert.deepEqual(await b.decrypt(m0), p0);
  assert.deepEqual(await b.decrypt(m1), p1);
});

test('transport: a reflected message fails, because each direction has its own key', async () => {
  const { a } = await pair();
  await rejectsWith(a.decrypt(await a.encrypt(p)), 'decryptFailed');
});

for (const offset of [0, 20, -1]) {
  test(`transport: a bit flipped at offset ${offset} fails`, async () => {
    const { a, b } = await pair();
    const tampered = await a.encrypt(p);
    tampered[offset < 0 ? tampered.length + offset : offset] ^= 0x01;
    await rejectsWith(b.decrypt(tampered), 'decryptFailed');
  });
}

test('transport: the nonce 2^64 - 1 is reserved in both directions', async () => {
  const k1 = randomKey();
  const k2 = randomKey();
  const a = await createTransport({ sendKey: k1, receiveKey: k2, sendNonce: LAST_USABLE_NONCE });
  const b = await createTransport({ sendKey: k2, receiveKey: k1, receiveNonce: LAST_USABLE_NONCE });

  const last = await a.encrypt(p);
  await rejectsWith(a.encrypt(p), 'nonceExhausted');

  assert.deepEqual(await b.decrypt(last), p);
  await rejectsWith(b.decrypt(new Uint8Array(16)), 'nonceExhausted');
  // As in the daemon, the nonce is checked before the length.
  await rejectsWith(b.decrypt(new Uint8Array(15)), 'nonceExhausted');
});

test('transport: size limits, with no nonce spent on a refused message', async () => {
  const { a, b } = await pair();
  const largest = await a.encrypt(new Uint8Array(65519));
  assert.equal(largest.length, 65535);
  await rejectsWith(a.encrypt(new Uint8Array(65520)), 'messageTooLong');
  await rejectsWith(b.decrypt(new Uint8Array(65536)), 'messageTooLong');
  await rejectsWith(b.decrypt(new Uint8Array(15)), 'messageTooShort');

  assert.deepEqual(await b.decrypt(largest), new Uint8Array(65519));
  assert.deepEqual(await b.decrypt(await a.encrypt(p)), p);
});

// The loader sends each frame when its encrypt resolves, so what reaches the
// relay is the order the calls finish in. The first plaintext is much larger,
// so it would finish last if the two encrypts raced; the loop gives a race
// many chances to show.
test('transport: concurrent encrypts finish in call order with consecutive nonces', async () => {
  const { a, b } = await pair();
  const large = pattern(65000, 4);
  const small = pattern(1, 3);
  for (let i = 0; i < 20; i += 1) {
    /** @type {Uint8Array[]} */
    const sent = [];
    await Promise.all([a.encrypt(large).then((c) => sent.push(c)), a.encrypt(small).then((c) => sent.push(c))]);
    assert.deepEqual(await b.decrypt(sent[0]), large, `round ${i}: first frame sent`);
    assert.deepEqual(await b.decrypt(sent[1]), small, `round ${i}: second frame sent`);
  }
});

test('transport: concurrent decrypts finish in call order', async () => {
  const { a, b } = await pair();
  const large = pattern(65000, 5);
  const small = pattern(1, 6);
  for (let i = 0; i < 20; i += 1) {
    const c0 = await a.encrypt(large);
    const c1 = await a.encrypt(small);
    /** @type {Uint8Array[]} */
    const received = [];
    await Promise.all([b.decrypt(c0).then((d) => received.push(d)), b.decrypt(c1).then((d) => received.push(d))]);
    assert.deepEqual(
      received.map((d) => d.length),
      [large.length, small.length],
      `round ${i}: frames handled in call order`,
    );
    assert.deepEqual(received[0], large, `round ${i}: first frame handled`);
    assert.deepEqual(received[1], small, `round ${i}: second frame handled`);
  }
});

test('transport: a failed decrypt does not stall the queue', async () => {
  const { a, b } = await pair();
  const message = await a.encrypt(p);
  const tampered = message.slice();
  tampered[0] ^= 0x01;
  const failing = b.decrypt(tampered);
  const next = b.decrypt(message);
  await rejectsWith(failing, 'decryptFailed');
  assert.deepEqual(await next, p);
});

test('transport: a queued encrypt sends the bytes as they were when it was called', async () => {
  const { a, b } = await pair();
  const buffer = p0.slice();
  // The second encrypt waits behind the first, so it would read the zeros if
  // its input were not copied at the call.
  const first = a.encrypt(pattern(60000, 6));
  const second = a.encrypt(buffer);
  buffer.fill(0);
  const [c0, c1] = await Promise.all([first, second]);
  assert.deepEqual(await b.decrypt(c0), pattern(60000, 6));
  assert.deepEqual(await b.decrypt(c1), p0);
});

// An array of numbers, a string, a bare ArrayBuffer, another typed array,
// nothing, and a number (which `new Uint8Array` reads as a length).
test('transport: encrypt and decrypt reject a non-Uint8Array without spending a nonce', async () => {
  const { a, b } = await pair();
  for (const value of [[1, 2, 3], 'abc', new ArrayBuffer(32), new Uint16Array(16), null, undefined, 16]) {
    const kind = Object.prototype.toString.call(value);
    /** @type {Promise<Uint8Array> | undefined} */
    let encrypting;
    /** @type {Promise<Uint8Array> | undefined} */
    let decrypting;
    // A promise that rejects, like every other refusal, not a synchronous throw.
    assert.doesNotThrow(() => {
      encrypting = a.encrypt(/** @type {any} */ (value));
      decrypting = b.decrypt(/** @type {any} */ (value));
    }, kind);
    await assert.rejects(/** @type {Promise<Uint8Array>} */ (encrypting), TypeError, `encrypt: ${kind}`);
    await assert.rejects(/** @type {Promise<Uint8Array>} */ (decrypting), TypeError, `decrypt: ${kind}`);
  }
  // Both counters are still at 0.
  assert.deepEqual(await b.decrypt(await a.encrypt(p)), p);
});

test('transport: decrypts a view into a larger buffer', async () => {
  const { a, b } = await pair();
  const message = await a.encrypt(p);
  const backing = new Uint8Array(message.length + 2);
  backing.set(message, 1);
  assert.deepEqual(await b.decrypt(backing.subarray(1, 1 + message.length)), p);
});

test('transport: refuses a missing or wrong-size key and an out-of-range nonce', async () => {
  const key = randomKey();
  await assert.rejects(createTransport({ sendKey: key, receiveKey: new Uint8Array(16) }), RangeError);
  await assert.rejects(createTransport({ sendKey: new Uint8Array(33), receiveKey: key }), RangeError);
  await assert.rejects(
    createTransport(/** @type {any} */ ({ sendKey: key, receiveKey: null })),
    RangeError,
  );
  await assert.rejects(createTransport({ sendKey: key, receiveKey: key, sendNonce: -1n }), RangeError);
  await assert.rejects(createTransport({ sendKey: key, receiveKey: key, receiveNonce: 2n ** 64n }), RangeError);
  await assert.rejects(createTransport(/** @type {any} */ ({ sendKey: key, receiveKey: key, sendNonce: 0 })), RangeError);
});

test('transport: a transport created at the reserved nonce refuses its first message', async () => {
  const key = randomKey();
  const transport = await createTransport({
    sendKey: key,
    receiveKey: key,
    sendNonce: 2n ** 64n - 1n,
    receiveNonce: 2n ** 64n - 1n,
  });
  await rejectsWith(transport.encrypt(p), 'nonceExhausted');
  await rejectsWith(transport.decrypt(new Uint8Array(32)), 'nonceExhausted');
});
