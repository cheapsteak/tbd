import { test } from 'node:test';
import assert from 'node:assert/strict';

import { base64urlDecode, base64urlEncode } from '../../channel/pairingLink.js';
import { DB_NAME, DB_VERSION, MAX_BUNDLE_COMPRESSED, MAX_BUNDLE_TEXT } from '../../constants.js';
import { createPhoneKeyPair, createWrapKey } from '../../keys.js';
import {
  DamagedRecordError, StoreBlockedError, bundleCacheDeletions, bundleFromRows, bundlesToPrune, laptopFromRow,
  laptopIDFromKey, openStore, readLaptopRows, touchedLaptop, validateBundleRecord, validateLaptopRecord,
} from '../../store.js';

const subtle = globalThis.crypto.subtle;
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
  wrapKey: await createWrapKey(subtle),
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

test('validateLaptopRecord checks the type and size of every field, with a TypeError', async () => {
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
    ['wrapKey', undefined], ['wrapKey', null], ['wrapKey', random(32)],
    ['wrapKey', await subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['wrapKey', 'unwrapKey'])],
    ['wrapKey', await subtle.generateKey({ name: 'AES-GCM', length: 128 }, false, ['wrapKey', 'unwrapKey'])],
    ['wrapKey', await subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt'])],
    ['wrapKey', await subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['wrapKey', 'unwrapKey', 'decrypt'])],
    ['wrapKey', await subtle.generateKey({ name: 'AES-KW', length: 256 }, false, ['wrapKey', 'unwrapKey'])],
    ['wrapKey', (await createPhoneKeyPair(subtle)).pair.privateKey],
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
  const out = validateLaptopRecord({ ...good, extra: 'dropped', futureField: 'dropped' });
  assert.deepEqual(out, good);
  assert.deepEqual(Object.keys(out).sort(), Object.keys(good).sort());
  // A CryptoKey cannot be copied, and needs no copy: it is immutable.
  assert.equal(out.wrapKey, good.wrapKey);
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

// ---- Laptop rows ----

/**
 * A second good laptop record.
 * @returns {Promise<import('../../types.js').LaptopRecord>}
 */
async function anotherLaptop() {
  const key = random(32);
  return { ...good, id: laptopIDFromKey(key), laptopKey: key, laptopName: 'acme-desktop', wrapKey: await createWrapKey(subtle) };
}

/**
 * @param {() => unknown} fn
 * @param {{ key: unknown, laptopName: string | null, cause?: (cause: unknown) => boolean }} expected
 */
function throwsDamaged(fn, expected) {
  assert.throws(fn, (error) => {
    assert.ok(error instanceof DamagedRecordError, String(error));
    assert.equal(error.name, 'DamagedRecordError');
    assert.equal(error.key, expected.key);
    assert.equal(error.laptopName, expected.laptopName);
    assert.notEqual(error.cause, undefined);
    if (expected.cause) assert.ok(expected.cause(error.cause), String(error.cause));
    return true;
  });
}

test('laptopFromRow returns the validated record stored under its own id', () => {
  assert.deepEqual(laptopFromRow(good.id, { ...good, futureField: 1 }), good);
});

test('laptopFromRow throws DamagedRecordError with the key and any stored name for a damaged row', () => {
  throwsDamaged(() => laptopFromRow(good.id, { ...good, wrapIV: new Uint8Array(3) }),
    { key: good.id, laptopName: 'acme-laptop', cause: (cause) => cause instanceof TypeError });
  throwsDamaged(() => laptopFromRow(good.id, { ...good, wrapKey: undefined }), { key: good.id, laptopName: 'acme-laptop' });
  // A good record under another key is damaged too: its key is what Forget deletes.
  throwsDamaged(() => laptopFromRow('other', good), { key: 'other', laptopName: 'acme-laptop' });
  throwsDamaged(() => laptopFromRow(7, good), { key: 7, laptopName: 'acme-laptop' });
  throwsDamaged(() => laptopFromRow(good.id, { ...good, laptopName: 42 }), { key: good.id, laptopName: null });
  for (const value of [undefined, null, 'record', 42, [good]]) {
    throwsDamaged(() => laptopFromRow(good.id, value), { key: good.id, laptopName: null });
  }
  // A row that could not be read at all.
  const unreadable = new DOMException('could not read the value', 'DataError');
  throwsDamaged(() => laptopFromRow(good.id, undefined, unreadable), { key: good.id, laptopName: null, cause: (cause) => cause === unreadable });
  throwsDamaged(() => laptopFromRow(good.id, good, unreadable), { key: good.id, laptopName: 'acme-laptop', cause: (cause) => cause === unreadable });
});

test('readLaptopRows keeps the good records and lists the damaged ones, in order, so none blocks another', async () => {
  const other = await anotherLaptop();
  const { laptops, damaged } = readLaptopRows([
    { key: good.id, value: good },
    { key: 'bad-1', value: { ...good, id: 'bad-1', room: 'x' } },
    { key: other.id, value: other },
    { key: 'bad-2', value: undefined, error: new DOMException('could not read the value', 'DataError') },
    { key: 3, value: { laptopName: 'acme-old' } },
  ]);
  assert.deepEqual(laptops, [good, other]);
  assert.deepEqual(damaged, [
    { key: 'bad-1', laptopName: 'acme-laptop' },
    { key: 'bad-2', laptopName: null },
    { key: 3, laptopName: 'acme-old' },
  ]);
  assert.deepEqual(readLaptopRows([]), { laptops: [], damaged: [] });
});

test('touchedLaptop keeps every stored field, those it does not know included, and sets the two it updates', () => {
  const stored = { ...good, futureField: { nested: [1, 2] } };
  const before = { ...stored };
  const next = touchedLaptop(good.id, stored, { lastConnectedAt: 1_800_000_500_000, laptopName: 'acme-renamed' });
  assert.deepEqual(next, { ...before, lastConnectedAt: 1_800_000_500_000, laptopName: 'acme-renamed' });
  assert.equal(next.wrapKey, good.wrapKey);
  assert.equal(next.futureField, stored.futureField);
  assert.deepEqual(stored, before, 'the stored value is not changed');
});

test('touchedLaptop refuses a damaged stored row and an update the record cannot take', () => {
  const update = { lastConnectedAt: 1, laptopName: 'acme-laptop' };
  throwsDamaged(() => touchedLaptop(good.id, { ...good, phoneKey: new Uint8Array(1) }, update), { key: good.id, laptopName: 'acme-laptop' });
  throwsDamaged(() => touchedLaptop('other', good, update), { key: 'other', laptopName: 'acme-laptop' });
  for (const bad of [
    { lastConnectedAt: NaN, laptopName: 'acme-laptop' },
    { lastConnectedAt: '1', laptopName: 'acme-laptop' },
    { lastConnectedAt: undefined, laptopName: 'acme-laptop' },
    { lastConnectedAt: 1, laptopName: 42 },
    { lastConnectedAt: 1, laptopName: undefined },
  ]) {
    assert.throws(() => touchedLaptop(good.id, good, /** @type {any} */ (bad)), TypeError, JSON.stringify(bad));
  }
});

test('DamagedRecordError carries the key, the name and the cause', () => {
  const cause = new TypeError('x');
  const error = new DamagedRecordError(['a', 1], null, cause);
  assert.ok(error instanceof Error);
  assert.deepEqual([error.name, error.key, error.laptopName, error.cause], ['DamagedRecordError', ['a', 1], null, cause]);
});

// ---- Bundle rows ----

const SHA = /** @param {string} c */ (c) => c.repeat(64);
const textRow = { laptopID: good.id, sha256: SHA('a'), text: 'globalThis.app = 1;\n' };
const metaRow = { laptopID: good.id, sha256: SHA('a'), size: 20, usedAt: 1_800_000_000_000 };

test('bundleFromRows joins the text and meta rows into a BundleRecord with only its fields', () => {
  assert.deepEqual(bundleFromRows(good.id, SHA('a'), { ...textRow, extra: 1 }, { ...metaRow, extra: 2 }), {
    laptopID: good.id, sha256: SHA('a'), text: textRow.text, size: 20, usedAt: 1_800_000_000_000,
  });
});

test('bundleFromRows is null for a missing, damaged or mismatched row, never a throw', () => {
  const otherID = laptopIDFromKey(random(32));
  /** @type {Array<[string, unknown, unknown]>} */
  const cases = [
    ['no text row', undefined, metaRow],
    ['no meta row', textRow, undefined],
    ['neither', undefined, undefined],
    ['text not a string', { ...textRow, text: 42 }, metaRow],
    ['text too long', { ...textRow, text: 'a'.repeat(MAX_BUNDLE_TEXT + 1) }, metaRow],
    ['text row not an object', 'text', metaRow],
    ['usedAt NaN', textRow, { ...metaRow, usedAt: NaN }],
    ['size 0', textRow, { ...metaRow, size: 0 }],
    ['meta row null', textRow, null],
    ['text row for another laptop', { ...textRow, laptopID: otherID }, metaRow],
    ['text row for another bundle', { ...textRow, sha256: SHA('b') }, metaRow],
    ['meta row for another laptop', textRow, { ...metaRow, laptopID: otherID }],
    ['meta row for another bundle', textRow, { ...metaRow, sha256: SHA('b') }],
  ];
  for (const [name, text, meta] of cases) {
    assert.equal(bundleFromRows(good.id, SHA('a'), text, meta), null, name);
  }
  // Rows that match each other but not the key asked for.
  assert.equal(bundleFromRows(good.id, SHA('b'), textRow, metaRow), null);
  assert.equal(bundleFromRows(otherID, SHA('a'), textRow, metaRow), null);
});

/**
 * A bundleMeta row as read.
 * @param {string} sha256
 * @param {number} usedAt
 * @param {string} [laptopID]
 */
const meta = (sha256, usedAt, laptopID = good.id) => ({ key: [laptopID, sha256], value: { laptopID, sha256, size: 10, usedAt } });
/** @param {string} sha256 */
const key = (sha256) => [good.id, sha256];

test('bundleCacheDeletions keeps the bundle just written and the most recently used other, in both stores', () => {
  const rows = [meta(SHA('1'), 5), meta(SHA('2'), 9), meta(SHA('3'), 7), meta(SHA('4'), 1)];
  const texts = [key(SHA('1')), key(SHA('2')), key(SHA('3')), key(SHA('4'))];
  // SHA('4') was just written, with the oldest usedAt (a clock set back): it is still kept.
  assert.deepEqual(bundleCacheDeletions(good.id, SHA('4'), rows, texts), {
    meta: [key(SHA('1')), key(SHA('3'))],
    text: [key(SHA('1')), key(SHA('3'))],
  });
  // Ties go to the lower sha256.
  const tied = [meta(SHA('c'), 5), meta(SHA('b'), 5), meta(SHA('d'), 1)];
  assert.deepEqual(bundleCacheDeletions(good.id, SHA('d'), tied, tied.map((row) => row.key)).meta, [key(SHA('c'))]);
  // Nothing to prune.
  const two = [meta(SHA('1'), 5), meta(SHA('2'), 9)];
  assert.deepEqual(bundleCacheDeletions(good.id, SHA('2'), two, two.map((row) => row.key)), { meta: [], text: [] });
});

test('bundleCacheDeletions deletes damaged and unreadable meta rows and text rows with no kept meta row', () => {
  const rows = [
    meta(SHA('1'), 5),
    { key: key(SHA('2')), value: { ...meta(SHA('2'), 9).value, usedAt: 'soon' } },        // damaged
    { key: key(SHA('3')), value: undefined, error: new DOMException('x', 'DataError') }, // unreadable
    { key: key(SHA('5')), value: meta(SHA('6'), 99).value },                              // not its key
    meta(SHA('4'), 1),
  ];
  // SHA('7') has text but no meta row; SHA('1') has both and stays.
  const texts = [key(SHA('1')), key(SHA('2')), key(SHA('3')), key(SHA('4')), key(SHA('7'))];
  assert.deepEqual(bundleCacheDeletions(good.id, SHA('4'), rows, texts), {
    meta: [key(SHA('2')), key(SHA('3')), key(SHA('5'))],
    text: [key(SHA('2')), key(SHA('3')), key(SHA('7'))],
  });
});

// ---- openStore ----

/**
 * A scripted IDBFactory that stands in for the open request only: it records the schema an
 * upgrade creates, and lets a test fire the open and connection events. No data sits behind
 * it; the IndexedDB methods are covered by the Playwright suite.
 */
function scriptedFactory() {
  /** @type {any[]} */
  const opens = [];
  const factory = {
    /**
     * @param {string} name
     * @param {number} version
     */
    open(name, version) {
      /** @type {any[]} */
      const created = [];
      const db = {
        closed: false,
        /** @type {any} */ onversionchange: null,
        /** @type {any} */ onclose: null,
        close() { this.closed = true; },
        /**
         * @param {string} storeName
         * @param {object} options
         */
        createObjectStore(storeName, options) {
          /** @type {Array<[string, string]>} */
          const indexes = [];
          created.push({ name: storeName, options, indexes });
          return { createIndex: (/** @type {string} */ index, /** @type {string} */ path) => { indexes.push([index, path]); } };
        },
      };
      /** @type {any} */
      const request = { result: db, error: null, onupgradeneeded: null, onsuccess: null, onerror: null, onblocked: null };
      opens.push({ name, version, request, db, created });
      return request;
    },
  };
  return { factory: /** @type {any} */ (factory), opens };
}

/** Opens a store through a scripted factory, upgrading from nothing. */
async function scriptedStore() {
  const { factory, opens } = scriptedFactory();
  const opening = openStore(factory);
  const [{ request, db, created, name, version }] = opens;
  request.onupgradeneeded({ oldVersion: 0, newVersion: version });
  request.onsuccess();
  return { store: await opening, db, created, name, version };
}

test('openStore creates the laptops, bundles and bundleMeta stores, and nothing else', async () => {
  const { created, name, version } = await scriptedStore();
  assert.equal(name, DB_NAME);
  assert.equal(version, DB_VERSION);
  assert.deepEqual(created, [
    { name: 'laptops', options: { keyPath: 'id' }, indexes: [] },
    { name: 'bundles', options: { keyPath: ['laptopID', 'sha256'] }, indexes: [['byLaptop', 'laptopID']] },
    { name: 'bundleMeta', options: { keyPath: ['laptopID', 'sha256'] }, indexes: [['byLaptop', 'laptopID']] },
  ]);
});

test('onClosed fires once, after the connection is closed, when another tab needs to upgrade', async () => {
  const { store, db } = await scriptedStore();
  /** @type {Array<[string, boolean]>} */
  const calls = [];
  store.onClosed = (reason) => calls.push([reason, db.closed]);
  assert.equal(store.closed, null);
  db.onversionchange({ oldVersion: 1, newVersion: 2 });
  assert.deepEqual(calls, [['versionchange', true]]);
  assert.equal(store.closed, 'versionchange');
  db.onclose();
  db.onversionchange({ oldVersion: 1, newVersion: 3 });
  assert.deepEqual(calls, [['versionchange', true]]);
});

test('onClosed fires once when the browser closes the connection', async () => {
  const { store, db } = await scriptedStore();
  /** @type {string[]} */
  const calls = [];
  store.onClosed = (reason) => calls.push(reason);
  db.onclose();
  db.onclose();
  assert.deepEqual(calls, ['close']);
  assert.equal(store.closed, 'close');
  assert.equal(db.closed, false, 'the browser closed it; the store does not close it again');
});

test('a store closed before anyone listened still says so', async () => {
  const { store, db } = await scriptedStore();
  db.onversionchange({ oldVersion: 1, newVersion: 2 });
  assert.equal(store.closed, 'versionchange');
  assert.equal(db.closed, true);
});

test('a blocked open rejects StoreBlockedError, and closes a connection that opens later', async () => {
  const { factory, opens } = scriptedFactory();
  const opening = openStore(factory);
  opens[0].request.onblocked();
  await assert.rejects(opening, StoreBlockedError);
  opens[0].request.onsuccess();
  assert.equal(opens[0].db.closed, true);
});

test('a failed open rejects with its error, and so does a factory that throws', async () => {
  const { factory, opens } = scriptedFactory();
  const opening = openStore(factory);
  const error = new DOMException('no storage', 'UnknownError');
  opens[0].request.error = error;
  opens[0].request.onerror();
  await assert.rejects(opening, (thrown) => thrown === error);
  const denied = new DOMException('denied', 'SecurityError');
  await assert.rejects(openStore(/** @type {any} */ ({ open() { throw denied; } })), (thrown) => thrown === denied);
});
