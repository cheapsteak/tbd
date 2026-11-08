// The app's stylesheet is the mock's, copied. These tests read both files as text and check
// the copy: the colour tokens, the app-screen rules line for line, and that no review-page
// rule came along. The mock's blocks are found by their content, not by line number.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const mock = readFileSync(fileURLToPath(new URL('../../../../docs/design/phone-control/phone-control-mocks.html', import.meta.url)), 'utf8');
const appCss = readFileSync(fileURLToPath(new URL('./app.css', import.meta.url)), 'utf8');

const REVIEW_PAGE_TOKENS = new Set(['--page', '--page-fg', '--page-muted', '--page-line', '--frame', '--cam', '--cam-fg', '--qr-bg', '--qr-fg']);
/** Variant rules the mock switches on with a body class. The app ships the chosen designs only. */
const VARIANT = /body\.(?:d-comfy|w-words|tabs-pills|ch-stack)/;

/** The custom properties declared in the first block that opens with `open`. */
function tokens(text: string, open: string): Map<string, string> {
  const start = text.indexOf(open);
  assert.ok(start >= 0, `no block ${open}`);
  const body = text.slice(start + open.length, text.indexOf('}', start));
  const out = new Map<string, string>();
  for (const m of body.matchAll(/(--[\w-]+)\s*:\s*([^;}]+)/g)) out.set(m[1] as string, (m[2] as string).trim());
  return out;
}

/** The mock's lines from the line starting with `from` up to, not including, the line starting with `to`. */
function mockRange(from: string, to: string): Array<{ no: number; text: string }> {
  const lines = mock.split('\n');
  const a = lines.findIndex((l) => l.startsWith(from));
  const b = lines.findIndex((l, i) => i > a && l.startsWith(to));
  assert.ok(a >= 0 && b > a, `range ${from} .. ${to}`);
  return lines.slice(a, b).map((text, i) => ({ no: a + i + 1, text }));
}

const appLines = new Set(appCss.split('\n'));

test('every colour token matches the mock in light and dark', () => {
  let checked = 0;
  for (const block of [':root{', ':root:not([data-theme="light"]){', ':root[data-theme="dark"]{'])
    for (const [name, value] of tokens(mock, block)) {
      if (REVIEW_PAGE_TOKENS.has(name)) {
        assert.equal(tokens(appCss, block).has(name), false, `${block} ${name} is a review-page token`);
        continue;
      }
      assert.equal(tokens(appCss, block).get(name), value, `${block} ${name}`);
      checked += 1;
    }
  assert.ok(checked > 60, `only ${checked} tokens checked`);
});

test('the app-screen rules are copied line for line', () => {
  const lines = mockRange('/* ---------- sessions list', '/* ---------- loader screens');
  assert.ok(lines.length > 150);
  let variants = 0;
  for (const line of lines) {
    if (!line.text.trim()) continue;
    if (VARIANT.test(line.text)) { variants += 1; continue; }
    assert.ok(appLines.has(line.text), `mock ${line.no}: ${line.text.slice(0, 60)}`);
  }
  assert.ok(variants >= 9, 'the variant rules were found');
});

test('the dropdown rules are copied line for line', () => {
  const from = mock.split('\n').findIndex((l) => l.startsWith('.lapdrop{'));
  const to = mock.split('\n').findIndex((l) => l.startsWith('.pd-ask div{'));
  assert.ok(from > 0 && to > from);
  for (const text of mock.split('\n').slice(from, to + 1)) assert.ok(appLines.has(text), text.slice(0, 60));
});

test('the centred-message rules are copied line for line', () => {
  const center = mock.split('\n').filter((l) => l.startsWith('.center'));
  assert.equal(center.length, 4);
  for (const text of center) assert.ok(appLines.has(text), text.slice(0, 60));
});

test('the frame rules become the #app rules', () => {
  assert.ok(appLines.has('#app{height:100%;display:flex;flex-direction:column;position:relative;overflow:hidden;background:var(--side);color:var(--fg);font-size:var(--fs);line-height:1.4;font-family:var(--sys)}'));
  assert.ok(appLines.has('#app[data-screen="session"]{background:var(--pane)}'));
  assert.ok(appLines.has('html,body{height:100%;margin:0}'));
  assert.ok(appLines.has('#app{--home:var(--safe-bottom);padding:var(--safe-top) var(--safe-right) 0 var(--safe-left)}'));
  assert.ok(appLines.has('.dock{padding-bottom:calc(10px + var(--dock-pad))}'));
});

test('only the chosen designs and no review-page rules ship', () => {
  for (const s of ['d-comfy', 'w-words', 'tabs-pills', 'ch-stack', '#panel', '.mocktab', '.sim-sb', '#strip', '.lapbtn', '#frame', '#page'])
    assert.equal(appCss.includes(s), false, s);
});
