// Tests `npm run build:app` (build.mjs): that it writes the committed bundle byte for byte on
// every run, writes nothing else, and refuses arguments it does not know. Each run writes into a
// fresh temporary directory through `--out`, never into the checkout. The `phone-app` CI job
// (scripts/ci/phone-app-bundle-check.sh) checks the default output path, by running the build in
// the checkout and comparing the bundle's folder with the committed one.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const BUILD = fileURLToPath(new URL('build.mjs', import.meta.url));
const SOURCE = new URL('placeholder.js', import.meta.url);
const BUNDLE = new URL('../../Sources/TBDDaemon/Resources/phone-app/app.js', import.meta.url);

/**
 * Runs build.mjs with `args` and returns its exit status and stderr.
 * @param {string[]} args
 */
function build(args) {
  const result = spawnSync(process.execPath, [BUILD, ...args], { encoding: 'utf8' });
  return { status: result.status, stderr: result.stderr };
}

/**
 * Calls `body` with a fresh temporary directory, and removes the directory afterwards.
 * @param {(dir: string) => void} body
 */
function inTempDir(body) {
  const dir = mkdtempSync(join(tmpdir(), 'tbd-phone-app-build-'));
  try {
    body(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test('build:app writes the committed bundle, byte for byte, on every run', () => {
  const committed = readFileSync(BUNDLE);
  inTempDir((dir) => {
    const first = join(dir, 'first.js');
    const second = join(dir, 'second.js');
    assert.equal(build(['--out', first]).status, 0);
    assert.equal(build(['--out', second]).status, 0);
    assert.deepEqual(readdirSync(dir).sort(), ['first.js', 'second.js'], 'one file per run, nothing else');
    assert.ok(readFileSync(first).equals(committed), 'the committed app.js is what build:app writes; run it and commit');
    assert.ok(readFileSync(second).equals(committed), 'a second run writes the same bytes');
  });
});

test('the bundle is placeholder.js unchanged, after a comment that names it', () => {
  const bundle = readFileSync(BUNDLE);
  const source = readFileSync(SOURCE);
  assert.ok(bundle.length > source.length);
  assert.ok(bundle.subarray(bundle.length - source.length).equals(source), 'the bundle ends with placeholder.js');
  const banner = bundle.subarray(0, bundle.length - source.length).toString('utf8');
  assert.ok(banner.includes('phone/app/placeholder.js'), 'the banner names the source');
  for (const line of banner.split('\n').slice(0, -1)) {
    assert.ok(line.startsWith('// '), `banner line is a comment: ${line}`);
  }
  assert.ok(banner.endsWith('\n'));
});

test('build.mjs refuses arguments it does not know, and writes nothing', () => {
  inTempDir((dir) => {
    for (const args of [['--bogus'], ['--out'], ['--out', ''], ['--out', join(dir, 'a.js'), 'extra']]) {
      const { status, stderr } = build(args);
      assert.equal(status, 64, `exit status for ${JSON.stringify(args)}`);
      assert.match(stderr, /^usage: node app\/build\.mjs \[--out FILE\]$/m);
    }
    assert.deepEqual(readdirSync(dir), []);
  });
});
