import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import { confirmationCode } from './confirm.js';

const file = JSON.parse(readFileSync(new URL('../../test-vectors/confirmation-code.json', import.meta.url), 'utf8'));
/** @param {string} hex */
const fromHex = (hex) => new Uint8Array(Buffer.from(hex, 'hex'));

test('confirmation code: shared vectors', async () => {
  assert.equal(file.cases.length, 7);
  for (const c of file.cases) {
    assert.equal(await confirmationCode(fromHex(c.handshakeHash)), c.code, c.description);
  }
});

test('confirmation code: the cacophony IKpsk2 handshake hash gives 801003', async () => {
  const hash = fromHex('48c3f1eb397c797af6b139032c6074cb41282ff033ee25d5aee4a4badd3a2c3f');
  assert.equal(await confirmationCode(hash), '801003');
});

test('confirmation code: a hash that is a view into a larger buffer', async () => {
  const backing = new Uint8Array(40);
  backing.set(fromHex(`0000002a${'11'.repeat(28)}`), 5);
  assert.equal(await confirmationCode(backing.subarray(5, 37)), '000042');
});

test('confirmation code: rejects a hash that is not 32 bytes', async () => {
  await assert.rejects(confirmationCode(new Uint8Array(31)), RangeError);
  await assert.rejects(confirmationCode(new Uint8Array(33)), RangeError);
});

// Some of these would give a code if read as bytes: a Uint16Array or a
// Uint8ClampedArray of 32 elements has a 4-byte view at its start.
test('confirmation code: rejects a hash that is not a Uint8Array with a TypeError', async () => {
  const notBytes = [
    new Uint16Array(32),
    new Uint8ClampedArray(32),
    new DataView(new ArrayBuffer(32)),
    new ArrayBuffer(32),
    Array.from({ length: 32 }, () => 7),
    'x'.repeat(32),
    null,
    undefined,
    32,
  ];
  for (const value of notBytes) {
    const kind = Object.prototype.toString.call(value);
    await assert.rejects(
      confirmationCode(value),
      (/** @type {unknown} */ error) => error instanceof TypeError && /Uint8Array/.test(error.message),
      kind,
    );
  }
  // A Node Buffer is a Uint8Array, so it is accepted.
  assert.equal(await confirmationCode(Buffer.alloc(32)), '000000');
});
