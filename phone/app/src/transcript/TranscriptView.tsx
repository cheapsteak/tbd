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
 * The list writes `scrollTop` itself, and notes where each write left the view, so the scroll
 * event the write fires reads as the list's own and not as a swipe (`moved`). A write from a tap
 * or from a store change lands before the next frame, whose scroll event the virtualizer reads
 * first, so the rows at the new place are drawn before that frame paints. The list's scroll
 * listener is a capture listener on `.tx-wrap`: it runs before the virtualizer's own listener on
 * `.tx`, which may draw rows on the spot, and so runs the list's effects, which must see the
 * reader's scroll already.
 */

import { useCallback, useLayoutEffect, useRef, useState, type JSX } from 'react';
import { useVirtualizer } from '@tanstack/react-virtual';
import { useActions, useAppState } from '../state/context.tsx';
import type { DetailState } from '../state/detail.ts';
import type { TranscriptRow } from '../state/transcript.ts';
import type { PhoneSession } from '../protocol/types.ts';
import { sameRef } from '../protocol/wire.ts';
import { Icon } from '../ui/Icon.tsx';
import { ItemRow, type RowPart } from './ItemRow.tsx';
import { atBottom, fromBottom, moved, pushedFromBottom, rowsChange, seenRows, sticksAfterScroll } from './scroll.ts';
import type { Metrics, SeenRows } from './scroll.ts';

/** The height the virtualizer gives a row it has not measured yet. */
const ESTIMATE_PX = 48;

/** The rows the virtualizer draws beyond each end of the screen. */
const OVERSCAN = 8;

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
  return <List rows={shown ? t.rows : NO_ROWS} appended={shown ? t.appendedSinceSeen : 0} details={t.details} toggle={toggle} />;
}

/**
 * What the list keeps between renders, none of which it draws:
 * - `stuck`: whether the view keeps to the bottom (`sticksAfterScroll`);
 * - `top`: the `scrollTop` it last saw or wrote, so a scroll event can tell whether the view
 *   moved;
 * - `seen`: how far the view was above its bottom then (`fromBottom`), so a layout can tell
 *   whether something pushed it away;
 * - `rows`: the rows it last saw (`rowsChange`).
 */
interface ViewState {
  stuck: boolean;
  top: number;
  seen: number;
  rows: SeenRows;
}

/**
 * The virtual list, the bottom it keeps to and the pill (this file's header).
 * - `rows`: the rows to show, the slice's when it holds this session's transcript.
 * - `appended`: the slice's `appendedSinceSeen` for those rows; a rise means rows came in below.
 */
function List(p: {
  rows: readonly TranscriptRow[];
  appended: number;
  details: Readonly<Record<number, DetailState>>;
  toggle: (rowKey: number, part: RowPart) => void;
}): JSX.Element {
  const { rows, appended } = p;
  const wrapRef = useRef<HTMLDivElement>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const view = useRef<ViewState>({ stuck: true, top: 0, seen: 0, rows: { lastKey: null, appended: 0 } }).current;
  const [pill, setPill] = useState(false);
  // A new function only when the rows change, so the virtualizer lays the rows out again then.
  const getItemKey = useCallback((index: number) => rows[index]!.key, [rows]);
  const virtualizer = useVirtualizer<HTMLDivElement, HTMLDivElement>({
    count: rows.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: estimateRow,
    getItemKey,
    overscan: OVERSCAN,
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
    };
    const resized = new ResizeObserver(settle);
    wrap.addEventListener('scroll', onScroll, { capture: true, passive: true });
    resized.observe(el);
    return () => {
      wrap.removeEventListener('scroll', onScroll, { capture: true });
      resized.disconnect();
    };
  }, [view, settle]);

  // Rows that came in. A page in place of the rows starts at the bottom; rows below a view that
  // does not keep to the bottom show the pill.
  useLayoutEffect(() => {
    const change = rowsChange(view.rows, rows, appended);
    view.rows = seenRows(rows, appended);
    if (change === 'replaced') {
      view.stuck = true;
      setPill(false);
      if (scrollRef.current !== null) toBottom(scrollRef.current);
    } else if (change === 'appended' && !view.stuck) {
      setPill(true);
    }
  }, [view, rows, appended, toBottom]);

  // After every render, since rows can change height in any of them.
  useLayoutEffect(settle);

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
        <div className="tx-list" style={{ height: virtualizer.getTotalSize() }}>
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
