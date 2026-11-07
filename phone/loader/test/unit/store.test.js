import { test } from 'node:test';
import assert from 'node:assert/strict';

import { base64urlDecode, base64urlEncode } from '../../channel/pairingLink.js';
import { MAX_BUNDLE_COMPRESSED, MAX_BUNDLE_TEXT } from '../../constants.js';
import { bundlesToPrune, laptopIDFromKey, validateBundleRecord, validateLaptopRecord } from '../../store.js';

/** @param {number} length */
const random = (length) => crypto.getRandomValues(new Uint8Array(length));

/**
 * @param {string} laptopID
 * @param {string} sha256
 * @param {number} usedAt
 */
const b = (laptopID, sha256, usedAt) => ({ laptopID, sha256, usedAt });

const laptopKey = random(32);
/** @type {import('../../types.js').LaptopRecord} */
const good = {
  id: laptopIDFromKey(laptopKey),
  relay: 'https://acme-relay.acme.workers.dev',
  room: base64urlEncode(random(32)),
  laptopKey,
  laptopName: 'acme-laptop',
  phoneName: "Ada's iPhone",
  phoneKey: random(32),
  wrappedKey: random(64),
  wrapIV: random(12),
  pairedAt: 1_800_000_000_000,
  lastConnectedAt: null,
};

const goodBundle = {
  laptopID: good.id, sha256: 'ab'.repeat(32), text: 'globalThis.app = 1;\n', size: 20, usedAt: 1_800_000_000_000,
};

test('bundlesToPrune keeps the two most recently used per laptop', () => {
  const r = [b('A', 'aa', 5), b('A', 'bb', 9), b('A', 'cc', 7), b('B', 'dd', 1)];
  assert.deepEqual(bundlesToPrune(r, 'A'), [['A', 'aa']]);
  assert.deepEqual(bundlesToPrune([b('A', 'bb', 5), b('A', 'aa', 5), b('A', 'cc', 5)], 'A'), [['A', 'cc']]);
});

test('bundlesToPrune reads only that laptop, honors keep and never reorders its input', () => {
  const r = [b('A', 'aa', 5), b('A', 'bb', 9), b('A', 'cc', 7), b('B', 'dd', 1), b('B', 'ee', 2), b('B', 'ff', 3)];
  const before = structuredClone(r);
  assert.deepEqual(bundlesToPrune(r, 'B'), [['B', 'dd']]);
  assert.deepEqual(bundlesToPrune(r, 'C'), []);
  assert.deepEqual(bundlesToPrune(r, 'A', 0), [['A', 'bb'], ['A', 'cc'], ['A', 'aa']]);
  assert.deepEqual(bundlesToPrune(r, 'A', 1), [['A', 'cc'], ['A', 'aa']]);
  assert.deepEqual(bundlesToPrune(r, 'A', 3), []);
  assert.deepEqual(bundlesToPrune([], 'A'), []);
  assert.deepEqual(r, before);
  for (const keep of [-1, 1.5, NaN, Infinity]) assert.throws(() => bundlesToPrune(r, 'A', keep), RangeError);
});

test('bundlesToPrune counts a usedAt that is not a finite number as least recently used', () => {
  const r = [b('A', 'aa', NaN), b('A', 'bb', 1), b('A', 'cc', /** @type {any} */ (undefined)), b('A', 'dd', 2)];
  assert.deepEqual(bundlesToPrune(r, 'A'), [['A', 'aa'], ['A', 'cc']]);
  assert.deepEqual(bundlesToPrune(r, 'A', 3), [['A', 'cc']]);
});

test('validateLaptopRecord rejects wrong shapes', () => {
  assert.throws(() => validateLaptopRecord({ ...good, laptopKey: new Uint8Array(31) }));
  assert.throws(() => validateLaptopRecord({ ...good, phoneKey: new Uint8Array(33) }));
  assert.throws(() => validateLaptopRecord({ ...good, room: 'x' }));
  assert.throws(() => validateLaptopRecord({ ...good, wrapIV: new Uint8Array(16) }));
  assert.throws(() => validateLaptopRecord({ ...good, id: laptopIDFromKey(new Uint8Array(32)) })); // id must match laptopKey
  assert.deepEqual(validateLaptopRecord(good), good);
});

test('validateLaptopRecord checks the type and size of every field, with a TypeError', () => {
  const room = good.room;
  /** @type {Array<[string, unknown]>} */
  const bad = [
    ['id', undefined], ['id', `${good.id}=`], ['id', good.id.slice(0, 42)], ['id', base64urlEncode(laptopKey).toUpperCase()],
    ['room', undefined], ['room', room.slice(0, 42)], ['room', `${room.slice(0, 42)}+`], ['room', base64urlDecode(room)],
    ['relay', undefined], ['relay', 42], ['relay', 'http://acme.example'], ['relay', 'https://acme.example/relay'],
    ['relay', 'https://user@acme.example'], ['relay', 'wss://acme.example'], ['relay', 'acme.example'], ['relay', ''],
    ['laptopKey', undefined], ['laptopKey', new Uint8Array(33)], ['laptopKey', Array.from(laptopKey)], ['laptopKey', laptopKey.buffer],
    ['phoneKey', undefined], ['phoneKey', new Uint8Array(31)], ['phoneKey', Array.from(good.phoneKey)],
    ['wrappedKey', undefined], ['wrappedKey', new Uint8Array(0)], ['wrappedKey', 'AAAA'],
    ['wrapIV', undefined], ['wrapIV', new Uint8Array(11)], ['wrapIV', new Uint16Array(12)],
    ['laptopName', undefined], ['laptopName', null], ['laptopName', 42],
    ['phoneName', undefined], ['phoneName', null], ['phoneName', ['iPhone']],
    ['pairedAt', undefined], ['pairedAt', null], ['pairedAt', NaN], ['pairedAt', Infinity], ['pairedAt', '1800000000000'],
    ['lastConnectedAt', undefined], ['lastConnectedAt', NaN], ['lastConnectedAt', -Infinity], ['lastConnectedAt', '1'],
  ];
  for (const [field, value] of bad) {
    assert.throws(() => validateLaptopRecord({ ...good, [field]: value }), TypeError, `${field}: ${String(value)}`);
  }
  for (const value of [null, undefined, 42, 'record', [good], () => good]) {
    assert.throws(() => validateLaptopRecord(value), TypeError, String(value));
  }
  // The relay accepts what relaySocketURL accepts, loopback cleartext included.
  for (const relay of ['https://acme-relay.acme.workers.dev/', 'https://acme.example:8443', 'http://127.0.0.1:8787', 'http://localhost:8787']) {
    assert.equal(validateLaptopRecord({ ...good, relay }).relay, relay);
  }
  assert.equal(validateLaptopRecord({ ...good, lastConnectedAt: 0 }).lastConnectedAt, 0);
  assert.equal(validateLaptopRecord({ ...good, laptopName: '', phoneName: '' }).laptopName, '');
});

test('validateLaptopRecord returns a fresh record with only its fields, its bytes copied', () => {
  const out = validateLaptopRecord({ ...good, extra: 'dropped', wrapKey: 'dropped' });
  assert.deepEqual(out, good);
  assert.deepEqual(Object.keys(out).sort(), Object.keys(good).sort());
  for (const field of /** @type {const} */ (['laptopKey', 'phoneKey', 'wrappedKey', 'wrapIV'])) {
    assert.notEqual(out[field], good[field], field);
    assert.notEqual(out[field].buffer, good[field].buffer, field);
  }
  out.laptopKey[0] ^= 1;
  assert.notEqual(out.laptopKey[0], good.laptopKey[0]);
  // A Uint8Array subclass, such as a Buffer, comes back as a plain Uint8Array.
  const fromBuffer = validateLaptopRecord({ ...good, wrappedKey: Buffer.from(good.wrappedKey) });
  assert.equal(Object.getPrototypeOf(fromBuffer.wrappedKey), Uint8Array.prototype);
});

test('laptopIDFromKey is 43 base64url characters', () => {
  for (const key of [random(32), new Uint8Array(32), new Uint8Array(32).fill(0xff)]) {
    const id = laptopIDFromKey(key);
    assert.match(id, /^[A-Za-z0-9_-]{43}$/);
    assert.equal(id, base64urlEncode(key));
    assert.deepEqual(base64urlDecode(id), key);
  }
  for (const bad of [new Uint8Array(31), new Uint8Array(33), Array.from(random(32)), 'key', undefined]) {
    assert.throws(() => laptopIDFromKey(/** @type {any} */ (bad)), TypeError);
  }
});

test('validateBundleRecord checks every field and returns only them', () => {
  assert.deepEqual(validateBundleRecord({ ...goodBundle, extra: 1 }), goodBundle);
  assert.deepEqual(validateBundleRecord({ ...goodBundle, text: '', size: MAX_BUNDLE_COMPRESSED }).size, MAX_BUNDLE_COMPRESSED);
  /** @type {Array<[string, unknown]>} */
  const bad = [
    ['laptopID', undefined], ['laptopID', 'A'], ['laptopID', `${good.id}=`], ['laptopID', 42],
    ['sha256', undefined], ['sha256', 'AB'.repeat(32)], ['sha256', 'ab'.repeat(31)], ['sha256', 'ab'.repeat(33)],
    ['text', undefined], ['text', 42], ['text', 'a'.repeat(MAX_BUNDLE_TEXT + 1)],
    ['size', undefined], ['size', 0], ['size', 1.5], ['size', MAX_BUNDLE_COMPRESSED + 1], ['size', '20'],
    ['usedAt', undefined], ['usedAt', null], ['usedAt', NaN], ['usedAt', Infinity], ['usedAt', '1'],
  ];
  for (const [field, value] of bad) {
    assert.throws(() => validateBundleRecord({ ...goodBundle, [field]: value }), TypeError, `${field}: ${String(value)}`);
  }
  for (const value of [null, undefined, 'bundle', [goodBundle]]) {
    assert.throws(() => validateBundleRecord(value), TypeError);
  }
});
