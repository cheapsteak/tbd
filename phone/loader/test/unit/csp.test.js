import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';

const loaderDir = new URL('../../', import.meta.url);
const ORIGIN_PLACEHOLDER = 'https://loader-origin.invalid';

/** @param {string} name a path under phone/loader/ */
function read(name) {
  return readFileSync(new URL(name, loaderDir), 'utf8');
}

/**
 * The policy in the one `<meta http-equiv="Content-Security-Policy">` of `html`, as
 * `{ directive: [token, …] }`. Directives split on `;` and tokens on whitespace. Fails
 * unless there is exactly one such tag, and when a directive repeats (a browser would
 * ignore the repeat).
 * @param {string} html
 * @returns {Record<string, string[]>}
 */
function parseMetaPolicy(html) {
  const tags = (html.match(/<meta\b[^>]*>/gi) ?? [])
    .filter((tag) => /\shttp-equiv\s*=\s*"content-security-policy"/i.test(tag));
  assert.equal(tags.length, 1, 'exactly one policy <meta>');
  const content = /\scontent\s*=\s*"([^"]*)"/i.exec(tags[0]);
  assert.ok(content, 'the policy <meta> has a content attribute');
  /** @type {Record<string, string[]>} */
  const policy = {};
  for (const directive of content[1].split(';')) {
    const [name, ...tokens] = directive.trim().split(/\s+/);
    if (!name) continue;
    const key = name.toLowerCase();
    assert.ok(!Object.hasOwn(policy, key), `directive ${key} repeats`);
    policy[key] = tokens;
  }
  return policy;
}

test('runner policy names an origin, never self', () => {
  const p = parseMetaPolicy(read('runner.html'));
  assert.deepEqual(p, {
    'default-src': ["'none'"], 'script-src': ['https://loader-origin.invalid', 'blob:'],
    'worker-src': ["'none'"], 'style-src': ['blob:'], 'img-src': ['data:', 'blob:'],
    'connect-src': ["'none'"], 'base-uri': ["'none'"], 'form-action': ["'none'"],
    'require-trusted-types-for': ["'script'"], 'trusted-types': ['runner'] });
  assert.ok(!read('runner.html').includes("'self'"));
});

test('runner.html carries the origin placeholder exactly once', () => {
  assert.equal(read('runner.html').split(ORIGIN_PLACEHOLDER).length - 1, 1);
});

test('runner.html has no inline script: every <script> has a src', () => {
  const html = read('runner.html');
  const opened = html.match(/<script\b/gi) ?? [];
  const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi)];
  assert.ok(scripts.length > 0, 'runner.html loads runner.js');
  assert.equal(scripts.length, opened.length, 'every <script> is closed');
  for (const [, attributes, body] of scripts) {
    assert.match(attributes, /\ssrc\s*=\s*"[^"]+"/i);
    assert.equal(body.trim(), '');
  }
  assert.doesNotMatch(html, /<[^>]*\son[a-z]+\s*=/i, 'no on* handler attributes');
});

test('runner policy comes before any script', () => {
  const html = read('runner.html');
  const policyAt = html.search(/<meta\b[^>]*http-equiv\s*=\s*"content-security-policy"/i);
  assert.ok(policyAt >= 0);
  assert.ok(policyAt < html.search(/<script\b/i));
});

// --- the loader page ---------------------------------------------------------------------

/** Every file under phone/loader/ that the page or runner can load: not tests, not vendored. */
function loaderSources() {
  /** @type {string[]} */
  const found = [];
  /** @param {string} rel a directory under phone/loader/, '' for the top */
  const walk = (rel) => {
    for (const entry of readdirSync(new URL(rel || '.', loaderDir), { withFileTypes: true })) {
      const path = `${rel}${entry.name}`;
      if (entry.isDirectory()) {
        if (path !== 'test' && path !== 'vendor' && path !== 'node_modules') walk(`${path}/`);
      } else if (/\.(js|html|css|webmanifest)$/.test(entry.name) && !entry.name.endsWith('.test.js')) {
        found.push(path);
      }
    }
  };
  walk('');
  return found.sort();
}

test('index.html policy is exactly the loader policy', () => {
  assert.deepEqual(parseMetaPolicy(read('index.html')), {
    'default-src': ["'none'"], 'script-src': ["'self'"], 'style-src': ["'self'"], 'img-src': ["'self'"],
    'connect-src': ["'self'", 'https:', 'wss:'], 'frame-src': ["'self'"], 'worker-src': ["'none'"],
    'manifest-src': ["'self'"], 'base-uri': ["'none'"], 'form-action': ["'none'"],
    'require-trusted-types-for': ["'script'"], 'trusted-types': ['loader-jsqr'],
  });
});

test('index.html loads main.js as its one script, with no inline script or handler', () => {
  const html = read('index.html');
  const opened = html.match(/<script\b/gi) ?? [];
  const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi)];
  assert.equal(opened.length, 1);
  assert.equal(scripts.length, 1);
  const [, attributes, body] = scripts[0];
  assert.match(attributes, /\stype\s*=\s*"module"/i);
  assert.match(attributes, /\ssrc\s*=\s*"main\.js"/i);
  assert.equal(body.trim(), '');
  assert.doesNotMatch(html, /<[^>]*\son[a-z]+\s*=/i, 'no on* handler attributes');
  assert.doesNotMatch(html, /\sstyle\s*=/i, 'no style attributes');
  assert.doesNotMatch(html, /<style\b/i, 'no style element');
});

test('index.html policy comes before every script, stylesheet and manifest', () => {
  const html = read('index.html');
  const policyAt = html.search(/<meta\b[^>]*http-equiv\s*=\s*"content-security-policy"/i);
  assert.ok(policyAt >= 0);
  for (const tag of [/<script\b/i, /<link\b/i]) {
    assert.ok(policyAt < html.search(tag), `${tag} after the policy`);
  }
});

test('index.html has the page skeleton main.js mounts into', () => {
  const html = read('index.html');
  assert.match(html, /<html lang="en">/);
  assert.match(html, /<header id="strip" hidden><\/header>/);
  assert.match(html, /<main id="screen"><\/main>/);
  assert.match(html, /<div id="frame-host" hidden><\/div>/);
  assert.match(html, /<div id="safe-probe" aria-hidden="true"><\/div>/);
  assert.match(html, /<link rel="manifest" href="manifest\.webmanifest">/);
  assert.match(html, /<link rel="stylesheet" href="loader\.css">/);
});

test('no loader source holds an HTML-string sink or an inline style', () => {
  const sources = loaderSources();
  for (const name of ['index.html', 'main.js', 'ui.js', 'loader.css', 'runner.html', 'runner.js']) {
    assert.ok(sources.includes(name), `${name} is scanned`);
  }
  const banned = [
    'innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'eval(', 'new Function', 'style="',
    'setAttribute(\'style\'', 'srcdoc',
  ];
  for (const name of sources) {
    const text = read(name);
    for (const word of banned) {
      assert.ok(!text.includes(word), `${name} contains ${word}`);
    }
  }
});

test('the loader page creates no Trusted Types policy but loader-jsqr', () => {
  for (const name of loaderSources()) {
    // runner.html is its own document with its own policy, `runner`.
    if (name === 'runner.js' || name === 'qr.js') continue;
    assert.ok(!read(name).includes('createPolicy'), `${name} creates a Trusted Types policy`);
  }
  assert.equal(read('qr.js').split('createPolicy(').length - 1, 1);
  assert.match(read('qr.js'), /const JSQR_POLICY = 'loader-jsqr';/);
});

test('the manifest opens the loader standalone', () => {
  assert.deepEqual(JSON.parse(read('manifest.webmanifest')), {
    name: 'TBD', short_name: 'TBD', start_url: './', scope: './', display: 'standalone',
  });
});
