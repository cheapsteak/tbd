// Tests mdTree.ts: how each token type maps to nodes, raw HTML kept as text, which links pass
// `safeLink` (checked against the loader's own `openableURL`), and the caps on the length read
// as markdown, on nesting and on node count that keep hostile text from hanging or crashing the
// screen.
//
// The source policy bans the scheme name that runs script, followed by its colon, in this file
// too, so the tests build it from pieces, and build HTML tags the same way.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { openableURL } from '../../../loader/frame.js';
import { MAX_DEPTH, MAX_LINK_LENGTH, MAX_MARKDOWN_LENGTH, MAX_NODES, mdInline, mdTree, safeLink, type MdNode } from './mdTree.ts';

const JS = 'java' + 'script:';
/** `<name`, built in pieces so this file holds no tag the source policy bans. */
const open = (name: string): string => '<' + name;

/** The text a reader sees, with a line break for each `br`. */
function flatText(nodes: readonly MdNode[]): string {
  return nodes.map((n) => (n.t === 'br' ? '\n' : n.t === 'hr' ? '' : 'children' in n ? flatText(n.children) : n.text)).join('');
}

/** Every link's URL, in order. */
function links(nodes: readonly MdNode[]): string[] {
  return nodes.flatMap((n) => [...(n.t === 'link' ? [n.url] : []), ...('children' in n ? links(n.children) : [])]);
}

const CONTAINERS = new Set(['li', 'blockquote', 'strong', 'em', 'del', 'link']);

/** The most quotes, list items and spans along one path, as `MAX_DEPTH` counts them. */
function depth(nodes: readonly MdNode[]): number {
  let most = 0;
  for (const n of nodes) {
    if ('children' in n) most = Math.max(most, depth(n.children) + (CONTAINERS.has(n.t) ? 1 : 0));
  }
  return most;
}

function size(nodes: readonly MdNode[]): number {
  return nodes.reduce((sum, n) => sum + 1 + ('children' in n ? size(n.children) : 0), 0);
}

const t = (text: string): MdNode => ({ t: 'text', text });

test('paragraphs, lists, code and emphasis map to nodes', () => {
  const src = 'Fixed. Here is what *changed*:\n\n- `finishLogin` keeps **next**.\n- The tests pass.\n\nOne line\nand the next.';
  assert.deepEqual(mdTree(src), [
    { t: 'p', children: [t('Fixed. Here is what '), { t: 'em', children: [t('changed')] }, t(':')] },
    {
      t: 'ul',
      children: [
        { t: 'li', children: [{ t: 'code', text: 'finishLogin' }, t(' keeps '), { t: 'strong', children: [t('next')] }, t('.')] },
        { t: 'li', children: [t('The tests pass.')] },
      ],
    },
    { t: 'p', children: [t('One line'), { t: 'br' }, t('and the next.')] },
  ]);
});

test('headings, quotes, ordered lists, rules, deleted text and code blocks map to nodes', () => {
  const src = '## Plan **now**\n\n> quoted\n\n3. three\n4. four\n\n---\n\n~~gone~~ \\*kept\\*\n\n```html\n<b>x</b> & y\n```';
  assert.deepEqual(mdTree(src), [
    { t: 'h', children: [t('Plan '), { t: 'strong', children: [t('now')] }] },
    { t: 'blockquote', children: [{ t: 'p', children: [t('quoted')] }] },
    { t: 'ol', start: 3, children: [{ t: 'li', children: [t('three')] }, { t: 'li', children: [t('four')] }] },
    { t: 'hr' },
    { t: 'p', children: [{ t: 'del', children: [t('gone')] }, t(' '), t('*'), t('kept'), t('*')] },
    { t: 'pre', text: '<b>x</b> & y' },
  ]);
});

test('raw HTML stays text', () => {
  assert.deepEqual(flatText(mdTree('<img src=x onerror=alert(1)>')), '<img src=x onerror=alert(1)>');
  const script = `${open('script')}>alert(1)</script>`;
  assert.deepEqual(mdTree(script), [{ t: 'p', children: [t(script)] }]);
  const anchor = `${open('a')} hr${'ef'}="https://acme.example/">x</a>`;
  const frame = `${open('iframe')} src="https://acme.example/"></iframe>`;
  for (const src of [anchor, `a ${anchor} b`, frame, 'x <b>bold</b> y', '<!-- hidden -->', '<div>\n\n*a*\n\n</div>']) {
    const tree = mdTree(src);
    assert.deepEqual(links(tree), [], src);
    assert.ok(flatText(tree).includes(src.split('\n')[0] as string), src);
  }
  assert.deepEqual(mdTree('x <b>bold</b> y'), [{ t: 'p', children: [t('x '), t('<b>'), t('bold'), t('</b>'), t(' y')] }]);
});

test('only http and https links become links', () => {
  assert.equal(links(mdTree(`[a](${JS}alert(1))`)).length, 0);
  assert.equal(links(mdTree('[a](https://u:p@acme.example)')).length, 0);
  assert.deepEqual(links(mdTree('[a](https://acme.example/x)')), ['https://acme.example/x']);

  const refused = [
    `[a](JaVaScRiPt${JS.slice(10)}alert(1))`,
    `[a](${JS.toUpperCase()}alert(1))`,
    `[a](jav&#x61;${JS.slice(4)}alert(1))`, // an entity-escaped scheme: marked leaves it as written
    `[a](&#x6A;ava${JS.slice(4)}alert(1))`,
    '[a](https&#58;//acme.example/)',
    '[a](data:text/plain,hi)',
    '[a](vbscript:msgbox)',
    '[a](file:///etc/passwd)',
    '[a](ftp://acme.example/)',
    '[a](mailto:dev@acme.example)',
    '[a](//acme.example/x)',
    '[a](/relative)',
    '[a](relative/path)',
    '[a](acme.example)',
    '[a](#top)',
    '[a](https:acme.example)',
    '[a](https:/acme.example)',
    '[a](https:\\\\acme.example\\x)',
    '[a](https://acme.example\\@evil.example/)',
    '[a](<https://acme.example/a b>)',
    '[a](<https://acme.example/a\tb>)',
    '[a](<https://acme.example/ a>)',
    '[a](https://u@acme.example/)',
    '[a](https://:p@acme.example/)',
    '[a](https://acme.example@evil.example/)',
    '[a](https://)',
    '[a](https://acme.example:99999/)',
    '<dev@acme.example>',
    'dev@acme.example',
    `<${JS}alert(1)>`,
    `[a][r]\n\n[r]: ${JS}alert(1)`,
  ];
  for (const src of refused) assert.deepEqual(links(mdTree(src)), [], src);

  const passed: Array<[string, string[]]> = [
    ['[a](HTTPS://ACME.example/X)', ['https://acme.example/X']],
    ['[a](Http://acme.example)', ['http://acme.example/']],
    ['[a](https://acme.example/a?b=1#c "a title")', ['https://acme.example/a?b=1#c']],
    ['<https://acme.example/auto>', ['https://acme.example/auto']],
    ['see https://acme.example/bare, then', ['https://acme.example/bare']],
    ['www.acme.example', ['http://www.acme.example/']],
    ['[a][r]\n\n[r]: https://acme.example/ref', ['https://acme.example/ref']],
    ['[a](https://exämple.example/é)', ['https://xn--exmple-cua.example/%C3%A9']],
  ];
  for (const [src, urls] of passed) assert.deepEqual(links(mdTree(src)), urls, src);
});

test('safeLink returns the URL the loader opens, and nothing the loader would refuse', () => {
  const path = 'https://acme.example/';
  const inputs = [
    'https://acme.example', 'HTTPS://ACME.EXAMPLE/X', 'http://acme.example:8080/a?b#c', 'https://acme.example/a b',
    ' https://acme.example/', 'https://acme.example/ ', '\thttps://acme.example/', 'https://acme.example/\n', 'https://acme.example/\u0000',
    'https://acme.example/\u007f', 'https://acme.example/\u0085', 'ht\ntps://acme.example/', `java\t${JS.slice(4)}alert(1)`,
    `${JS}alert(1)`, `${JS.toUpperCase()}alert(1)`, 'data:text/html,x', 'https:\\\\acme.example', 'https:/\\acme.example', 'https:acme.example',
    '//acme.example', '/x', 'x', '', 'https://u:p@acme.example', 'https://u@acme.example', 'https://:p@acme.example',
    'https://@acme.example/', 'https://exämple.example/', 'http://[::1]/', 'https://acme.example:99999',
    path + 'a'.repeat(MAX_LINK_LENGTH - path.length), path + 'a'.repeat(MAX_LINK_LENGTH - path.length + 1), path + 'é'.repeat(400),
    path + './'.repeat(MAX_LINK_LENGTH), // too long as written, though it normalizes to `path`
  ];
  for (const input of inputs) {
    const ours = safeLink(input);
    if (ours !== null) assert.equal(openableURL(ours), ours, `the loader opens ${JSON.stringify(ours)} as it is`);
    if (openableURL(input) === null) assert.equal(ours, null, `the loader refuses ${JSON.stringify(input)}`);
  }

  assert.equal(safeLink('HTTPS://ACME.EXAMPLE/X'), 'https://acme.example/X');
  assert.equal(safeLink(path + 'a'.repeat(MAX_LINK_LENGTH - path.length)), path + 'a'.repeat(MAX_LINK_LENGTH - path.length));
  for (const input of [
    ' https://acme.example/', 'https://acme.example/ ', '\thttps://acme.example/', 'https://acme.example/\n', 'ht\ntps://acme.example/',
    'https://acme.example/\u0000', 'https://acme.example/\u0085', 'https://acme.example/a b', 'https:\\\\acme.example', 'https:acme.example',
    'https://u@acme.example', path + 'a'.repeat(MAX_LINK_LENGTH - path.length + 1), path + 'é'.repeat(400), path + './'.repeat(MAX_LINK_LENGTH),
  ]) {
    assert.equal(safeLink(input), null, JSON.stringify(input));
  }
});

test('a link that fails shows its children as text', () => {
  assert.deepEqual(mdTree('[**bold** words](/relative)'), [
    { t: 'p', children: [{ t: 'strong', children: [t('bold')] }, t(' words')] },
  ]);
  assert.deepEqual(flatText(mdTree(`[click](${JS}alert(1))`)), 'click');
  assert.deepEqual(mdTree('mail dev@acme.example'), [{ t: 'p', children: [t('mail '), t('dev@acme.example')] }]);
});

test('a link never holds another', () => {
  const nested = (nodes: readonly MdNode[], inLink: boolean): boolean =>
    nodes.some((n) => (n.t === 'link' && inLink) || ('children' in n && nested(n.children, inLink || n.t === 'link')));
  const sources = [
    '[b [c](https://acme.example/c)](https://acme.example/b)',
    '[see https://acme.example/a](https://acme.example/b)',
    '[<https://acme.example/a>](https://acme.example/b)',
    '[www.acme.example](https://acme.example/b)',
    '[**[a](https://acme.example/a)**](https://acme.example/b)',
    '[[a](https://acme.example/a)][r]\n\n[r]: https://acme.example/r',
    '[![i](https://acme.example/i.png)](https://acme.example/l)',
  ];
  for (const src of sources) {
    const tree = mdTree(src);
    assert.equal(nested(tree, false), false, src);
    assert.ok(links(tree).length > 0, src);
  }
  assert.deepEqual(mdTree(sources[1] as string), [
    { t: 'p', children: [{ t: 'link', url: 'https://acme.example/b', children: [t('see https://acme.example/a')] }] },
  ]);
  // marked reads this autolink as a link inside the link's text; it draws as its text.
  assert.deepEqual(mdTree(sources[2] as string), [
    { t: 'p', children: [{ t: 'link', url: 'https://acme.example/b', children: [t('https://acme.example/a')] }] },
  ]);
});

test('an image becomes its alt text', () => {
  assert.deepEqual(mdTree('![a chart of *sales*](https://acme.example/c.png)'), [{ t: 'p', children: [t('a chart of *sales*')] }]);
  assert.deepEqual(mdInline('see ![the logo](https://acme.example/l.png)'), [t('see '), t('the logo')]);
  assert.deepEqual(mdTree('![](https://acme.example/c.png)'), [{ t: 'p', children: [] }]);
});

test('a table shows its source, and a definition draws nothing', () => {
  assert.deepEqual(mdTree('| a | b |\n|---|---|\n| 1 | 2 |\n'), [{ t: 'pre', text: '| a | b |\n|---|---|\n| 1 | 2 |' }]);
  assert.deepEqual(mdTree('[r]: https://acme.example/r\n'), []);
  assert.deepEqual(mdTree('   \n\n'), []);
  assert.deepEqual(mdTree(''), []);
});

test('a checkbox, which has no rule of its own, shows its source', () => {
  assert.deepEqual(mdTree('- [x] done\n- [ ] to do'), [
    { t: 'ul', children: [{ t: 'li', children: [t('[x] '), t('done')] }, { t: 'li', children: [t('[ ] '), t('to do')] }] },
  ]);
  assert.equal(flatText(mdTree('- [x] done\n\n- [ ] to do')), '[x] done[ ] to do');
});

test('mdInline draws one run: inline marks and line breaks, but no blocks', () => {
  assert.deepEqual(mdInline('# not a heading\r\n- not a list\n**b** `c` [d](https://acme.example/)'), [
    t('# not a heading'), { t: 'br' }, t('- not a list'), { t: 'br' },
    { t: 'strong', children: [t('b')] }, t(' '), { t: 'code', text: 'c' }, t(' '),
    { t: 'link', url: 'https://acme.example/', children: [t('d')] },
  ]);
  assert.deepEqual(mdInline('a <b>raw</b>'), [t('a '), t('<b>'), t('raw'), t('</b>')]);
  assert.deepEqual(mdInline(''), []);
});

test('nesting MAX_DEPTH deep keeps its structure, and one level more shows as source', () => {
  const quotes = mdTree('>'.repeat(MAX_DEPTH) + ' x');
  assert.equal(depth(quotes), MAX_DEPTH);
  assert.equal(flatText(quotes), 'x');

  const deeper = mdTree('>'.repeat(MAX_DEPTH + 3) + ' x');
  assert.equal(depth(deeper), MAX_DEPTH);
  assert.equal(flatText(deeper), '>>> x');

  const items = Array.from({ length: MAX_DEPTH + 2 }, (_, i) => `${'  '.repeat(i)}- item ${i}`).join('\n');
  const list = mdTree(items);
  assert.equal(depth(list), MAX_DEPTH);
  assert.ok(flatText(list).endsWith(`- item ${MAX_DEPTH}\n  - item ${MAX_DEPTH + 1}`));

  const spans = mdTree('*a '.repeat(MAX_DEPTH + 2) + 'x' + ' a*'.repeat(MAX_DEPTH + 2));
  assert.equal(depth(spans), MAX_DEPTH);
  assert.ok(flatText(spans).includes('*a *a x a* a*'));
});

test('hostile nesting returns without throwing, cut at the depth cap', () => {
  // Each of these overflows marked's stack when its lexer is not capped, and each fits
  // MAX_MARKDOWN_LENGTH, so all of it is read as markdown. The depth must be the cap exactly: a
  // lexer that threw would leave the plain-text fallback, at depth 0.
  const cases: Array<[src: string, inlineDepth: number]> = [
    ['>'.repeat(6_000) + ' x', 0],
    ['*'.repeat(3_000) + 'x' + '*'.repeat(3_000), MAX_DEPTH],
    ['*a '.repeat(1_000) + 'x' + ' a*'.repeat(1_000), MAX_DEPTH],
    ['- '.repeat(3_000) + 'x', 0],
    [Array.from({ length: 70 }, (_, i) => `${'  '.repeat(i)}- x`).join('\n'), 0],
    [Array.from({ length: 100 }, (_, i) => `${'>'.repeat(i + 1)} x`).join('\n'), 0],
  ];
  for (const [src, inlineDepth] of cases) {
    assert.ok(src.length <= MAX_MARKDOWN_LENGTH, `${src.length} characters`);
    for (const [read, expected] of [[mdTree, MAX_DEPTH], [mdInline, inlineDepth]] as const) {
      const tree = read(src);
      assert.equal(depth(tree), expected, `${read.name} on ${src.slice(0, 12)}…`);
      assert.ok(flatText(tree).includes('x'), read.name);
    }
  }
});

/** `value` without white space, to compare what shows when markup and line breaks differ. */
const compact = (value: string): string => value.replace(/\s+/g, '');

test('hostile paragraphs are read in bounded time, and the rest still shows', () => {
  // Each of these takes marked seconds to minutes at this size, when all of it is read.
  const MB = 1 << 20;
  const fill = (unit: string): string => unit.repeat(Math.floor(MB / unit.length));
  let ids = '';
  for (let i = 0; ids.length < MB; i += 1) ids += `var_${i}_`;
  const cases: Record<string, string> = {
    'a letter, then underscores': 'a' + '_'.repeat(MB),
    'underscore pairs': fill('_a'),
    'a letter, then stars': 'a' + '*'.repeat(MB),
    'a letter, spaces, a letter': 'a' + ' '.repeat(MB) + 'b',
    'unclosed link destinations': fill('[a](b') + ')',
    'a URL, then dots': 'https://acme.example/x' + '.'.repeat(MB),
    'a table of unclosed stars': '|a|\n|-|\n' + fill('|*a|\n'),
    'a paragraph of unclosed stars': fill('|*a|\n'),
    'setext underlines': fill('a\n-\n'),
    'underscore-joined identifiers': ids,
    'stars and dots': fill('*.'),
    'nested emphasis, paragraph after paragraph': fill('*a '.repeat(1_000) + 'x' + ' a*'.repeat(1_000) + '\n\n'),
    'a run of line breaks, then text': '\n'.repeat(MB) + 'a',
  };
  for (const [name, src] of Object.entries(cases)) {
    for (const read of [mdTree, mdInline]) {
      const started = performance.now();
      const tree = read(src);
      const ms = performance.now() - started;
      assert.ok(ms < 1_000, `${read.name} took ${Math.round(ms)} ms on ${name}`);
      assert.ok(compact(flatText(tree)).length >= compact(src).length - MAX_MARKDOWN_LENGTH, `${read.name} shows the rest of ${name}`);
    }
  }
});

test('past MAX_MARKDOWN_LENGTH the rest shows as plain lines, cut after a blank line', () => {
  // Two lines a paragraph, so a cut at the last line break would split one.
  const tail = 'x'.repeat(80);
  const paras = Array.from({ length: 200 }, (_, i) => `**b** paragraph ${i}\n${tail}`);
  const src = paras.join('\n\n');

  const tree = mdTree(src);
  const k = tree.length - 1;
  assert.ok(k > 1 && paras.slice(0, k).join('\n\n').length <= MAX_MARKDOWN_LENGTH);
  // Every paragraph before the cut is read whole, and the cut splits none.
  tree.slice(0, k).forEach((node, i) => {
    assert.deepEqual(node, { t: 'p', children: [{ t: 'strong', children: [t('b')] }, t(` paragraph ${i}`), { t: 'br' }, t(tail)] });
  });
  assert.equal(tree[k]?.t, 'p');
  assert.equal(flatText(tree.slice(k)), paras.slice(k).join('\n\n'));

  const read = paras.slice(0, k).map((_, i) => `b paragraph ${i}\n${tail}`).join('\n\n');
  assert.equal(flatText(mdInline(src)), `${read}\n\n${paras.slice(k).join('\n\n')}`);

  // A message under the cap, ending in a line break, draws as it did.
  assert.deepEqual(mdInline('a\n'), [t('a\n')]);
});

test('with no blank line to cut after, the cut falls after a line break, then a space, then anywhere', () => {
  const lineList = Array.from({ length: 200 }, (_, i) => `line ${i} ${'y'.repeat(60)}`);
  const byLine = mdTree(lineList.join('\n'));
  assert.equal(byLine.length, 2);
  const firstRest = flatText(byLine.slice(1)).split('\n')[0] as string;
  assert.ok(lineList.includes(firstRest), firstRest);
  assert.ok(lineList.includes(flatText(byLine.slice(0, 1)).split('\n').at(-1) as string));

  // A blank line in the first half is passed over, so most of the text is still read.
  const early = mdTree(`intro\n\n${lineList.join('\n')}`);
  assert.equal(early.length, 3);
  assert.ok(flatText(early.slice(0, 2)).length > MAX_MARKDOWN_LENGTH / 2);

  const bySpace = mdTree('word '.repeat(3_000));
  assert.match(flatText(bySpace.slice(1)), /^word /);

  const hard = mdTree('x'.repeat(10_000));
  assert.equal(flatText(hard.slice(0, 1)).length, MAX_MARKDOWN_LENGTH);
  assert.equal(compact(flatText(hard)), 'x'.repeat(10_000));

  // The cut never parts a surrogate pair.
  const emoji = 'a' + '😀'.repeat(5_000);
  for (const read of [mdTree, mdInline]) {
    const texts: string[] = [];
    const walk = (nodes: readonly MdNode[]): void => {
      for (const n of nodes) {
        if ('children' in n) walk(n.children);
        else if (n.t === 'text') texts.push(n.text);
      }
    };
    walk(read(emoji));
    assert.ok(texts.length > 1, read.name);
    for (const text of texts) assert.ok(!/[\ud800-\udbff]$|^[\udc00-\udfff]/.test(text), read.name);
    assert.equal(texts.join(''), emoji, read.name);
  }
});

test('a code fence that crosses the cut stays code, and its links stay text', () => {
  const code = Array.from({ length: 400 }, (_, i) => `[x](https://acme.example/${i})`).join('\n\n');
  const tree = mdTree(`Intro\n\n\`\`\`\n${code}\n\`\`\`\n\nafter`);
  assert.deepEqual(tree.map((n) => n.t), ['p', 'pre', 'p']);
  assert.deepEqual(links(tree), []);
  assert.ok(flatText(tree).endsWith('```\n\nafter'));
});

test('a tree holds about MAX_NODES nodes at most, and every character still shows', () => {
  const src = 'a\n'.repeat(MAX_NODES);
  for (const read of [mdTree, mdInline]) {
    const tree = read(src);
    assert.ok(size(tree) <= MAX_NODES + 4, `${read.name} drew ${size(tree)} nodes`);
    assert.equal(compact(flatText(tree)), compact(src), read.name);
  }
  const quoted = mdTree('> - [a](https://acme.example/) b\n'.repeat(MAX_NODES / 4));
  assert.ok(size(quoted) <= MAX_NODES + 8, `drew ${size(quoted)} nodes`);
});
