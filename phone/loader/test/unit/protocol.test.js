import { test } from 'node:test';
import assert from 'node:assert/strict';

import { base64urlEncode } from '../../channel/pairingLink.js';
import { LOADER_VERSION, MAX_BUNDLE_COMPRESSED } from '../../constants.js';
import {
  ProtocolError, checkCompat, decodeMessage, encodeMessage, makeHello, parseLaptopMessage,
} from '../../protocol.js';

const HASH = 'ab'.repeat(32);
const ROOM = base64urlEncode(Uint8Array.from({ length: 32 }, (_, i) => i)); // ends in 8
const WELCOME = { type: 'welcome', protocol: 1, minProtocol: 1, tbdVersion: '0.9.0', bundle: { sha256: HASH, size: 1234 } };
const CHUNK = { type: 'bundle.chunk', sha256: HASH, index: 0, count: 3, data: 'QUJD' };

/** @param {unknown} value */
const bytes = (value) => new TextEncoder().encode(typeof value === 'string' ? value : JSON.stringify(value));

/**
 * @param {unknown} message
 * @param {string} reason
 */
function rejects(message, reason) {
  assert.throws(() => parseLaptopMessage(message), (error) => {
    assert.ok(error instanceof ProtocolError, JSON.stringify(message));
    assert.equal(error.reason, reason, JSON.stringify(message));
    return true;
  });
}

test('hello', () => {
  assert.deepEqual(makeHello(), { type: 'hello', loaderVersion: LOADER_VERSION, protocols: [1] });
  // A fresh list each time: a caller changing one cannot change the next.
  const hello = makeHello();
  hello.protocols.push(2);
  assert.deepEqual(makeHello().protocols, [1]);
});

test('encode and decode round-trip', () => {
  const message = { type: 'bundle.get', sha256: HASH, note: 'é😀' };
  assert.deepEqual(encodeMessage(message), bytes(message));
  assert.deepEqual(decodeMessage(encodeMessage(message)), message);
});

test('decodeMessage rejects what is not one JSON object with a string type', () => {
  /** @type {Array<[Uint8Array, string]>} */
  const cases = [
    [bytes('[1]'), 'notObject'],
    [bytes('"x"'), 'notObject'],
    [bytes('null'), 'notObject'],
    [bytes('7'), 'notObject'],
    [bytes('{}'), 'type'],
    [bytes('{"type":1}'), 'type'],
    [bytes('{"type":null}'), 'type'],
    [bytes('{"type":"a"'), 'json'],
    [bytes(''), 'json'],
    [Uint8Array.of(0xff), 'utf8'],
    [Uint8Array.of(0x7b, 0x22, 0xc3, 0x28, 0x22, 0x7d), 'utf8'], // {"<bad 2-byte>"}
  ];
  for (const [input, reason] of cases) {
    assert.throws(() => decodeMessage(input), { name: 'ProtocolError', reason }, reason);
  }
});

test('each index example parses to exactly its fields', () => {
  /** @type {object[]} */
  const examples = [
    WELCOME,
    { type: 'incompatible', tooOld: 'laptop' },
    { type: 'incompatible', tooOld: 'loader' },
    CHUNK,
    { type: 'app', body: { kind: 'event', event: 'sessions.changed', seq: 1, data: {} } },
    { type: 'revoked' },
    { type: 'paired', room: ROOM },
    { type: 'pairDenied', reason: 'denied' },
    { type: 'pairDenied', reason: 'expired' },
  ];
  for (const example of examples) {
    assert.deepEqual(parseLaptopMessage(decodeMessage(bytes(example))), example);
  }
});

test('fields that were not validated never come through', () => {
  /** @type {Array<[object, object]>} */
  const cases = [
    [{ ...WELCOME, extra: 1, bundle: { ...WELCOME.bundle, url: 'https://acme.example' } }, WELCOME],
    [{ type: 'incompatible', tooOld: 'laptop', extra: 1 }, { type: 'incompatible', tooOld: 'laptop' }],
    [{ ...CHUNK, extra: 1 }, CHUNK],
    [{ type: 'app', body: { a: 1 }, extra: 1 }, { type: 'app', body: { a: 1 } }],
    [{ type: 'revoked', extra: 1 }, { type: 'revoked' }],
    [{ type: 'paired', room: ROOM, extra: 1 }, { type: 'paired', room: ROOM }],
    [{ type: 'pairDenied', reason: 'denied', extra: 1 }, { type: 'pairDenied', reason: 'denied' }],
    [{ type: 'later.thing', extra: 1 }, { type: 'unknown' }],
  ];
  for (const [input, expected] of cases) {
    assert.deepEqual(parseLaptopMessage(input), expected);
  }
  // A copied bundle object, not the laptop's.
  const input = structuredClone(WELCOME);
  const parsed = /** @type {any} */ (parseLaptopMessage(input));
  assert.notEqual(parsed.bundle, input.bundle);
});

test('unknown types are unknown, whatever their name', () => {
  for (const type of ['later.thing', 'hello', 'bundle.get', 'constructor', '__proto__', 'toString', 'hasOwnProperty', '', 'WELCOME', 'welcome ']) {
    assert.deepEqual(parseLaptopMessage(JSON.parse(`{"type":${JSON.stringify(type)},"protocol":"x"}`)), { type: 'unknown' }, type);
  }
});

test('a message that is not an object with a string type is refused', () => {
  for (const value of [null, undefined, 1, 'welcome', [WELCOME]]) {
    assert.throws(() => parseLaptopMessage(value), { name: 'ProtocolError', reason: 'notObject' });
  }
  for (const value of [{}, { type: 1 }, { type: ['welcome'] }]) {
    assert.throws(() => parseLaptopMessage(value), { name: 'ProtocolError', reason: 'type' });
  }
});

test('welcome field rules', () => {
  for (const protocol of [0, -1, 1.5, '1', null, true, undefined]) rejects({ ...WELCOME, protocol }, 'welcome.protocol');
  for (const minProtocol of [0, -1, 1.5, '1', null, undefined]) rejects({ ...WELCOME, minProtocol }, 'welcome.minProtocol');
  for (const tbdVersion of ['', 'x'.repeat(65), '😀'.repeat(65), 1, null, undefined]) rejects({ ...WELCOME, tbdVersion }, 'welcome.tbdVersion');
  assert.equal(/** @type {any} */ (parseLaptopMessage({ ...WELCOME, tbdVersion: 'x'.repeat(64) })).tbdVersion.length, 64);
  assert.equal(/** @type {any} */ (parseLaptopMessage({ ...WELCOME, tbdVersion: '😀'.repeat(64) })).tbdVersion.length, 128);
  for (const bundle of [null, undefined, [], 'x', 1]) rejects({ ...WELCOME, bundle }, 'welcome.bundle');
  for (const sha256 of ['AB'.repeat(32), 'ab'.repeat(31), 'ab'.repeat(33), 'g'.repeat(64), ` ${'a'.repeat(63)}`, `${'a'.repeat(64)}\n`, 1, undefined]) {
    rejects({ ...WELCOME, bundle: { sha256, size: 1 } }, 'welcome.bundle.sha256');
  }
  for (const size of [0, -1, 1.5, MAX_BUNDLE_COMPRESSED + 1, '1', null, undefined]) {
    rejects({ ...WELCOME, bundle: { sha256: HASH, size } }, 'welcome.bundle.size');
  }
  for (const size of [1, MAX_BUNDLE_COMPRESSED]) {
    assert.equal(/** @type {any} */ (parseLaptopMessage({ ...WELCOME, bundle: { sha256: HASH, size } })).bundle.size, size);
  }
});

test('incompatible, chunk, app and pairDenied field rules', () => {
  for (const tooOld of ['phone', 'Laptop', '', null, undefined]) rejects({ type: 'incompatible', tooOld }, 'incompatible.tooOld');

  for (const sha256 of ['AB'.repeat(32), 'ab'.repeat(31), null]) rejects({ ...CHUNK, sha256 }, 'bundle.chunk.sha256');
  for (const index of [-1, 0.5, '0', null, undefined]) rejects({ ...CHUNK, index }, 'bundle.chunk.index');
  for (const count of [0, -1, 1.5, '3', null, undefined]) rejects({ ...CHUNK, count }, 'bundle.chunk.count');
  rejects({ ...CHUNK, index: 3, count: 3 }, 'bundle.chunk.index');
  rejects({ ...CHUNK, index: 4, count: 3 }, 'bundle.chunk.index');
  assert.equal(/** @type {any} */ (parseLaptopMessage({ ...CHUNK, index: 2, count: 3 })).index, 2);
  for (const data of [1, null, undefined, ['QUJD']]) rejects({ ...CHUNK, data }, 'bundle.chunk.data');

  for (const body of [null, undefined, [], [1], 'x', 1, true]) rejects({ type: 'app', body }, 'app.body');

  for (const reason of ['allowed', 'Denied', '', null, undefined]) rejects({ type: 'pairDenied', reason }, 'pairDenied.reason');
});

test('paired carries a room ID', () => {
  assert.deepEqual(parseLaptopMessage({ type: 'paired', room: ROOM }), { type: 'paired', room: ROOM });
  assert.equal(ROOM.at(-1), '8');
  const bad = [
    undefined, // missing
    ROOM.slice(0, 42),
    ROOM + 'A',
    '+' + ROOM.slice(1),
    ROOM.slice(0, 42) + '9', // non-zero spare bits
    ROOM.slice(0, 42) + '=',
    42,
    null,
    [ROOM],
  ];
  for (const room of bad) rejects({ type: 'paired', room }, 'paired.room');
  rejects({ type: 'paired' }, 'paired.room');
});

test('compatibility', () => {
  assert.equal(checkCompat({ protocol: 1, minProtocol: 1 }), 'ok');
  assert.equal(checkCompat({ protocol: 2, minProtocol: 1 }), 'loaderTooOld');
  assert.equal(checkCompat({ protocol: 1, minProtocol: 2 }), 'loaderTooOld');
  assert.equal(checkCompat({ protocol: 0, minProtocol: 1 }), 'loaderTooOld');
});
