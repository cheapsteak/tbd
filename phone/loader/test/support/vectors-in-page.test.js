import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import * as noise from '../../channel/noise.js';
import * as confirm from '../../channel/confirm.js';
import * as pairingLink from '../../channel/pairingLink.js';
import { runChannelVectors } from './vectors-in-page.js';

const NAMES = ['noise-cacophony.json', 'framing.json', 'confirmation-code.json', 'pairing-link.json'];

/** A fresh parsed copy of the four vector files, keyed by name, for one test to change. */
const readFiles = () => Object.fromEntries(NAMES.map((name) => [
  name,
  JSON.parse(readFileSync(new URL(`../../../test-vectors/${name}`, import.meta.url), 'utf8')),
]));

/**
 * The number of cases in the files, counted here and not by the runner.
 * @param {Record<string, any>} files
 */
function expectedCount(files) {
  const framing = files['framing.json'];
  const link = files['pairing-link.json'];
  return 2 + framing.messages.length + 1 + files['confirmation-code.json'].cases.length
    + link.base64url.valid.length + link.base64url.invalid.length + link.valid.length + link.invalid.length;
}

/** @param {Record<string, any>} files */
const run = (files) => runChannelVectors({ noise, confirm, pairingLink, files });

/**
 * The text with one hex digit changed to another hex digit.
 * @param {string} text
 * @param {number} [index]
 */
const flipDigit = (text, index = 0) => `${text.slice(0, index)}${text[index] === '0' ? '1' : '0'}${text.slice(index + 1)}`;

/**
 * Runs the files and expects exactly one failure, whose text starts with `name` (a case's
 * label and index, or its whole name), and every case still counted.
 * @param {Record<string, any>} files
 * @param {string} name
 */
async function expectOneFailure(files, name) {
  const { failures, checked } = await run(files);
  assert.equal(failures.length, 1, `expected one failure, got:\n${failures.join('\n')}`);
  assert.ok(failures[0].startsWith(name), failures[0]);
  assert.equal(checked, expectedCount(files));
  return failures[0];
}

test('every vector passes and every case is counted', async () => {
  const files = readFiles();
  const { failures, checked } = await run(files);
  assert.deepEqual(failures, []);
  assert.equal(checked, expectedCount(files));
});

test('a corrupted framing ciphertext is reported', async () => {
  const files = readFiles();
  const m = files['framing.json'].messages[2];
  m.ciphertext = flipDigit(m.ciphertext);
  const failure = await expectOneFailure(files, `framing.json messages[2] (nonce ${m.nonce}): `);
  assert.match(failure, /encrypt is [0-9a-f]+, expected [0-9a-f]+/);
});

test('a corrupted confirmation code is reported', async () => {
  const files = readFiles();
  const c = files['confirmation-code.json'].cases[1];
  c.code = `${c.code.slice(0, 5)}${(Number(c.code[5]) + 1) % 10}`;
  const failure = await expectOneFailure(files, `confirmation-code.json cases[1] (${c.description}): `);
  assert.match(failure, /code is "\d{6}", expected "\d{6}"/);
});

test('an invalid pairing link that parses is reported', async () => {
  const files = readFiles();
  const link = files['pairing-link.json'];
  const c = link.invalid[0];
  c.url = link.valid[0].url;
  const failure = await expectOneFailure(files, `pairing-link.json invalid[0] (${c.description}): `);
  assert.match(failure, new RegExp(`parsed .*, expected ${c.error}$`));
});

// Every other kind of case, broken in one place, so no part of the runner passes vacuously.
/** @type {Array<[string, string, (files: Record<string, any>) => void]>} */
const BREAKAGES = [
  ['cacophony message 1', 'noise-cacophony.json vectors[0]', (files) => {
    const m = files['noise-cacophony.json'].vectors[0].messages[0];
    m.ciphertext = flipDigit(m.ciphertext, 70);
  }],
  ['cacophony message 2 payload', 'noise-cacophony.json vectors[1]', (files) => {
    const m = files['noise-cacophony.json'].vectors[1].messages[1];
    m.payload = flipDigit(m.payload);
  }],
  ['cacophony handshake hash', 'noise-cacophony.json vectors[0]', (files) => {
    const v = files['noise-cacophony.json'].vectors[0];
    v.handshake_hash = flipDigit(v.handshake_hash);
  }],
  ['cacophony transport message 5', 'noise-cacophony.json vectors[1]', (files) => {
    const m = files['noise-cacophony.json'].vectors[1].messages[5];
    m.payload = flipDigit(m.payload);
  }],
  ['prologue', 'framing.json prologue', (files) => {
    const p = files['framing.json'].prologue;
    p.prologue = flipDigit(p.prologue, p.prologue.length - 1);
  }],
  ['base64url valid text', 'pairing-link.json base64url.valid[1]', (files) => {
    const c = files['pairing-link.json'].base64url.valid[1];
    c.hex = flipDigit(c.hex);
  }],
  ['base64url invalid text that decodes', 'pairing-link.json base64url.invalid[0]', (files) => {
    files['pairing-link.json'].base64url.invalid[0] = 'AA';
  }],
  ['valid pairing link', 'pairing-link.json valid[0]', (files) => {
    files['pairing-link.json'].valid[0].link.name = 'Someone else';
  }],
  ['invalid pairing link with another code', 'pairing-link.json invalid[0]', (files) => {
    files['pairing-link.json'].invalid[0].error = 'badJSON';
  }],
];

for (const [what, name, breakIt] of BREAKAGES) {
  test(`a broken ${what} is reported`, async () => {
    const files = readFiles();
    breakIt(files);
    await expectOneFailure(files, name);
  });
}

test('a missing vector list is reported and counts nothing', async () => {
  const files = readFiles();
  const removed = files['pairing-link.json'].base64url.invalid.length;
  delete files['pairing-link.json'].base64url.invalid;
  const { failures, checked } = await run(files);
  assert.deepEqual(failures, ['pairing-link.json base64url.invalid: not a list']);
  files['pairing-link.json'].base64url.invalid = [];
  assert.equal(checked, expectedCount(files));
  assert.ok(removed > 0);
});
