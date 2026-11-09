/**
 * The transcript slice of `AppState`: the one transcript the laptop sends this phone, as rows in
 * order, with its paging cursor, its open details and the receipts left in it (spec section 7).
 * Everything here is pure. The actions in `actions/transcript.ts` send the requests and fold
 * the replies in with these functions; `applyEvent` (`events.ts`) folds in the events.
 *
 * **Row keys.** Every row gets a key, `nextKey`, as it enters the slice, and keeps it until a
 * page replaces the rows. The list, the reader's anchor and the open details all use the key.
 * An item's ID is used only to find the row a `transcript.update` or a same-ID append replaces,
 * and to name the item in a `transcript.detail` request. The laptop names a line with no `uuid`
 * by its byte offset (`at-<offset>`), and a remote session's earlier history, prepended to the
 * laptop's cache, shifts those offsets (4b `Transcript/TranscriptFeed.swift:79-87, 96-100`). So
 * an ID can name another line after a prepend, two rows can carry the same ID, and the slice
 * never drops or merges rows by ID.
 *
 * **Which events fold in.** An event or a receipt folds in only while the slice shows the
 * transcript it is for: `phase` is `open` and its session is `ref`. While an open is on its way
 * (`opening`), events are dropped, and that loses nothing. The laptop starts sending an open's
 * events only after its reply, so an event that comes before the reply is from the feed the
 * open replaces, and the open's page and the events after it hold all of that. A resume
 * (`beginResume`) leaves the slice `open`: the laptop replays what the phone missed before it
 * answers, and those events must land on the rows the resume keeps. A failed open holds no
 * transcript, so nothing folds in then either.
 *
 * **Older pages on the wire.** One open has at most one `transcript.page` on the wire: the one
 * the slice waits on (`olderRequestID`), or one a reset or a resume's page made stale, which
 * holds the open's turn until it settles (`heldPageID`). A new open, of another session or of
 * the same one, and a close leave the page they made stale on the wire without its holding the
 * turn, so the next open pages at once. Those pages are counted (`stalePages`), and while
 * `MAX_STALE_PAGES` of them are unanswered no page is asked for, so a laptop that stops
 * answering pages takes at most `MAX_STALE_PAGES + 1` of the client's slots however often the
 * reader reopens (`mayAskOlder`). A stale page's reply never touches the rows, since only the
 * page the slice waits on counts.
 *
 * Each function returns a new object when it changes anything, and `s` itself when it does
 * not, so the store does not notify.
 */

import type { AppEvent, PhoneItem, PhoneSessionRef, TranscriptPage } from '../protocol/types.ts';
import { sameRef } from '../protocol/wire.ts';
import { followItem } from './detail.ts';
import type { DetailState } from './detail.ts';

/** One row of the transcript: an item the laptop sent, or a receipt for an answered prompt, keyed by the prompt's ID. */
export type TranscriptRow = { key: number; kind: 'item'; item: PhoneItem } | { key: number; kind: 'receipt'; id: string; text: string };

export interface TranscriptState {
  /** The session whose transcript the slice holds or is opening, or null when none is open. */
  ref: PhoneSessionRef | null;
  /** The "Show details" setting the open was sent with. A resume sends it again. */
  showDetails: boolean;
  /**
   * The token of the latest open or resume (`beginOpen`, `beginResume`). A reply counts only
   * while its request's token is still this one.
   */
  openRequestID: string | null;
  /**
   * - `idle`: no transcript is open.
   * - `opening`: a `transcript.open` is on its way. The rows are the ones shown before, for a
   *   reopen of the same session, or none. A resume stays `open` (`beginResume`).
   * - `open`: the rows are the laptop's transcript.
   * - `failed`: the open failed with `error`. There are no rows.
   */
  phase: 'idle' | 'opening' | 'open' | 'failed';
  error: string | null;
  rows: readonly TranscriptRow[];
  /** The key the next row gets. It only grows, so a key never names a second row. */
  nextKey: number;
  /** Asks for the page above the rows. Null once the start is reached. */
  cursor: string | null;
  reachedStart: boolean;
  /**
   * The token of the `transcript.page` on its way for these rows (`loadOlder`), or null while
   * none is. Each older page takes a fresh token, and its reply counts only while this is still
   * its token, so a reply never takes the wait of a later page for its own. Every open, reset
   * and close ends the wait (`dropOlder`), and so does the page's own reply.
   */
  olderRequestID: string | null;
  /**
   * The token of a `transcript.page` this open asked for rows that a reset or a resume's page
   * has since replaced, while it is unanswered; null otherwise. It holds this open's one page
   * turn, so none is asked for these rows until it settles (`settleStalePage`), and the list
   * then asks again if it still wants one. A new open or a close clears it (this file's header).
   */
  heldPageID: string | null;
  /**
   * How many `transcript.page` requests made stale by a page, an open or a close are
   * unanswered, this open's held one included, across every open since the app started. At
   * `MAX_STALE_PAGES`, none is asked for until one settles.
   */
  stalePages: number;
  /**
   * The last older page failed to load, or moved the scroll back nowhere: it added no row, or
   * gave back the cursor it was asked with (`prependPage`). Nothing asks for another until the
   * reader scrolls, or touches rows that fit the screen.
   */
  olderFailed: boolean;
  /**
   * A `transcript.close` went out unanswered, so the laptop may still keep a transcript open
   * for this phone.
   */
  pendingClose: boolean;
  /** The open details, by row key. */
  details: Readonly<Record<number, DetailState>>;
  /**
   * How many rows came in at the bottom since a page last replaced the rows: new items from
   * `transcript.append`, and new receipts. A rise in it tells the list that rows arrived below,
   * and by how many.
   */
  appendedSinceSeen: number;
  /**
   * How many times the rows were replaced: by a page (an open's, a reopen's, a reset's) or by
   * a clear. It only grows, as `nextKey` does, so a change in it tells the list that a page took
   * the place of the rows, and a rise in `appendedSinceSeen` alone that rows came in below, an
   * empty transcript's first items included.
   */
  replacements: number;
}

/** The slice with no transcript open. */
export function emptyTranscript(): TranscriptState {
  return {
    ref: null,
    showDetails: false,
    openRequestID: null,
    phase: 'idle',
    error: null,
    rows: [],
    nextKey: 0,
    cursor: null,
    reachedStart: false,
    olderRequestID: null,
    heldPageID: null,
    stalePages: 0,
    olderFailed: false,
    pendingClose: false,
    details: {},
    appendedSinceSeen: 0,
    replacements: 0,
  };
}

/**
 * `s` with no transcript open: every field as `emptyTranscript` has it, except `nextKey`, which
 * only grows, so a key never names a second row, `stalePages`, since the stale pages are still
 * on the wire (`dropOlder`), and `replacements`, which only grows too and counts this.
 */
export function clearTranscript(s: TranscriptState): TranscriptState {
  return { ...emptyTranscript(), nextKey: s.nextKey, stalePages: dropOlder(s, false).stalePages, replacements: s.replacements + 1 };
}

/**
 * The paging fields once the rows an older page was asked for are gone: the slice no longer
 * waits for that page, and while it was on its way, it is still on the wire, so it counts as
 * stale (`stalePages`). Within the same open (`sameOpen`), as after a reset, it holds the
 * open's turn (`heldPageID`); a new open or a close frees the turn for the next rows.
 */
function dropOlder(s: TranscriptState, sameOpen: boolean): Pick<TranscriptState, 'olderRequestID' | 'heldPageID' | 'stalePages'> {
  return {
    olderRequestID: null,
    heldPageID: sameOpen ? (s.olderRequestID ?? s.heldPageID) : null,
    stalePages: s.stalePages + (s.olderRequestID === null ? 0 : 1),
  };
}

/**
 * How many stale `transcript.page` requests may be unanswered before no page is asked for. Each
 * new open can leave one on the wire, and the client sends at most `MAX_IN_FLIGHT` (32)
 * requests at a time, so a laptop that stops answering pages must not take its slots: with 3,
 * pages take at most 4, as the detail reads do (`MAX_DETAIL_READS`), and a reader who reopens
 * transcripts faster than the laptop answers still pages three opens in a row.
 */
export const MAX_STALE_PAGES = 3;

/** The slice's fields that say whether an older page may be asked for (`mayAskOlder`). */
export type Paging = Pick<TranscriptState, 'cursor' | 'olderRequestID' | 'heldPageID' | 'stalePages' | 'reachedStart' | 'olderFailed'>;

/**
 * Whether a stale page keeps any older page from being asked for: this open's own (`heldPageID`),
 * or `MAX_STALE_PAGES` of them. Each one's settling can free it (`settleStalePage`).
 */
export function staleHolds(s: Paging): boolean {
  return s.heldPageID !== null || s.stalePages >= MAX_STALE_PAGES;
}

/**
 * Whether the page above the rows may be asked for: the laptop gave a cursor for it, and none of
 * these holds: a page is on its way for these rows, a stale page holds the turn (`staleHolds`),
 * the start is reached, or the last page failed (which the reader's next scroll clears).
 */
export function mayAskOlder(s: Paging): boolean {
  return s.cursor !== null && s.olderRequestID === null && !staleHolds(s) && !s.reachedStart && !s.olderFailed;
}

/**
 * `s` once the stale page with token `requestID` settled, with a reply or an error: one fewer
 * is on the wire, and when it held this open's turn, the turn is free.
 */
export function settleStalePage(s: TranscriptState, requestID: string): TranscriptState {
  return { ...s, heldPageID: s.heldPageID === requestID ? null : s.heldPageID, stalePages: Math.max(0, s.stalePages - 1) };
}

/**
 * `s` opening `ref`'s transcript, the open's token being `requestID`. Opening the session the
 * slice holds already keeps its rows, cursor and details on screen until a page replaces them.
 * Opening another starts with none. Either way, an older page still on its way is dropped
 * (`dropOlder`), since it belongs above rows the open replaces, and the new open may page at
 * once: a stale page holds no new open's turn. A close still unanswered no longer matters,
 * since the open replaces whatever the laptop had open.
 */
export function beginOpen(s: TranscriptState, ref: PhoneSessionRef, showDetails: boolean, requestID: string): TranscriptState {
  const base = s.ref !== null && sameRef(s.ref, ref) ? s : clearTranscript(s);
  return {
    ...base, ref, showDetails, openRequestID: requestID, phase: 'opening', error: null, ...dropOlder(base, false), olderFailed: false,
    pendingClose: false,
  };
}

/**
 * `s` resuming the transcript it shows, the resume's token being `requestID`. Everything else
 * stands: the rows, the cursor, an older page on its way, and `phase` `open`, so the events the
 * laptop replays before it answers fold in. Its reply keeps the rows, or replaces them with a
 * page (`applyPage`).
 */
export function beginResume(s: TranscriptState, requestID: string): TranscriptState {
  return { ...s, openRequestID: requestID };
}

/**
 * `s` with `page` as its rows, in place of every row it had, receipts and open details
 * included: an open's first page, or a `transcript.reset`, which `replacements` counts. Each row
 * gets a new key. It takes the page's cursor, and drops an older page still on its way
 * (`dropOlder`), which belongs above rows that are gone and holds the open's turn until it
 * settles. It leaves `phase` to the caller.
 */
export function applyPage(s: TranscriptState, page: TranscriptPage): TranscriptState {
  const { rows, nextKey } = itemRows(page.items, s.nextKey);
  return {
    ...s, rows, nextKey, cursor: page.cursor ?? null, reachedStart: page.reachedStart, ...dropOlder(s, true), olderFailed: false,
    details: {}, appendedSinceSeen: 0, replacements: s.replacements + 1,
  };
}

/**
 * `s` with an older page above its rows: every item of `page`, in order, each a new row. None
 * is dropped for sharing an ID with a row below it. An older page ends where the shown rows
 * begin, and two lines can share an ID (this file's header). It takes the page's cursor and
 * `reachedStart`, and ends the wait for the page.
 *
 * A page short of the start that adds no row, or that gives back the cursor it was asked with,
 * which is `s.cursor` while the slice waits on it, moved the scroll back nowhere, and the next
 * page would ask the same. So it sets `olderFailed`, as a failed page does, and nothing asks
 * again until the reader's next scroll or touch. Rows that fit the screen would otherwise ask
 * again after every layout, back to back, for as long as the laptop answered so.
 */
export function prependPage(s: TranscriptState, page: TranscriptPage): TranscriptState {
  const { rows, nextKey } = itemRows(page.items, s.nextKey);
  const cursor = page.cursor ?? null;
  const stuck = !page.reachedStart && (page.items.length === 0 || cursor === s.cursor);
  return {
    ...s, rows: [...rows, ...s.rows], nextKey, cursor, reachedStart: page.reachedStart, olderRequestID: null, olderFailed: s.olderFailed || stuck,
  };
}

/**
 * `s` with one event folded in, when it is for the transcript the slice shows (this file's
 * header):
 * - `transcript.append` adds each new item at the bottom, and replaces an item it has already,
 *   in place, keeping its key;
 * - `transcript.update` replaces each item it has, in place, keeping its key, and ignores an
 *   ID it does not have;
 * - `transcript.reset` replaces every row with its page (`applyPage`).
 *
 * An item matches the last row that carries its ID: the laptop changes items near the bottom.
 * Any other event, or one for another session, returns `s` itself.
 */
export function applyTranscriptEvent(s: TranscriptState, e: AppEvent): TranscriptState {
  switch (e.event) {
    case 'transcript.append':
      return holds(s, e.data.session) ? putItems(s, e.data.items, true) : s;
    case 'transcript.update':
      return holds(s, e.data.session) ? putItems(s, e.data.items, false) : s;
    case 'transcript.reset':
      return holds(s, e.data.session) ? applyPage(s, e.data.page) : s;
    default:
      return s;
  }
}

/**
 * `s` with a receipt line, such as "Answered on this phone: …", for prompt `id`, when the
 * slice shows `ref`'s transcript. A new receipt goes at the bottom, below the
 * items the answer came after, and stays there as later items arrive below it. A second
 * receipt for the same prompt replaces the first, in place. For another session, or the same
 * text again, it returns `s` itself.
 */
export function addReceipt(s: TranscriptState, ref: PhoneSessionRef, id: string, text: string): TranscriptState {
  if (!holds(s, ref)) return s;
  const at = s.rows.findIndex((row) => row.kind === 'receipt' && row.id === id);
  if (at < 0) {
    const row: TranscriptRow = { key: s.nextKey, kind: 'receipt', id, text };
    return { ...s, rows: [...s.rows, row], nextKey: s.nextKey + 1, appendedSinceSeen: s.appendedSinceSeen + 1 };
  }
  const row = s.rows[at]!;
  if (row.kind !== 'receipt' || row.text === text) return s;
  const rows = [...s.rows];
  rows[at] = { ...row, text };
  return { ...s, rows };
}

/** Whether `s` shows `ref`'s transcript, so its events and receipts fold in. */
function holds(s: TranscriptState, ref: PhoneSessionRef): boolean {
  return s.phase === 'open' && s.ref !== null && sameRef(s.ref, ref);
}

/** A row for each of `items`, in order, keyed from `nextKey` on, and the key after the last. */
function itemRows(items: readonly PhoneItem[], nextKey: number): { rows: TranscriptRow[]; nextKey: number } {
  const rows = items.map((item, i): TranscriptRow => ({ key: nextKey + i, kind: 'item', item }));
  return { rows, nextKey: nextKey + items.length };
}

/**
 * `s` with `items` put in: each replaces the last row carrying its ID, keeping that row's key,
 * and the row's open detail follows the new item (`followItem`). With `appendNew`, an item no
 * row carries goes at the bottom as a new row. An item the same as the one it replaces changes
 * nothing. It returns `s` itself when nothing changed. `rowFinder` finds each item's row.
 */
function putItems(s: TranscriptState, items: readonly PhoneItem[], appendNew: boolean): TranscriptState {
  if (items.length === 0) return s;
  const find = rowFinder(s.rows.length);
  let rows: TranscriptRow[] | null = null;
  let details: Record<number, DetailState> | null = null;
  let nextKey = s.nextKey;
  let added = 0;
  for (const item of items) {
    const at = find.last(rows ?? s.rows, item.id);
    if (at >= 0) {
      const row = (rows ?? s.rows)[at]!;
      if (row.kind === 'item' && sameItem(row.item, item)) continue;
      rows ??= [...s.rows];
      rows[at] = { key: row.key, kind: 'item', item };
      const d = (details ?? s.details)[row.key];
      const next = d !== undefined && row.kind === 'item' ? followItem(d, row.item, item) : d;
      if (next !== d) {
        details ??= { ...s.details };
        if (next === null) delete details[row.key];
        else if (next !== undefined) details[row.key] = next;
      }
    } else if (appendNew) {
      rows ??= [...s.rows];
      find.appended(item.id, rows.length);
      rows.push({ key: nextKey++, kind: 'item', item });
      added++;
    }
  }
  if (rows === null) return s;
  return { ...s, rows, nextKey, appendedSinceSeen: s.appendedSinceSeen + added, details: details ?? s.details };
}

/**
 * How `putItems` finds the last row carrying an item's ID, for one call. It looks up from the
 * bottom, where the laptop changes items, so an update or a repeat of an item near the bottom
 * reads a few rows, however long the transcript. An ID no row carries, as a new item's, reads
 * every row, so once the call's looking has read `budget` rows, as many as the slice held, it
 * indexes the rows by ID once and reads the index from then on. A burst of new items then costs
 * about two passes over the rows, where an index for every call would cost one each time.
 * - `last(rows, id)`: the index of the last of `rows` carrying `id`, or -1.
 * - `appended(id, at)`: a row carrying `id` went in at `at`, below every other row.
 */
function rowFinder(budget: number): { last(rows: readonly TranscriptRow[], id: string): number; appended(id: string, at: number): void } {
  let index: Map<string, number> | null = null;
  let left = budget;
  return {
    last(rows, id) {
      if (index === null) {
        const stop = Math.max(0, rows.length - left);
        for (let i = rows.length - 1; i >= stop; i--) {
          const row = rows[i]!;
          if (row.kind === 'item' && row.item.id === id) {
            left -= rows.length - i;
            return i;
          }
        }
        left -= rows.length - stop;
        if (stop === 0) return -1;
        const built = new Map<string, number>();
        rows.forEach((row, i) => {
          if (row.kind === 'item') built.set(row.item.id, i);
        });
        index = built;
      }
      return index.get(id) ?? -1;
    },
    appended(id, at) {
      index?.set(id, at);
    },
  };
}

/** Whether two items hold the same fields with the same values. Every field of an item is a string, a number or a boolean. */
function sameItem(a: PhoneItem, b: PhoneItem): boolean {
  if (a === b) return true;
  const keys = Object.keys(a) as Array<keyof PhoneItem>;
  return keys.length === Object.keys(b).length && keys.every((k) => Object.hasOwn(b, k) && a[k] === b[k]);
}
