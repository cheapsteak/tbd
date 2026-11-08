/**
 * The open session's transcript (spec section 7, "Rendering on the phone"): its rows, read from
 * the transcript slice, in a virtual list, so only the rows near the screen exist in the page.
 * Contract: `TranscriptView({ session })`. The session screen keys it by the session, so a
 * switch to another session mounts it afresh.
 *
 * - **No transcript.** When the session's transcript capability is unavailable, the laptop's
 *   reason is all it shows (`.codex-note`).
 * - **Opening.** The mock has no loading state for a transcript, so while an open is on its way
 *   with no rows, the list is empty.
 * - **Failed.** The slice's error, which is the laptop's own text, in the same note.
 *
 * **The list** (`List`). `.tx` is the scroll element, as in the mock (mock 207-208). Inside it,
 * `.tx-list` is as tall as the virtualizer's total, and sits at the bottom of a short transcript
 * through the mock's `.tx > :first-child{margin-top:auto}`. Each row is a `.tx-row`, placed by
 * `translateY` at its start, whose padding stands in for `.tx`'s gap (app.css). The virtualizer
 * measures each row as it appears, and again whenever its height changes, as when a detail, Show
 * more or a nest opens. Rows are keyed by their row key (`TranscriptRow.key`), never by item ID,
 * and each row element carries `data-key` (the row key) and `data-tx-row`. (`data-row` is not
 * used: the e2e fixtures' `rowButtons` matches `button[data-row]`.)
 *
 * **Keeping to the bottom**, by the rules in `scroll.ts`. The view keeps to the bottom at mount
 * and after a page replaces the rows (an open, a reopen, a reset), and from then on while the
 * reader leaves it within 30 px of the bottom. While it does, whatever pushes it away from the
 * bottom puts it back after layout: new rows or a receipt, a row that grew, and a shorter `.tx`,
 * as when the keyboard opens or the phone turns (a `ResizeObserver` on `.tx`). Rows that arrive
 * while it does not keep to the bottom show the pill, "New messages" and the down glyph (mock
 * 1022). A tap on it scrolls to the newest row, and so hides it, as reaching the bottom by
 * scrolling does.
 *
 * **Older pages**, also by the rules in `scroll.ts`. A scroll the reader made first clears a
 * failed older page (`clearOlderFailed`), so a failure shows nothing and the next scroll asks
 * again. Then, within two screens of the top (`wantsOlder`), the list records an anchor, the row
 * at the top of the view and how far its top sits from the view's top (`anchorAt`), and asks for
 * the page (`loadOlder`). Rows that fit the view, which the reader cannot scroll, ask at once.
 * - **While the page is on its way** the anchor follows the view: it is taken again after every
 *   scroll event and every layout, so a page that lands after a swipe or a fling went on holds
 *   where the reader is then, not where the page was asked for.
 * - **When the page goes in** above the rows (`prepended`), the layout effect of that very commit
 *   scrolls the anchor's row back to its offset (`restoreTop`), before the browser paints and
 *   before any scroll event can run, so no frame shows the rows moved. It finds the row by its
 *   key, and its start in the virtualizer's measurements, brought up to date first.
 * - **For two frames after**, while the virtualizer measures the new rows near the screen, the
 *   list puts the anchor back after every layout, and once more in the next animation frame. The
 *   virtualizer corrects `scrollTop` itself for a row measured above the view, and the restore
 *   reads the row's start after that correction, so the two agree and the correction is never
 *   counted twice. A scroll the reader makes in those frames takes the anchor again, so the
 *   restore holds the reader's new place and never pulls them back. Then the anchor goes, unless
 *   the reader's scroll asked for the next page.
 * - **A page in place of the rows** (a reset, a reopen) drops the anchor and starts at the
 *   bottom.
 *
 * The list writes `scrollTop` itself, and notes where each write left the view, so the scroll
 * event the write fires reads as the list's own and not as a swipe (`moved`). It notes the
 * virtualizer's writes the same way (`scrollToFn`): the virtualizer moves the view by as much as
 * a row above it grew when it measures that row, and that is not the reader's scroll, so it
 * neither asks for a page nor retries a failed one. A write from a tap
 * or from a store change lands before the next frame, whose scroll event the virtualizer reads
 * first, so the rows at the new place are drawn before that frame paints. The list's scroll
 * listener is a capture listener on `.tx-wrap`: it runs before the virtualizer's own listener on
 * `.tx`, which may draw rows on the spot, and so runs the list's effects, which must see the
 * reader's scroll already.
 */

import { useCallback, useLayoutEffect, useRef, useState, type JSX } from 'react';
import { elementScroll, useVirtualizer } from '@tanstack/react-virtual';
import { useActions, useAppState } from '../state/context.tsx';
import type { DetailState } from '../state/detail.ts';
import type { TranscriptRow, TranscriptState } from '../state/transcript.ts';
import type { PhoneSession } from '../protocol/types.ts';
import { sameRef } from '../protocol/wire.ts';
import { Icon } from '../ui/Icon.tsx';
import { ItemRow, type RowPart } from './ItemRow.tsx';
import {
  anchorAt, atBottom, fitsView, fromBottom, moved, prepended, pushedFromBottom, restoreTop, rowsChange, seenRows, sticksAfterScroll,
  wantsOlder,
} from './scroll.ts';
import type { Anchor, Metrics, SeenRows } from './scroll.ts';

/** The height the virtualizer gives a row it has not measured yet. */
const ESTIMATE_PX = 48;

/** The rows the virtualizer draws beyond each end of the screen. */
const OVERSCAN = 8;

const NO_ROWS: readonly TranscriptRow[] = [];

/** The slice's fields that say whether the list may ask for the page above its rows. */
type Paging = Pick<TranscriptState, 'cursor' | 'loadingOlder' | 'reachedStart' | 'olderFailed'>;

export function TranscriptView(p: { session: PhoneSession }): JSX.Element {
  const actions = useActions();
  const t = useAppState((s) => s.transcript);
  // One function for every row on every render, so a row draws again only when it changes.
  const toggle = useCallback((rowKey: number, part: RowPart) => void actions.toggleDetail(rowKey, part), [actions]);
  const { available, reason } = p.session.capabilities.transcript;
  if (!available) return <Note text={reason ?? ''} />;
  if (t.phase === 'failed') return <Note text={t.error ?? ''} />;
  const shown = t.ref !== null && sameRef(t.ref, p.session.ref);
  return (
    <List
      rows={shown ? t.rows : NO_ROWS}
      appended={shown ? t.appendedSinceSeen : 0}
      paging={shown && t.phase === 'open' ? t : null}
      details={t.details}
      toggle={toggle}
    />
  );
}

/**
 * What the list keeps between renders, none of which it draws:
 * - `stuck`: whether the view keeps to the bottom (`sticksAfterScroll`);
 * - `top`: the `scrollTop` it last saw or wrote, so a scroll event can tell whether the view
 *   moved;
 * - `seen`: how far the view was above its bottom then (`fromBottom`), so a layout can tell
 *   whether something pushed it away;
 * - `rows`: the rows it last saw (`rowsChange`, `prepended`);
 * - `shown` and `paging`: the rows and paging of the last commit, for the listeners, which run
 *   between renders;
 * - `anchor`: the reader's place while an older page is on its way or going in, or null;
 * - `restoring`: the animation frame request that ends the restore after a page went in, or
 *   null while no restore runs.
 */
interface ViewState {
  stuck: boolean;
  top: number;
  seen: number;
  rows: SeenRows;
  shown: readonly TranscriptRow[];
  paging: Paging | null;
  anchor: Anchor | null;
  restoring: number | null;
}

/**
 * The virtual list, the bottom it keeps to, the pill and the older pages (this file's header).
 * - `rows`: the rows to show, the slice's when it holds this session's transcript.
 * - `appended`: the slice's `appendedSinceSeen` for those rows; a rise means rows came in below.
 * - `paging`: the slice, while it holds those rows open, or null, when no older page may be
 *   asked for them.
 */
function List(p: {
  rows: readonly TranscriptRow[];
  appended: number;
  paging: Paging | null;
  details: Readonly<Record<number, DetailState>>;
  toggle: (rowKey: number, part: RowPart) => void;
}): JSX.Element {
  const { rows, appended, paging } = p;
  const actions = useActions();
  const wrapRef = useRef<HTMLDivElement>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const view = useRef<ViewState>({
    stuck: true, top: 0, seen: 0, rows: { firstKey: null, lastKey: null, appended: 0 }, shown: NO_ROWS, paging: null, anchor: null,
    restoring: null,
  }).current;
  const [pill, setPill] = useState(false);
  // A new function only when the rows change, so the virtualizer lays the rows out again then.
  const getItemKey = useCallback((index: number) => rows[index]!.key, [rows]);
  // The virtualizer's own writes, as when it corrects for a row measured above the view, are
  // noted as the list's, so their scroll events never read as the reader's.
  const scrollToFn = useCallback<typeof elementScroll<HTMLDivElement>>(
    (offset, options, instance) => {
      elementScroll(offset, options, instance);
      if (instance.scrollElement !== null) view.top = instance.scrollElement.scrollTop;
    },
    [view],
  );
  const virtualizer = useVirtualizer<HTMLDivElement, HTMLDivElement>({
    count: rows.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: estimateRow,
    getItemKey,
    overscan: OVERSCAN,
    scrollToFn,
  });

  /** Scrolls to the bottom, and notes where that left the view. */
  const toBottom = useCallback(
    (el: HTMLElement): void => {
      el.scrollTop = el.scrollHeight - el.clientHeight;
      const m = metricsOf(el);
      view.top = m.scrollTop;
      view.seen = fromBottom(m);
    },
    [view],
  );

  /** After a layout: puts a view that keeps to the bottom back there when something pushed it away. */
  const settle = useCallback((): void => {
    const el = scrollRef.current;
    if (el === null) return;
    const m = metricsOf(el);
    if (pushedFromBottom(view.stuck, view.seen, m)) toBottom(el);
    else view.seen = fromBottom(m);
  }, [view, toBottom]);

  /** The anchor for the view as it is now: the row that holds its top line, by the virtualizer's measurements. */
  const anchorNow = useCallback(
    (el: HTMLElement): Anchor | null => {
      const list = listRef.current;
      if (list === null || view.shown.length === 0) return null;
      const listTop = topIn(el, list);
      const row = virtualizer.getVirtualItemForOffset(Math.max(0, el.scrollTop - listTop));
      return row === undefined ? null : anchorAt({ key: Number(row.key), start: row.start }, listTop, el.scrollTop);
    },
    [view, virtualizer],
  );

  /**
   * Scrolls the anchor's row back to the anchor's offset, and notes where that left the view.
   * It writes only when the view is more than half a pixel away, so a restore that agrees with
   * the view, as after the virtualizer's own correction, fires no scroll event.
   */
  const restore = useCallback(
    (el: HTMLElement): void => {
      const anchor = view.anchor;
      const list = listRef.current;
      if (anchor === null || list === null) return;
      const index = view.shown.findIndex((row) => row.key === anchor.key);
      if (index < 0) return;
      const start = startOf(virtualizer, index);
      if (start === undefined) return;
      const top = restoreTop(anchor, topIn(el, list) + start);
      if (Math.abs(el.scrollTop - top) > 0.5) el.scrollTop = top;
      const m = metricsOf(el);
      view.top = m.scrollTop;
      view.seen = fromBottom(m);
    },
    [view, virtualizer],
  );

  /** Records the anchor and asks for the page above the rows. */
  const askOlder = useCallback(
    (el: HTMLElement): void => {
      view.anchor = anchorNow(el);
      void actions.loadOlder();
    },
    [view, actions, anchorNow],
  );

  /** Ends a restore under way, if any, and drops the anchor. */
  const dropAnchor = useCallback((): void => {
    if (view.restoring !== null) cancelAnimationFrame(view.restoring);
    view.restoring = null;
    view.anchor = null;
  }, [view]);

  /**
   * The page went in above the rows: the restore, now, after every layout until two frames
   * from now, and in the next animation frame (this file's header).
   */
  const startRestore = useCallback(
    (el: HTMLElement): void => {
      if (view.restoring !== null) cancelAnimationFrame(view.restoring);
      restore(el);
      view.restoring = requestAnimationFrame(() => {
        restore(el);
        view.restoring = requestAnimationFrame(() => {
          view.restoring = null;
          // A page the reader's scroll asked for meanwhile keeps the anchor, which follows the view again.
          view.anchor = view.paging?.loadingOlder === true ? anchorNow(el) : null;
        });
      });
    },
    [view, restore, anchorNow],
  );

  /**
   * After every layout: the restore while one runs, the bottom (`settle`), the anchor following
   * the view while a page is on its way, and, for rows that fit the view, the page above.
   */
  const afterLayout = useCallback((): void => {
    const el = scrollRef.current;
    if (el === null) return;
    if (view.restoring !== null) restore(el);
    settle();
    if (view.anchor !== null && view.restoring === null) {
      view.anchor = view.paging?.loadingOlder === true ? anchorNow(el) : null;
    }
    const m = metricsOf(el);
    if (view.anchor === null && view.paging !== null && fitsView(m) && wantsOlder(m, view.paging)) askOlder(el);
  }, [view, restore, settle, anchorNow, askOlder]);

  // The reader's scroll, and a `.tx` that changed size.
  useLayoutEffect(() => {
    const wrap = wrapRef.current;
    const el = scrollRef.current;
    if (wrap === null || el === null) return;
    const onScroll = (e: Event): void => {
      if (e.target !== el) return;
      const m = metricsOf(el);
      const byScroll = moved(view.top, m);
      view.stuck = sticksAfterScroll(view.stuck, view.top, m);
      view.top = m.scrollTop;
      // The event of the list's own write may come after a layout that pushed the view.
      if (byScroll) view.seen = fromBottom(m);
      else settle();
      if (atBottom(metricsOf(el))) setPill(false);
      // The anchor follows the view while a page is on its way, and the reader while one goes in.
      if (view.anchor !== null && (byScroll || view.restoring === null)) view.anchor = anchorNow(el);
      if (!byScroll) return;
      actions.clearOlderFailed();
      const paging = view.paging;
      if (paging !== null && wantsOlder(metricsOf(el), { ...paging, olderFailed: false })) askOlder(el);
    };
    const resized = new ResizeObserver(afterLayout);
    wrap.addEventListener('scroll', onScroll, { capture: true, passive: true });
    resized.observe(el);
    return () => {
      wrap.removeEventListener('scroll', onScroll, { capture: true });
      resized.disconnect();
      dropAnchor();
    };
  }, [view, actions, settle, anchorNow, askOlder, afterLayout, dropAnchor]);

  // What the listeners read between renders.
  useLayoutEffect(() => {
    view.shown = rows;
    view.paging = paging;
  });

  // Rows that came in. A page in place of the rows starts at the bottom; rows below a view that
  // does not keep to the bottom show the pill; a page above the rows holds the reader's place.
  useLayoutEffect(() => {
    const change = rowsChange(view.rows, rows, appended);
    const above = prepended(view.rows, rows);
    view.rows = seenRows(rows, appended);
    const el = scrollRef.current;
    if (change === 'replaced') {
      dropAnchor();
      view.stuck = true;
      setPill(false);
      if (el !== null) toBottom(el);
      return;
    }
    if (above && view.anchor !== null && el !== null) startRestore(el);
    if (change === 'appended' && !view.stuck) setPill(true);
  }, [view, rows, appended, toBottom, dropAnchor, startRestore]);

  // After every render, since rows can change height in any of them.
  useLayoutEffect(afterLayout);

  const onPill = (): void => {
    const el = scrollRef.current;
    if (el === null) return;
    view.stuck = true;
    setPill(false);
    toBottom(el);
  };

  return (
    <div className="tx-wrap" ref={wrapRef}>
      <div className="tx" id="tx" aria-live="polite" ref={scrollRef}>
        <div className="tx-list" ref={listRef} style={{ height: virtualizer.getTotalSize() }}>
          {virtualizer.getVirtualItems().map((v) => {
            const row = rows[v.index]!;
            return (
              <div
                key={row.key}
                ref={virtualizer.measureElement}
                className="tx-row"
                data-index={v.index}
                data-key={row.key}
                data-tx-row=""
                style={{ transform: `translateY(${v.start}px)` }}
              >
                <ItemRow row={row} detail={p.details[row.key]} toggle={p.toggle} />
              </div>
            );
          })}
        </div>
      </div>
      {pill && (
        <button className="pill" type="button" onClick={onPill}>
          New messages <Icon name="down" />
        </button>
      )}
    </div>
  );
}

function estimateRow(): number {
  return ESTIMATE_PX;
}

function metricsOf(el: HTMLElement): Metrics {
  return { scrollTop: el.scrollTop, scrollHeight: el.scrollHeight, clientHeight: el.clientHeight };
}

/** Where `list` starts in the content of the scroll element `el`, which scrolling does not change. */
function topIn(el: HTMLElement, list: HTMLElement): number {
  return list.getBoundingClientRect().top - el.getBoundingClientRect().top + el.scrollTop;
}

/**
 * Where row `index` starts in the list, by the virtualizer's measurements. A row measured since
 * the virtualizer last laid the rows out leaves its `measurementsCache` behind; reading the total
 * size lays them out again first.
 */
function startOf(
  virtualizer: { getTotalSize(): number; measurementsCache: ReadonlyArray<{ start: number }> },
  index: number,
): number | undefined {
  virtualizer.getTotalSize();
  return virtualizer.measurementsCache[index]?.start;
}

function Note(p: { text: string }): JSX.Element {
  return (
    <div className="tx-wrap">
      <div className="tx">
        <div className="codex-note">
          <Icon name="term" />
          <b>{p.text}</b>
        </div>
      </div>
    </div>
  );
}
