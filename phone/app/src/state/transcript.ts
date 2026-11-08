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
 * Each function returns a new object when it changes anything, and `s` itself when it does
 * not, so the store does not notify.
 */

import type { AppEvent, PhoneItem, PhoneSessionRef, TranscriptPage } from '../protocol/types.ts';
import { sameRef } from '../protocol/wire.ts';
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
  /** A `transcript.page` for these rows is on its way. */
  loadingOlder: boolean;
  /** The last older page failed to load. Nothing asks for another until the reader scrolls. */
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
   * `transcript.append`, and new receipts. A rise in it tells the list that rows arrived below.
   */
  appendedSinceSeen: number;
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
    loadingOlder: false,
    olderFailed: false,
    pendingClose: false,
    details: {},
    appendedSinceSeen: 0,
  };
}

/**
 * `s` opening `ref`'s transcript, the open's token being `requestID`. Opening the session the
 * slice holds already keeps its rows, cursor and details on screen until a page replaces them.
 * Opening another starts with none. Either way, an older page still on its way is dropped
 * (`loadingOlder` turns false), since it belongs above rows the open replaces. A close still
 * unanswered no longer matters, since the open replaces whatever the laptop had open.
 */
export function beginOpen(s: TranscriptState, ref: PhoneSessionRef, showDetails: boolean, requestID: string): TranscriptState {
  const base = s.ref !== null && sameRef(s.ref, ref) ? s : { ...emptyTranscript(), nextKey: s.nextKey };
  return {
    ...base, ref, showDetails, openRequestID: requestID, phase: 'opening', error: null, loadingOlder: false, olderFailed: false,
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
 * included: an open's first page, or a `transcript.reset`. Each row gets a new key. It takes
 * the page's cursor, and drops an older page still on its way, which belongs above rows that
 * are gone. It leaves `phase` to the caller.
 */
export function applyPage(s: TranscriptState, page: TranscriptPage): TranscriptState {
  const { rows, nextKey } = itemRows(page.items, s.nextKey);
  return {
    ...s, rows, nextKey, cursor: page.cursor ?? null, reachedStart: page.reachedStart, loadingOlder: false, olderFailed: false,
    details: {}, appendedSinceSeen: 0,
  };
}

/**
 * `s` with an older page above its rows: every item of `page`, in order, each a new row. None
 * is dropped for sharing an ID with a row below it. An older page ends where the shown rows
 * begin, and two lines can share an ID (this file's header). It takes the page's cursor and
 * `reachedStart`, and ends the wait for the page.
 */
export function prependPage(s: TranscriptState, page: TranscriptPage): TranscriptState {
  const { rows, nextKey } = itemRows(page.items, s.nextKey);
  return { ...s, rows: [...rows, ...s.rows], nextKey, cursor: page.cursor ?? null, reachedStart: page.reachedStart, loadingOlder: false };
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
 * and with `appendNew`, an item no row carries goes at the bottom as a new row. An item the
 * same as the one it replaces changes nothing. It returns `s` itself when nothing changed.
 */
function putItems(s: TranscriptState, items: readonly PhoneItem[], appendNew: boolean): TranscriptState {
  if (items.length === 0) return s;
  const lastRowWithID = new Map<string, number>();
  s.rows.forEach((row, i) => {
    if (row.kind === 'item') lastRowWithID.set(row.item.id, i);
  });
  let rows: TranscriptRow[] | null = null;
  let nextKey = s.nextKey;
  let added = 0;
  for (const item of items) {
    const at = lastRowWithID.get(item.id);
    if (at !== undefined) {
      const row = (rows ?? s.rows)[at]!;
      if (row.kind === 'item' && sameItem(row.item, item)) continue;
      rows ??= [...s.rows];
      rows[at] = { key: row.key, kind: 'item', item };
    } else if (appendNew) {
      rows ??= [...s.rows];
      lastRowWithID.set(item.id, rows.length);
      rows.push({ key: nextKey++, kind: 'item', item });
      added++;
    }
  }
  if (rows === null) return s;
  return { ...s, rows, nextKey, appendedSinceSeen: s.appendedSinceSeen + added };
}

/** Whether two items hold the same fields with the same values. Every field of an item is a string, a number or a boolean. */
function sameItem(a: PhoneItem, b: PhoneItem): boolean {
  if (a === b) return true;
  const keys = Object.keys(a) as Array<keyof PhoneItem>;
  return keys.length === Object.keys(b).length && keys.every((k) => Object.hasOwn(b, k) && a[k] === b[k]);
}
