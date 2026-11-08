// Tests scroll.ts with exact numbers: at the bottom within 30 px, an older page within two
// screens of the top, the anchor's place, when a view keeps to the bottom, and how the rows
// changed, read from rows the real transcript slice made.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AppEvent, PhoneItem, PhoneSessionRef, TranscriptPage } from '../protocol/types.ts';
import { addReceipt, applyPage, applyTranscriptEvent, beginOpen, emptyTranscript, prependPage } from '../state/transcript.ts';
import type { TranscriptState } from '../state/transcript.ts';
import {
  anchorAt, atBottom, fitsView, fromBottom, moved, prepended, pushedFromBottom, restoreTop, rowsChange, seenRows, STICK_PX,
  sticksAfterScroll, wantsOlder,
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
const PAGING = { cursor: 'c1', loadingOlder: false, reachedStart: false, olderFailed: false } as const;

test('an older page is wanted within two screens of the top, and not at two', () => {
  const tall = (scrollTop: number): Metrics => ({ scrollTop, scrollHeight: 10_000, clientHeight: 800 });
  assert.equal(wantsOlder(tall(0), PAGING), true);
  assert.equal(wantsOlder(tall(1599), PAGING), true);
  assert.equal(wantsOlder(tall(1599.9), PAGING), true);
  assert.equal(wantsOlder(tall(1600), PAGING), false);
  assert.equal(wantsOlder(tall(5000), PAGING), false);
});

test('no older page is wanted without a cursor, or with a page on its way, the start reached or a failure', () => {
  const near: Metrics = { scrollTop: 100, scrollHeight: 10_000, clientHeight: 800 };
  assert.equal(wantsOlder(near, { ...PAGING, cursor: null }), false);
  assert.equal(wantsOlder(near, { ...PAGING, loadingOlder: true }), false);
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

test('at the bottom a view keeps to it, whatever it did before', () => {
  assert.equal(sticksAfterScroll(false, 0, at(970)), true);
  assert.equal(sticksAfterScroll(false, 2000, at(1000)), true);
  assert.equal(sticksAfterScroll(true, 1000, at(975)), true);
});

test('above the bottom a view stops keeping to it only when it moved up', () => {
  // The reader swiped up 31 px from the bottom.
  assert.equal(sticksAfterScroll(true, 1000, at(969)), false);
  // Rows grew below the view before the list put it back: its own write's event moved nothing.
  const grown: Metrics = { scrollTop: 1000, scrollHeight: 2400, clientHeight: 800 };
  assert.equal(sticksAfterScroll(true, 1000, grown), true);
  // A rounded read-back of a write, up to a pixel short.
  assert.equal(sticksAfterScroll(true, 1000.5, { ...grown, scrollTop: 999.5 }), true);
  assert.equal(sticksAfterScroll(true, 1000.5, { ...grown, scrollTop: 999.4 }), false);
  // Moving down without reaching the bottom keeps a view that does not keep to it as it is.
  assert.equal(sticksAfterScroll(false, 100, at(500)), false);
});

test('a view that keeps to the bottom goes back to it when pushed more than a pixel further away', () => {
  // Rows grew 200 px below a view at the bottom.
  assert.equal(pushedFromBottom(true, 0, { scrollTop: 1000, scrollHeight: 2000, clientHeight: 800 }), true);
  // The keyboard took 300 px off a view 10 px above the bottom.
  assert.equal(pushedFromBottom(true, 10, { scrollTop: 990, scrollHeight: 1800, clientHeight: 500 }), true);
  // Nothing moved, or a pixel only.
  assert.equal(pushedFromBottom(true, 10, at(990)), false);
  assert.equal(pushedFromBottom(true, 10, at(989)), false);
  assert.equal(pushedFromBottom(true, 10, at(988)), true);
  // Rows got shorter.
  assert.equal(pushedFromBottom(true, 200, at(1000)), false);
  // A view that does not keep to the bottom stays where it is.
  assert.equal(pushedFromBottom(false, 0, { scrollTop: 0, scrollHeight: 5000, clientHeight: 800 }), false);
});

test('the event of the list’s own write, after the view got shorter, keeps it to the bottom and shows the push', () => {
  // Measured in Chromium: the list wrote 1,605 over 2,066 px in a 461 px view, and the phone
  // turned before that write's event came, leaving the view 299 px tall.
  const m: Metrics = { scrollTop: 1605, scrollHeight: 2066, clientHeight: 299 };
  assert.equal(moved(1605, m), false);
  assert.equal(sticksAfterScroll(true, 1605, m), true);
  assert.equal(pushedFromBottom(true, 0, m), true);
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

/** How the rows changed from `a` to `b`, as the list reads it. */
function change(a: TranscriptState, b: TranscriptState): string {
  return rowsChange(seenRows(a.rows, a.appendedSinceSeen), b.rows, b.appendedSinceSeen);
}

test('an append and a receipt read as appended', () => {
  const s = opened(['a', 'b']);
  const appended = applyTranscriptEvent(s, event('transcript.append', ['c']));
  assert.equal(change(s, appended), 'appended');
  const receipt = addReceipt(appended, R, 'p1', 'Answered on the laptop');
  assert.equal(change(appended, receipt), 'appended');
  // Seen at once: two appends.
  assert.equal(change(s, receipt), 'appended');
});

test('a row changed in place, an append that replaces a row, and an older page read as same', () => {
  const s = opened(['a', 'b']);
  assert.equal(change(s, applyTranscriptEvent(s, event('transcript.update', ['b'], 'b, longer'))), 'same');
  assert.equal(change(s, applyTranscriptEvent(s, event('transcript.append', ['b'], 'b again'))), 'same');
  const older = { ...s, loadingOlder: true };
  assert.equal(change(s, prependPage(older, page(['y', 'z']))), 'same');
});

test('an older page and an append seen at once read as appended', () => {
  const s = { ...opened(['a', 'b']), loadingOlder: true };
  const both = applyTranscriptEvent(prependPage(s, page(['z'])), event('transcript.append', ['c']));
  assert.equal(change(s, both), 'appended');
});

test('a reset, and a reopen’s page, read as replaced, even with the same items', () => {
  const s = applyTranscriptEvent(opened(['a', 'b']), event('transcript.append', ['c']));
  const reset: AppEvent = { event: 'transcript.reset', seq: 2, data: { session: R, reason: 'rollover', page: page(['a', 'b', 'c']) } };
  assert.equal(change(s, applyTranscriptEvent(s, reset)), 'replaced');
  const reopened = { ...applyPage(beginOpen(s, R, true, 'open-2'), page(['a', 'b', 'c'])), phase: 'open' as const };
  assert.equal(change(s, reopened), 'replaced');
  // A page and an append after it, seen at once.
  assert.equal(change(s, applyTranscriptEvent(applyTranscriptEvent(s, reset), event('transcript.append', ['d']))), 'replaced');
});

test('the first page over no rows reads as replaced, and no rows to none as same', () => {
  const none = beginOpen(emptyTranscript(), R, false, 'open-1');
  assert.equal(change(none, opened(['a'])), 'replaced');
  assert.equal(change(none, none), 'same');
  assert.equal(change(none, opened([])), 'same');
  // Rows to none, as a reset to an empty page does.
  assert.equal(rowsChange(seenRows(opened(['a']).rows, 0), [], 0), 'replaced');
});

test('seenRows names the first and the last row’s keys and the appends', () => {
  const s = applyTranscriptEvent(opened(['a', 'b']), event('transcript.append', ['c']));
  assert.deepEqual(seenRows(s.rows, s.appendedSinceSeen), { firstKey: s.rows[0]!.key, lastKey: s.rows[2]!.key, appended: 1 });
  assert.deepEqual(seenRows([], 0), { firstKey: null, lastKey: null, appended: 0 });
});

/** Whether the list reads rows that came in above, from `a` to `b`. */
function above(a: TranscriptState, b: TranscriptState): boolean {
  return prepended(seenRows(a.rows, a.appendedSinceSeen), b.rows);
}

test('an older page reads as prepended, with an append or without', () => {
  const s = { ...opened(['a', 'b']), loadingOlder: true };
  const older = prependPage(s, page(['y', 'z']));
  assert.equal(above(s, older), true);
  assert.equal(above(s, applyTranscriptEvent(older, event('transcript.append', ['c']))), true);
  // Two pages seen at once.
  assert.equal(above(s, prependPage({ ...older, loadingOlder: true }, page(['x']))), true);
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
  assert.equal(above(none, opened(['a'])), false);
  assert.equal(prepended(seenRows(s.rows, 0), []), false);
});
