/**
 * What the transcript's live region says (`TranscriptView`'s header): the rows that just came in
 * at the bottom, as the words a screen reader reads. The list itself is no live region, since
 * the rows the virtualizer draws as the reader scrolls would read as if they had just arrived.
 *
 * - **Which rows.** Only rows that came in at the bottom, new items or a receipt
 *   (`rowsChange` reads `appended`): never the rows of an open, a reopen or a reset, an older
 *   page, or rows drawn as the reader scrolls.
 * - **What each says** (`spoken`), in the row's own words and no others: a message from the
 *   reader, Claude or a peer says its text, as plain text without its markdown marks; a receipt
 *   says its text; a tool call says its tool's name and its target, as the row shows them. Any
 *   other row (a file edit, a subagent, a slash command, thinking, a system note) says nothing.
 * - **How much.** The last `ANNOUNCE_ROWS` rows that say something, each cut to
 *   `ANNOUNCE_CHARS` characters, so a burst of rows or a long message cannot flood the reader.
 *
 * Everything here is pure.
 */

import { mdInline, mdTree, type MdNode } from '../markdown/mdTree.ts';
import type { TranscriptRow } from '../state/transcript.ts';

/** The most rows one announcement says. */
export const ANNOUNCE_ROWS = 3;

/** The most characters one row says. */
export const ANNOUNCE_CHARS = 500;

/** The words a screen reader hears for `row`, cut to `ANNOUNCE_CHARS`, or null for a row that says nothing. */
export function spoken(row: TranscriptRow): string | null {
  let words: string;
  if (row.kind === 'receipt') {
    words = row.text;
  } else {
    const it = row.item;
    const text = it.text ?? '';
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

/** What the live region says for `arrived`, the rows that came in at the bottom, oldest first: a line for each of the last few that say something. */
export function announcement(arrived: readonly TranscriptRow[]): string[] {
  const lines: string[] = [];
  for (let i = arrived.length - 1; i >= 0 && lines.length < ANNOUNCE_ROWS; i--) {
    const said = spoken(arrived[i]!);
    if (said !== null) lines.unshift(said);
  }
  return lines;
}

/** The rows of `rows` after the one keyed `lastKey`, looked for from the bottom; none when it is gone. */
export function rowsAfter(rows: readonly TranscriptRow[], lastKey: number | null): readonly TranscriptRow[] {
  if (lastKey === null) return [];
  for (let i = rows.length - 1; i >= 0; i--) {
    if (rows[i]!.key === lastKey) return rows.slice(i + 1);
  }
  return [];
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

/** `s` cut to its first `max` UTF-16 units, never inside a surrogate pair. */
function cut(s: string, max: number): string {
  if (s.length <= max) return s;
  const code = s.charCodeAt(max - 1);
  return s.slice(0, code >= 0xd800 && code <= 0xdbff ? max - 1 : max);
}
