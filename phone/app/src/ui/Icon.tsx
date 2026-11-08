/**
 * Glyphs and the working dots, drawn as React elements from `GLYPHS`. The glyph data keeps
 * the mock's attribute names; `reactAttrs` maps them to the names React expects.
 */

import type { JSX } from 'react';
import { GLYPHS, reactAttrs, type GlyphName } from './glyphs.ts';

export function Icon(p: { name: GlyphName; cls?: string }): JSX.Element {
  return (
    <svg className={p.cls ? `i ${p.cls}` : 'i'} viewBox="0 0 24 24" aria-hidden="true">
      {GLYPHS[p.name].map(([tag, attrs], i) => {
        const Tag = tag as 'path' | 'circle' | 'rect';
        return <Tag key={i} {...reactAttrs(attrs)} />;
      })}
    </svg>
  );
}

export function Dots(): JSX.Element {
  return (
    <span className="dots" aria-hidden="true">
      <b />
      <b />
      <b />
    </span>
  );
}
