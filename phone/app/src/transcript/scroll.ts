/**
 * The transcript list's scroll rules (spec section 7, "Rendering on the phone"), pure, so
 * `node --test` checks them with exact numbers. `TranscriptView` reads the scroll element's
 * metrics and acts on what these say.
 *
 * - **Sticking to the bottom.** A view within `STICK_PX` of its bottom is at the bottom
 *   (`atBottom`). While the view keeps to the bottom, rows that arrive or grow below it, and a
 *   scroll element that gets shorter, as when the keyboard opens, put it back at the bottom
 *   (`pushedFromBottom`). The reader's scroll never does, even when a layout comes between it and
 *   its scroll event, and the browser bringing a view at its bottom up with a shorter scroll
 *   element is not the reader's (`clampedToBottom`). After every scroll event, once the list has
 *   put back a view that was pushed, the view keeps to the bottom exactly when it is at the
 *   bottom, whatever moved it and by how little. Rows that arrive while it does not keep to the
 *   bottom show the "New messages" pill instead (`rowsChange`).
 * - **The reader's scroll.** A scroll event is the reader's when it moved the view more than a
 *   pixel from where the list last wrote it or last took the reader's scroll (`takeScroll`), so
 *   the event of the list's own write never counts, and a slow drag adds up until it does.
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

/** The slice's fields that say whether the list may ask for the page above its rows. */
export type Paging = Pick<TranscriptState, 'cursor' | 'olderRequestID' | 'stalePage' | 'reachedStart' | 'olderFailed'>;

/**
 * Whether the list should ask for the page above its rows: the view is within two of its own
 * heights of the top, the laptop gave a cursor for that page, and none of these holds: a page
 * is on its way, for these rows or for rows a page replaced (which its settling clears), the
 * start is reached, or the last page failed (which the reader's next scroll clears).
 */
export function wantsOlder(m: Metrics, s: Paging): boolean {
  return m.scrollTop < 2 * m.clientHeight && s.cursor !== null && s.olderRequestID === null && !s.stalePage && !s.reachedStart
    && !s.olderFailed;
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
 * Whether a scroll event moved the view from `prevTop` by more than a pixel, so a rounded
 * read-back does not count. `prevTop` is the `scrollTop` of the list's last write, or of the last
 * event `takeScroll` counted as the reader's. The list notes where each of its writes left the
 * view, and the virtualizer's when rows above the view change height, so their events do not
 * move it.
 */
export function moved(prevTop: number, m: Metrics): boolean {
  return Math.abs(m.scrollTop - prevTop) > 1;
}

/**
 * What the list takes from a scroll event, from `top` as for `moved`: whether the reader made
 * it, and the `top` the next event is measured from. An event that moved the view more than a
 * pixel is the reader's, and its `scrollTop` becomes `top`. Any other leaves `top` as it was,
 * so a drag of a pixel or less a frame, or of a fraction of one on a 3x screen, adds up from
 * where it began until an event counts, and the next counts again from there.
 */
export function takeScroll(top: number, m: Metrics): { byReader: boolean; top: number } {
  return moved(top, m) ? { byReader: true, top: m.scrollTop } : { byReader: false, top };
}

/**
 * Whether something pushed a view that keeps to the bottom away from it, so the list should
 * put it back: the view is now more than a pixel further above its bottom than `seen`, its
 * distance when the list last looked, and its `scrollTop` is still where the list last noted it
 * (`top`, as for `moved`). Rows that arrived or grew below it do that, and so does a shorter
 * scroll element: they move the bottom, not the view. The reader's scroll moves the view, so a
 * layout that comes after it and before its scroll event, as when an update or a tap draws the
 * rows again in that frame, does not take it for a push and pull the view back. The list looks
 * after every layout, after every scroll event the reader made, and after every one they did not
 * (`takeScroll`), and puts it back then too, so a push that came before the event of the list's
 * own write is not taken for a swipe. Rows that grew above the view do not push it, since the
 * virtualizer moves the view by as much as they grew.
 */
export function pushedFromBottom(stuck: boolean, seen: number, top: number, m: Metrics): boolean {
  return stuck && !moved(top, m) && fromBottom(m) > seen + 1;
}

/**
 * Whether the browser, not the reader, moved the view from `top` (as for `moved`): the scroll
 * element got shorter below a view at its bottom, so the browser brought the view up with it,
 * and the view is still at its bottom. A reader's scroll up leaves the view above the bottom, and
 * one down moves it down. The scroll event of that move comes only later, so a layout notes the
 * new `scrollTop` as the list's, and the next layout, after rows that grew, still sees the push.
 */
export function clampedToBottom(top: number, m: Metrics): boolean {
  return moved(top, m) && m.scrollTop < top && fromBottom(m) <= 1;
}

/**
 * What the list sees of its rows at a commit, from what the slice records rather than from the
 * rows' keys: how many times a page has replaced them (`replacements`), how many came in at the
 * bottom since (`appendedSinceSeen`), and how many there are.
 */
export interface SeenRows {
  replacements: number;
  appended: number;
  count: number;
}

/** What the list sees of `rows`, given the slice's `replacements` and `appendedSinceSeen` for them. */
export function seenRows(rows: readonly TranscriptRow[], replacements: number, appended: number): SeenRows {
  return { replacements, appended, count: rows.length };
}

/**
 * How the rows changed from `seen`, what the list saw of them last, to `now`:
 * - `replaced`: a page took the place of the rows, as an open, a reopen and a reset do, or they
 *   were cleared (`replacements` changed), whether there were rows before or not.
 * - `appended`: rows came in at the bottom, new items or a receipt (`appendedSinceSeen` rose),
 *   the first items of an empty transcript included.
 * - `same`: anything else, such as a row changed in place or an older page above.
 *
 * The list may see several store changes at once, so a page and appends after it read as
 * `replaced`, and an older page with appends as `appended`.
 */
export function rowsChange(seen: SeenRows, now: SeenRows): 'replaced' | 'appended' | 'same' {
  if (now.replacements !== seen.replacements) return 'replaced';
  return now.appended > seen.appended ? 'appended' : 'same';
}

/**
 * How many rows came in at the bottom from `seen` to `now`, so the last that many rows are the
 * ones that arrived; none when a page replaced the rows. Rows come in only at the bottom, by an
 * append or a receipt, or above, by an older page, and only a page takes any away.
 */
export function arrivedCount(seen: SeenRows, now: SeenRows): number {
  return now.replacements === seen.replacements ? Math.max(0, now.appended - seen.appended) : 0;
}

/**
 * Whether rows came in above the rows the list last saw, as an older page puts them: with no
 * page in place of the rows, there are more rows than came in at the bottom.
 */
export function prepended(seen: SeenRows, now: SeenRows): boolean {
  return now.replacements === seen.replacements && now.count - seen.count > now.appended - seen.appended;
}
