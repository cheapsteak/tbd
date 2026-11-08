// Tests references.ts: character references decode as CommonMark decodes them, numeric ones in
// full and named ones for the names of HTML 4 and `apos`, and anything else stays as written.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { decodeReferences } from './references.ts';

test('numeric references decode to their characters, and one to no character to U+FFFD', () => {
  assert.equal(decodeReferences("it&#39;s a & b"), "it's a & b");
  assert.equal(decodeReferences('&#38; &#x26; &#X26; &#60;b&#62; &#34;q&#34; &#x27;s'), '& & & <b> "q" \'s');
  assert.equal(decodeReferences('&#128512; &#x1F600; &#x10FFFF;'), '😀 😀 \u{10ffff}');
  for (const ref of ['&#0;', '&#x0;', '&#xD800;', '&#xdfff;', '&#1114112;', '&#x110000;', '&#9999999;']) {
    assert.equal(decodeReferences(ref), '�', ref);
  }
  // Too many digits, no digits, no semicolon, or a space inside: as written.
  for (const text of ['&#12345678;', '&#x1234567;', '&#;', '&#x;', '&#39', '&# 39;', '&#x 27;', '&#-1;']) {
    assert.equal(decodeReferences(text), text);
  }
});

test('named references decode for the names of HTML 4 and apos, case and all', () => {
  const named: Array<[string, string]> = [
    ['&amp;', '&'], ['&lt;', '<'], ['&gt;', '>'], ['&quot;', '"'], ['&apos;', "'"], ['&nbsp;', ' '], ['&copy;', '©'],
    ['&eacute;', 'é'], ['&Eacute;', 'É'], ['&mdash;', '—'], ['&ndash;', '–'], ['&hellip;', '…'], ['&rarr;', '→'],
    ['&rArr;', '⇒'], ['&le;', '≤'], ['&ne;', '≠'], ['&Omega;', 'Ω'], ['&thetasym;', 'ϑ'], ['&euro;', '€'], ['&zwj;', '‍'],
    ['&lang;', '⟨'], ['&rang;', '⟩'],
  ];
  for (const [ref, ch] of named) assert.equal(decodeReferences(ref), ch, ref);
  assert.equal(decodeReferences('a &amp; b &lt;c&gt; &quot;d&quot;'), 'a & b <c> "d"');
  // A name it does not know, a name in another case, and a name with no semicolon stay as written.
  for (const text of ['&nope;', '&AMP;', '&Copy;', '&check;', '&copy', '&amp ;', '& amp;', '&', '&;', '&1;']) {
    assert.equal(decodeReferences(text), text);
  }
});

test('a decoded character never joins its neighbours into another reference', () => {
  assert.equal(decodeReferences('&amp;lt;'), '&lt;');
  assert.equal(decodeReferences('&#38;#39;'), '&#39;');
  assert.equal(decodeReferences('&amp;amp;'), '&amp;');
});

test('a long text of near references decodes in time that grows with its length alone', () => {
  const MB = 1 << 20;
  for (const unit of ['&', '&#', '&#x', '&#1234567', '&a', `&${'a'.repeat(40)}`, '&amp;']) {
    const src = unit.repeat(Math.floor(MB / unit.length));
    const started = performance.now();
    const out = decodeReferences(src);
    const ms = performance.now() - started;
    assert.ok(ms < 500, `${Math.round(ms)} ms on ${unit}`);
    assert.equal(out.length > 0, true);
  }
});
