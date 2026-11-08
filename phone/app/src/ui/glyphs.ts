// Glyph data copied from the symbols in docs/design/phone-control/phone-control-mocks.html.
// Each glyph is a list of [tag, attributes] children of a 24x24 svg. Attribute names stay as the mock writes them.

export type GlyphName =
  | 'hand'
  | 'moon'
  | 'octa'
  | 'glass'
  | 'power'
  | 'unk'
  | 'check'
  | 'cloud'
  | 'chev-r'
  | 'chev-l'
  | 'chev-d'
  | 'chev-u'
  | 'plus'
  | 'more'
  | 'laptop'
  | 'term'
  | 'pen'
  | 'eye'
  | 'search'
  | 'globe'
  | 'bot'
  | 'tri-r'
  | 'tri-d'
  | 'x'
  | 'camera'
  | 'link'
  | 'warn'
  | 'wifi-off'
  | 'refresh'
  | 'download'
  | 'user'
  | 'fork'
  | 'cpu'
  | 'layers'
  | 'msg'
  | 'down'
  | 'swap';

type Child = readonly [string, Readonly<Record<string, string>>];

export const GLYPHS: Readonly<Record<GlyphName, ReadonlyArray<Child>>> = {
  hand: [
    ['path', { d: 'M18 11V6a2 2 0 0 0-4 0' }],
    ['path', { d: 'M14 10V4a2 2 0 0 0-4 0v2' }],
    ['path', { d: 'M10 10.5V6a2 2 0 0 0-4 0v8' }],
    ['path', { d: 'M18 8a2 2 0 1 1 4 0v6a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.86-6-2.34l-3.6-3.6a2 2 0 0 1 2.83-2.82L7 15' }],
  ],
  moon: [
    ['path', { d: 'M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z' }],
  ],
  octa: [
    ['path', { d: 'M7.86 2h8.28L22 7.86v8.28L16.14 22H7.86L2 16.14V7.86Z' }],
    ['path', { d: 'M12 8v4' }],
    ['path', { d: 'M12 16h.01' }],
  ],
  glass: [
    ['path', { d: 'M5 22h14' }],
    ['path', { d: 'M5 2h14' }],
    ['path', { d: 'M17 22v-4.17a2 2 0 0 0-.59-1.42L12 12l-4.41 4.41A2 2 0 0 0 7 17.83V22' }],
    ['path', { d: 'M7 2v4.17a2 2 0 0 0 .59 1.42L12 12l4.41-4.41A2 2 0 0 0 17 6.17V2' }],
  ],
  power: [
    ['path', { d: 'M12 2v10' }],
    ['path', { d: 'M18.4 6.6a9 9 0 1 1-12.8 0' }],
  ],
  unk: [
    ['circle', { cx: '12', cy: '12', r: '9.5', 'stroke-dasharray': '3 2.6' }],
    ['path', { d: 'M9.5 9.5a2.5 2.5 0 0 1 4.8.8c0 1.7-2.3 2.2-2.3 3.4' }],
    ['path', { d: 'M12 17h.01' }],
  ],
  check: [
    ['path', { d: 'm5 12.5 4.5 4.5L19 7.5' }],
  ],
  cloud: [
    ['path', { d: 'M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z' }],
  ],
  'chev-r': [
    ['path', { d: 'm9 6 6 6-6 6' }],
  ],
  'chev-l': [
    ['path', { d: 'm15 6-6 6 6 6' }],
  ],
  'chev-d': [
    ['path', { d: 'm6 9 6 6 6-6' }],
  ],
  'chev-u': [
    ['path', { d: 'm6 15 6-6 6 6' }],
  ],
  plus: [
    ['path', { d: 'M12 5v14' }],
    ['path', { d: 'M5 12h14' }],
  ],
  more: [
    ['circle', { cx: '5', cy: '12', r: '1.4', fill: 'currentColor' }],
    ['circle', { cx: '12', cy: '12', r: '1.4', fill: 'currentColor' }],
    ['circle', { cx: '19', cy: '12', r: '1.4', fill: 'currentColor' }],
  ],
  laptop: [
    ['rect', { x: '4', y: '5', width: '16', height: '11', rx: '1.5' }],
    ['path', { d: 'M2 19h20' }],
  ],
  term: [
    ['path', { d: 'm4 17 6-6-6-6' }],
    ['path', { d: 'M12 19h8' }],
  ],
  pen: [
    ['path', { d: 'M12 20h9' }],
    ['path', { d: 'M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z' }],
  ],
  eye: [
    ['path', { d: 'M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12Z' }],
    ['circle', { cx: '12', cy: '12', r: '3' }],
  ],
  search: [
    ['circle', { cx: '11', cy: '11', r: '7' }],
    ['path', { d: 'm20 20-3.5-3.5' }],
  ],
  globe: [
    ['circle', { cx: '12', cy: '12', r: '10' }],
    ['path', { d: 'M2 12h20' }],
    ['path', { d: 'M12 2a15 15 0 0 1 0 20a15 15 0 0 1 0-20' }],
  ],
  bot: [
    ['rect', { x: '4', y: '8', width: '16', height: '12', rx: '2' }],
    ['path', { d: 'M12 8V4' }],
    ['circle', { cx: '12', cy: '3', r: '1' }],
    ['path', { d: 'M9 13v2M15 13v2' }],
  ],
  'tri-r': [
    ['path', { d: 'M8 4v16l12-8Z', fill: 'currentColor', stroke: 'none' }],
  ],
  'tri-d': [
    ['path', { d: 'M4 7h16l-8 12Z', fill: 'currentColor', stroke: 'none' }],
  ],
  x: [
    ['path', { d: 'M18 6 6 18M6 6l12 12' }],
  ],
  camera: [
    ['path', { d: 'M14.5 4h-5L7 7H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-3Z' }],
    ['circle', { cx: '12', cy: '13', r: '3.5' }],
  ],
  link: [
    ['path', { d: 'M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7' }],
    ['path', { d: 'M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7' }],
  ],
  warn: [
    ['path', { d: 'M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z' }],
    ['path', { d: 'M12 9v4' }],
    ['path', { d: 'M12 17h.01' }],
  ],
  'wifi-off': [
    ['path', { d: 'M2 2l20 20' }],
    ['path', { d: 'M8.5 16.5a5 5 0 0 1 7 0' }],
    ['path', { d: 'M5 12.9a10 10 0 0 1 5.2-2.8' }],
    ['path', { d: 'M19 12.9a10 10 0 0 0-2.3-1.6' }],
    ['path', { d: 'M2 8.8a15 15 0 0 1 4.2-2.6' }],
    ['path', { d: 'M22 8.8A15 15 0 0 0 11 5' }],
    ['path', { d: 'M12 20h.01' }],
  ],
  refresh: [
    ['path', { d: 'M21 12a9 9 0 1 1-3-6.7L21 8' }],
    ['path', { d: 'M21 3v5h-5' }],
  ],
  download: [
    ['path', { d: 'M12 3v12' }],
    ['path', { d: 'm7 10 5 5 5-5' }],
    ['path', { d: 'M5 21h14' }],
  ],
  user: [
    ['circle', { cx: '12', cy: '8', r: '4' }],
    ['path', { d: 'M4 21a8 8 0 0 1 16 0' }],
  ],
  fork: [
    ['circle', { cx: '6', cy: '5', r: '2.5' }],
    ['circle', { cx: '18', cy: '5', r: '2.5' }],
    ['circle', { cx: '12', cy: '19', r: '2.5' }],
    ['path', { d: 'M6 7.5V9a3 3 0 0 0 3 3h6a3 3 0 0 0 3-3V7.5' }],
    ['path', { d: 'M12 12v4.5' }],
  ],
  cpu: [
    ['rect', { x: '5', y: '5', width: '14', height: '14', rx: '2' }],
    ['path', { d: 'M9 9h6v6H9z' }],
    ['path', { d: 'M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3' }],
  ],
  layers: [
    ['path', { d: 'm12 2 10 5-10 5L2 7Z' }],
    ['path', { d: 'm2 12 10 5 10-5' }],
    ['path', { d: 'm2 17 10 5 10-5' }],
  ],
  msg: [
    ['path', { d: 'M21 12a8 8 0 0 1-11.6 7.1L3 21l1.9-6.4A8 8 0 1 1 21 12Z' }],
  ],
  down: [
    ['path', { d: 'M12 5v14' }],
    ['path', { d: 'm5 12 7 7 7-7' }],
  ],
  swap: [
    ['path', { d: 'M7 4 3 8l4 4' }],
    ['path', { d: 'M3 8h14' }],
    ['path', { d: 'm17 20 4-4-4-4' }],
    ['path', { d: 'M21 16H7' }],
  ],
};

/** The SVG attributes the glyph data may use, by the name React wants. */
const REACT_ATTRS: Readonly<Record<string, string>> = {
  d: 'd', cx: 'cx', cy: 'cy', r: 'r', x: 'x', y: 'y', rx: 'rx', ry: 'ry',
  width: 'width', height: 'height', fill: 'fill', stroke: 'stroke',
  'stroke-width': 'strokeWidth',
  'stroke-linecap': 'strokeLinecap',
  'stroke-linejoin': 'strokeLinejoin',
  'stroke-dasharray': 'strokeDasharray',
  'fill-rule': 'fillRule',
  'clip-rule': 'clipRule',
};

/** An attribute map in React's names. A name the table lacks is dropped, never passed on. */
export function reactAttrs(attrs: Readonly<Record<string, string>>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [name, value] of Object.entries(attrs)) {
    const mapped = REACT_ATTRS[name];
    if (mapped !== undefined) out[mapped] = value;
  }
  return out;
}
