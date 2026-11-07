import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import { PairingLinkError, base64urlDecode, base64urlEncode, parsePairingLink } from './pairingLink.js';

const file = JSON.parse(readFileSync(new URL('../../test-vectors/pairing-link.json', import.meta.url), 'utf8'));
const nowMs = file.now * 1000;
/** @param {string} hex */
const fromHex = (hex) => new Uint8Array(Buffer.from(hex, 'hex'));

test('base64url: shared valid vectors encode and decode', () => {
  assert.equal(file.base64url.valid.length, 5);
  for (const c of file.base64url.valid) {
    assert.equal(base64urlEncode(fromHex(c.hex)), c.text, c.text);
    assert.deepEqual(base64urlDecode(c.text), fromHex(c.hex), c.text);
  }
});

test('base64url: shared invalid vectors decode to null', () => {
  assert.equal(file.base64url.invalid.length, 7);
  for (const text of file.base64url.invalid) {
    assert.equal(base64urlDecode(text), null, JSON.stringify(text));
  }
});

test('base64url: 300,000 bytes round-trip without overflowing the stack', () => {
  const bytes = Uint8Array.from({ length: 300_000 }, (_, i) => (i * 31 + 7) & 0xff);
  const text = base64urlEncode(bytes);
  assert.equal(text.length, 400_000);
  assert.deepEqual(base64urlDecode(text), bytes);
});

test('pairing link: URL parsing leaves every vector fragment unchanged', () => {
  for (const c of [...file.valid, ...file.invalid]) {
    const hashIndex = c.url.indexOf('#');
    if (hashIndex !== -1) {
      assert.equal(new URL(c.url).hash, c.url.slice(hashIndex), c.description);
    }
  }
});

test('pairing link: shared valid vectors parse', () => {
  assert.equal(file.valid.length, 3);
  for (const c of file.valid) {
    assert.deepEqual(parsePairingLink(c.url, { now: nowMs }), c.link, c.description);
  }
});

test('pairing link: shared invalid vectors fail with their code and field', () => {
  assert.equal(file.invalid.length, 20);
  for (const c of file.invalid) {
    // c.field is undefined unless the code is badField, so this also checks
    // that other errors carry no field.
    assert.throws(
      () => parsePairingLink(c.url, { now: nowMs }),
      { name: 'PairingLinkError', code: c.error, field: c.field },
      c.description,
    );
  }
});

test('pairing link: a pasted link with surrounding whitespace parses', () => {
  const [v1] = file.valid;
  assert.deepEqual(parsePairingLink(`  ${v1.url}\n`, { now: nowMs }), v1.link);
  // The URL parser strips ASCII spaces itself; a no-break space needs trim().
  assert.deepEqual(parsePairingLink(` ${v1.url} `, { now: nowMs }), v1.link);
});

test('pairing link: a URL object parses like its text', () => {
  const [v1] = file.valid;
  assert.deepEqual(parsePairingLink(new URL(v1.url), { now: nowMs }), v1.link);
});

test('pairing link: expires at exp, to the millisecond', () => {
  const [v1] = file.valid;
  const expMs = v1.link.exp * 1000;
  assert.deepEqual(parsePairingLink(v1.url, { now: expMs - 1 }), v1.link);
  assert.throws(() => parsePairingLink(v1.url, { now: expMs }), { code: 'expired' });
});

test('pairing link: invalid UTF-8 inside a JSON string is badJSON', () => {
  // The fffe7b7d vector fails JSON.parse even when decoded leniently, so
  // only a bad byte inside a string shows that decoding is strict.
  const [v1] = file.valid;
  const [before, after] = JSON.stringify({ ...v1.link, name: 'NAME' }).split('NAME');
  /** @param {number} nameByte */
  const linkWithName = (nameByte) => {
    const encoder = new TextEncoder();
    const json = Uint8Array.from([...encoder.encode(before), nameByte, ...encoder.encode(after)]);
    return `${file.loaderURL}#p=${base64urlEncode(json)}`;
  };
  assert.deepEqual(parsePairingLink(linkWithName(0x78), { now: nowMs }), { ...v1.link, name: 'x' });
  assert.throws(() => parsePairingLink(linkWithName(0xff), { now: nowMs }), { code: 'badJSON' });
});

test('pairing link: a JSON value that is not an object is badJSON', () => {
  for (const json of ['null', '1', '"v"', 'true']) {
    const url = `${file.loaderURL}#p=${base64urlEncode(new TextEncoder().encode(json))}`;
    assert.throws(() => parsePairingLink(url, { now: nowMs }), { name: 'PairingLinkError', code: 'badJSON' }, json);
  }
});

test('pairing link: errors are PairingLinkError instances', () => {
  assert.throws(() => parsePairingLink('not a url', { now: nowMs }), PairingLinkError);
});
