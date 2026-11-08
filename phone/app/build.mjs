// Builds the phone app bundle the daemon serves, `Sources/TBDDaemon/Resources/phone-app/app.js`,
// from the app's sources in `phone/app/src` (docs/specs/2026-11-07-phone-control-design.md,
// section 9).
//
//   node app/build.mjs              (`npm run build:app` in phone/) writes the bundle
//   node app/build.mjs --out FILE   writes it to FILE instead; the app's tests use this
//
// esbuild bundles `src/main.tsx` and the libraries it imports into one minified classic script:
// the runner starts the bundle from a `<script src>` with no `type="module"`
// (`phone/loader/runner.js`). The `phone-app` CI job (`scripts/ci/phone-app-bundle-check.sh`)
// rebuilds it on Linux, in another checkout, and fails on any byte that differs from the
// committed file, so the build must write the same bytes on every machine, from every directory,
// at every time:
// - esbuild resolves everything from `absWorkingDir`, which is this folder whatever the current
//   directory is, and the licence notices it gathers name their files relative to it;
// - nothing reads the clock, the environment or the host, and there is no source map;
// - the libraries are the exact versions the lockfile pins.
//
// It writes that one file and nothing else, because the same check fails on any file in the
// bundle's folder that differs from the committed one, an added one included.

import { build } from 'esbuild';
import { writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/** The bundle's first line. The daemon's test (`PhoneAppBundleTests`) checks that it is there. */
export const BANNER =
  '/* TBD phone app. Built by `npm run build:app` in phone/ from phone/app/src; CI fails while this file differs from that build. */';

/** The most bytes the bundle may take gzipped at level 9. `build.test.js` holds the bundle to it. */
export const GZIP_BUDGET = 163_840;

const APP = fileURLToPath(new URL('.', import.meta.url));
const BUNDLE = new URL('../../Sources/TBDDaemon/Resources/phone-app/app.js', import.meta.url);
const USAGE = 'usage: node app/build.mjs [--out FILE]';

/** @type {import('esbuild').BuildOptions} */
const OPTIONS = {
  entryPoints: ['src/main.tsx'],
  absWorkingDir: APP,
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: ['safari17'],
  minify: true,
  jsx: 'automatic',
  loader: { '.css': 'text' },
  define: { 'process.env.NODE_ENV': '"production"' },
  legalComments: 'eof',
  charset: 'utf8',
  sourcemap: false,
  write: false,
  banner: { js: BANNER },
  logLevel: 'warning',
};

/**
 * The output path the arguments name, or null when they are not `[]` or `['--out', FILE]`.
 * @param {string[]} args
 * @returns {string | null}
 */
function outputPath(args) {
  if (args.length === 0) return fileURLToPath(BUNDLE);
  if (args.length === 2 && args[0] === '--out' && args[1] !== '') return resolve(args[1]);
  return null;
}

/**
 * The bundle's text: esbuild's one output file, ending in exactly one newline.
 * @returns {Promise<string>}
 */
async function bundleText() {
  const result = await build(OPTIONS);
  const files = result.outputFiles ?? [];
  if (files.length !== 1) throw new Error(`esbuild made ${files.length} output files; the bundle must be one`);
  return `${files[0].text.replace(/\n*$/, '')}\n`;
}

/** @param {string[]} args */
async function main(args) {
  const out = outputPath(args);
  if (out === null) {
    process.stderr.write(`${USAGE}\n`);
    process.exitCode = 64;
    return;
  }
  try {
    writeFileSync(out, await bundleText());
  } catch (error) {
    // esbuild prints its own errors at logLevel 'warning'; anything else is printed here.
    const fromEsbuild = typeof error === 'object' && error !== null && Array.isArray(/** @type {any} */ (error).errors);
    if (!fromEsbuild) process.stderr.write(`${error instanceof Error ? error.stack : String(error)}\n`);
    process.exitCode = 1;
  }
}

// Run as a script, it builds; imported, as `build.test.js` imports it, it only gives its constants.
if (import.meta.main) await main(process.argv.slice(2));
