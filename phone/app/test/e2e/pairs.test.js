// pairs.mjs, run as the coordinator runs it, against the mocks' real screenshots and stand-in
// built shots in a temporary folder.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.join(HERE, 'pairs.mjs');
const MOCKS = path.resolve(HERE, '../../../../docs/design/phone-control/screenshots');
const NO_MOCK_TEXT = 'No mock: a new state.';

/**
 * Runs pairs.mjs with `args` and returns its exit code and output.
 * @param {string[]} args
 * @returns {Promise<{ code: number, stdout: string, stderr: string }>}
 */
function run(args) {
  return new Promise((resolve) => {
    execFile(process.execPath, [SCRIPT, ...args], (error, stdout, stderr) => {
      resolve({ code: error === null ? 0 : Number(error.code), stdout, stderr });
    });
  });
}

/**
 * A temporary folder with `built/<scheme>/<state>.png` for each of `shots` (`scheme/state`),
 * each holding bytes that name it, and an empty `out`.
 * @param {import('node:test').TestContext} t
 * @param {string[]} shots
 */
function workspace(t, shots) {
  const dir = mkdtempSync(path.join(tmpdir(), 'tbd-pairs-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const built = path.join(dir, 'built');
  for (const shot of shots) {
    const file = path.join(built, `${shot}.png`);
    mkdirSync(path.dirname(file), { recursive: true });
    writeFileSync(file, `built ${shot}`);
  }
  return { dir, built, out: path.join(dir, 'out') };
}

/** Each `.pair` row of the page, as `state/scheme`. */
function rowsOf(html) {
  return [...html.matchAll(/<div class="pair" data-state="([^"]+)" data-scheme="([^"]+)">/g)].map((m) => `${m[1]}/${m[2]}`);
}

test('built shots beside the mocks give one row per state and scheme, with every file beside the page', async (t) => {
  const { built, out } = workspace(t, ['light/sessions', 'dark/sessions', 'light/reconnect', 'dark/reconnect']);
  const result = await run(['--built', built, '--out', out, 'sessions', 'reconnect']);
  assert.equal(result.code, 0, result.stderr);

  const html = readFileSync(path.join(out, 'index.html'), 'utf8');
  assert.match(html, /<title>Phone app pairs<\/title>/);
  assert.deepEqual(rowsOf(html), ['sessions/light', 'sessions/dark', 'reconnect/light', 'reconnect/dark']);
  assert.ok(!html.includes(NO_MOCK_TEXT));

  // Every picture the page shows is in the folder, by a relative path, and is the source's bytes.
  const sources = [...html.matchAll(/<img src="([^"]+)"/g)].map((m) => m[1]);
  assert.equal(sources.length, 8);
  for (const src of sources) {
    assert.ok(!src.startsWith('/') && !src.includes('..') && !src.includes(':'), `${src} is relative`);
    const [kind, scheme, file] = src.split('/');
    const from = kind === 'mock' ? path.join(MOCKS, scheme, file) : path.join(built, scheme, file);
    assert.deepEqual(readFileSync(path.join(out, src)), readFileSync(from), src);
  }
  assert.ok(sources.includes('mock/dark/sessions.webp'));
  assert.ok(sources.includes('built/light/reconnect.png'));
});

test('a missing built shot exits 1, names it, and writes nothing', async (t) => {
  const { built, out } = workspace(t, ['light/sessions', 'dark/sessions', 'light/reconnect']);
  const result = await run(['--built', built, '--out', out, 'sessions', 'reconnect']);
  assert.equal(result.code, 1);
  assert.match(result.stderr, /reconnect: no built dark screenshot at .*dark[/\\]reconnect\.png/);
  assert.doesNotMatch(result.stderr, /sessions:/);
  assert.equal(existsSync(out), false);
});

test('a state with no mock exits 1 and names the missing mock, unless --no-mock shows the built shot alone', async (t) => {
  const { built, out } = workspace(t, ['light/sessions', 'dark/sessions', 'light/loading', 'dark/loading']);

  const refused = await run(['--built', built, '--out', out, 'sessions', 'loading']);
  assert.equal(refused.code, 1);
  assert.match(refused.stderr, /loading: no mock light screenshot at .*light[/\\]loading\.webp \(pass --no-mock loading for a new state\)/);
  assert.equal(existsSync(out), false);

  const result = await run(['--built', built, '--out', out, '--no-mock', 'loading', 'sessions', 'loading']);
  assert.equal(result.code, 0, result.stderr);
  const html = readFileSync(path.join(out, 'index.html'), 'utf8');
  assert.deepEqual(rowsOf(html), ['sessions/light', 'sessions/dark', 'loading/light', 'loading/dark']);
  const loading = html.slice(html.indexOf('<section id="loading">'));
  assert.equal(loading.split(NO_MOCK_TEXT).length - 1, 2, 'the words once in each scheme');
  assert.ok(loading.includes('<img src="built/light/loading.png"'));
  assert.ok(!loading.includes('mock/'));
  assert.equal(existsSync(path.join(out, 'mock', 'light', 'loading.webp')), false);
  assert.ok(existsSync(path.join(out, 'built', 'dark', 'loading.png')));
});

test('--no-mock still needs the built shots, and refuses a state the mocks have', async (t) => {
  const { built, out } = workspace(t, ['light/loading', 'light/sessions', 'dark/sessions']);
  const missing = await run(['--built', built, '--out', out, '--no-mock', 'loading', 'loading']);
  assert.equal(missing.code, 1);
  assert.match(missing.stderr, /loading: no built dark screenshot at /);

  const hasMock = await run(['--built', built, '--out', out, '--no-mock', 'sessions', 'sessions']);
  assert.equal(hasMock.code, 1);
  assert.match(hasMock.stderr, /sessions: the mocks have it .*so it cannot be --no-mock/);
  assert.equal(existsSync(out), false);
});

test('a usage mistake exits 2', async (t) => {
  const { built, out } = workspace(t, []);
  for (const args of [
    ['--out', out, 'sessions'],
    ['--built', built, '--out', out],
    ['--built', built, '--out', out, '--fast', 'sessions'],
    ['--built', built, '--out', out, '../sessions'],
    ['--built', built, '--out', out, '--no-mock', 'loading', 'sessions'],
  ]) {
    const result = await run(args);
    assert.equal(result.code, 2, args.join(' '));
    assert.match(result.stderr, /^pairs: .*\nusage: /);
  }
});
