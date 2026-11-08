/**
 * What the transcript's live region says (`TranscriptView`'s header): the rows that just came in
 * at the bottom, or changed there, as the words a screen reader reads. The list itself is no live
 * region, since the rows the virtualizer draws as the reader scrolls would read as if they had
 * just arrived.
 *
 * - **Which rows.** Rows that came in at the bottom, new items or a receipt (`rowsChange` reads
 *   `appended`), and a message among the last `ANNOUNCE_ROWS` rows whose text changed in place,
 *   as when its text comes after its row: it says its new words, once (`changedWords`). A tool
 *   whose status changes, a receipt that changes, and a row further up say nothing. Never the
 *   rows of an open, a reopen or a reset, an older page, or rows drawn as the reader scrolls.
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
  let words: string;
  if (row.kind === 'receipt') {
    words = row.text;
  } else {
    const it = row.item;
    const text = cut(it.text ?? '', ANNOUNCE_SOURCE_CHARS);
    switch (it.kind) {
      case 'assistant':
        words = plainText(mdTree(text));
        break;
      case 'user':
      case 'peer':
        words = plainText(mdInline(text));
        break;
      case 'tool':
        words = `${it.toolName ?? ''} ${it.target ?? ''}`;
        break;
      default:
        return null;
    }
  }
  const said = words.replace(/\s+/g, ' ').trim();
  return said === '' ? null : cut(said, ANNOUNCE_CHARS);
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

/** The kinds of row whose text changing in place is said again: messages from the reader, Claude and a peer. */
const MESSAGE_KINDS: ReadonlySet<string> = new Set(['user', 'assistant', 'peer']);

/**
 * The new words of `row` when it is a message that changed in place since `before`: `before`
 * holds it, by its key, with other text, and its words now are not empty and not the ones it
 * said then. Null for any other row, so a tool whose status changes says nothing.
 */
function changedWords(row: TranscriptRow, before: readonly TranscriptRow[]): string | null {
  if (row.kind !== 'item' || !MESSAGE_KINDS.has(row.item.kind)) return null;
  const was = before.find((r) => r.key === row.key);
  if (was === undefined || was === row || was.kind !== 'item' || was.item.text === row.item.text) return null;
  const said = spoken(row);
  return said !== null && said !== spoken(was) ? said : null;
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
