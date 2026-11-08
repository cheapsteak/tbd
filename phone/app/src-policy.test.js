// The app's source policy. The runner's security policy (`phone/loader/runner.html`) and the
// frame's sandbox are what enforce the rules at run time. This test bans, in every source file
// under `app/src/`, the patterns that would break them or lead out of the frame: HTML strings,
// eval, runtime styles, the network, storage, workers, other windows, and links that skip the
// loader's link sheet. It reads the files as text, comments included, so a banned name in a
// comment fails too. A file the bundle never imports, such as a test, is held to it as well.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const SRC = fileURLToPath(new URL('src/', import.meta.url));
/** `phone/`, so a failure names the file as `app/src/…`. */
const PHONE = fileURLToPath(new URL('../', import.meta.url));

/**
 * Each banned pattern, with one line it must match, so a regex that stops matching fails the
 * self-check below instead of passing every file.
 * @type {Array<{pattern: RegExp, sample: string}>}
 */
const BANNED = [
  // HTML strings and script text.
  { pattern: /dangerouslySetInnerHTML/, sample: '<div dangerouslySetInnerHTML={{ __html: s }} />' },
  { pattern: /\binnerHTML\b/, sample: 'el.innerHTML = s;' },
  { pattern: /outerHTML/, sample: 'el.outerHTML = s;' },
  { pattern: /insertAdjacentHTML/, sample: "el.insertAdjacentHTML('beforeend', s);" },
  { pattern: /document\.write/, sample: 'document.writeln(s);' },
  { pattern: /\bDOMParser\b/, sample: "new DOMParser().parseFromString(s, 'text/html');" },
  { pattern: /createContextualFragment/, sample: 'range.createContextualFragment(s);' },
  { pattern: /setHTMLUnsafe/, sample: 'el.setHTMLUnsafe(s);' },
  { pattern: /parseHTMLUnsafe/, sample: 'Document.parseHTMLUnsafe(s);' },
  { pattern: /srcdoc/i, sample: '<iframe srcDoc={s} />' },
  { pattern: /trustedTypes/i, sample: "window.trustedTypes.createPolicy('x', {});" },
  { pattern: /javascript:/i, sample: "const u = 'JavaScript:alert(1)';" },
  // Code from strings.
  { pattern: /\beval\s*\(/, sample: 'eval (s);' },
  { pattern: /new Function/, sample: "new Function('return 1');" },
  { pattern: /\bset(?:Timeout|Interval)\s*\(\s*['"`]/, sample: "setTimeout('tick()', 10);" },
  { pattern: /\bimport\s*\(/, sample: "const m = await import('./x.ts');" },
  // Styles outside the constructed sheets and React's style prop.
  { pattern: /setAttribute\(\s*['"]style/, sample: "el.setAttribute('style', s);" },
  // The network.
  { pattern: /\bfetch\s*\(/, sample: "fetch('https://acme.example/');" },
  { pattern: /XMLHttpRequest/, sample: 'new XMLHttpRequest();' },
  { pattern: /WebSocket/, sample: "new WebSocket('wss://acme.example/');" },
  { pattern: /EventSource/, sample: "new EventSource('/events');" },
  { pattern: /sendBeacon/, sample: "navigator.sendBeacon('/b', s);" },
  { pattern: /RTCPeerConnection/, sample: 'new RTCPeerConnection();' },
  // Workers.
  { pattern: /new\s+Worker\b/, sample: 'new Worker(url);' },
  { pattern: /SharedWorker/, sample: 'new SharedWorker(url);' },
  { pattern: /importScripts/, sample: 'importScripts(url);' },
  { pattern: /serviceWorker/i, sample: 'navigator.serviceWorker.register(url);' },
  // Storage.
  { pattern: /localStorage/, sample: "localStorage.getItem('k');" },
  { pattern: /sessionStorage/, sample: "sessionStorage.getItem('k');" },
  { pattern: /indexedDB/, sample: "indexedDB.open('db');" },
  { pattern: /document\.cookie/, sample: 'document.cookie = s;' },
  { pattern: /document\.domain/, sample: 'document.domain = s;' },
  // Other windows and the frame's own navigation. The loader port is the only way out.
  { pattern: /window\.open/, sample: 'window.open(url);' },
  { pattern: /location\.(href|assign|replace)/, sample: 'location.assign(url);' },
  { pattern: /\b(?:window|self|globalThis)\.parent\b/, sample: "window.parent.postMessage(m, '*');" },
  { pattern: /\b(?:window|self|globalThis)\.top\b/, sample: 'globalThis.top.location = url;' },
  { pattern: /\bparent\.postMessage/, sample: "parent.postMessage(m, '*');" },
  { pattern: /\btop\.postMessage/, sample: "top.postMessage(m, '*');" },
  { pattern: /\bopener\b/, sample: 'window.opener.postMessage(m);' },
  // Links. Only {t: 'openLink'} on the loader port opens one, behind the loader's sheet.
  { pattern: /<a[\s>]/, sample: '<a href={url}>docs</a>' },
  { pattern: /\bhref=/, sample: '<link href="x" />' },
];

/** Lines the app does write, which no pattern may match, so the bans stay narrow. */
const ALLOWED = [
  "import type { HostEnv } from './env.ts';",
  "port.postMessage({ t: 'openLink', url });",
  'link.openLink(url);',
  'const top = rect.top + safeArea.top;',
  "setTimeout(() => setToast(null), 2_600);",
  'const id = setInterval(tick, 1_000);',
  '<Abbr title={label}>{name}</Abbr>',
  "el.style.setProperty('--dock-pad', value);",
  "document.documentElement.dataset.theme = 'dark';",
  'const parentRow = rows[parentIndex];',
  'const { href } = new URL(value);',
];

/** Every `.ts` and `.tsx` file under `app/src/`, as an absolute path. */
function sourceFiles() {
  return readdirSync(SRC, { recursive: true, encoding: 'utf8' })
    .filter((name) => /\.tsx?$/.test(name))
    .map((name) => join(SRC, name))
    .sort();
}

/**
 * Each match of each banned pattern in `text`, with its 1-based line. The whole file is
 * searched, so a pattern whose match spans lines, such as `eval` and its parenthesis on the
 * next line, is still found.
 * @param {string} text
 * @returns {Array<{line: number, pattern: RegExp}>}
 */
function violations(text) {
  /** @type {Array<{line: number, pattern: RegExp}>} */
  const found = [];
  for (const { pattern } of BANNED) {
    const global = new RegExp(pattern.source, `${pattern.flags}g`);
    for (const match of text.matchAll(global)) {
      found.push({ line: text.slice(0, match.index).split('\n').length, pattern });
    }
  }
  return found.sort((a, b) => a.line - b.line);
}

test('every banned pattern matches its sample line', () => {
  for (const { pattern, sample } of BANNED) {
    assert.ok(pattern.test(sample), `${pattern} must match ${JSON.stringify(sample)}`);
    assert.equal(violations(sample).some((v) => v.pattern === pattern), true, `${pattern} is found by the file scan`);
  }
});

test('no banned pattern matches the lines the app writes', () => {
  for (const line of ALLOWED) {
    assert.deepEqual(violations(line).map((v) => String(v.pattern)), [], JSON.stringify(line));
  }
});

test('the scan reports the line a match starts on', () => {
  assert.deepEqual(violations('const a = 1;\n\nconst b = eval\n  (s);\n'), [{ line: 3, pattern: /\beval\s*\(/ }]);
});

test('the walk reaches the app sources', () => {
  const names = sourceFiles().map((file) => relative(SRC, file));
  for (const expected of ['host.ts', 'env.ts', 'limits.ts']) assert.ok(names.includes(expected), expected);
});

test('no app source uses a banned pattern', () => {
  const failures = [];
  for (const file of sourceFiles()) {
    const text = readFileSync(file, 'utf8');
    for (const { line, pattern } of violations(text)) {
      failures.push(`${relative(PHONE, file)}:${line} matches ${pattern}`);
    }
  }
  assert.deepEqual(failures, [], `banned patterns in app/src:\n${failures.join('\n')}`);
});
