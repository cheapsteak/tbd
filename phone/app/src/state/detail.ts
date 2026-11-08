/**
 * One open detail of a transcript row: a tool call's input and result, the whole of a message
 * whose preview was cut, or a subagent's items, loaded chunk by chunk through
 * `transcript.detail` (spec section 7, "Large details"). The transcript slice holds each open
 * detail by its row's key (`TranscriptState.details` in `transcript.ts`), and `toggleDetail`
 * (`actions/transcript.ts`) sends the requests and folds each reply in with `addChunk`.
 *
 * **The chunk rules.** A detail asks for chunk 0 of its first part, then, one reply at a time,
 * for the next chunk while `chunk + 1 < chunkCount`, then for chunk 0 of the next part. Each
 * reply appends its `text`, or adds its `items`. One request is in flight per detail, and the
 * next goes out only once the last one's reply is in.
 *
 * **The laptop's numbers are not trusted.** A reply's `chunk`, `chunkCount`, `totalBytes`,
 * `tooLarge`, `part` and `itemID` can be wrong, and the phone must never ask without end nor
 * hold without bound because of them:
 * - **A reply that does not answer the request** (another part or chunk, a `chunkCount` that is
 *   not a positive integer, a text part with no `text`, a subagent with no `items`) is not
 *   added. The detail fails with the client's own words for a reply it cannot read,
 *   `BAD_REPLY_TEXT`, so it needs no copy of its own. The action checks `itemID` the same way.
 * - **`chunkCount` is read from a part's first reply** and capped at `MAX_DETAIL_CHUNKS`, the
 *   most an honest laptop sends for a part within the 1 MB limit. Past it, the part is too
 *   large: the phone keeps the first chunk and asks for no more of that part.
 * - **What the phone holds is capped, whatever the laptop says.** Once a text part passes
 *   `DETAIL_LIMIT_BYTES` in UTF-8, or a subagent's items pass it as JSON in UTF-8, or pass
 *   `MAX_SUBAGENT_ITEMS` in number, the detail is too large. The part holds at most the limit
 *   and one chunk, and one chunk fits one frame.
 * - **`totalBytes` is never read.** The phone counts what arrived.
 *
 * **Endings.** A part too large, by the laptop's `tooLarge` or by the caps above, keeps what
 * arrived of it and asks for no more of it, and the detail goes on to its next part, as a tool's
 * result after an input too large. It is named in `largeParts`, and the detail ends `tooLarge`
 * rather than `open`. An error fails the detail with its message, keeping what arrived. A
 * collapse (`cancelDetail`) drops what arrived, and `addChunk` drops every later reply.
 *
 * **Drawing.** A part of 1 MB can still be a million short lines, a page far taller than a phone
 * lays out well, so the pane draws at most `MAX_DETAIL_LINES` lines of a part (`firstLines`).
 *
 * Every function is pure and returns a new object when it changes anything.
 */

import { BAD_REPLY_TEXT } from '../client/client.ts';
import { utf8Length } from '../limits.ts';
import type { PhoneItem, TranscriptDetailPart, TranscriptDetailResult } from '../protocol/types.ts';

/** A detail over this many UTF-8 bytes is too large for the phone (`PhoneAppConstants.detailLimitBytes`). */
export const DETAIL_LIMIT_BYTES = 1_048_576;

/**
 * The laptop's budget for one chunk's text, as JSON-escaped bytes (`PhoneFrameBudget.detailChunkBytes`),
 * which keeps a chunk's reply within one frame (`MAX_BODY_BYTES` in `limits.ts`).
 */
export const DETAIL_CHUNK_BYTES = 60_000;

/**
 * The most chunks the phone asks for one part: 105. The laptop fills every chunk but the last
 * until the next scalar would pass its budget, and an escaped scalar takes at most 6 bytes
 * (`\u00XX`), so a full chunk takes at least `DETAIL_CHUNK_BYTES - 5` escaped bytes, and at
 * least a sixth of that in UTF-8: 10,000 bytes. A part within `DETAIL_LIMIT_BYTES` therefore has
 * at most 104 full chunks and a last one. A subagent's chunks are runs of whole items, each
 * filled nearly to the same budget, so its honest count is far lower.
 */
export const MAX_DETAIL_CHUNKS = Math.floor(DETAIL_LIMIT_BYTES / Math.ceil((DETAIL_CHUNK_BYTES - 5) / 6)) + 1;

/**
 * The most lines the pane draws of one text part: 20,000. Past them it shows "Too large for the
 * phone. Open on the laptop." A 1 MB text with no line break wraps to about 22,000 lines at a
 * phone's width (about 48 characters of the pane's mono text a line), so the cap holds a part of
 * short lines to about the height any 1 MB part takes, where a megabyte of line breaks alone
 * would draw a million.
 */
export const MAX_DETAIL_LINES = 20_000;

/**
 * The most subagent items the phone holds for one detail. They draw in one row of the list, so
 * the cap bounds that row too. A subagent with more shows its first ones and "Too large for the
 * phone. Open on the laptop."
 */
export const MAX_SUBAGENT_ITEMS = 1_000;

export interface DetailState {
  /** The parts to load, in order, such as `input` then `result` for a tool row. */
  parts: readonly TranscriptDetailPart[];
  /** The part loading now, as an index into `parts`. */
  partIndex: number;
  /** The chunk of that part asked for last. */
  chunk: number;
  /** How many chunks that part has, as its first result said, or 0 before it came. */
  chunkCount: number;
  /** Each text part's text so far, by part name. */
  text: Readonly<Partial<Record<TranscriptDetailPart, string>>>;
  /** A subagent's items so far. */
  items: readonly PhoneItem[];
  /** The UTF-8 bytes the part loading now holds: its text, or its items as JSON. */
  bytes: number;
  /** The parts that were too large for the phone, each keeping what arrived of it. */
  largeParts: readonly TranscriptDetailPart[];
  phase: 'loading' | 'open' | 'tooLarge' | 'failed';
  /** True once the reader collapsed the row: later results are dropped. */
  cancelled: boolean;
  /** The laptop's message when `phase` is `failed`. */
  error: string | null;
}

/** One `transcript.detail` request: which part, and which chunk of it. */
export interface DetailAsk {
  part: TranscriptDetailPart;
  chunk: number;
}

/**
 * The parts a tap on `item`'s row loads, from the part its row names: `input` loads the tool
 * call's input, then its result, and every other part loads itself (`text` for "Show more",
 * `subagent` for a subagent's items). A tool still running has no result yet, which the laptop
 * would answer `not_found`, so it loads its input alone.
 */
export function detailParts(part: TranscriptDetailPart, item: PhoneItem): readonly TranscriptDetailPart[] {
  if (part !== 'input') return [part];
  return item.toolStatus === 'running' ? ['input'] : ['input', 'result'];
}

/** A detail about to ask for chunk 0 of `parts[0]`. `parts` must not be empty. */
export function startDetail(parts: readonly TranscriptDetailPart[]): DetailState {
  return {
    parts, partIndex: 0, chunk: 0, chunkCount: 0, text: {}, items: [], bytes: 0, largeParts: [], phase: 'loading', cancelled: false, error: null,
  };
}

/** The request `d` waits on: the part loading now, and the chunk asked for last. */
export function askOf(d: DetailState): DetailAsk {
  return { part: d.parts[d.partIndex]!, chunk: d.chunk };
}

/**
 * `d` with one reply folded in, and the request to send next, or null when the detail is done.
 * See this file's header for the rules. A reply that comes once `d` is cancelled, or no longer
 * loading, changes nothing and asks for nothing.
 */
export function addChunk(d: DetailState, r: TranscriptDetailResult): { next: DetailState; ask: DetailAsk | null } {
  if (d.cancelled || d.phase !== 'loading') return { next: d, ask: null };
  const part = d.parts[d.partIndex]!;
  const first = d.chunk === 0;
  const chunkCount = first ? r.chunkCount : d.chunkCount;
  if (r.part !== part || r.chunk !== d.chunk || !Number.isSafeInteger(chunkCount) || chunkCount < 1) return badReply(d);

  let next: DetailState;
  let over: boolean;
  const held = first ? 0 : d.bytes;
  if (part === 'subagent') {
    if (r.items === undefined) return badReply(d);
    const room = MAX_SUBAGENT_ITEMS - d.items.length;
    const taken = r.items.length > room ? r.items.slice(0, room) : r.items;
    let bytes = held;
    for (const item of taken) bytes += utf8Length(JSON.stringify(item));
    next = { ...d, chunkCount, items: [...d.items, ...taken], bytes };
    over = taken.length < r.items.length || bytes > DETAIL_LIMIT_BYTES;
  } else {
    if (r.text === undefined) return badReply(d);
    const bytes = held + utf8Length(r.text);
    next = { ...d, chunkCount, text: { ...d.text, [part]: (first ? '' : (d.text[part] ?? '')) + r.text }, bytes };
    over = bytes > DETAIL_LIMIT_BYTES;
  }

  const large = r.tooLarge || over || chunkCount > MAX_DETAIL_CHUNKS;
  if (!large && d.chunk + 1 < chunkCount) {
    const ask = { part, chunk: d.chunk + 1 };
    return { next: { ...next, chunk: ask.chunk }, ask };
  }
  const largeParts = large ? [...d.largeParts, part] : d.largeParts;
  if (d.partIndex + 1 < d.parts.length) {
    const ask = { part: d.parts[d.partIndex + 1]!, chunk: 0 };
    return { next: { ...next, largeParts, partIndex: d.partIndex + 1, chunk: 0, chunkCount: 0, bytes: 0 }, ask };
  }
  return { next: { ...next, largeParts, phase: largeParts.length > 0 ? 'tooLarge' : 'open' }, ask: null };
}

/**
 * `text`'s first `max` lines, without the line break that ends the last of them, and whether
 * any line was left out. A text of `max` lines or fewer comes back whole.
 */
export function firstLines(text: string, max = MAX_DETAIL_LINES): { text: string; cut: boolean } {
  let end = -1;
  for (let line = 0; line < max; line += 1) {
    end = text.indexOf('\n', end + 1);
    if (end === -1) return { text, cut: false };
  }
  return end + 1 >= text.length ? { text, cut: false } : { text: text.slice(0, end), cut: true };
}

/** `d` failed with `message`, keeping what arrived. A cancelled detail stays as it is. */
export function failDetail(d: DetailState, message: string): DetailState {
  return d.cancelled ? d : { ...d, phase: 'failed', error: message };
}

/**
 * `d` collapsed: later results are dropped, and what arrived is let go, since a collapsed row
 * shows none of it and a tap loads it afresh.
 */
export function cancelDetail(d: DetailState): DetailState {
  return d.cancelled ? d : { ...d, cancelled: true, text: {}, items: [], bytes: 0 };
}

/** Whether `d` shows: loaded, loading or ended, and not collapsed. */
export function isOpen(d: DetailState | undefined): d is DetailState {
  return d !== undefined && !d.cancelled;
}

/**
 * `d` failed for a reply that does not answer its request, with the client's words for a reply it
 * cannot read (`BAD_REPLY_TEXT`), and nothing more to ask.
 */
export function badReply(d: DetailState): { next: DetailState; ask: null } {
  return { next: failDetail(d, BAD_REPLY_TEXT), ask: null };
}
