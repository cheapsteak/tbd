// Tests limits.ts against the limits it mirrors: the loader's frame limit and size check
// (`phone/loader/channel/noise.js`, `phone/loader/protocol.js`, `sendApp` in
// `phone/loader/connection.js`) and the daemon's request limits (`PhoneAppConstants.swift`).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { MAX_PLAINTEXT_LENGTH } from '../../loader/channel/noise.js';
import { encodeMessage } from '../../loader/protocol.js';
import {
  fitsFrame, LOADER_WRAPPER_BYTES, MAX_BODY_BYTES, MAX_IN_FLIGHT, MAX_PLAINTEXT, RESEND_HORIZON_MS, utf8Length,
} from './limits.ts';

const SWIFT_CONSTANTS = new URL('../../../Sources/TBDDaemon/PhoneBridge/App/PhoneAppConstants.swift', import.meta.url);

/** The loader's own check in `sendApp`: the wrapped body, encoded, against the frame limit. */
function loaderSends(body: Record<string, unknown>): boolean {
  return encodeMessage({ type: 'app', body }).length <= MAX_PLAINTEXT_LENGTH;
}

/** UTF-8 bytes as TextEncoder makes them, independent of utf8Length. */
function encodedLength(s: string): number {
  return new TextEncoder().encode(s).length;
}

/** A seeded generator (mulberry32), so a failing sample can be reproduced. */
function random(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4_294_967_296;
  };
}

test("the app's frame limit is the loader's", () => {
  assert.equal(MAX_PLAINTEXT, MAX_PLAINTEXT_LENGTH); assert.equal(MAX_BODY_BYTES, MAX_PLAINTEXT - LOADER_WRAPPER_BYTES);
  assert.equal(MAX_BODY_BYTES, 65_497);
});

test("LOADER_WRAPPER_BYTES is what the loader's encodeMessage adds around a body", () => {
  assert.equal(encodeMessage({ type: 'app', body: {} }).length, LOADER_WRAPPER_BYTES + 2);
  const bodies: Array<Record<string, unknown>> = [
    {},
    { kind: 'request', requestID: 'r1', method: 'sessions.subscribe', params: {} },
    { text: 'héllo € 😀 "quoted" \\ \n\t\u0001   /' },
    { lone: '\ud800 \udc00 \udbff\ud800', nested: { list: [1, -0, 1.5e300, null, true, 'x'], empty: [] } },
    { [`kéy`]: 'v', n: Number.NaN, missing: undefined },
  ];
  for (const body of bodies) {
    const wrapped = encodeMessage({ type: 'app', body }).length;
    assert.equal(wrapped, LOADER_WRAPPER_BYTES + utf8Length(JSON.stringify(body)), JSON.stringify(body));
    assert.equal(wrapped, LOADER_WRAPPER_BYTES + encodedLength(JSON.stringify(body)), JSON.stringify(body));
  }
});

test('fitsFrame counts UTF-8 bytes of the body', () => {   // {"text":"…"} adds 11 bytes
  assert.equal(fitsFrame({ text: 'x'.repeat(65_486) }), true);
  assert.equal(fitsFrame({ text: 'x'.repeat(65_487) }), false);
  assert.equal(fitsFrame({ text: 'é'.repeat(32_743) }), true);
  assert.equal(fitsFrame({ text: 'é'.repeat(32_744) }), false);
});

test("fitsFrame draws the line exactly where the loader's own check does", () => {
  // Each filler costs a different number of bytes once JSON-escaped and encoded. A lone
  // surrogate costs 6: JSON.stringify writes it as a \uXXXX escape before any encoder sees it.
  const fillers = ['x', 'é', '€', '😀', '"', '\\', '\n', '\u0001', '\u007f', ' ', '\ud800', '\udfff'];
  const empty = encodedLength(JSON.stringify({ text: '' }));
  for (const filler of fillers) {
    const per = encodedLength(JSON.stringify(filler)) - 2;
    const count = Math.floor((MAX_BODY_BYTES - empty) / per);
    const rest = MAX_BODY_BYTES - empty - count * per;
    const full = { text: filler.repeat(count) + 'x'.repeat(rest) };
    assert.equal(encodeMessage({ type: 'app', body: full }).length, MAX_PLAINTEXT_LENGTH, `${JSON.stringify(filler)} fills the frame`);
    for (const body of [full, { text: full.text + 'x' }, { text: full.text + filler }, { text: full.text.slice(0, -1) }]) {
      assert.equal(fitsFrame(body), loaderSends(body), `${JSON.stringify(filler)}, ${encodeMessage({ type: 'app', body }).length} bytes wrapped`);
    }
    assert.equal(fitsFrame(full), true);
    assert.equal(fitsFrame({ text: full.text + 'x' }), false);
  }
});

test('fitsFrame agrees with the loader on random bodies near the limit', () => {
  const next = random(0x7bd);
  // The two surrogate halves pair up into one 4-byte scalar wherever they land side by side.
  const pool = ['a', 'é', '€', '😀', '"', '\n', '\u0000', '\ud83d', '\ude00', ' '];
  const cost = new Map(pool.map((piece) => [piece, encodedLength(JSON.stringify(piece)) - 2]));
  const empty = encodedLength(JSON.stringify({ text: '' }));
  for (let i = 0; i < 100; i++) {
    const target = MAX_BODY_BYTES - 64 + Math.floor(next() * 128);
    const pieces: string[] = [];
    // An upper bound: a pair that forms costs less than its two halves did apart.
    let bound = empty;
    while (bound < target - 16) {
      const piece = pool[Math.floor(next() * pool.length)] ?? 'a';
      pieces.push(piece);
      bound += cost.get(piece) ?? 0;
    }
    let text = pieces.join('');
    text += 'x'.repeat(target - encodedLength(JSON.stringify({ text })));
    const body = { text };
    assert.equal(encodedLength(JSON.stringify(body)), target, `sample ${i} is ${target} bytes`);
    assert.equal(fitsFrame(body), target <= MAX_BODY_BYTES, `sample ${i}, ${target} bytes`);
    assert.equal(fitsFrame(body), loaderSends(body), `sample ${i}, ${target} bytes`);
  }
});

test('utf8Length counts what TextEncoder encodes, lone surrogates as 3-byte U+FFFD', () => {
  const edges = [
    '', 'a', '\u0000', '\u007f', '\u0080', '߿', 'ࠀ', '�', '￿', '퟿', '',
    '😀', '𐀀', '􏿿',
    '\ud800', '\udbff', '\udc00', '\udfff', '\udc00\ud800', '\ud800\ud800', 'a\ud800', '\ud800a', '\ud800𐀀',
  ];
  for (const s of edges) assert.equal(utf8Length(s), encodedLength(s), JSON.stringify(s));
  assert.equal(utf8Length('\ud800'), 3);
  assert.equal(utf8Length('😀'), 4);

  const next = random(0x5eed);
  for (let i = 0; i < 2_000; i++) {
    const units: number[] = [];
    const length = Math.floor(next() * 12);
    for (let j = 0; j < length; j++) {
      // Half the units are surrogates, so pairs, lone halves and reversed pairs all come up.
      units.push(next() < 0.5 ? 0xd800 + Math.floor(next() * 0x800) : Math.floor(next() * 0x10000));
    }
    const s = String.fromCharCode(...units);
    assert.equal(utf8Length(s), encodedLength(s), JSON.stringify(s));
  }
});

test('a body JSON cannot encode never fits, as the loader reports it tooLarge', () => {
  const cycle: Record<string, unknown> = {}; cycle.self = cycle;
  assert.equal(fitsFrame(cycle), false);
  assert.equal(fitsFrame({ n: 1n }), false);
  assert.equal(fitsFrame({ toJSON: () => undefined }), false);
});

test("the request limits mirror the daemon's", () => {
  const swift = readFileSync(SWIFT_CONSTANTS, 'utf8');
  const value = (pattern: RegExp): number => {
    const digits = pattern.exec(swift)?.[1];
    if (digits === undefined) throw new Error(`PhoneAppConstants.swift has no match for ${pattern}`);
    return Number(digits.replaceAll('_', ''));
  };
  assert.equal(MAX_IN_FLIGHT, value(/static let requestsInFlightPerDevice = ([\d_]+)/));
  assert.equal(LOADER_WRAPPER_BYTES, value(/static let loaderWrapperBytes = ([\d_]+)/));
  const memoryMs = value(/static let requestMemory: Duration = \.seconds\(([\d_]+)\)/) * 1_000;
  assert.equal(RESEND_HORIZON_MS, 540_000);
  assert.ok(RESEND_HORIZON_MS < memoryMs, 'a resend lands while the daemon still remembers the request');
});
