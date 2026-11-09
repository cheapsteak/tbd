/**
 * What the transcript's live region says (`TranscriptView`'s header): the rows that just came in
 * at the bottom, or changed there, as the words a screen reader reads. The list itself is no live
 * region, since the rows the virtualizer draws as the reader scrolls would read as if they had
 * just arrived.
 *
 * - **Which rows.** Rows that came in at the bottom, new items or a receipt (`rowsChange` reads
 *   `appended`), and a message among the last `ANNOUNCE_ROWS` rows whose text changed in place,
 *   as when its text comes after its row: it says its new words, once (`changedWords`), which are
 *   the words its row draws after the old ones when the new text extends the old, as a message
 *   written as it streams does.
 *   A tool whose status changes, a receipt that changes, and a row further up say nothing. Never
 *   the rows of an open, a reopen or a reset, an older page, or rows drawn as the reader scrolls.
 * - **What each says** (`spoken`), in the row's own words and no others: a message from the
 *   reader, Claude or a peer says its text, as plain text without its markdown marks; a receipt
 *   says its text; a tool call says its tool's name and its target, as the row shows them. Any
 *   other row (a file edit, a subagent, a slash command, thinking, a system note) says nothing.
 * - **How much.** The last `ANNOUNCE_ROWS` rows that say something, each cut to
 *   `ANNOUNCE_CHARS` characters, so a burst of rows or a long message cannot flood the reader.
 * - **What it costs.** A message's words come from its first `ANNOUNCE_SOURCE_CHARS` characters
 *   only, read as markdown, since the list works out an announcement as it lays its rows out.
 *   Read whole, a message would cost up to `MAX_MARKDOWN_LENGTH` characters of markdown, whose
 *   time can grow with the square of a paragraph's length (`markdown/mdTree.ts`), to keep 500.
 *   A message whose text grew is read with its old text, at most `ANNOUNCE_SOURCE_CHARS`
 *   characters of it, so at most twice those characters in all.
 *
 * Everything here is pure.
 */

import { mdInline, mdTree, pairSafeEnd, type MdNode } from '../markdown/mdTree.ts';
import type { TranscriptRow } from '../state/transcript.ts';

/** The most rows one announcement says. */
export const ANNOUNCE_ROWS = 3;

/** The most characters one row says. */
export const ANNOUNCE_CHARS = 500;

/**
 * The most characters of a message read for its words: twice what a row says, so the marks of
 * ordinary markdown still leave about `ANNOUNCE_CHARS` of words, while heavy markup, such as a
 * run of links, says less. Marks that close past them show as typed.
 */
export const ANNOUNCE_SOURCE_CHARS = 2 * ANNOUNCE_CHARS;

/** The words a screen reader hears for `row`, cut to `ANNOUNCE_CHARS`, or null for a row that says nothing. */
export function spoken(row: TranscriptRow): string | null {
  if (row.kind === 'receipt') return said(row.text);
  const it = row.item;
  switch (it.kind) {
    case 'assistant':
    case 'user':
    case 'peer':
      return messageWords(it.kind, it.text ?? '');
    case 'tool':
      return said(`${it.toolName ?? ''} ${it.target ?? ''}`);
    default:
      return null;
  }
}

/** The kinds of row whose text is a message, read as markdown. */
type MessageKind = 'assistant' | 'user' | 'peer';

/**
 * The words of a message of `kind` whose text is `text`, as `spoken` says them: its first
 * `ANNOUNCE_SOURCE_CHARS` characters read as markdown, as the row draws it (`mdTree` for Claude,
 * `mdInline` for the reader and a peer), its plain text cut to `ANNOUNCE_CHARS`.
 */
function messageWords(kind: MessageKind, text: string): string | null {
  return said(plainWords(kind, cut(text, ANNOUNCE_SOURCE_CHARS)));
}

/**
 * The plain text of `text` read as markdown, as a message of `kind` draws it, with each run of
 * white space as one space, uncut.
 */
function plainWords(kind: MessageKind, text: string): string {
  return plainText(kind === 'assistant' ? mdTree(text) : mdInline(text)).replace(/\s+/g, ' ').trim();
}

/** `words` with each run of white space as one space, cut to `ANNOUNCE_CHARS`, or null when nothing is left. */
function said(words: string): string | null {
  const one = words.replace(/\s+/g, ' ').trim();
  return one === '' ? null : cut(one, ANNOUNCE_CHARS);
}

/**
 * What the live region says for `rows`, oldest first: a line for each of the last few rows that
 * say something, of the rows that came in at the bottom, the last `arrived` of `rows`, and the
 * messages above them among the last `ANNOUNCE_ROWS` rows that changed in place since `before`,
 * the last rows as the list last saw them (`lastRows`).
 */
export function announcement(rows: readonly TranscriptRow[], arrived: number, before: readonly TranscriptRow[]): string[] {
  const lines: string[] = [];
  const firstArrived = rows.length - arrived;
  const lowest = rows.length - ANNOUNCE_ROWS;
  for (let i = rows.length - 1; i >= 0 && (i >= firstArrived || i >= lowest) && lines.length < ANNOUNCE_ROWS; i--) {
    const row = rows[i]!;
    const said = i >= firstArrived ? spoken(row) : changedWords(row, before);
    if (said !== null) lines.unshift(said);
  }
  return lines;
}

/** The last `ANNOUNCE_ROWS` of `rows`, which the list keeps to tell next time which changed in place (`announcement`). */
export function lastRows(rows: readonly TranscriptRow[]): readonly TranscriptRow[] {
  return rows.slice(Math.max(0, rows.length - ANNOUNCE_ROWS));
}

/**
 * The new words of `row` when it is a message that changed in place since `before`, which holds
 * it, by its key, with other text. Null for any other row, so a tool whose status changes says
 * nothing.
 * - **Text that extends the old text**, as a message's does while it streams, says the words its
 *   row draws after the ones it drew before, cut to `ANNOUNCE_CHARS`. Both texts are read as
 *   markdown, the old one whole and the new one up to `ANNOUNCE_SOURCE_CHARS` characters past
 *   the old, so an addition reads as its row draws it: inside the code block, link or emphasis
 *   the old text left open. When the old words do not begin the new ones, as when an addition
 *   closes a link or emphasis the old text opened, it says the new text's start, as any other
 *   change does.
 * - **Past `ANNOUNCE_SOURCE_CHARS` characters of old text**, the addition alone is read, as
 *   `spoken` reads a message, so a message past those characters still says each addition.
 * - **Any other change** says the new text's start, as `spoken` does, when its words are not
 *   empty and not the ones it said then.
 */
function changedWords(row: TranscriptRow, before: readonly TranscriptRow[]): string | null {
  if (row.kind !== 'item') return null;
  const { kind } = row.item;
  if (kind !== 'assistant' && kind !== 'user' && kind !== 'peer') return null;
  const was = before.find((r) => r.key === row.key);
  if (was === undefined || was === row || was.kind !== 'item' || was.item.text === row.item.text) return null;
  const old = was.item.text ?? '';
  const now = row.item.text ?? '';
  if (now.startsWith(old)) {
    if (old.length > ANNOUNCE_SOURCE_CHARS) return messageWords(kind, now.slice(pairSafeEnd(now, old.length)));
    const oldWords = plainWords(kind, old);
    const newWords = plainWords(kind, cut(now, old.length + ANNOUNCE_SOURCE_CHARS));
    if (newWords.startsWith(oldWords)) return said(newWords.slice(pairSafeEnd(newWords, oldWords.length)));
  }
  const words = spoken(row);
  return words !== null && words !== spoken(was) ? words : null;
}

/** The text of a markdown tree, with a space between its blocks and in place of each line break. */
function plainText(nodes: readonly MdNode[]): string {
  const out: string[] = [];
  const walk = (list: readonly MdNode[]): void => {
    for (const n of list) {
      switch (n.t) {
        case 'text':
        case 'code':
          out.push(n.text);
          break;
        case 'pre':
          out.push(' ', n.text, ' ');
          break;
        case 'br':
        case 'hr':
          out.push(' ');
          break;
        case 'link':
        case 'strong':
        case 'em':
        case 'del':
          walk(n.children);
          break;
        default:
          out.push(' ');
          walk(n.children);
          out.push(' ');
      }
    }
  };
  walk(nodes);
  return out.join('');
}

/** `s` cut to its first `max` UTF-16 units, never inside a surrogate pair (`pairSafeEnd`). */
function cut(s: string, max: number): string {
  return s.length <= max ? s : s.slice(0, pairSafeEnd(s, max));
}
