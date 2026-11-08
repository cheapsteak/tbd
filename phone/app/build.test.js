// Tests `npm run build:app` (build.mjs) and the bundle it writes: that every run writes the
// committed bundle byte for byte, from any directory, writes nothing else, keeps no trace of the
// machine it ran on, and refuses arguments it does not know; and that the bundle is one classic
// script within the loader's limit and the size budget, which makes no code from strings. Each
// run writes into a fresh temporary directory through `--out`, never into the checkout. The
// `phone-app` CI job (scripts/ci/phone-app-bundle-check.sh) checks the default output path, by
// running the build in the checkout and comparing the bundle's folder with the committed one.
//
// What the bundle does once it runs is the end-to-end tests' job (app/test/e2e/), which start it
// under the real runner, its policy and Trusted Types.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { gzipSync } from 'node:zlib';

import { MAX_BUNDLE_TEXT } from '../loader/constants.js';
import { BANNER, GZIP_BUDGET } from './build.mjs';

const BUILD = fileURLToPath(new URL('build.mjs', import.meta.url));
// Outside phone/: the classifier's `Sources/TBDDaemon/Resources/phone-app/*` route
// (scripts/ci/phone-parts-needed.sh) runs these tests when it changes.
const BUNDLE = new URL('../../Sources/TBDDaemon/Resources/phone-app/app.js', import.meta.url);
/** `phone/`, where `npm run build:app` runs. */
const PHONE = fileURLToPath(new URL('../', import.meta.url));

/**
 * Runs build.mjs with `args`, from `cwd`, and returns its exit status and stderr.
 * @param {string[]} args
 * @param {string} [cwd]
 */
function build(args, cwd = PHONE) {
  const result = spawnSync(process.execPath, [BUILD, ...args], { cwd, encoding: 'utf8' });
  return { status: result.status, stderr: result.stderr };
}

/**
 * Calls `body` with a fresh temporary directory, and removes the directory afterwards.
 * @template T
 * @param {(dir: string) => T} body
 * @returns {T}
 */
function inTempDir(body) {
  const dir = mkdtempSync(join(tmpdir(), 'tbd-phone-app-build-'));
  try {
    return body(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/**
 * Builds into a fresh directory from `cwd`, and returns the bytes and what the directory holds.
 * @param {string} [cwd]
 */
function buildOnce(cwd) {
  return inTempDir((dir) => {
    const out = join(dir, 'app.js');
    const { status, stderr } = build(['--out', out], cwd);
    assert.equal(status, 0, `build.mjs failed:\n${stderr}`);
    return { bytes: readFileSync(out), files: readdirSync(dir) };
  });
}

/** The first build, shared by the tests that need only one. */
let first = /** @type {ReturnType<typeof buildOnce> | null} */ (null);
function firstBuild() {
  first ??= buildOnce();
  return first;
}

/**
 * A path with no trailing separator, as it would appear inside a longer one.
 * @param {string} path
 */
function bare(path) {
  return path.replace(/[\\/]+$/, '');
}

test('two builds write the same bytes', () => {
  assert.ok(firstBuild().bytes.equals(buildOnce().bytes));
});

test('a build from another directory writes the same bytes', () => {
  inTempDir((cwd) => assert.ok(buildOnce(cwd).bytes.equals(firstBuild().bytes), `built from ${cwd}`));
});

test('a build writes exactly one file', () => {
  assert.deepEqual(firstBuild().files, ['app.js']);
});

test('the committed bundle is what the build writes', () => {
  assert.ok(firstBuild().bytes.equals(readFileSync(BUNDLE)), 'the committed app.js is not what build:app writes; run it in phone/ and commit');
});

test('the bundle names no path of the machine that built it', () => {
  const text = firstBuild().bytes.toString('utf8');
  const paths = {
    'phone/app': fileURLToPath(new URL('./', import.meta.url)),
    'the repository': fileURLToPath(new URL('../../', import.meta.url)),
    'the current directory': process.cwd(),
    'the home directory': homedir(),
  };
  for (const [name, path] of Object.entries(paths)) {
    // A root directory leaves nothing to look for.
    if (bare(path) === '') continue;
    assert.equal(text.includes(bare(path)), false, `the bundle holds the path of ${name}, ${path}`);
  }
});

test('the bundle is one classic script that starts with the banner', () => {
  const text = readFileSync(BUNDLE, 'utf8');
  assert.ok(text.startsWith(`${BANNER}\n`));
  // The runner starts it from a `<script src>` with no `type="module"`, where an `import` or
  // `export` statement is a syntax error. `vm.Script` parses it the same way.
  assert.doesNotThrow(() => new vm.Script(text, { filename: 'app.js' }));
  assert.equal(text.includes('sourceMappingURL'), false);
  assert.ok(text.endsWith('\n') && !text.endsWith('\n\n'), 'the bundle ends in one newline');
});

test("the bundle is UTF-8 within the loader's limit and the size budget", () => {
  const bytes = readFileSync(BUNDLE);
  // The loader decodes the inflated bundle exactly this way, and refuses it when this throws.
  assert.doesNotThrow(() => new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes));
  assert.ok(bytes.length <= MAX_BUNDLE_TEXT, `${bytes.length} bytes is over MAX_BUNDLE_TEXT`);
  const gzipped = gzipSync(bytes, { level: 9 }).length;
  assert.ok(gzipped <= GZIP_BUDGET, `${gzipped} bytes gzipped is over the ${GZIP_BUDGET}-byte budget`);
});

test('the bundle makes no code from strings', () => {
  // The runner's policy has no 'unsafe-eval', so either would throw there.
  const text = readFileSync(BUNDLE, 'utf8');
  assert.doesNotMatch(text, /\beval\s*\(/);
  assert.doesNotMatch(text, /\bFunction\s*\(/);
});

test('with no tbdHost, the bundle throws before it draws anything', () => {
  // A throw at the bundle's top level is what the runner reports as `fault: 'script'`. The
  // context has no `document`, so a bundle that reached for it first would fail with a
  // ReferenceError instead, and it refuses code made from strings, as the runner's policy does.
  const context = vm.createContext({}, { codeGeneration: { strings: false, wasm: false } });
  const text = readFileSync(BUNDLE, 'utf8');
  assert.throws(() => new vm.Script(text, { filename: 'app.js' }).runInContext(context), (error) => {
    assert.equal(/** @type {Error} */ (error).message, 'TBD phone app: no tbdHost with protocol 1');
    return true;
  });
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
