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
 * - **Only the first `MAX_MARKDOWN_LENGTH` characters are read as markdown.** The rest shows as
 *   plain lines. See there.
 * - **Nesting stops at `MAX_DEPTH`.** See there.
 * - **A tree holds about `MAX_NODES` nodes at most.** See there.
 * - **Texts drawn together can share those two caps** through an `MdBudget`, such as a
 *   subagent's items in one nest, so many texts cost about what one message does. See there.
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
 * The most characters of a message read as markdown. The rest shows as plain lines of its
 * source, after a cut `cutPoint` places.
 *
 * Several of marked's own rules take time that grows with the square of one paragraph's length,
 * whatever its nesting: an opening `*` or `_` with no partner, a run of `_` after a letter, an
 * unclosed link destination, the GitHub rule that looks for a bare URL or email at each `_`, `*`
 * or `.`. Measured in Node on marked 18.1.3, 64 KB of such text took 1 to 8 s, and 1 MB of `*.`
 * took 110 s. `Markdown` reads a message while it renders, so that time is a frozen screen. The
 * worst case known reads 6,144 characters in under 100 ms in Node, 8,192 in about 150 ms and 4,096
 * in about 40 ms. A preview is at most 4,096 UTF-8 bytes (`messagePreviewBytes`, 4b
 * `PhoneAppConstants.swift`), so it is always read whole, and "Show more" adds formatted text
 * before the plain lines start.
 */
export const MAX_MARKDOWN_LENGTH = 6_144;

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
 * What several texts drawn together may still spend between them: characters read as markdown,
 * and nodes. `mdTree` and `mdInline` take an optional budget, read at most its `markdown`
 * characters as markdown and stop at about its `nodes` nodes, each also within its own caps
 * (`MAX_MARKDOWN_LENGTH`, `MAX_NODES`), and take what they spent off it, so the next text gets
 * what is left. Past the markdown, a text shows as plain lines, and past the nodes, as one text
 * child holding the rest of its source. A text drawn alone, with no budget, has one message's
 * caps to itself.
 *
 * The markdown matters because the lexer's time can grow with the square of a paragraph's
 * length: many texts each read in full would each pay up to a message's worth. The nodes matter
 * because each is an element or text the page lays out.
 */
export interface MdBudget {
  markdown: number;
  nodes: number;
}

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
 * Past `MAX_MARKDOWN_LENGTH`, or what `budget` has left, the rest is one more paragraph of plain
 * lines. If the lexer fails anyway, the whole text shows as one paragraph of its lines.
 */
export function mdTree(src: string, budget?: MdBudget): MdNode[] {
  const all = src.replace(CRLF, '\n');
  const [head, rest] = splitForLexing(all, markdownLimit(budget));
  const walk = startWalk(budget);
  let tree: MdNode[];
  try {
    tree = blocks(new CappedLexer(lexOptions()).lex(head), 0, walk);
  } catch {
    const plain = startWalk(budget);
    const out = [count(plain, { t: 'p', children: lines(all, plain) })];
    spend(budget, head.length, plain);
    return out;
  }
  const tail = trimBreaks(rest.replace(/^\n+/, ''));
  if (tail !== '') tree.push(count(walk, { t: 'p', children: lines(tail, walk) }));
  spend(budget, head.length, walk);
  return tree;
}

/**
 * `src` as one run of inline markdown, as the mock's `inline` draws a message: code, emphasis,
 * links and line breaks, but no paragraphs, lists or other blocks, whose markers show as typed.
 * Past `MAX_MARKDOWN_LENGTH`, or what `budget` has left, the rest shows as plain lines. If the
 * lexer fails anyway, the whole text shows as its lines.
 */
export function mdInline(src: string, budget?: MdBudget): MdNode[] {
  const all = src.replace(CRLF, '\n');
  const [prefix, rest] = splitForLexing(all, markdownLimit(budget));
  // A cut after line breaks: the lexer draws none at the end of its text, so they are drawn here.
  const cut = rest === '' ? { start: prefix.length, breaks: 0 } : trailingBreaks(prefix);
  const walk = startWalk(budget);
  let tree: MdNode[];
  try {
    tree = inlines(new CappedLexer(lexOptions()).inlineTokens(prefix.slice(0, cut.start)), 0, false, walk);
  } catch {
    const plain = startWalk(budget);
    const out = lines(all, plain);
    spend(budget, prefix.length, plain);
    return out;
  }
  for (let i = 0; i < cut.breaks; i += 1) tree.push(count(walk, { t: 'br' }));
  for (const node of lines(trimBreaks(rest), walk)) tree.push(node);
  spend(budget, prefix.length, walk);
  return tree;
}

/** The most characters a text reads as markdown: `MAX_MARKDOWN_LENGTH`, or less when `budget` has less left. */
function markdownLimit(budget: MdBudget | undefined): number {
  return budget === undefined ? MAX_MARKDOWN_LENGTH : Math.max(0, Math.min(MAX_MARKDOWN_LENGTH, budget.markdown));
}

/** A walk that stops at `MAX_NODES` nodes, or at what `budget` has left. */
function startWalk(budget: MdBudget | undefined): Walk {
  return { nodes: 0, max: budget === undefined ? MAX_NODES : Math.max(0, Math.min(MAX_NODES, budget.nodes)) };
}

/** Takes `read` characters of markdown and the walk's nodes off `budget`. */
function spend(budget: MdBudget | undefined, read: number, walk: Walk): void {
  if (budget === undefined) return;
  budget.markdown -= read;
  budget.nodes -= walk.nodes;
}

/**
 * Where the line breaks at the end of `value` start, with the spaces and tabs among and before
 * them, and how many there are. With none, the end of `value` and 0. A loop, not a regular
 * expression anchored at the end, which would take time growing with the square of a long run.
 */
function trailingBreaks(value: string): { start: number; breaks: number } {
  let start = value.length;
  let breaks = 0;
  while (start > 0) {
    const ch = value.charCodeAt(start - 1);
    if (ch === 0x0a) breaks += 1;
    else if (ch !== 0x20 && ch !== 0x09) break;
    start -= 1;
  }
  return breaks === 0 ? { start: value.length, breaks: 0 } : { start, breaks };
}

/**
 * `text` split into the part read as markdown and the rest, which shows as plain lines: the
 * whole text and nothing when it fits `limit` characters, at most `MAX_MARKDOWN_LENGTH`.
 */
function splitForLexing(text: string, limit: number): [head: string, rest: string] {
  if (text.length <= limit) return [text, ''];
  const cut = cutPoint(text.slice(0, limit));
  return [text.slice(0, cut), text.slice(cut)];
}

/**
 * Where markdown stops in a text longer than `MAX_MARKDOWN_LENGTH`, given its first that many
 * characters: just after the last blank line when one falls in the second half, else after the
 * last line break, else after the last space or tab, else at the end, never between the two
 * halves of a surrogate pair.
 *
 * A blank line ends every paragraph, so no code span, link or emphasis crosses that cut, and the
 * part before it reads as it does in the whole text, with two differences that only take away. A
 * reference link whose definition comes after the cut shows as its text. A block that can hold
 * blank lines (a code fence, an indented code block, an HTML block, a loose list) ends at the
 * cut: a fence or HTML block left open runs to the end of the part read and shows what it holds
 * as code or source text, which is what it is, and the rest shows as plain lines either way.
 *
 * A cut at a line break or a space can fall inside a paragraph, and so inside a code span or a
 * link's text that continues past it. Then the part read has an opening backtick or bracket with
 * no partner, which shows as itself, and the text after it reads as markdown: code from that span
 * can show as emphasis, or as a link. Such a link has passed `safeLink`, and the loader's sheet
 * shows the whole URL and asks before opening it (`renderLinkSheet` in `phone/loader/ui.js`), so
 * the cost is a misdrawn span, never a hidden destination.
 * Only a message with no blank line in the second half of its first 6,144 characters is cut there.
 */
function cutPoint(window: string): number {
  let afterBlank = -1;
  for (const match of window.matchAll(BLANK_LINE)) afterBlank = match.index + match[0].length + 1;
  if (afterBlank >= window.length / 2) return afterBlank;
  const lineEnd = window.lastIndexOf('\n');
  if (lineEnd >= 0) return lineEnd + 1;
  const space = Math.max(window.lastIndexOf(' '), window.lastIndexOf('\t'));
  if (space >= 0) return space + 1;
  const last = window.charCodeAt(window.length - 1);
  return last >= 0xd800 && last <= 0xdbff ? window.length - 1 : window.length;
}

/** A line break followed by a blank line: spaces and tabs, then the next line break. */
const BLANK_LINE = /\n[ \t]*(?=\n)/g;

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

/** How many nodes the tree being built holds so far, and about the most it may hold. */
interface Walk {
  nodes: number;
  max: number;
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
 * `rule` applied to each token in turn, until the tree holds `walk.max` nodes. Then the rest of
 * the tokens show as one text child holding their source.
 */
function each(tokens: readonly Token[], walk: Walk, rule: (token: Token) => MdNode[]): MdNode[] {
  const out: MdNode[] = [];
  for (let i = 0; i < tokens.length; i += 1) {
    if (walk.nodes >= walk.max) {
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
    if (walk.nodes >= walk.max) {
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

/**
 * `value` without the line breaks at its end. A loop, not `/\n+$/`, which takes time growing with
 * the square of a long run of line breaks that is not at the end.
 */
function trimBreaks(value: string): string {
  let end = value.length;
  while (end > 0 && value.charCodeAt(end - 1) === 0x0a) end -= 1;
  return value.slice(0, end);
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
