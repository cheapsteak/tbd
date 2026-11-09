/**
 * Character references in markdown text, decoded as CommonMark decodes them: `&#39;`, `&#x27;`
 * and `&apos;` all show as `'`. `mdTree` decodes the text it shows from each text token's source
 * here, and never takes marked's own `text`, which marked writes for an HTML renderer: once a
 * text holds a numeric reference, marked decodes it and writes every other `&` in that text as
 * `&amp;`, which the app would show as typed.
 *
 * As in CommonMark, a reference stands for its character in text, a link's text and destination,
 * a heading, a list item and an image's alt text, and nowhere else: code spans, code blocks, raw
 * HTML and a table's source show as written. A link's destination is decoded before `safeLink`
 * checks it, so the check sees the URL the link opens (`link` in `mdTree.ts`). Decoding makes a
 * character and never markup: the tree holds it as text, so `&lt;b&gt;` shows as `<b>`.
 *
 * - **Numeric references**: `&#` and 1 to 7 decimal digits, or `&#x` (or `&#X`) and 1 to 6
 *   hexadecimal digits, then `;`. Zero, a surrogate, or a number past U+10FFFF shows as U+FFFD,
 *   as in CommonMark and marked.
 * - **Named references**: the 252 names of HTML 4 and `apos`, with the values HTML gives them now,
 *   which make `lang` and `rang` U+27E8 and U+27E9. They hold what prose writes: spaces,
 *   dashes, quotes, arrows, accented letters, Greek and common math. HTML has 2,125 names, most
 *   of them added for MathML, and their table would add about 11 KB gzipped to the bundle, where
 *   this one adds about 1.3 KB. A name outside it shows as written, as CommonMark shows a name it
 *   does not know.
 *
 * One pass of one regular expression whose every match is at most 34 characters long, so the
 * time grows with the text's length alone. Pure, so `node --test` loads it.
 */

/** A reference: `&#` and decimal digits, `&#x` and hexadecimal digits, or `&` and a name, then `;`. */
const REFERENCE = /&(?:#(\d{1,7})|#[xX]([0-9A-Fa-f]{1,6})|([A-Za-z][A-Za-z0-9]{0,31}));/g;

/** The character that stands for a reference to no character. */
const REPLACEMENT = '\ufffd';

/** `text` with each character reference replaced by its character (this file's header). */
export function decodeReferences(text: string): string {
  if (!text.includes('&')) return text;
  return text.replace(REFERENCE, (ref: string, dec?: string, hex?: string, name?: string) => {
    if (name !== undefined) return namedCharacter(name) ?? ref;
    const code = dec !== undefined ? Number.parseInt(dec, 10) : Number.parseInt(hex!, 16);
    if (code === 0 || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) return REPLACEMENT;
    return String.fromCodePoint(code);
  });
}

/**
 * Each name with its code point in hexadecimal, as `name:hex`, separated by spaces, in code point
 * order: the names of HTML 4 and `apos` (this file's header).
 */
const NAMES =
  'quot:22 amp:26 apos:27 lt:3c gt:3e nbsp:a0 iexcl:a1 cent:a2 pound:a3 curren:a4 yen:a5 brvbar:a6 sect:a7 uml:a8 ' +
  'copy:a9 ordf:aa laquo:ab not:ac shy:ad reg:ae macr:af deg:b0 plusmn:b1 sup2:b2 sup3:b3 acute:b4 micro:b5 para:b6 ' +
  'middot:b7 cedil:b8 sup1:b9 ordm:ba raquo:bb frac14:bc frac12:bd frac34:be iquest:bf Agrave:c0 Aacute:c1 Acirc:c2 ' +
  'Atilde:c3 Auml:c4 Aring:c5 AElig:c6 Ccedil:c7 Egrave:c8 Eacute:c9 Ecirc:ca Euml:cb Igrave:cc Iacute:cd Icirc:ce ' +
  'Iuml:cf ETH:d0 Ntilde:d1 Ograve:d2 Oacute:d3 Ocirc:d4 Otilde:d5 Ouml:d6 times:d7 Oslash:d8 Ugrave:d9 Uacute:da ' +
  'Ucirc:db Uuml:dc Yacute:dd THORN:de szlig:df agrave:e0 aacute:e1 acirc:e2 atilde:e3 auml:e4 aring:e5 aelig:e6 ' +
  'ccedil:e7 egrave:e8 eacute:e9 ecirc:ea euml:eb igrave:ec iacute:ed icirc:ee iuml:ef eth:f0 ntilde:f1 ograve:f2 ' +
  'oacute:f3 ocirc:f4 otilde:f5 ouml:f6 divide:f7 oslash:f8 ugrave:f9 uacute:fa ucirc:fb uuml:fc yacute:fd thorn:fe ' +
  'yuml:ff OElig:152 oelig:153 Scaron:160 scaron:161 Yuml:178 fnof:192 circ:2c6 tilde:2dc Alpha:391 Beta:392 ' +
  'Gamma:393 Delta:394 Epsilon:395 Zeta:396 Eta:397 Theta:398 Iota:399 Kappa:39a Lambda:39b Mu:39c Nu:39d Xi:39e ' +
  'Omicron:39f Pi:3a0 Rho:3a1 Sigma:3a3 Tau:3a4 Upsilon:3a5 Phi:3a6 Chi:3a7 Psi:3a8 Omega:3a9 alpha:3b1 beta:3b2 ' +
  'gamma:3b3 delta:3b4 epsilon:3b5 zeta:3b6 eta:3b7 theta:3b8 iota:3b9 kappa:3ba lambda:3bb mu:3bc nu:3bd xi:3be ' +
  'omicron:3bf pi:3c0 rho:3c1 sigmaf:3c2 sigma:3c3 tau:3c4 upsilon:3c5 phi:3c6 chi:3c7 psi:3c8 omega:3c9 thetasym:3d1 ' +
  'upsih:3d2 piv:3d6 ensp:2002 emsp:2003 thinsp:2009 zwnj:200c zwj:200d lrm:200e rlm:200f ndash:2013 mdash:2014 ' +
  'lsquo:2018 rsquo:2019 sbquo:201a ldquo:201c rdquo:201d bdquo:201e dagger:2020 Dagger:2021 bull:2022 hellip:2026 ' +
  'permil:2030 prime:2032 Prime:2033 lsaquo:2039 rsaquo:203a oline:203e frasl:2044 euro:20ac image:2111 weierp:2118 ' +
  'real:211c trade:2122 alefsym:2135 larr:2190 uarr:2191 rarr:2192 darr:2193 harr:2194 crarr:21b5 lArr:21d0 uArr:21d1 ' +
  'rArr:21d2 dArr:21d3 hArr:21d4 forall:2200 part:2202 exist:2203 empty:2205 nabla:2207 isin:2208 notin:2209 ni:220b ' +
  'prod:220f sum:2211 minus:2212 lowast:2217 radic:221a prop:221d infin:221e ang:2220 and:2227 or:2228 cap:2229 ' +
  'cup:222a int:222b there4:2234 sim:223c cong:2245 asymp:2248 ne:2260 equiv:2261 le:2264 ge:2265 sub:2282 sup:2283 ' +
  'nsub:2284 sube:2286 supe:2287 oplus:2295 otimes:2297 perp:22a5 sdot:22c5 lceil:2308 rceil:2309 lfloor:230a ' +
  'rfloor:230b loz:25ca spades:2660 clubs:2663 hearts:2665 diams:2666 lang:27e8 rang:27e9';

let named: ReadonlyMap<string, string> | null = null;

/** The character `name` stands for, or null for a name this file does not know. Names are case-sensitive, as in HTML. */
function namedCharacter(name: string): string | null {
  if (named === null) {
    const table = new Map<string, string>();
    for (const entry of NAMES.split(' ')) {
      const colon = entry.indexOf(':');
      table.set(entry.slice(0, colon), String.fromCodePoint(Number.parseInt(entry.slice(colon + 1), 16)));
    }
    named = table;
  }
  return named.get(name) ?? null;
}
