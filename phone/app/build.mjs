// Builds the phone app bundle the daemon serves, `Sources/TBDDaemon/Resources/phone-app/app.js`,
// from the placeholder app in this folder.
//
//   node app/build.mjs              (`npm run build:app` in phone/) writes the bundle
//   node app/build.mjs --out FILE   writes it to FILE instead; the app's tests use this
//
// The bundle is a fixed banner followed by `placeholder.js`, byte for byte. Nothing else goes in:
// no clock, no environment, no network and no dependency, so every run writes the same bytes. It
// writes that one file and nothing else, because the `phone-app` CI job
// (`scripts/ci/phone-app-bundle-check.sh`) runs this build and fails on any file in the bundle's
// folder that differs from the committed one, an added one included.

import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SOURCE = new URL('placeholder.js', import.meta.url);
const BUNDLE = new URL('../../Sources/TBDDaemon/Resources/phone-app/app.js', import.meta.url);
const BANNER = '// Built by `npm run build:app` in phone/ from phone/app/placeholder.js. Edit that file and\n'
  + '// rebuild: CI fails while this one differs from what the build writes.\n';
const USAGE = 'usage: node app/build.mjs [--out FILE]';

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

const out = outputPath(process.argv.slice(2));
if (out === null) {
  process.stderr.write(`${USAGE}\n`);
  process.exitCode = 64;
} else {
  writeFileSync(out, Buffer.concat([Buffer.from(BANNER, 'utf8'), readFileSync(SOURCE)]));
}
