/**
 * Markdown as plain data, for the transcript on the phone.
 *
 * marked's lexer reads a message into tokens, and `mdTree` maps each token to an `MdNode`: an
 * element of a fixed kind, a text child, or a link the app has checked. `Markdown.tsx` draws the
 * nodes as React elements. Nothing in either file makes an HTML string. marked's parser, its
 * renderer, `parse`, `parseInline` and `use` are never called (spec section 9), so raw HTML in a
 * transcript shows as its source text and never runs, and no sanitizer is needed.
 *
 * Transcript text comes from the laptop and can hold text an outsider chose, such as a web page
 * the agent fetched and quoted. A message fetched in full through "Show more" can be 1 MB. So
 * every rule here is bounded:
 * - **Every token type has a rule.** The types in `block` and `inline` map to nodes. `space`
 *   draws nothing, and so does `def`, a reference link's definition, which no markdown renderer
 *   shows (its link shows where it is used). Any other type, a future one included, shows its
 *   source text, never markup.
 * - **Links pass only through `safeLink`**, which is at least as strict as the loader's own check,
 *   so the app never offers a link the loader would refuse. A link that fails shows its text.
 * - **Nesting stops at `MAX_DEPTH`.** See there.
 * - **A tree holds about `MAX_NODES` nodes at most.** See there.
 *
 * Pure, with no React, so `node --test` loads it.
 */

import { Lexer, getDefaults, type MarkedOptions, type Token, type Tokens, type TokensList } from 'marked';

export type MdNode =
  | { t: 'p' | 'ul' | 'li' | 'blockquote' | 'strong' | 'em' | 'del' | 'h'; children: MdNode[] }
  | { t: 'ol'; start: number; children: MdNode[] }
  | { t: 'text'; text: string }
  | { t: 'code'; text: string }
  | { t: 'pre'; text: string }
  | { t: 'br' }
  | { t: 'hr' }
  | { t: 'link'; url: string; children: MdNode[] };

/** The longest link the app offers: the loader's own limit, `MAX_OPENABLE_URL_LENGTH` in `phone/loader/frame.js`. */
export const MAX_LINK_LENGTH = 2_048;

/**
 * How deep quotes, list items, strong, em, del and links may nest, counted together along one
 * path. A quote, item or span that would be one deeper shows as its markdown source text.
 *
 * marked's lexer reads each level's text again for the level inside it, so its time grows with
 * the text's length times its depth, and its stack with the depth alone. Measured in Node on
 * marked 18.1.3: 5,000 nested `>` or a run of 10,000 `*` overflow its stack, and 850 KB of
 * emphasis nested 1,000 deep takes 15 s. Real transcripts nest a few levels, such as a quote in a
 * list item in a list, so 16 leaves room for them and holds the lexer to a fixed number of
 * passes over the text. The lexer the app runs, `CappedLexer`, stops reading nesting just past
 * the depth the tree draws, so its cut never shows.
 */
export const MAX_DEPTH = 16;

/**
 * About the most nodes one tree holds. Past it, the rest of the list of tokens being read shows
 * as one text child holding their source, and so does each enclosing list's rest. The line
 * breaks in that text are not drawn. A 1 MB message of short lines would otherwise draw about a
 * million nodes, more than a phone can lay out without stalling. Ordinary text stays far under:
 * 1 MB of 80-character lines draws about 25,000.
 */
export const MAX_NODES = 50_000;

/**
 * `target` as the normalized URL the loader opens, when it is a link the app offers; otherwise
 * null. It must start with `http://` or `https://` in any case of letters, hold no ASCII control
 * character, space, DEL, C1 control or backslash, parse as an absolute http or https URL with no
 * user name or password, and be at most 2,048 characters long both as written and normalized.
 *
 * That is the loader's `openableURL` (`phone/loader/frame.js`) plus the character and prefix
 * rules. The URL parser drops tabs and newlines anywhere and controls and spaces at either end,
 * reads a backslash as a slash, and fills in the slashes of `https:acme.example`, so a link
 * written that way would go somewhere other than its source says. A relative link, `//host`, and
 * any other scheme (mail, data, script, file) never pass. marked leaves character references in a
 * link's destination as written, so an entity-escaped scheme fails the prefix rule.
 *
 * It returns the normalized `href`, not `target`, so the app holds exactly the string the loader
 * checks and opens: `openableURL` returns it unchanged, nothing normalizes it a second time, and
 * the length rule applies to what is sent. A host in Unicode arrives in its ASCII form.
 */
export function safeLink(target: string): string | null {
  if (target.length > MAX_LINK_LENGTH || UNSAFE_LINK_CHAR.test(target) || !WEB_PREFIX.test(target)) return null;
  let url: URL;
  try {
    url = new URL(target);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return null;
  if (url.username !== '' || url.password !== '') return null;
  const { href } = url;
  return href.length <= MAX_LINK_LENGTH ? href : null;
}

/** ASCII controls and space, DEL, the C1 controls, and the backslash. */
const UNSAFE_LINK_CHAR = /[\u0000-\u0020\u007f-\u009f\\]/;
const WEB_PREFIX = /^https?:\/\//i;

/**
 * `src` as block markdown: paragraphs, lists, quotes, code blocks, headings and rules, with
 * GitHub's extensions and a line break wherever the text has one, as the mock's `md` draws them.
 * If the lexer fails anyway, the text shows as one paragraph of its lines.
 */
export function mdTree(src: string): MdNode[] {
  const walk: Walk = { nodes: 0 };
  try {
    return blocks(new CappedLexer(lexOptions()).lex(src), 0, walk);
  } catch {
    const plain: Walk = { nodes: 0 };
    return [count(plain, { t: 'p', children: lines(src.replace(CRLF, '\n'), plain) })];
  }
}

/**
 * `src` as one run of inline markdown, as the mock's `inline` draws a message: code, emphasis,
 * links and line breaks, but no paragraphs, lists or other blocks, whose markers show as typed.
 * If the lexer fails anyway, the text shows as its lines.
 */
export function mdInline(src: string): MdNode[] {
  const text = src.replace(CRLF, '\n');
  const walk: Walk = { nodes: 0 };
  try {
    return inlines(new CappedLexer(lexOptions()).inlineTokens(text), 0, false, walk);
  } catch {
    return lines(text, { nodes: 0 });
  }
}

const CRLF = /\r\n?/g;

/**
 * marked's defaults, with GitHub's extensions and `breaks`, which makes each line break in a
 * paragraph a `br`. A fresh object each time, because a lexer keeps its tokenizer on the options
 * it is given, and so the lexer never reads marked's shared defaults.
 */
function lexOptions(): MarkedOptions {
  return { ...getDefaults(), gfm: true, breaks: true };
}

/** The type of the token `CappedLexer` leaves where it stops reading. It draws as its source text. */
const CUT = 'tbd-cut';

/**
 * marked's lexer, stopped from reading nesting deeper than `MAX_DEPTH`. marked reads a quote's or
 * list item's text through `blockTokens` and a span's text through `inlineTokens`, one call per
 * level, and the inline text of each paragraph afterwards, from the top. Past `MAX_DEPTH` levels
 * of either, the text is left as one `CUT` token. The tree has already cut there or above.
 */
class CappedLexer extends Lexer {
  #depth = 0;

  override blockTokens(src: string, tokens?: Token[], lastParagraphClipped?: boolean): Token[];
  override blockTokens(src: string, tokens?: TokensList, lastParagraphClipped?: boolean): TokensList;
  override blockTokens(src: string, tokens: Token[] = [], lastParagraphClipped = false): Token[] {
    return this.#nested(src, tokens, () => super.blockTokens(src, tokens, lastParagraphClipped));
  }

  override inlineTokens(src: string, tokens: Token[] = []): Token[] {
    return this.#nested(src, tokens, () => super.inlineTokens(src, tokens));
  }

  #nested(src: string, tokens: Token[], read: () => Token[]): Token[] {
    if (this.#depth > MAX_DEPTH) {
      tokens.push({ type: CUT, raw: src });
      return tokens;
    }
    this.#depth += 1;
    try {
      return read();
    } finally {
      this.#depth -= 1;
    }
  }
}

/** How many nodes the tree being built holds so far. */
interface Walk {
  nodes: number;
}

/** `node`, counted. Every node is made through this or `text`. */
function count<N extends MdNode>(walk: Walk, node: N): N {
  walk.nodes += 1;
  return node;
}

function text(walk: Walk, value: string): MdNode {
  return count(walk, { t: 'text', text: value });
}

/** A token's source, or nothing when it has none. */
function source(token: Token, walk: Walk): MdNode[] {
  return typeof token.raw === 'string' && token.raw !== '' ? [text(walk, token.raw)] : [];
}

/** A token's child tokens, or null when it has none, in which case it shows as its source. */
function kids(token: Token): Token[] | null {
  const { tokens } = token as { tokens?: unknown };
  return Array.isArray(tokens) ? (tokens as Token[]) : null;
}

/**
 * `rule` applied to each token in turn, until the tree holds `MAX_NODES` nodes. Then the rest of
 * the tokens show as one text child holding their source.
 */
function each(tokens: readonly Token[], walk: Walk, rule: (token: Token) => MdNode[]): MdNode[] {
  const out: MdNode[] = [];
  for (let i = 0; i < tokens.length; i += 1) {
    if (walk.nodes >= MAX_NODES) {
      out.push(text(walk, tokens.slice(i).map((t) => (typeof t.raw === 'string' ? t.raw : '')).join('')));
      break;
    }
    for (const node of rule(tokens[i] as Token)) out.push(node);
  }
  return out;
}

/**
 * The node `make` builds one level deeper than `level`, or the token's source when that level
 * would be deeper than `MAX_DEPTH`.
 */
function nest(token: Token, level: number, walk: Walk, make: (inner: number) => MdNode): MdNode[] {
  return level >= MAX_DEPTH ? source(token, walk) : [count(walk, make(level + 1))];
}

/** `value`'s lines, each a text child, with a `br` between them. */
function lines(value: string, walk: Walk): MdNode[] {
  const out: MdNode[] = [];
  let start = 0;
  while (start <= value.length) {
    if (walk.nodes >= MAX_NODES) {
      if (start < value.length) out.push(text(walk, value.slice(start)));
      break;
    }
    const end = value.indexOf('\n', start);
    if (end === -1) {
      if (start < value.length) out.push(text(walk, value.slice(start)));
      break;
    }
    if (end > start) out.push(text(walk, value.slice(start, end)));
    out.push(count(walk, { t: 'br' }));
    start = end + 1;
  }
  return out;
}

/** `value` without the line breaks at its end. */
function trimBreaks(value: string): string {
  return value.replace(/\n+$/, '');
}

/** Block tokens at `level`, the number of quotes, list items and spans around them. */
function blocks(tokens: readonly Token[], level: number, walk: Walk): MdNode[] {
  return each(tokens, walk, (token) => block(token, level, walk));
}

function block(token: Token, level: number, walk: Walk): MdNode[] {
  const children = kids(token);
  switch (token.type) {
    case 'space':
    case 'def':
      return [];
    case 'paragraph':
      return children === null ? source(token, walk) : [count(walk, { t: 'p', children: inlines(children, level, false, walk) })];
    case 'heading':
      return children === null ? source(token, walk) : [count(walk, { t: 'h', children: inlines(children, level, false, walk) })];
    case 'text':
      // The text of a list item with no blank lines between its items, holding inline tokens.
      return children === null ? [text(walk, (token as Tokens.Text).text)] : inlines(children, level, false, walk);
    case 'blockquote':
      if (children === null) return source(token, walk);
      return nest(token, level, walk, (inner) => ({ t: 'blockquote', children: blocks(children, inner, walk) }));
    case 'list':
      return list(token as Tokens.List, level, walk);
    case 'code':
      return [count(walk, { t: 'pre', text: (token as Tokens.Code).text })];
    case 'hr':
      return [count(walk, { t: 'hr' })];
    case 'html':
      // A block of raw HTML, shown as its source, line by line.
      return [count(walk, { t: 'p', children: lines(trimBreaks(token.raw), walk) })];
    case 'table':
      // A table, shown as its source in a monospaced block that keeps its columns.
      return [count(walk, { t: 'pre', text: trimBreaks(token.raw) })];
    default:
      // A task item's checkbox (`[x] `), the lexer's cut, and any type marked adds later.
      return source(token, walk);
  }
}

function list(token: Tokens.List, level: number, walk: Walk): MdNode[] {
  if (!Array.isArray(token.items)) return source(token, walk);
  const items = each(token.items, walk, (item) => {
    const children = kids(item);
    if (item.type !== 'list_item' || children === null) return source(item, walk);
    return nest(item, level, walk, (inner) => ({ t: 'li', children: blocks(children, inner, walk) }));
  });
  if (!token.ordered) return [count(walk, { t: 'ul', children: items })];
  return [count(walk, { t: 'ol', start: typeof token.start === 'number' ? token.start : 1, children: items })];
}

/**
 * Inline tokens at `level`. `inLink` is true inside a link's text. marked can put a link there,
 * an autolink such as `[<https://acme.example/>](https://acme.example/b)`, and that one draws as
 * its text, so a link node never holds another.
 */
function inlines(tokens: readonly Token[], level: number, inLink: boolean, walk: Walk): MdNode[] {
  return each(tokens, walk, (token) => inline(token, level, inLink, walk));
}

function inline(token: Token, level: number, inLink: boolean, walk: Walk): MdNode[] {
  const children = kids(token);
  switch (token.type) {
    case 'text':
      return children === null ? [text(walk, (token as Tokens.Text).text)] : inlines(children, level, inLink, walk);
    case 'escape':
      return [text(walk, (token as Tokens.Escape).text)];
    case 'codespan':
      return [count(walk, { t: 'code', text: (token as Tokens.Codespan).text })];
    case 'br':
      return [count(walk, { t: 'br' })];
    case 'strong':
    case 'em':
    case 'del': {
      if (children === null) return source(token, walk);
      const t = token.type;
      return nest(token, level, walk, (inner) => ({ t, children: inlines(children, inner, inLink, walk) }));
    }
    case 'link':
      return children === null ? source(token, walk) : link(token as Tokens.Link, children, level, inLink, walk);
    case 'image': {
      // No image loads from a transcript: it shows its alt text, as written.
      const alt = (token as Tokens.Image).text;
      return alt === '' ? [] : [text(walk, alt)];
    }
    case 'html':
      // An inline tag or comment, shown as its source.
      return [text(walk, token.raw)];
    default:
      // A checkbox, the lexer's cut, and any type marked adds later.
      return source(token, walk);
  }
}

/** A link when it is not inside one and `safeLink` passes its destination; otherwise its text. */
function link(token: Tokens.Link, children: Token[], level: number, inLink: boolean, walk: Walk): MdNode[] {
  const url = inLink ? null : safeLink(token.href);
  if (url === null) return inlines(children, level, inLink, walk);
  return nest(token, level, walk, (inner) => ({ t: 'link', url, children: inlines(children, inner, true, walk) }));
}
