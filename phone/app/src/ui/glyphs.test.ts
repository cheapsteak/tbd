// GLYPHS is the mock's sprite as data. This test parses the sprite out of the mock and checks
// every symbol: same names, same child elements, same attributes, same order.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { GLYPHS, reactAttrs } from './glyphs.ts';

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
