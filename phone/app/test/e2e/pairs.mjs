// Builds the side-by-side page a phone screen PR shows (spec section 16, and "Proof" in
// docs/design/phone-control/README.md): for each state, in light and dark, the mock's
// screenshot beside the built app's, both 195 px wide.
//
//   node app/test/e2e/pairs.mjs --built <dir> --out <dir> [--mocks <dir>] [--no-mock <state>]… <state>…
//
// - `--built`: the end-to-end screenshots, `<built>/<scheme>/<state>.png` (`capture` in
//   fixtures.js writes them to app/test/e2e/screenshots/).
// - `--mocks`: the mocks' screenshots, `<mocks>/<scheme>/<state>.webp`. By default
//   docs/design/phone-control/screenshots/.
// - `--no-mock <state>`: a state the mocks do not have, such as a new error screen. The page
//   shows its built shot alone, beside the words "No mock: a new state.". A state named this way
//   must be listed too, and must have no mock: one that has a mock is compared with it.
//
// It writes `<out>/index.html`, `<out>/mock/<scheme>/<state>.webp` and
// `<out>/built/<scheme>/<state>.png`. The page uses relative paths only, so the folder stands
// alone. When any state lacks an image it needs, it names each one, writes nothing, and exits 1.
// A usage mistake exits 2. Node only.

import { copyFile, mkdir, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_MOCKS = path.resolve(HERE, '../../../../docs/design/phone-control/screenshots');
const SCHEMES = /** @type {const} */ (['light', 'dark']);
const STATE_NAME = /^[a-z0-9][a-z0-9-]*$/;
export const NO_MOCK_TEXT = 'No mock: a new state.';

const USAGE = 'usage: node pairs.mjs --built <dir> --out <dir> [--mocks <dir>] [--no-mock <state>]... <state>...';

/** A usage mistake. */
class UsageError extends Error {}

/**
 * @param {string[]} argv the arguments after the script
 * @returns {{ built: string, out: string, mocks: string, noMock: Set<string>, states: string[] }}
 */
function parseArgs(argv) {
  /** @type {Record<string, string>} */
  const dirs = {};
  const noMock = new Set();
  const states = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--built' || arg === '--out' || arg === '--mocks' || arg === '--no-mock') {
      const value = argv[++i];
      if (value === undefined || value.startsWith('--')) throw new UsageError(`${arg} needs a value`);
      if (arg === '--no-mock') noMock.add(checkState(value));
      else dirs[arg.slice(2)] = value;
    } else if (arg.startsWith('--')) {
      throw new UsageError(`no option ${arg}`);
    } else {
      states.push(checkState(arg));
    }
  }
  if (dirs.built === undefined || dirs.out === undefined) throw new UsageError('--built and --out are required');
  if (states.length === 0) throw new UsageError('name at least one state');
  if (new Set(states).size !== states.length) throw new UsageError('a state is named twice');
  for (const state of noMock) {
    if (!states.includes(state)) throw new UsageError(`--no-mock ${state} names a state that is not listed`);
  }
  return { built: dirs.built, out: dirs.out, mocks: dirs.mocks ?? DEFAULT_MOCKS, noMock, states };
}

/** @param {string} name */
function checkState(name) {
  if (!STATE_NAME.test(name)) throw new UsageError(`"${name}" is not a state name (lower case letters, digits and hyphens)`);
  return name;
}

/** @param {string} file */
async function isFile(file) {
  try {
    return (await stat(file)).isFile();
  } catch {
    return false;
  }
}

/**
 * @param {string[]} argv
 * @returns {Promise<number>} the exit code
 */
async function main(argv) {
  let args;
  try {
    args = parseArgs(argv);
  } catch (error) {
    if (!(error instanceof UsageError)) throw error;
    process.stderr.write(`pairs: ${error.message}\n${USAGE}\n`);
    return 2;
  }
  const { built, out, mocks, noMock, states } = args;

  /** @type {Array<{ from: string, to: string }>} */
  const copies = [];
  /** @type {string[]} */
  const problems = [];
  for (const state of states) {
    for (const scheme of SCHEMES) {
      const builtShot = path.join(built, scheme, `${state}.png`);
      if (await isFile(builtShot)) copies.push({ from: builtShot, to: path.join(out, 'built', scheme, `${state}.png`) });
      else problems.push(`${state}: no built ${scheme} screenshot at ${builtShot}`);
      const mockShot = path.join(mocks, scheme, `${state}.webp`);
      const hasMock = await isFile(mockShot);
      if (noMock.has(state)) {
        if (hasMock) problems.push(`${state}: the mocks have it (${mockShot}), so it cannot be --no-mock`);
      } else if (hasMock) {
        copies.push({ from: mockShot, to: path.join(out, 'mock', scheme, `${state}.webp`) });
      } else {
        problems.push(`${state}: no mock ${scheme} screenshot at ${mockShot} (pass --no-mock ${state} for a new state)`);
      }
    }
  }
  if (problems.length > 0) {
    process.stderr.write(`pairs: wrote nothing, because:\n${problems.map((p) => `- ${p}\n`).join('')}`);
    return 1;
  }

  for (const { from, to } of copies) {
    await mkdir(path.dirname(to), { recursive: true });
    await copyFile(from, to);
  }
  await writeFile(path.join(out, 'index.html'), pageHTML(states, noMock));
  process.stdout.write(`pairs: wrote ${path.join(out, 'index.html')} with ${states.length} states\n`);
  return 0;
}

/**
 * The page: one section per state, and in it one row per scheme, the mock beside the built shot.
 * @param {string[]} states
 * @param {Set<string>} noMock
 */
export function pageHTML(states, noMock) {
  const sections = states.map((state) => {
    const rows = SCHEMES.map((scheme) => {
      const mock = noMock.has(state)
        ? `<figure class="none"><figcaption>Mock, ${scheme}</figcaption><p>${NO_MOCK_TEXT}</p></figure>`
        : shot(`mock/${scheme}/${state}.webp`, `Mock, ${scheme}`, `${state}, ${scheme}, mock`);
      const app = shot(`built/${scheme}/${state}.png`, `Built, ${scheme}`, `${state}, ${scheme}, built`);
      return `<div class="pair" data-state="${state}" data-scheme="${scheme}">${mock}${app}</div>`;
    });
    return `<section id="${state}"><h2>${state}</h2>\n${rows.join('\n')}\n</section>`;
  });
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Phone app pairs</title>
<style>
:root{--bg:#f2f2f7;--fg:#1c1c1e;--muted:#6c6c70;--line:#d1d1d6;--card:#ffffff}
@media (prefers-color-scheme: dark){
  :root:not([data-theme="light"]){--bg:#000000;--fg:#f2f2f7;--muted:#98989f;--line:#38383a;--card:#1c1c1e}
}
:root[data-theme="dark"]{--bg:#000000;--fg:#f2f2f7;--muted:#98989f;--line:#38383a;--card:#1c1c1e}
*{box-sizing:border-box}
body{margin:0;padding:16px;background:var(--bg);color:var(--fg);font:15px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
h1{font-size:22px;margin:0 0 4px}
h2{font-size:17px;margin:28px 0 8px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
p.lead{margin:0;color:var(--muted);max-width:60ch}
.pair{display:flex;gap:12px;margin:0 0 16px}
figure{margin:0;flex:0 1 195px;min-width:0}
figcaption{font-size:13px;color:var(--muted);margin:0 0 4px}
img{display:block;width:195px;max-width:100%;height:auto;border:1px solid var(--line);border-radius:8px;background:var(--card)}
.none p{margin:0;width:195px;max-width:100%;aspect-ratio:390/844;display:flex;align-items:center;justify-content:center;padding:12px;text-align:center;color:var(--muted);border:1px dashed var(--line);border-radius:8px}
</style>
</head>
<body>
<h1>Phone app pairs</h1>
<p class="lead">Each state in light and dark: the mock on the left, the built app on the right, both 195 px wide. Tap a picture to see it at full size.</p>
${sections.join('\n')}
</body>
</html>
`;
}

/**
 * @param {string} src a relative path
 * @param {string} caption
 * @param {string} alt
 */
function shot(src, caption, alt) {
  return `<figure><figcaption>${caption}</figcaption><a href="${src}"><img src="${src}" width="195" alt="${alt}"></a></figure>`;
}

if (process.argv[1] !== undefined && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = await main(process.argv.slice(2));
}
