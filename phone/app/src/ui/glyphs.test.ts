// GLYPHS is the mock's sprite as data. This test parses the sprite out of the mock and checks
// every symbol: same names, same child elements, same attributes, same order.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { APP_GLYPHS, glyph, GLYPHS, reactAttrs } from './glyphs.ts';

// Outside phone/: the classifier's `docs/design/phone-control/*` route
// (scripts/ci/phone-parts-needed.sh) runs this test when the mock changes.
const mock = readFileSync(fileURLToPath(new URL('../../../../docs/design/phone-control/phone-control-mocks.html', import.meta.url)), 'utf8');

function parse(): Map<string, Array<[string, Record<string, string>]>> {
  const out = new Map<string, Array<[string, Record<string, string>]>>();
  for (const sym of mock.matchAll(/<symbol id="([^"]+)"[^>]*>(.*?)<\/symbol>/g)) {
    const kids: Array<[string, Record<string, string>]> = [];
    for (const el of (sym[2] as string).matchAll(/<(\w+)((?:\s+[\w-]+="[^"]*")*)\s*\/>/g)) {
      const attrs: Record<string, string> = {};
      for (const a of (el[2] as string).matchAll(/([\w-]+)="([^"]*)"/g)) attrs[a[1] as string] = a[2] as string;
      kids.push([el[1] as string, attrs]);
    }
    out.set(sym[1] as string, kids);
  }
  return out;
}

test('every symbol in the mock sprite is a glyph, with the same children', () => {
  const sprite = parse();
  assert.ok(sprite.size >= 36);
  assert.deepEqual(Object.keys(GLYPHS).sort(), [...sprite.keys()].sort());
  for (const [id, kids] of sprite) assert.deepEqual(GLYPHS[id as keyof typeof GLYPHS], kids, id);
});

test('hyphenated attributes reach React in its own names', () => {
  assert.deepEqual(
    reactAttrs({ 'stroke-width': '2', 'stroke-linecap': 'round', 'fill-rule': 'evenodd', 'stroke-dasharray': '3 2.6', d: 'M0 0', bogus: 'x', 'data-x': 'y' }),
    { strokeWidth: '2', strokeLinecap: 'round', fillRule: 'evenodd', strokeDasharray: '3 2.6', d: 'M0 0' },
  );
  for (const kids of Object.values(GLYPHS))
    for (const [, attrs] of kids) assert.equal(Object.keys(attrs).length, Object.keys(reactAttrs(attrs)).length);
});

test("the app's own glyphs repeat no sprite symbol's name, and each reaches React whole", () => {
  const sprite = parse();
  for (const [name, kids] of Object.entries(APP_GLYPHS)) {
    assert.equal(sprite.has(name), false, name);
    assert.equal(Object.hasOwn(GLYPHS, name), false, name);
    assert.ok(kids.length > 0, name);
    for (const [tag, attrs] of kids) {
      assert.ok(['path', 'circle', 'rect'].includes(tag), `${name}: ${tag}`);
      assert.equal(Object.keys(reactAttrs(attrs)).length, Object.keys(attrs).length, name);
    }
  }
  // The filter chip's two: the same funnel, outlined and filled.
  assert.deepEqual(APP_GLYPHS['filter-on'].map(([tag, a]) => [tag, a['d']]), APP_GLYPHS.filter.map(([tag, a]) => [tag, a['d']]));
  assert.equal(APP_GLYPHS['filter-on'][0]?.[1]['fill'], 'currentColor');
  assert.equal(APP_GLYPHS.filter[0]?.[1]['fill'], undefined);
});

test('glyph finds a sprite glyph and an app glyph', () => {
  assert.equal(glyph('plus'), GLYPHS.plus);
  assert.equal(glyph('filter'), APP_GLYPHS.filter);
  assert.equal(glyph('filter-on'), APP_GLYPHS['filter-on']);
});
