import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

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
