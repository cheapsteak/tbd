// The app's source policy. The runner's security policy (`phone/loader/runner.html`) and the
// frame's sandbox are what enforce the rules at run time. This test bans, in every source file
// under `app/src/`, the patterns that would break them or lead out of the frame: HTML strings,
// eval, runtime styles, the network, storage, workers, other windows, the frame's own
// navigation, links that skip the loader's link sheet, and the raw loader port outside
// `host.ts`. Self-navigation matters most: neither the policy nor the sandbox stops it, and the
// request leaves before the loader sees the frame's second load.
//
// It reads the files as text, comments included, so a banned name in a comment fails too. A
// file the bundle never imports, such as a test, is held to it as well.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const SRC = fileURLToPath(new URL('src/', import.meta.url));
/** `phone/`, so a failure names the file as `app/src/…`. */
const PHONE = fileURLToPath(new URL('../', import.meta.url));

/**
 * `host.ts` is the one module that holds the loader port, so that everything the app sends
 * leaves through `HostLink`'s two message shapes. Its test drives the raw port to check that.
 */
const PORT_FILES = ['host.ts', 'host.test.ts'];

/**
 * @typedef {object} Ban
 * @property {RegExp} pattern
 * @property {string[]} samples Lines the pattern must match, so a regex that stops matching
 *   fails the self-check below instead of passing every file.
 * @property {string[]} [exempt] Files under `app/src/`, by relative path, that may use it.
 */

/** @type {Ban[]} */
const BANNED = [
  // HTML strings and script text.
  { pattern: /dangerouslySetInnerHTML/, samples: ['<div dangerouslySetInnerHTML={{ __html: s }} />'] },
  { pattern: /\binnerHTML\b/, samples: ['el.innerHTML = s;'] },
  { pattern: /outerHTML/, samples: ['el.outerHTML = s;'] },
  { pattern: /insertAdjacentHTML/, samples: ["el.insertAdjacentHTML('beforeend', s);"] },
  { pattern: /insertHTML/, samples: ["document.execCommand('insertHTML', false, s);"] },
  // No \b, so ownerDocument.write and contentDocument.write are caught too.
  { pattern: /document\.write/i, samples: ['document.writeln(s);', 'el.ownerDocument.write(s);', 'Document.write(s);'] },
  { pattern: /contentDocument/, samples: ['frame.contentDocument.body.append(node);'] },
  { pattern: /\bDOMParser\b/, samples: ["new DOMParser().parseFromString(s, 'text/html');"] },
  { pattern: /createContextualFragment/, samples: ['range.createContextualFragment(s);'] },
  { pattern: /setHTMLUnsafe/, samples: ['el.setHTMLUnsafe(s);'] },
  { pattern: /parseHTMLUnsafe/, samples: ['Document.parseHTMLUnsafe(s);'] },
  { pattern: /srcdoc/i, samples: ['<iframe srcDoc={s} />'] },
  { pattern: /trustedTypes/i, samples: ["window.trustedTypes.createPolicy('x', {});"] },
  { pattern: /javascript:/i, samples: ["const u = 'JavaScript:alert(1)';"] },
  // Code from strings.
  { pattern: /\beval\s*\(/, samples: ['eval (s);'] },
  { pattern: /\bFunction\s*\(/, samples: ["new Function('return 1');", "Function('return 1')();", "globalThis.Function ('x');"] },
  { pattern: /\bset(?:Timeout|Interval)\s*\(\s*['"`]/, samples: ["setTimeout('tick()', 10);", 'setInterval(`tick()`, 10);'] },
  { pattern: /\bimport\s*\(/, samples: ["const m = await import('./x.ts');"] },
  // Elements that load something or navigate, and <style>, made outside JSX or in it. The
  // runner's policy refuses a <style>, but the end-to-end tests let WebKit's refusal of one
  // through while they take a screenshot, so this ban is what stops the app making one then.
  {
    pattern: /createElement(?:NS)?\s*\([^)]*?['"`](?:a|area|script|iframe|frame|object|embed|form|meta|base|link|style)['"`]/,
    samples: ["document.createElement('a');", 'document.createElementNS(SVG_NS, "script");', 'React.createElement(`iframe`, props);',
      "document.createElement('style');", "document.createElementNS(SVG_NS, 'style');", 'React.createElement("style", null, css);'],
  },
  {
    // The lookbehind lets a type argument such as `Array<object>` through: in JSX, `<` never
    // follows a name directly.
    pattern: /(?<![\w$])<(?:script|iframe|frame|object|embed|form|meta|base|area|link)(?![\w-])/,
    samples: ['<iframe src={u} />', '<form action={u}>', '<meta httpEquiv="refresh" content="0;url=x" />',
      '<base href="x" />', '<link rel="prefetch" href={u} />', 'return (<object data={u}></object>);'],
  },
  {
    // A backtick may come before it too: that is prose naming the element in code type, as
    // styles/apply.ts does, never JSX. A string that holds it is HTML only through the HTML
    // sinks banned above.
    pattern: /(?<![\w$`])<style(?![\w-])/,
    samples: ['<style>{css}</style>', 'return (<style>{css}</style>);', '<style\n  media="print">'],
  },
  // Attributes that load, navigate or run code, and styles outside the constructed sheets and
  // React's style prop. HTML attribute names ignore case.
  {
    pattern: /\bsetAttribute\s*\(\s*['"`](?:style|href|src|srcdoc|srcset|action|formaction|http-equiv|on\w+)['"`]/i,
    samples: ["el.setAttribute('style', s);", 'el.setAttribute("href", u);', "el.setAttribute('src', u);",
      "el.setAttribute('srcdoc', s);", "form.setAttribute('action', u);", "b.setAttribute('formaction', u);",
      "m.setAttribute('http-equiv', 'refresh');", "el.setAttribute('onclick', s);", "el.setAttribute('ONLOAD', s);"],
  },
  {
    pattern: /\bsetAttributeNS\s*\([^,()]*,\s*['"`](?:[\w-]+:)?(?:style|href|src|srcdoc|srcset|action|formaction|http-equiv|on\w+)['"`]/i,
    samples: ["use.setAttributeNS(XLINK_NS, 'xlink:href', u);", "el.setAttributeNS(null, 'onload', s);"],
  },
  // The network.
  { pattern: /\bfetch\s*\(/, samples: ["fetch('https://acme.example/');"] },
  { pattern: /XMLHttpRequest/, samples: ['new XMLHttpRequest();'] },
  { pattern: /WebSocket/, samples: ["new WebSocket('wss://acme.example/');"] },
  { pattern: /EventSource/, samples: ["new EventSource('/events');"] },
  { pattern: /sendBeacon/, samples: ["navigator.sendBeacon('/b', s);"] },
  { pattern: /RTCPeerConnection/, samples: ['new RTCPeerConnection();'] },
  // Workers.
  { pattern: /new\s+Worker\b/, samples: ['new Worker(url);'] },
  { pattern: /SharedWorker/, samples: ['new SharedWorker(url);'] },
  { pattern: /importScripts/, samples: ['importScripts(url);'] },
  { pattern: /serviceWorker/i, samples: ['navigator.serviceWorker.register(url);'] },
  // Storage.
  { pattern: /localStorage/, samples: ["localStorage.getItem('k');"] },
  { pattern: /sessionStorage/, samples: ["sessionStorage.getItem('k');"] },
  { pattern: /indexedDB/, samples: ["indexedDB.open('db');"] },
  { pattern: /document\.cookie/, samples: ['document.cookie = s;'] },
  { pattern: /document\.domain/, samples: ['document.domain = s;'] },
  // The frame's own navigation, and other windows.
  {
    pattern: /\blocation\b/,
    samples: ['location = url;', 'window.location = url;', "location['href'] = url;", 'document.location.assign(url);',
      'location.replace(url);'],
  },
  // The history and Navigation APIs reload the frame (`history.go(0)`, `navigation.reload()`) or
  // move it to another entry of the session history it shares with the loader's page. Each is
  // banned with any accessor: `.`, `?.`, or a bracket around a string.
  {
    pattern: /\bnavigation\s*(?:\??\.\s*|(?:\?\.)?\[\s*['"`])(?:navigate|reload|back|forward|traverseTo)\b/,
    samples: ['navigation.navigate(url);', 'window.navigation.navigate(url);', 'navigation.reload();', 'navigation.back();',
      'navigation.forward();', 'navigation.traverseTo(key);', 'navigation?.reload();', "navigation['back']();",
      'self.navigation?.["traverseTo"](key);', 'navigation\n  .forward();'],
  },
  {
    pattern: /\bhistory\s*(?:\??\.\s*|(?:\?\.)?\[\s*['"`])(?:go|back|forward)\b/,
    samples: ['history.go(-1);', 'history.go(0);', 'history.go();', 'window.history.back();', 'history.forward();',
      'history?.go(0);', "history['back']();", 'globalThis.history?.[`forward`]();', 'history\n  .go(0);'],
  },
  { pattern: /['"`]_self['"`]/, samples: ["form.target = '_self';", 'const target = "_self";'] },
  { pattern: /\b(?:window|self|globalThis)\.open\b/, samples: ['window.open(url);', "self.open(url, '_blank');"] },
  { pattern: /\b(?:window|self|globalThis)\.parent\b/, samples: ["window.parent.postMessage(m, '*');"] },
  { pattern: /\b(?:window|self|globalThis)\.top\b/, samples: ['globalThis.top.location = url;'] },
  { pattern: /\bparent\.postMessage/, samples: ["parent.postMessage(m, '*');"] },
  { pattern: /\btop\.postMessage/, samples: ["top.postMessage(m, '*');"] },
  { pattern: /\b(?:window|self|globalThis)\.opener\b|\bopener\.postMessage/, samples: ['window.opener.focus();', 'opener.postMessage(m);'] },
  // Links. Only {t: 'openLink'} on the loader port opens one, behind the loader's sheet.
  { pattern: /<a[\s>]/, samples: ['<a href={url}>docs</a>'] },
  { pattern: /\bhref\s*=(?!=)/, samples: ['<link href="x" />', 'a.href = url;'] },
  // The raw loader port.
  { pattern: /\btbdHost\b/, samples: ['const host = globalThis.tbdHost;'], exempt: PORT_FILES },
  { pattern: /\.postMessage\b/, samples: ['port.postMessage(m);', "host.port.postMessage({ t: 'app', body });"], exempt: PORT_FILES },
];

/** Lines the app does write, in a file with no exemption, which no pattern may match. */
const ALLOWED = [
  "import type { HostEnv } from './env.ts';",
  'link.openLink(url);',
  'actions.open(ref);',
  'open(ref) {',
  'setOpen(true);',
  'const opener = useRef(null);',
  'const top = rect.top + safeArea.top;',
  'setTimeout(() => setToast(null), 2_600);',
  'const id = setInterval(tick, 1_000);',
  '<Abbr title={label}>{name}</Abbr>',
  '<img src={dataURL} />',
  "el.style.setProperty('--dock-pad', value);",
  '<div style={{ color }} />',
  'document.adoptedStyleSheets = [sheet];',
  " * frame's content policy allows where a `<style>` element or a style attribute would not.",
  'function first(xs: Array<style>): style | undefined { return xs[0]; }',
  "el.setAttribute('aria-hidden', 'true');",
  "el.setAttribute('data-src', u);",
  "el.setAttribute('open', '');",
  "document.createElement('div');",
  "document.createElement('abbr');",
  "document.documentElement.dataset.theme = 'dark';",
  'const parentRow = rows[parentIndex];',
  'const { href } = new URL(value);',
  'if (a.href === b.href) return;',
  'if (isFunction(value)) return;',
  'const run = (f: Function) => f;',
  'const seen = new Map<object, string>();',
  'function first(xs: Array<object>): object | undefined { return xs[0]; }',
  'actions.back();',
  ' * Opening it clears `pendingOpen`. So does a navigation the user makes, `openSession` or `back`',
  'const older = history.slice(0, n);',
  'const goBack = history.length > 0;',
];

/** Every `.ts` and `.tsx` file under `app/src/`, as a path relative to it with `/` separators. */
function sourceFiles() {
  return readdirSync(SRC, { recursive: true, encoding: 'utf8' })
    .filter((name) => /\.tsx?$/.test(name))
    .map((name) => name.split(sep).join('/'))
    .sort();
}

/**
 * Each match of each banned pattern in `text`, with its 1-based line, skipping the bans that
 * exempt `file`. The whole text is searched, so a pattern whose match spans lines, such as
 * `eval` and its parenthesis on the next line, is still found.
 * @param {string} text
 * @param {string} [file] The file's path relative to `app/src/`. Without it, no ban is exempt.
 * @returns {Array<{line: number, pattern: RegExp}>}
 */
function violations(text, file) {
  /** @type {Array<{line: number, pattern: RegExp}>} */
  const found = [];
  for (const { pattern, exempt = [] } of BANNED) {
    if (file !== undefined && exempt.includes(file)) continue;
    const global = new RegExp(pattern.source, `${pattern.flags}g`);
    for (const match of text.matchAll(global)) {
      found.push({ line: text.slice(0, match.index).split('\n').length, pattern });
    }
  }
  return found.sort((a, b) => a.line - b.line);
}

test('every banned pattern matches each of its samples', () => {
  for (const { pattern, samples } of BANNED) {
    assert.ok(samples.length > 0, `${pattern} has a sample`);
    for (const sample of samples) {
      assert.ok(pattern.test(sample), `${pattern} must match ${JSON.stringify(sample)}`);
      assert.equal(violations(sample).some((v) => v.pattern === pattern), true, `${pattern} is found by the file scan`);
    }
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

test('only host.ts and its test may touch the raw port', () => {
  const line = "const host = globalThis.tbdHost; host.port.postMessage({ t: 'app', body });";
  for (const file of PORT_FILES) assert.deepEqual(violations(line, file), [], file);
  for (const file of ['main.tsx', 'client/client.ts', 'state/host.ts', 'host.tsx']) {
    assert.deepEqual(violations(line, file).map((v) => String(v.pattern)), [String(/\btbdHost\b/), String(/\.postMessage\b/)], file);
  }
});

test('the walk reaches the app sources', () => {
  const names = sourceFiles();
  for (const expected of ['host.ts', 'env.ts', 'limits.ts', ...PORT_FILES]) assert.ok(names.includes(expected), expected);
});

test('no app source uses a banned pattern', () => {
  const failures = [];
  for (const file of sourceFiles()) {
    const text = readFileSync(join(SRC, file), 'utf8');
    for (const { line, pattern } of violations(text, file)) {
      failures.push(`${relative(PHONE, join(SRC, file))}:${line} matches ${pattern}`);
    }
  }
  assert.deepEqual(failures, [], `banned patterns in app/src:\n${failures.join('\n')}`);
});
