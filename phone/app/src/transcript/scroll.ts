/**
 * The transcript list's scroll rules (spec section 7, "Rendering on the phone"), pure, so
 * `node --test` checks them with exact numbers. `TranscriptView` reads the scroll element's
 * metrics and acts on what these say.
 *
 * - **Sticking to the bottom.** A view within `STICK_PX` of its bottom is at the bottom
 *   (`atBottom`). While the view keeps to the bottom (`sticksAfterScroll`), rows that arrive or
 *   grow below it, and a scroll element that gets shorter, as when the keyboard opens, put it
 *   back at the bottom (`pushedFromBottom`). Rows that arrive while it does not keep to the
 *   bottom show the "New messages" pill instead (`rowsChange`).
 * - **Older pages.** The list asks for the page above its rows once the reader is within two
 *   screen heights of the top, one page at a time (`wantsOlder`), and at once when the rows fit
 *   the view, which the reader cannot scroll (`fitsView`).
 * - **Holding the reader's place.** Before an older page goes in above the rows, the list
 *   records an anchor: the row at the top of the view, and how far its top sits below the top
 *   of the view (`anchorAt`). Once the page is in (`prepended`), it scrolls so that row sits
 *   there again (`restoreTop`).
 *
 * Every number is in CSS pixels, as the scroll element reports them.
 */

import type { TranscriptRow, TranscriptState } from '../state/transcript.ts';

/** How near its bottom a view still counts as at the bottom. */
export const STICK_PX = 30;

/** The scroll element's metrics, as the DOM reports them. */
export interface Metrics {
  scrollTop: number;
  scrollHeight: number;
  clientHeight: number;
}

/** How far the view is above its bottom; 0 at the bottom, and below 0 in a bounce past it. */
export function fromBottom(m: Metrics): number {
  return m.scrollHeight - m.scrollTop - m.clientHeight;
}

/** Whether the view is within `STICK_PX` of its bottom. */
export function atBottom(m: Metrics): boolean {
  return fromBottom(m) <= STICK_PX;
}

/**
 * Whether the list should ask for the page above its rows: the view is within two of its own
 * heights of the top, the laptop gave a cursor for that page, and none of these holds: a page
 * is on its way, the start is reached, or the last page failed (which the reader's next scroll
 * clears).
 */
export function wantsOlder(m: Metrics, s: Pick<TranscriptState, 'cursor' | 'loadingOlder' | 'reachedStart' | 'olderFailed'>): boolean {
  return m.scrollTop < 2 * m.clientHeight && s.cursor !== null && !s.loadingOlder && !s.reachedStart && !s.olderFailed;
}

/**
 * Whether the rows fit the view, so the reader cannot scroll it at all and no scroll of theirs
 * can ask for the page above. A first page of four short messages can fit a phone's screen.
 */
export function fitsView(m: Metrics): boolean {
  return m.scrollHeight <= m.clientHeight;
}

/** A place in the list: a row, by its key, and the row's top minus the view's `scrollTop`. */
export interface Anchor {
  key: number;
  offset: number;
}

/**
 * The anchor for a view scrolled to `scrollTop`: `row` is the row that holds the view's top
 * line, which is the first row whose bottom is below it, by its key and its start in the list,
 * and `listTop` is where the list starts in the scroll element's content. Its offset is below 0
 * when the row starts above the view.
 */
export function anchorAt(row: { key: number; start: number }, listTop: number, scrollTop: number): Anchor {
  return { key: row.key, offset: listTop + row.start - scrollTop };
}

/** The `scrollTop` that puts the anchor's row, whose top is now at `rowTop`, back where it was. */
export function restoreTop(anchor: Anchor, rowTop: number): number {
  return rowTop - anchor.offset;
}

/**
 * Whether a scroll event moved the view from `prevTop`, the `scrollTop` the list last saw or
 * wrote, by more than a pixel, so a rounded read-back does not count. The reader's swipe moves
 * it. The event of a write by the list, or by the virtualizer when rows above the view change
 * height, does not, since the list notes where each of those writes left the view.
 */
export function moved(prevTop: number, m: Metrics): boolean {
  return Math.abs(m.scrollTop - prevTop) > 1;
}

/**
 * Whether the view keeps to the bottom after a scroll event, from whether it did before and
 * `prevTop` (as for `moved`):
 * - at the bottom, it does;
 * - above it, it stops only when the view moved up, as a reader's swipe moves it. A view that
 *   keeps to the bottom can be pushed above it from below, by rows that grew or a scroll element
 *   that got shorter, before the list put it back, and the event of the list's own last write
 *   can come only then. That event did not move the view, so it keeps to the bottom.
 */
export function sticksAfterScroll(stuck: boolean, prevTop: number, m: Metrics): boolean {
  if (atBottom(m)) return true;
  return stuck && m.scrollTop >= prevTop - 1;
}

/**
 * Whether something pushed a view that keeps to the bottom away from it, so the list should
 * put it back: the view is now more than a pixel further above its bottom than `seen`, its
 * distance when the list last looked. Rows that arrived or grew below it do that, and so does
 * a shorter scroll element. The list looks after every layout, after every scroll event that
 * moved the view, and after every one that did not (`moved`), and puts it back then too, so a
 * swipe does not count as a push, and a push that came before the event of the list's own write
 * is not taken for a swipe. Rows that grew above the view do not push it, since the virtualizer
 * moves the view by as much as they grew.
 */
export function pushedFromBottom(stuck: boolean, seen: number, m: Metrics): boolean {
  return stuck && fromBottom(m) > seen + 1;
}

/**
 * What the list last saw of its rows: the first and the last row's keys, each null with no
 * rows, and the slice's `appendedSinceSeen`.
 */
export interface SeenRows {
  firstKey: number | null;
  lastKey: number | null;
  appended: number;
}

/**
 * How the rows changed since the list last saw them (`SeenRows`):
 * - `replaced`: a page took the place of the rows, as an open, a reopen and a reset do. The
 *   row that was last is gone, since a page gives every row a new key, or there were no rows
 *   and now there are.
 * - `appended`: rows came in at the bottom, new items or a receipt (`appendedSinceSeen` rose).
 * - `same`: anything else, such as a row changed in place or an older page above.
 *
 * The list may see several store changes at once, so a page and appends after it read as
 * `replaced`, and an older page with appends as `appended`.
 */
export function rowsChange(seen: SeenRows, rows: readonly TranscriptRow[], appended: number): 'replaced' | 'appended' | 'same' {
  if (seen.lastKey === null ? rows.length > 0 : !hasKey(rows, seen.lastKey)) return 'replaced';
  return appended > seen.appended ? 'appended' : 'same';
}

/** What the list sees of `rows` now, for the next `rowsChange` and `prepended`. */
export function seenRows(rows: readonly TranscriptRow[], appended: number): SeenRows {
  return { firstKey: rows[0]?.key ?? null, lastKey: rows[rows.length - 1]?.key ?? null, appended };
}

/**
 * Whether rows came in above the rows the list last saw, as an older page puts them: the row
 * that was first is still there, and no longer first. A page in place of the rows gives every
 * row a new key, so it never reads as prepended.
 */
export function prepended(seen: SeenRows, rows: readonly TranscriptRow[]): boolean {
  if (seen.firstKey === null || rows.length === 0 || rows[0]!.key === seen.firstKey) return false;
  return rows.some((row) => row.key === seen.firstKey);
}

/** Whether a row has `key`, looked for from the bottom, where the row that was last stays after an append. */
function hasKey(rows: readonly TranscriptRow[], key: number): boolean {
  for (let i = rows.length - 1; i >= 0; i--) {
    if (rows[i]!.key === key) return true;
  }
  return false;
}
