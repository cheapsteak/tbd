// Tests transcript.ts: row keys, appends, updates and resets, older pages above the rows,
// receipts, which events fold in while an open or a resume is on its way, and the slice itself
// returned when nothing changes.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AppEvent, PhoneItem, PhoneSessionRef, TranscriptPage } from '../protocol/types.ts';
import type { DetailState } from './detail.ts';
import { addReceipt, applyPage, applyTranscriptEvent, beginOpen, beginResume, emptyTranscript, prependPage } from './transcript.ts';
import type { TranscriptRow, TranscriptState } from './transcript.ts';

const R: PhoneSessionRef = { kind: 'local', terminalID: 'T-R' };
const OTHER: PhoneSessionRef = { kind: 'local', terminalID: 'T-other' };
const REMOTE: PhoneSessionRef = { kind: 'remote', provider: 'acme-cloud', sessionID: 'S1' };

function item(id: string, text = id): PhoneItem {
  return { id, kind: 'assistant', text, truncated: false };
}

/** A page of `items`. A null cursor is a page that reached the start. */
function page(items: PhoneItem[], cursor: string | null = 'c1'): TranscriptPage {
  const p: TranscriptPage = { items, reachedStart: cursor === null, omittedItems: 0 };
  if (cursor !== null) p.cursor = cursor;
  return p;
}

/** The slice showing `ref`'s transcript, its rows `items`. */
function withRows(items: PhoneItem[], ref: PhoneSessionRef = R): TranscriptState {
  return { ...applyPage(beginOpen(emptyTranscript(), ref, false, 'open-1'), page(items)), phase: 'open' };
}

function append(items: PhoneItem[], session: PhoneSessionRef = R): AppEvent {
  return { event: 'transcript.append', seq: 1, data: { session, items } };
}

function update(items: PhoneItem[], session: PhoneSessionRef = R): AppEvent {
  return { event: 'transcript.update', seq: 1, data: { session, items } };
}

function reset(p: TranscriptPage, session: PhoneSessionRef = R): AppEvent {
  return { event: 'transcript.reset', seq: 1, data: { session, reason: 'rollover', page: p } };
}

/** Each row as `id:text` for an item and `receipt:id:text` for a receipt. */
function shown(s: TranscriptState): string[] {
  return s.rows.map((r) => (r.kind === 'item' ? `${r.item.id}:${r.item.text ?? ''}` : `receipt:${r.id}:${r.text}`));
}

function keyOf(s: TranscriptState, i: number): number {
  return (s.rows[i] as TranscriptRow).key;
}

const DETAIL: DetailState = {
  parts: ['input', 'result'], partIndex: 0, chunk: 0, chunkCount: 1, text: {}, items: [], bytes: 0, largeParts: [], phase: 'loading',
  cancelled: false, error: null,
};

test('the empty slice holds no transcript', () => {
  const s = emptyTranscript();
  assert.equal(s.ref, null);
  assert.equal(s.phase, 'idle');
  assert.deepEqual(s.rows, []);
  assert.equal(s.nextKey, 0);
  assert.equal(s.cursor, null);
  assert.equal(s.pendingClose, false);
  assert.deepEqual(s.details, {});
});

test('an open page gives each item a row with its own key, in order', () => {
  const s = withRows([item('u1'), item('u2'), item('u3')]);
  assert.deepEqual(shown(s), ['u1:u1', 'u2:u2', 'u3:u3']);
  assert.deepEqual(s.rows.map((r) => r.key), [0, 1, 2]);
  assert.equal(s.nextKey, 3);
  assert.equal(s.cursor, 'c1');
  assert.equal(s.reachedStart, false);
});

test('append adds new items and replaces one it already has, keeping its key', () => {
  const s0 = withRows([item('u1'), item('u2', 'running')]);
  const s1 = applyTranscriptEvent(s0, append([item('u2', 'done'), item('u3')]));
  assert.deepEqual(shown(s1), ['u1:u1', 'u2:done', 'u3:u3']);
  assert.deepEqual(s1.rows.map((r) => r.key), [0, 1, 2]);
  assert.equal(s1.nextKey, 3);
  assert.equal(s1.appendedSinceSeen, 1);
  // The slice it came from is untouched.
  assert.deepEqual(shown(s0), ['u1:u1', 'u2:running']);
});

test('an append whose items repeat one another keeps the last, in one row', () => {
  const s1 = applyTranscriptEvent(withRows([item('u1')]), append([item('u2', 'a'), item('u2', 'b')]));
  assert.deepEqual(shown(s1), ['u1:u1', 'u2:b']);
  assert.equal(s1.appendedSinceSeen, 1);
});

test('update replaces by ID and ignores an unknown ID', () => {
  const s0 = withRows([item('u1'), item('u2', 'running')]);
  const s1 = applyTranscriptEvent(s0, update([item('u2', 'done'), item('nope')]));
  assert.deepEqual(shown(s1), ['u1:u1', 'u2:done']);
  assert.equal(keyOf(s1, 1), keyOf(s0, 1));
  assert.equal(s1.nextKey, s0.nextKey);
  assert.equal(s1.appendedSinceSeen, 0);
  assert.equal(applyTranscriptEvent(s0, update([item('nope')])), s0);
});

test('an item matches the last row that carries its ID', () => {
  // Two rows can share an ID once a remote prepend has moved the offsets.
  const s0 = prependPage(withRows([item('at-100', 'new')]), page([item('at-100', 'old')]));
  const s1 = applyTranscriptEvent(s0, update([item('at-100', 'newer')]));
  assert.deepEqual(shown(s1), ['at-100:old', 'at-100:newer']);
  const s2 = applyTranscriptEvent(s0, append([item('at-100', 'newest')]));
  assert.deepEqual(shown(s2), ['at-100:old', 'at-100:newest']);
});

test('reset replaces everything, receipts and open details included', () => {
  let s0 = withRows([item('u1'), item('u2')]);
  s0 = addReceipt(s0, R, 'p1', 'Answered on the laptop');
  s0 = { ...s0, details: { [keyOf(s0, 0)]: DETAIL }, loadingOlder: true };
  const s1 = applyTranscriptEvent(s0, reset(page([item('u9')], 'c9')));
  assert.deepEqual(shown(s1), ['u9:u9']);
  assert.deepEqual(s1.details, {});
  assert.equal(s1.cursor, 'c9');
  assert.equal(s1.loadingOlder, false);
  assert.equal(s1.appendedSinceSeen, 0);
  // Its rows take new keys, so no key names a row it named before.
  assert.ok(keyOf(s1, 0) >= s0.nextKey);
  assert.equal(s1.phase, 'open');
});

test('a page that reached the start has no cursor', () => {
  const s = applyPage(withRows([item('u1')]), page([item('u0')], null));
  assert.equal(s.cursor, null);
  assert.equal(s.reachedStart, true);
});

test('an older page goes above in order, and no row is dropped for sharing an ID', () => {
  const s1 = prependPage(withRows([item('at-100'), item('u2')]), page([item('u0'), item('at-100')]));
  assert.deepEqual(s1.rows.map((r) => r.kind === 'item' && r.item.id), ['u0', 'at-100', 'at-100', 'u2']);
  assert.equal(new Set(s1.rows.map((r) => r.key)).size, 4);
});

test('an older page keeps the rows below it and their keys, and takes its cursor', () => {
  const s0 = { ...withRows([item('u5'), item('u6')]), loadingOlder: true };
  const s1 = prependPage(s0, page([item('u3'), item('u4')], 'c0'));
  assert.deepEqual(shown(s1), ['u3:u3', 'u4:u4', 'u5:u5', 'u6:u6']);
  assert.deepEqual(s1.rows.slice(2).map((r) => r.key), s0.rows.map((r) => r.key));
  assert.equal(s1.cursor, 'c0');
  assert.equal(s1.loadingOlder, false);
  const s2 = prependPage(s1, page([item('u1')], null));
  assert.equal(s2.cursor, null);
  assert.equal(s2.reachedStart, true);
});

test('events for another session are ignored', () => {
  const s0 = withRows([item('u1')]);
  for (const other of [OTHER, REMOTE]) {
    assert.equal(applyTranscriptEvent(s0, append([item('u2')], other)), s0);
    assert.equal(applyTranscriptEvent(s0, update([item('u1', 'x')], other)), s0);
    assert.equal(applyTranscriptEvent(s0, reset(page([]), other)), s0);
    assert.equal(addReceipt(s0, other, 'p1', 'Answered on the laptop'), s0);
  }
  const idle = emptyTranscript();
  assert.equal(applyTranscriptEvent(idle, append([item('u2')])), idle);
  assert.equal(addReceipt(idle, R, 'p1', 'Answered on the laptop'), idle);
});

test('a remote session is matched by provider and session ID', () => {
  const s0 = withRows([item('u1')], REMOTE);
  const s1 = applyTranscriptEvent(s0, append([item('u2')], { kind: 'remote', provider: 'acme-cloud', sessionID: 'S1' }));
  assert.deepEqual(shown(s1), ['u1:u1', 'u2:u2']);
  const elsewhere: PhoneSessionRef = { kind: 'remote', provider: 'acme-other', sessionID: 'S1' };
  assert.equal(applyTranscriptEvent(s0, append([item('u2')], elsewhere)), s0);
});

test('anything that changes nothing returns the slice itself', () => {
  const s0 = withRows([item('u1'), item('u2')]);
  assert.equal(applyTranscriptEvent(s0, append([])), s0);
  assert.equal(applyTranscriptEvent(s0, update([])), s0);
  // The same item again, as a fresh object.
  assert.equal(applyTranscriptEvent(s0, append([item('u2')])), s0);
  assert.equal(applyTranscriptEvent(s0, update([{ ...item('u1') }])), s0);
  const changed: AppEvent = { event: 'sessions.changed', seq: 1, data: { rows: [], removedRowIDs: [] } };
  assert.equal(applyTranscriptEvent(s0, changed), s0);
  const s1 = addReceipt(s0, R, 'p1', 'Answered on the laptop');
  assert.equal(addReceipt(s1, R, 'p1', 'Answered on the laptop'), s1);
});

test('an item that gains or loses a field is a change', () => {
  const s0 = withRows([{ id: 't1', kind: 'tool', toolName: 'Bash', toolStatus: 'running', truncated: false }]);
  const s1 = applyTranscriptEvent(s0, update([{ id: 't1', kind: 'tool', toolName: 'Bash', toolStatus: 'ok', truncated: false }]));
  assert.notEqual(s1, s0);
  const s2 = applyTranscriptEvent(s0, update([{ id: 't1', kind: 'tool', toolName: 'Bash', truncated: false }]));
  assert.notEqual(s2, s0);
  assert.equal((s2.rows[0] as Extract<TranscriptRow, { kind: 'item' }>).item.toolStatus, undefined);
});

test('a receipt stays where the answer happened, and later items go below it', () => {
  const s0 = withRows([item('u1'), item('t1', 'running')]);
  const s1 = addReceipt(s0, R, 'p1', 'Answered on this phone: Allow');
  assert.deepEqual(shown(s1), ['u1:u1', 't1:running', 'receipt:p1:Answered on this phone: Allow']);
  assert.equal(s1.appendedSinceSeen, 1);
  const s2 = applyTranscriptEvent(s1, append([item('u3')]));
  assert.deepEqual(shown(s2), ['u1:u1', 't1:running', 'receipt:p1:Answered on this phone: Allow', 'u3:u3']);
  // An item above it that changes stays above it.
  const s3 = applyTranscriptEvent(s2, append([item('t1', 'done')]));
  assert.deepEqual(shown(s3), ['u1:u1', 't1:done', 'receipt:p1:Answered on this phone: Allow', 'u3:u3']);
  assert.equal(new Set(s3.rows.map((r) => r.key)).size, 4);
});

test('a second receipt for the same prompt replaces the first, in place', () => {
  const s0 = addReceipt(withRows([item('u1')]), R, 'p1', 'Answered on this phone: Allow');
  const s1 = addReceipt(applyTranscriptEvent(s0, append([item('u2')])), R, 'p1', 'Answered on the laptop');
  assert.deepEqual(shown(s1), ['u1:u1', 'receipt:p1:Answered on the laptop', 'u2:u2']);
  assert.equal(keyOf(s1, 1), keyOf(s0, 1));
  // A receipt for another prompt is a row of its own.
  const s2 = addReceipt(s1, R, 'p2', 'Answered on the laptop');
  assert.deepEqual(shown(s2).slice(-1), ['receipt:p2:Answered on the laptop']);
});

test("a receipt's prompt ID never matches an item's ID", () => {
  const s0 = addReceipt(withRows([item('p1')]), R, 'p1', 'Answered on the laptop');
  const s1 = applyTranscriptEvent(s0, update([item('p1', 'changed')]));
  assert.deepEqual(shown(s1), ['p1:changed', 'receipt:p1:Answered on the laptop']);
});

test('beginOpen keeps the rows of the session it opens again, and starts another with none', () => {
  let s0 = { ...withRows([item('u1')]), loadingOlder: true, olderFailed: true };
  s0 = { ...s0, details: { [keyOf(s0, 0)]: DETAIL } };
  const again = beginOpen(s0, R, true, 'open-2');
  assert.equal(again.phase, 'opening');
  assert.equal(again.openRequestID, 'open-2');
  assert.equal(again.showDetails, true);
  assert.equal(again.rows, s0.rows);
  assert.equal(again.cursor, 'c1');
  assert.equal(again.details, s0.details);
  // A page still on its way belongs to the open this one replaces.
  assert.equal(again.loadingOlder, false);
  assert.equal(again.olderFailed, false);

  const other = beginOpen(s0, OTHER, false, 'open-3');
  assert.deepEqual(other.ref, OTHER);
  assert.equal(other.phase, 'opening');
  assert.deepEqual(other.rows, []);
  assert.equal(other.cursor, null);
  assert.deepEqual(other.details, {});
  // Keys go on from where they were, so a new row never takes an old row's key.
  assert.equal(other.nextKey, s0.nextKey);
});

test('an open clears a close still unanswered', () => {
  const closing = { ...emptyTranscript(), pendingClose: true, nextKey: 7 };
  const s = beginOpen(closing, R, false, 'open-1');
  assert.equal(s.pendingClose, false);
  assert.equal(s.nextKey, 7);
});

test('events and receipts fold in only while the transcript shows: not while it opens, nor after a failed open', () => {
  // While an open is on its way, an event comes from the feed the open replaces, and its page
  // holds what the event said.
  for (const opening of [beginOpen(withRows([item('u1')]), R, true, 'open-2'), beginOpen(emptyTranscript(), R, false, 'open-1')]) {
    assert.equal(applyTranscriptEvent(opening, append([item('u2')])), opening);
    assert.equal(applyTranscriptEvent(opening, update([item('u1', 'x')])), opening);
    assert.equal(applyTranscriptEvent(opening, reset(page([item('u7')]))), opening);
    assert.equal(addReceipt(opening, R, 'p1', 'Answered on the laptop'), opening);
  }
  // A failed open holds no transcript.
  const failed: TranscriptState = { ...beginOpen(emptyTranscript(), R, false, 'open-1'), phase: 'failed', error: 'No.' };
  assert.equal(applyTranscriptEvent(failed, append([item('u2')])), failed);
  assert.equal(applyTranscriptEvent(failed, reset(page([item('u2')]))), failed);
  assert.equal(addReceipt(failed, R, 'p1', 'Answered on the laptop'), failed);
});

test('a resume keeps the slice showing, so the events the laptop replays before its reply fold in', () => {
  const shown0 = { ...withRows([item('u1')]), loadingOlder: true };
  const resuming = beginResume(shown0, 'open-2');
  assert.equal(resuming.openRequestID, 'open-2');
  assert.equal(resuming.phase, 'open');
  assert.equal(resuming.rows, shown0.rows);
  assert.equal(resuming.cursor, shown0.cursor);
  // An older page on its way still lands, if the resume keeps the feed.
  assert.equal(resuming.loadingOlder, true);
  const s1 = addReceipt(applyTranscriptEvent(resuming, append([item('u2')])), R, 'p1', 'Answered on the laptop');
  assert.deepEqual(shown(s1), ['u1:u1', 'u2:u2', 'receipt:p1:Answered on the laptop']);
  assert.deepEqual(shown(applyTranscriptEvent(resuming, reset(page([item('u7')])))), ['u7:u7']);
});
