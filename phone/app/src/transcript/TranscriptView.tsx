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
 * **The "Working…" line** (`Working`, mock 932) follows `.tx-list` inside `.tx`, outside the
 * virtual rows, while the session's chip is `working`. It reads how long since the chip changed
 * (`status.changedAt`), the one start time the wire has, again every second, and only while it
 * shows: no timer runs for a session that is not working. Its elapsed time is not announced on
 * each beat, though `.tx` is a live region. The line's coming and going is a layout like any
 * other, so a view that keeps to the bottom stays there (`settle`, below).
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
 * the page (`loadOlder`). Rows that fit the view, which the reader cannot scroll, ask at once,
 * and since no scroll event can follow them, a touch, a press or a wheel on `.tx` stands in for
 * the reader's next scroll after a failure: it clears the failure, and the layout after it asks
 * again. Each failure waits for another gesture, so a failing page never retries in a loop.
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
 * event the write fires reads as the list's own and not as a swipe (`takeScroll`). It notes the
 * virtualizer's writes the same way (`scrollToFn`): the virtualizer moves the view by as much as
 * a row above it grew when it measures that row, and that is not the reader's scroll, so it
 * neither asks for a page nor retries a failed one. A scroll event that moved the view a pixel or
 * less leaves the noted place as it was, so a slow drag adds up until it counts as the reader's,
 * and then asks for a page and retries a failed one as any scroll does. A write from a tap
 * or from a store change lands before the next frame, whose scroll event the virtualizer reads
 * first, so the rows at the new place are drawn before that frame paints. The list's scroll
 * listener is a capture listener on `.tx-wrap`: it runs before the virtualizer's own listener on
 * `.tx`, which may draw rows on the spot, and so runs the list's effects, which must see the
 * reader's scroll already.
 *
 * **The size of `.tx`** reaches the virtualizer one animation frame late, after the first
 * (`observeRect`). The virtualizer reads it from a resize observer of its own, and by default
 * draws rows inside that observer's callback. WebKit then reports "ResizeObserver loop completed
 * with undelivered notifications" as a page error when `.tx` changes size under a transcript
 * taller than the screen, as when a status change makes the header taller. Late by a frame, it
 * does not. The list's own observer, which keeps the view at the bottom, still runs at once, and
 * for that frame the virtualizer draws the rows for the old size, with the overscan around them.
 */

import { useCallback, useLayoutEffect, useRef, useState, type JSX } from 'react';
import { elementScroll, observeElementRect, useVirtualizer, type Rect, type Virtualizer } from '@tanstack/react-virtual';
import { useActions, useAppState } from '../state/context.tsx';
import type { DetailState } from '../state/detail.ts';
import type { TranscriptRow } from '../state/transcript.ts';
import type { PhoneSession } from '../protocol/types.ts';
import { sameRef } from '../protocol/wire.ts';
import { dur } from '../state/status.ts';
import { Dots, Icon } from '../ui/Icon.tsx';
import { useNow } from '../ui/now.ts';
import { ItemRow, type RowPart } from './ItemRow.tsx';
import {
  anchorAt, atBottom, fitsView, fromBottom, prepended, pushedFromBottom, restoreTop, rowsChange, seenRows, takeScroll, wantsOlder,
} from './scroll.ts';
import type { Anchor, Metrics, Paging, SeenRows } from './scroll.ts';

/** The height the virtualizer gives a row it has not measured yet. */
const ESTIMATE_PX = 48;

/** The rows the virtualizer draws beyond each end of the screen. */
const OVERSCAN = 8;

/** The reader's gestures on rows that fit the view, which no scroll event follows (this file's header). */
const GESTURES = ['touchstart', 'pointerdown', 'wheel'] as const;

/** How often the "Working…" line reads its elapsed time again, in milliseconds. */
const WORKING_REFRESH_MS = 1_000;

const NO_ROWS: readonly TranscriptRow[] = [];

export function TranscriptView(p: { session: PhoneSession }): JSX.Element {
  const actions = useActions();
  const t = useAppState((s) => s.transcript);
  // One function for every row on every render, so a row draws again only when it changes.
  const toggle = useCallback((rowKey: number, part: RowPart) => void actions.toggleDetail(rowKey, part), [actions]);
  const { available, reason } = p.session.capabilities.transcript;
  if (!available) return <Note text={reason ?? ''} />;
  if (t.phase === 'failed') return <Note text={t.error ?? ''} />;
  const shown = t.ref !== null && sameRef(t.ref, p.session.ref);
  const { status } = p.session;
  return (
    <List
      rows={shown ? t.rows : NO_ROWS}
      appended={shown ? t.appendedSinceSeen : 0}
      paging={shown && t.phase === 'open' ? t : null}
      details={t.details}
      toggle={toggle}
      workingSince={status.chip === 'working' ? status.changedAt : null}
    />
  );
}

/**
 * What the list keeps between renders, none of which it draws:
 * - `stuck`: whether the view keeps to the bottom: whether it was at the bottom after the last
 *   scroll event, or the list has put it there since;
 * - `top`: the `scrollTop` of the list's last write, or of the last scroll event it took as the
 *   reader's, so a scroll event can tell whether the reader moved the view (`takeScroll`);
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
 * - `workingSince`: when the session's chip turned `working`, in Unix milliseconds, while it is
 *   that; otherwise null, and no "Working…" line shows.
 */
function List(p: {
  rows: readonly TranscriptRow[];
  appended: number;
  paging: Paging | null;
  details: Readonly<Record<number, DetailState>>;
  toggle: (rowKey: number, part: RowPart) => void;
  workingSince: number | null;
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
    observeElementRect: observeRect,
  });

  /** Scrolls to the bottom, and notes where that left the view. */
  const toBottom = useCallback(
    (el: HTMLElement): void => {
      el.scrollTop = el.scrollHeight - el.clientHeight;
      noteWrite(view, el);
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
      noteWrite(view, el);
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

  // The reader's scroll, their gestures on rows that fit the view, and a `.tx` that changed size.
  useLayoutEffect(() => {
    const wrap = wrapRef.current;
    const el = scrollRef.current;
    if (wrap === null || el === null) return;
    const onScroll = (e: Event): void => {
      if (e.target !== el) return;
      const m = metricsOf(el);
      const { byReader, top } = takeScroll(view.top, m);
      view.top = top;
      // The event of the list's own write may come after a layout that pushed the view.
      if (byReader) view.seen = fromBottom(m);
      else settle();
      // Where the view is now says whether it keeps to the bottom, however little moved it.
      view.stuck = atBottom(metricsOf(el));
      if (view.stuck) setPill(false);
      // The anchor follows the view while a page is on its way, and the reader while one goes in.
      if (view.anchor !== null && (byReader || view.restoring === null)) view.anchor = anchorNow(el);
      if (!byReader) return;
      actions.clearOlderFailed();
      const paging = view.paging;
      if (paging !== null && wantsOlder(metricsOf(el), { ...paging, olderFailed: false })) askOlder(el);
    };
    const onGesture = (): void => {
      if (fitsView(metricsOf(el))) actions.clearOlderFailed();
    };
    const resized = new ResizeObserver(afterLayout);
    wrap.addEventListener('scroll', onScroll, { capture: true, passive: true });
    for (const type of GESTURES) el.addEventListener(type, onGesture, { passive: true });
    resized.observe(el);
    return () => {
      wrap.removeEventListener('scroll', onScroll, { capture: true });
      for (const type of GESTURES) el.removeEventListener(type, onGesture);
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
        {p.workingSince !== null && <Working since={p.workingSince} />}
      </div>
      {pill && (
        <button className="pill" type="button" onClick={onPill}>
          New messages <Icon name="down" />
        </button>
      )}
    </div>
  );
}

/**
 * The "Working…" line (mock 932): the dots, "Working… " and how long since `since`, read again
 * every `WORKING_REFRESH_MS`. A component of its own, so each beat draws this line again and
 * not the list, and its timer runs only while the line shows. The elapsed time opts out of
 * `.tx`'s live region (`aria-live="off"`), so a screen reader is not told the time every second.
 */
function Working(p: { since: number }): JSX.Element {
  const now = useNow(WORKING_REFRESH_MS);
  return (
    <div className="working">
      <Dots />
      {'Working… '}
      <span aria-live="off">{dur(now - p.since)}</span>
    </div>
  );
}

function estimateRow(): number {
  return ESTIMATE_PX;
}

/**
 * The virtualizer's `observeElementRect`, with every size after the first passed on in the next
 * animation frame, and only the latest of a frame's sizes (this file's header). The first comes
 * at once, so the first render draws the rows that fill the screen.
 */
function observeRect(instance: Virtualizer<HTMLDivElement, HTMLDivElement>, cb: (rect: Rect) => void): () => void {
  let first = true;
  let frame: number | null = null;
  const stop = observeElementRect(instance, (rect) => {
    if (first) {
      first = false;
      cb(rect);
      return;
    }
    if (frame !== null) cancelAnimationFrame(frame);
    frame = requestAnimationFrame(() => {
      frame = null;
      cb(rect);
    });
  });
  return () => {
    if (frame !== null) cancelAnimationFrame(frame);
    stop?.();
  };
}

function metricsOf(el: HTMLElement): Metrics {
  return { scrollTop: el.scrollTop, scrollHeight: el.scrollHeight, clientHeight: el.clientHeight };
}

/** Notes where the list's own write left the view, so the scroll event it fires does not read as a swipe (`takeScroll`). */
function noteWrite(view: ViewState, el: HTMLElement): void {
  const m = metricsOf(el);
  view.top = m.scrollTop;
  view.seen = fromBottom(m);
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
