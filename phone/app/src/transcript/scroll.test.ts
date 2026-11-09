// Tests scroll.ts with exact numbers: at the bottom within 30 px, an older page within two
// screens of the top, the anchor's place, which scroll events are the reader's, slow drags
// included, and how the rows changed, read from rows the real transcript slice made.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Virtualizer } from '@tanstack/react-virtual';
import type { AppEvent, PhoneItem, PhoneSessionRef, TranscriptPage } from '../protocol/types.ts';
import { addReceipt, applyPage, applyTranscriptEvent, beginOpen, clearTranscript, emptyTranscript, MAX_STALE_PAGES, prependPage } from '../state/transcript.ts';
import type { TranscriptRow, TranscriptState } from '../state/transcript.ts';
import {
  anchorAt, arrivedCount, atBottom, clampedToBottom, fitsView, fromBottom, itemKeys, moved, prepended, pushedFromBottom, restoreTop, rowsChange, seenRows,
  STICK_PX, takeScroll, wantsOlder,
} from './scroll.ts';
import type { Metrics } from './scroll.ts';

/** A view 800 px tall over 1,800 px of rows, scrolled to `scrollTop`. */
function at(scrollTop: number): Metrics {
  return { scrollTop, scrollHeight: 1800, clientHeight: 800 };
}

test('STICK_PX is the mock’s 30 px', () => {
  assert.equal(STICK_PX, 30);
});

test('a view is at the bottom within 30 px of it, and not at 31', () => {
  assert.equal(fromBottom(at(1000)), 0);
  assert.equal(atBottom(at(1000)), true);
  assert.equal(atBottom(at(970)), true);
  assert.equal(fromBottom(at(969)), 31);
  assert.equal(atBottom(at(969)), false);
  assert.equal(atBottom(at(0)), false);
  // A bounce past the bottom, and rows shorter than the view.
  assert.equal(atBottom(at(1040)), true);
  assert.equal(atBottom({ scrollTop: 0, scrollHeight: 500, clientHeight: 800 }), true);
});

test('fractional pixels count as they are', () => {
  assert.equal(atBottom(at(970.1)), true);
  assert.equal(atBottom(at(969.9)), false);
});

/** The slice's paging state with a cursor, nothing on its way, the start not reached and no failure. */
const PAGING = { cursor: 'c1', olderRequestID: null, heldPageID: null, stalePages: 0, reachedStart: false, olderFailed: false } as const;

test('an older page is wanted within two screens of the top, and not at two', () => {
  const tall = (scrollTop: number): Metrics => ({ scrollTop, scrollHeight: 10_000, clientHeight: 800 });
  assert.equal(wantsOlder(tall(0), PAGING), true);
  assert.equal(wantsOlder(tall(1599), PAGING), true);
  assert.equal(wantsOlder(tall(1599.9), PAGING), true);
  assert.equal(wantsOlder(tall(1600), PAGING), false);
  assert.equal(wantsOlder(tall(5000), PAGING), false);
});

test('no older page is wanted without a cursor, or with a page on its way, a stale page holding the turn, the start reached or a failure', () => {
  const near: Metrics = { scrollTop: 100, scrollHeight: 10_000, clientHeight: 800 };
  assert.equal(wantsOlder(near, { ...PAGING, cursor: null }), false);
  assert.equal(wantsOlder(near, { ...PAGING, olderRequestID: 'page-1' }), false);
  // A page on its way for rows a reset replaced, or as many stale pages as may be unanswered.
  assert.equal(wantsOlder(near, { ...PAGING, heldPageID: 'page-1', stalePages: 1 }), false);
  assert.equal(wantsOlder(near, { ...PAGING, stalePages: MAX_STALE_PAGES }), false);
  assert.equal(wantsOlder(near, { ...PAGING, stalePages: MAX_STALE_PAGES - 1 }), true);
  assert.equal(wantsOlder(near, { ...PAGING, reachedStart: true }), false);
  assert.equal(wantsOlder(near, { ...PAGING, olderFailed: true }), false);
  assert.equal(wantsOlder(near, PAGING), true);
});

test('rows fit the view when they are no taller than it, and not a pixel taller', () => {
  assert.equal(fitsView({ scrollTop: 0, scrollHeight: 500, clientHeight: 800 }), true);
  assert.equal(fitsView({ scrollTop: 0, scrollHeight: 800, clientHeight: 800 }), true);
  assert.equal(fitsView({ scrollTop: 0, scrollHeight: 801, clientHeight: 800 }), false);
  assert.equal(fitsView(at(0)), false);
});

test('anchorAt measures the row’s top from the view’s top, through the list’s own top', () => {
  // The list starts 12 px into the scroll element; the row starts 400 px into the list.
  assert.equal(anchorAt({ key: 7, start: 400 }, 12, 380).offset, 32);
  // The row starts above the view.
  assert.equal(anchorAt({ key: 7, start: 400 }, 12, 450).offset, -38);
  assert.deepEqual(anchorAt({ key: 3, start: 0 }, 12, 0), { key: 3, offset: 12 });
});

test('an anchor taken before a page and restored after it moves the view by the page’s height', () => {
  const a = anchorAt({ key: 7, start: 400 }, 12, 380);
  // A page 1,440 px tall went in above: the row now starts at 1,840 in the list.
  assert.equal(restoreTop(a, 12 + 1840), 380 + 1440);
  // The list's top moved too, as when the rows outgrew the view.
  const short = anchorAt({ key: 3, start: 0 }, 300, 0);
  assert.equal(restoreTop(short, 12 + 1440), 1440 + 12 - 300);
});

test('restoreTop puts the anchor’s row back at its offset', () => {
  // The row's top was 40 px below the view's top; a page above moved the row to 2,440.
  assert.equal(restoreTop({ key: 7, offset: 40 }, 2440), 2400);
  // A row partly above the view.
  assert.equal(restoreTop({ key: 7, offset: -25 }, 2440), 2465);
  assert.equal(restoreTop({ key: 7, offset: 0 }, 0), 0);
});

test('a scroll event moved the view when scrollTop changed by more than a pixel', () => {
  assert.equal(moved(1000, at(1000)), false);
  assert.equal(moved(1000, at(1001)), false);
  assert.equal(moved(1000, at(999)), false);
  assert.equal(moved(1000, at(1001.5)), true);
  assert.equal(moved(1000, at(998.5)), true);
});

test('a scroll event that moved the view more than a pixel is the reader’s, and is measured from next', () => {
  assert.deepEqual(takeScroll(1000, at(990)), { byReader: true, top: 990 });
  assert.deepEqual(takeScroll(1000, at(1001.5)), { byReader: true, top: 1001.5 });
  // The event of the list's own write, and a rounded read-back of it, are not.
  assert.deepEqual(takeScroll(1000, at(1000)), { byReader: false, top: 1000 });
  assert.deepEqual(takeScroll(1000.5, at(999.5)), { byReader: false, top: 1000.5 });
});

/**
 * A drag up from the bottom of `at`, `step` px an event for `n` events, folded through
 * `takeScroll` as the list folds it: which events count as the reader's, and whether the view
 * keeps to the bottom after each, which is whether it is at the bottom then.
 */
function drag(step: number, n: number): Array<{ scrollTop: number; byReader: boolean; stuck: boolean }> {
  let top = 1000;
  const out = [];
  for (let i = 1; i <= n; i++) {
    const m = at(1000 - i * step);
    const taken = takeScroll(top, m);
    top = taken.top;
    out.push({ scrollTop: m.scrollTop, byReader: taken.byReader, stuck: atBottom(m) });
  }
  return out;
}

test('a slow drag of a pixel or a third of one an event adds up until it counts as the reader’s', () => {
  // Every event alone moves the view a pixel or less.
  for (const [step, every] of [[1, 2], [1 / 3, 4]] as const) {
    const events = drag(step, 120);
    assert.ok(events.every((e) => !moved(e.scrollTop + step, at(e.scrollTop))), String(step));
    const counted = events.flatMap((e, i) => (e.byReader ? [i + 1] : []));
    assert.equal(counted[0], every, String(step));
    // From then on, every `every`-th event counts, measured from the last that did.
    assert.ok(counted.every((n, i) => n === every * (i + 1)), String(step));
  }
});

test('a slow drag stops keeping to the bottom once the view is more than 30 px from it', () => {
  for (const step of [1, 1 / 3]) {
    const events = drag(step, Math.ceil(60 / step));
    for (const e of events) assert.equal(e.stuck, 1000 - e.scrollTop <= STICK_PX, `${step} at ${e.scrollTop}`);
    assert.equal(events.at(-1)!.stuck, false);
  }
});

test('a view that keeps to the bottom goes back to it when pushed more than a pixel further away', () => {
  // Rows grew 200 px below a view at the bottom.
  assert.equal(pushedFromBottom(true, 0, 1000, { scrollTop: 1000, scrollHeight: 2000, clientHeight: 800 }), true);
  // The keyboard took 300 px off a view 10 px above the bottom.
  assert.equal(pushedFromBottom(true, 10, 990, { scrollTop: 990, scrollHeight: 1800, clientHeight: 500 }), true);
  // Nothing moved, or a pixel only, and rows that grew 2 px below the view.
  assert.equal(pushedFromBottom(true, 10, 990, at(990)), false);
  assert.equal(pushedFromBottom(true, 10, 990, { scrollTop: 990, scrollHeight: 1801, clientHeight: 800 }), false);
  assert.equal(pushedFromBottom(true, 10, 990, { scrollTop: 990, scrollHeight: 1802, clientHeight: 800 }), true);
  // A read-back a pixel off where the list noted it is no move of the reader's.
  assert.equal(pushedFromBottom(true, 0, 1000, { scrollTop: 999, scrollHeight: 2000, clientHeight: 800 }), true);
  // Rows got shorter.
  assert.equal(pushedFromBottom(true, 200, 1000, at(1000)), false);
  // A view that does not keep to the bottom stays where it is.
  assert.equal(pushedFromBottom(false, 0, 0, { scrollTop: 0, scrollHeight: 5000, clientHeight: 800 }), false);
});

test('a reader’s scroll that a layout sees before its scroll event is no push', () => {
  // Measured in WebKit: the reader scrolled a view at the bottom to the top, and the rows were
  // drawn again before that scroll's event came.
  assert.equal(pushedFromBottom(true, 0, 561, { scrollTop: 0, scrollHeight: 1092, clientHeight: 531 }), false);
  // Two pixels up, past the read-back rounding, is the reader's too.
  assert.equal(pushedFromBottom(true, 10, 990, at(988)), false);
});

test('a view at the bottom that the browser brought up with a shorter scroll element is not the reader’s', () => {
  // Measured in Chromium: the list noted 1,339 at the bottom of 2,050 px in a 711 px view; the
  // rows got 48 px shorter, which brought the view up to 1,291, and then grew 272 px, both
  // before the scroll event of the first change came.
  const shorter: Metrics = { scrollTop: 1291, scrollHeight: 2002, clientHeight: 711 };
  assert.equal(clampedToBottom(1339, shorter), true);
  const grown: Metrics = { scrollTop: 1291, scrollHeight: 2274, clientHeight: 711 };
  // Taken for the reader's, the move would leave the view 272 px up; noted, the view goes back.
  assert.equal(pushedFromBottom(true, 0, 1339, grown), false);
  assert.equal(pushedFromBottom(true, fromBottom(shorter), shorter.scrollTop, grown), true);
  // A reader's scroll up leaves the view above its bottom, and one down moves it down.
  assert.equal(clampedToBottom(1339, { ...shorter, scrollTop: 1000 }), false);
  assert.equal(clampedToBottom(1000, { scrollTop: 1291, scrollHeight: 2002, clientHeight: 711 }), false);
  // A view the list left where it was, or a pixel off it.
  assert.equal(clampedToBottom(1291, shorter), false);
  assert.equal(clampedToBottom(1292, shorter), false);
});

test('the event of the list’s own write, after the view got shorter, is not the reader’s and shows the push', () => {
  // Measured in Chromium: the list wrote 1,605 over 2,066 px in a 461 px view, and the phone
  // turned before that write's event came, leaving the view 299 px tall. The list puts the view
  // back at the bottom, so it still keeps to it.
  const m: Metrics = { scrollTop: 1605, scrollHeight: 2066, clientHeight: 299 };
  assert.deepEqual(takeScroll(1605, m), { byReader: false, top: 1605 });
  assert.equal(pushedFromBottom(true, 0, 1605, m), true);
  assert.equal(atBottom({ ...m, scrollTop: m.scrollHeight - m.clientHeight }), true);
});

// --- how the rows changed, from rows the slice made ------------------------------------------

const R: PhoneSessionRef = { kind: 'local', terminalID: 'T-R' };

function item(id: string): PhoneItem {
  return { id, kind: 'assistant', text: id, truncated: false };
}

function page(ids: string[], cursor: string | null = 'c1'): TranscriptPage {
  const p: TranscriptPage = { items: ids.map(item), reachedStart: cursor === null, omittedItems: 0 };
  if (cursor !== null) p.cursor = cursor;
  return p;
}

function event(e: 'transcript.append' | 'transcript.update', ids: string[], text?: string): AppEvent {
  const items = ids.map((id) => ({ ...item(id), text: text ?? id }));
  return { event: e, seq: 1, data: { session: R, items } };
}

/** The slice open on R with `ids` as its rows. */
function opened(ids: string[]): TranscriptState {
  return { ...applyPage(beginOpen(emptyTranscript(), R, false, 'open-1'), page(ids)), phase: 'open' };
}

/** What the list sees of the slice `s`'s rows. */
function seen(s: TranscriptState) {
  return seenRows(s.rows, s.replacements, s.appendedSinceSeen);
}

/** How the rows changed from `a` to `b`, as the list reads it. */
function change(a: TranscriptState, b: TranscriptState): string {
  return rowsChange(seen(a), seen(b));
}

/** The item IDs of the rows that came in at the bottom from `a` to `b`, as the list reads them. */
function arrived(a: TranscriptState, b: TranscriptState): string[] {
  return b.rows.slice(b.rows.length - arrivedCount(seen(a), seen(b))).map((r) => (r.kind === 'item' ? r.item.id : `receipt:${r.id}`));
}

test('an append and a receipt read as appended, and arrive', () => {
  const s = opened(['a', 'b']);
  const appended = applyTranscriptEvent(s, event('transcript.append', ['c']));
  assert.equal(change(s, appended), 'appended');
  assert.deepEqual(arrived(s, appended), ['c']);
  const receipt = addReceipt(appended, R, 'p1', 'Answered on the laptop');
  assert.equal(change(appended, receipt), 'appended');
  assert.deepEqual(arrived(appended, receipt), ['receipt:p1']);
  // Seen at once: two appends.
  assert.equal(change(s, receipt), 'appended');
  assert.deepEqual(arrived(s, receipt), ['c', 'receipt:p1']);
});

test('the first items appended to an empty transcript read as appended, and arrive', () => {
  const empty = opened([]);
  const first = applyTranscriptEvent(empty, event('transcript.append', ['a', 'b']));
  assert.equal(change(empty, first), 'appended');
  assert.deepEqual(arrived(empty, first), ['a', 'b']);
  // A receipt as a transcript's first row too.
  const receipt = addReceipt(empty, R, 'p1', 'Answered on the laptop');
  assert.equal(change(empty, receipt), 'appended');
  assert.deepEqual(arrived(empty, receipt), ['receipt:p1']);
});

test('a row changed in place, an append that replaces a row, and an older page read as same', () => {
  const s = opened(['a', 'b']);
  assert.equal(change(s, applyTranscriptEvent(s, event('transcript.update', ['b'], 'b, longer'))), 'same');
  assert.equal(change(s, applyTranscriptEvent(s, event('transcript.append', ['b'], 'b again'))), 'same');
  const older = { ...s, olderRequestID: 'page-1' };
  assert.equal(change(s, prependPage(older, page(['y', 'z']))), 'same');
});

test('an older page and an append seen at once read as appended, and only the append arrives', () => {
  const s = { ...opened(['a', 'b']), olderRequestID: 'page-1' };
  const both = applyTranscriptEvent(prependPage(s, page(['z'])), event('transcript.append', ['c']));
  assert.equal(change(s, both), 'appended');
  assert.deepEqual(arrived(s, both), ['c']);
});

test('a reset, and a reopen’s page, read as replaced, even with the same items', () => {
  const s = applyTranscriptEvent(opened(['a', 'b']), event('transcript.append', ['c']));
  const reset: AppEvent = { event: 'transcript.reset', seq: 2, data: { session: R, reason: 'rollover', page: page(['a', 'b', 'c']) } };
  assert.equal(change(s, applyTranscriptEvent(s, reset)), 'replaced');
  const reopened = { ...applyPage(beginOpen(s, R, true, 'open-2'), page(['a', 'b', 'c'])), phase: 'open' as const };
  assert.equal(change(s, reopened), 'replaced');
  // A page and an append after it, seen at once, and nothing arrives.
  const after = applyTranscriptEvent(applyTranscriptEvent(s, reset), event('transcript.append', ['d']));
  assert.equal(change(s, after), 'replaced');
  assert.deepEqual(arrived(s, after), []);
});

test('a page over no rows, or of no rows, reads as replaced, and nothing at all as same', () => {
  const none = beginOpen(emptyTranscript(), R, false, 'open-1');
  assert.equal(change(none, { ...applyPage(none, page(['a'])), phase: 'open' }), 'replaced');
  assert.equal(change(none, { ...applyPage(none, page([])), phase: 'open' }), 'replaced');
  assert.equal(change(none, none), 'same');
  // Rows to none, as a reset to an empty page does, and a close.
  const s = opened(['a']);
  assert.equal(change(s, applyTranscriptEvent(s, { event: 'transcript.reset', seq: 2, data: { session: R, reason: 'rollover', page: page([]) } })), 'replaced');
  assert.equal(change(s, clearTranscript(s)), 'replaced');
});

test('seenRows holds the slice’s replacements and appends, and the rows’ count', () => {
  const s = applyTranscriptEvent(opened(['a', 'b']), event('transcript.append', ['c']));
  assert.deepEqual(seen(s), { replacements: s.replacements, appended: 1, count: 3 });
  assert.deepEqual(seenRows([], -1, 0), { replacements: -1, appended: 0, count: 0 });
});

/** Whether the list reads rows that came in above, from `a` to `b`. */
function above(a: TranscriptState, b: TranscriptState): boolean {
  return prepended(seen(a), seen(b));
}

test('an older page reads as prepended, with an append or without', () => {
  const s = { ...opened(['a', 'b']), olderRequestID: 'page-1' };
  const older = prependPage(s, page(['y', 'z']));
  assert.equal(above(s, older), true);
  assert.equal(above(s, applyTranscriptEvent(older, event('transcript.append', ['c']))), true);
  // Two pages seen at once.
  assert.equal(above(s, prependPage({ ...older, olderRequestID: 'page-1' }, page(['x']))), true);
  // The same item IDs as the rows below are new rows all the same.
  assert.equal(above(s, prependPage(s, page(['a', 'b']))), true);
});

test('an append, an update, a reset, a reopen and a first page do not read as prepended', () => {
  const s = opened(['a', 'b']);
  assert.equal(above(s, s), false);
  assert.equal(above(s, applyTranscriptEvent(s, event('transcript.append', ['c']))), false);
  assert.equal(above(s, applyTranscriptEvent(s, event('transcript.update', ['a'], 'a, longer'))), false);
  const reset: AppEvent = { event: 'transcript.reset', seq: 2, data: { session: R, reason: 'rollover', page: page(['z', 'a', 'b']) } };
  assert.equal(above(s, applyTranscriptEvent(s, reset)), false);
  assert.equal(above(s, { ...applyPage(beginOpen(s, R, false, 'open-2'), page(['z', 'a', 'b'])), phase: 'open' }), false);
  const none = beginOpen(emptyTranscript(), R, false, 'open-1');
  assert.equal(above(none, { ...applyPage(none, page(['a'])), phase: 'open' }), false);
  assert.equal(above(s, clearTranscript(s)), false);
});

// --- the rows' keys, laid out by the virtualizer the list uses -------------------------------

/** The height the virtualizer below gives a row it has not measured. */
const ROW_PX = 50;

/**
 * The list's virtualizer, with no scroll element, over the rows of each slice it is given, with
 * the key function `itemKeys` makes for them, as the list renders it. `render` lays a slice's rows
 * out as a render does and says what came of it: the key function, how many rows the layout read
 * through it, and each row's key and start.
 */
function virtualList() {
  const keysFor = itemKeys();
  let reads = 0;
  // The rows, counting each row read.
  const counted = (rows: readonly TranscriptRow[]): readonly TranscriptRow[] =>
    new Proxy(rows, {
      get(target, prop, receiver) {
        if (typeof prop === 'string' && /^\d+$/.test(prop)) reads++;
        return Reflect.get(target, prop, receiver) as unknown;
      },
    });
  const options = {
    getScrollElement: () => null,
    estimateSize: () => ROW_PX,
    scrollToFn: () => {},
    observeElementRect: () => {},
    observeElementOffset: () => {},
  };
  const v = new Virtualizer<HTMLDivElement, HTMLDivElement>({ ...options, count: 0 });
  return {
    v,
    render(s: TranscriptState) {
      const getItemKey = keysFor(counted(s.rows), s.replacements);
      v.setOptions({ ...options, count: s.rows.length, getItemKey });
      reads = 0;
      const m = v.getMeasurements();
      const laidOut = Array.from({ length: m.length }, (_, i) => [m[i]!.key, m[i]!.start]);
      return { getItemKey, reads, laidOut };
    },
  };
}

test("the rows' key function stays one object until a page replaces the rows, and the rows are laid out anew whenever their keys moved", () => {
  const list = virtualList();
  const s0 = opened(['a', 'b', 'c', 'd']);
  const tall = s0.rows[1]!.key;
  // Each row's key and start, with the row `tall` measured at 120 px and the others unmeasured.
  const placed = (s: TranscriptState, tallPx = 120): Array<[number, number]> => {
    let start = 0;
    return s.rows.map((r): [number, number] => {
      const at: [number, number] = [r.key, start];
      start += r.key === tall ? tallPx : ROW_PX;
      return at;
    });
  };
  const first = list.render(s0);
  assert.deepEqual(first.laidOut, placed(s0, ROW_PX));

  // A row changed in place keeps the key function, and the layout reads no row.
  const s1 = applyTranscriptEvent(s0, event('transcript.update', ['b'], 'b, longer'));
  assert.notEqual(s1.rows, s0.rows);
  const inPlace = list.render(s1);
  assert.equal(inPlace.getItemKey, first.getItemKey);
  assert.equal(inPlace.reads, 0);
  // Measured anew, it lays out the rows from it on, and the row above stays put.
  list.v.resizeItem(1, 120);
  const measured = list.render(s1);
  assert.equal(measured.reads, 3);
  assert.deepEqual(measured.laidOut, placed(s1));

  // Rows that come in below, and an older page above, are laid out with their own keys, and the
  // measured row keeps its height under its key.
  const s2 = applyTranscriptEvent(s1, event('transcript.append', ['e']));
  const below = list.render(s2);
  assert.equal(below.getItemKey, first.getItemKey);
  assert.deepEqual(below.laidOut, placed(s2));
  const s3 = prependPage({ ...s2, olderRequestID: 'page-1' }, page(['y', 'z']));
  const above = list.render(s3);
  assert.equal(above.getItemKey, first.getItemKey);
  assert.deepEqual(above.laidOut, placed(s3));

  // A reset to as many rows takes a new key function, and the new rows are laid out under their own keys.
  const reset: AppEvent = { event: 'transcript.reset', seq: 2, data: { session: R, reason: 'rollover', page: page(['p', 'q', 'r', 's', 't', 'u', 'v']) } };
  const s4 = applyTranscriptEvent(s3, reset);
  assert.equal(s4.rows.length, s3.rows.length);
  const replaced = list.render(s4);
  assert.notEqual(replaced.getItemKey, first.getItemKey);
  assert.deepEqual(replaced.laidOut, placed(s4));
  // So does a clear, which leaves no row to lay out.
  const cleared = list.render(clearTranscript(s4));
  assert.notEqual(cleared.getItemKey, replaced.getItemKey);
  assert.deepEqual(cleared.laidOut, []);
});
