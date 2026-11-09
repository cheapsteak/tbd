// Tests transcript.ts: row keys, appends, updates and resets, older pages above the rows,
// receipts, which events fold in while an open or a resume is on its way, and the slice itself
// returned when nothing changes.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AppEvent, PhoneItem, PhoneSessionRef, TranscriptPage } from '../protocol/types.ts';
import type { DetailState } from './detail.ts';
import {
  addReceipt, applyPage, applyTranscriptEvent, beginOpen, beginResume, clearTranscript, emptyTranscript, MAX_STALE_PAGES, mayAskOlder, openFailure,
  prependPage, settleStalePage, staleHolds,
} from './transcript.ts';
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
  error: null,
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

/** `s` with each item row's `item` read through a getter that counts each read in `reads`. */
function counted(s: TranscriptState, reads: { n: number }): TranscriptState {
  const rows = s.rows.map((row): TranscriptRow => {
    if (row.kind !== 'item') return row;
    const { item } = row;
    return Object.defineProperty({ key: row.key, kind: 'item' }, 'item', {
      enumerable: true,
      get: () => {
        reads.n += 1;
        return item;
      },
    }) as TranscriptRow;
  });
  return { ...s, rows };
}

test('an update or a repeat near the bottom reads the rows near the bottom only, however long the transcript', () => {
  const n = 10_000;
  const items = Array.from({ length: n }, (_, i) => item(`u${i}`));
  const reads = { n: 0 };
  const s0 = counted(withRows(items), reads);
  /** How many rows `fn` read. */
  const readsOf = <T,>(fn: () => T): [T, number] => {
    reads.n = 0;
    const out = fn();
    return [out, reads.n];
  };
  const [s1, r1] = readsOf(() => applyTranscriptEvent(s0, update([item(`u${n - 1}`, 'done')])));
  assert.ok(r1 <= 3, `an update of the last row read ${r1} rows`);
  assert.equal(shown(s1).at(-1), `u${n - 1}:done`);
  const [s2, r2] = readsOf(() => applyTranscriptEvent(s0, append([item(`u${n - 5}`, 'again'), item(`u${n - 2}`, 'again')])));
  assert.ok(r2 <= 12, `a repeat near the bottom read ${r2} rows`);
  assert.deepEqual(shown(s2).slice(-5), [`u${n - 5}:again`, `u${n - 4}:u${n - 4}`, `u${n - 3}:u${n - 3}`, `u${n - 2}:again`, `u${n - 1}:u${n - 1}`]);
  assert.equal(s2.rows.length, n);
  // New items read every row, about twice at most, however many there are.
  const [s3, r3] = readsOf(() => applyTranscriptEvent(s0, append(Array.from({ length: 500 }, (_, i) => item(`n${i}`)))));
  assert.ok(r3 <= 2 * n + 10, `500 new items read ${r3} rows`);
  assert.equal(s3.rows.length, n + 500);
});

test('past its first pass over the rows, the search finds the same rows: the last with each ID, new rows included', () => {
  // Ten rows, two of them carrying `dup`; the first new item reads all ten, so the rest are looked up by ID.
  const s0 = withRows(['r0', 'r1', 'dup', 'r3', 'r4', 'r5', 'r6', 'r7', 'dup', 'r9'].map((id) => item(id)));
  const news = Array.from({ length: 20 }, (_, i) => item(`n${i}`));
  const s1 = applyTranscriptEvent(s0, append([...news, item('dup', 'changed'), item('n3', 'changed'), item('r0', 'changed'), item('n21')]));
  assert.deepEqual(shown(s1), [
    'r0:changed', 'r1:r1', 'dup:dup', 'r3:r3', 'r4:r4', 'r5:r5', 'r6:r6', 'r7:r7', 'dup:changed', 'r9:r9',
    ...news.map((x) => (x.id === 'n3' ? 'n3:changed' : `${x.id}:${x.id}`)), 'n21:n21',
  ]);
  // Each replaced row keeps its key, and each new row takes the next.
  assert.deepEqual(s1.rows.slice(0, 10).map((r) => r.key), s0.rows.map((r) => r.key));
  assert.deepEqual(s1.rows.slice(10).map((r) => r.key), Array.from({ length: 21 }, (_, i) => s0.nextKey + i));
  assert.equal(s1.appendedSinceSeen, 21);
  // An update past the first pass replaces only rows it has, and the last of two.
  const s2 = applyTranscriptEvent(s0, update([item('nope1'), item('nope2'), item('dup', 'x'), item('r1', 'y')]));
  assert.deepEqual(shown(s2), ['r0:r0', 'r1:y', 'dup:dup', 'r3:r3', 'r4:r4', 'r5:r5', 'r6:r6', 'r7:r7', 'dup:x', 'r9:r9']);
});

test('reset replaces everything, receipts and open details included', () => {
  let s0 = withRows([item('u1'), item('u2')]);
  s0 = addReceipt(s0, R, 'p1', 'Answered on the laptop');
  s0 = { ...s0, details: { [keyOf(s0, 0)]: DETAIL }, olderRequestID: 'page-1' };
  const s1 = applyTranscriptEvent(s0, reset(page([item('u9')], 'c9')));
  assert.deepEqual(shown(s1), ['u9:u9']);
  assert.deepEqual(s1.details, {});
  assert.equal(s1.cursor, 'c9');
  assert.equal(s1.olderRequestID, null);
  assert.equal(s1.appendedSinceSeen, 0);
  // Its rows take new keys, so no key names a row it named before.
  assert.ok(keyOf(s1, 0) >= s0.nextKey);
  assert.equal(s1.phase, 'open');
});

test('replacements counts each page in place of the rows and each clear, and only grows', () => {
  const s0 = withRows([item('u1')]);
  const n = s0.replacements;
  assert.ok(n > 0);
  assert.equal(applyTranscriptEvent(s0, reset(page([item('u9')]))).replacements, n + 1);
  assert.equal(applyTranscriptEvent(s0, reset(page([]))).replacements, n + 1);
  assert.equal(clearTranscript(s0).replacements, n + 1);
  assert.equal(beginOpen(s0, OTHER, false, 'open-2').replacements, n + 1);
  assert.equal(applyPage(beginOpen(s0, R, true, 'open-2'), page([item('u1')])).replacements, n + 1);
  // Rows that come in below or above, or change in place, and a reopen still on its way, leave it.
  assert.equal(beginOpen(s0, R, true, 'open-2').replacements, n);
  assert.equal(applyTranscriptEvent(s0, append([item('u2')])).replacements, n);
  assert.equal(applyTranscriptEvent(s0, update([item('u1', 'x')])).replacements, n);
  assert.equal(addReceipt(s0, R, 'p1', 'Answered on the laptop').replacements, n);
  assert.equal(prependPage(s0, page([item('u0')])).replacements, n);
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
  const s0 = { ...withRows([item('u5'), item('u6')]), olderRequestID: 'page-1' };
  const s1 = prependPage(s0, page([item('u3'), item('u4')], 'c0'));
  assert.deepEqual(shown(s1), ['u3:u3', 'u4:u4', 'u5:u5', 'u6:u6']);
  assert.deepEqual(s1.rows.slice(2).map((r) => r.key), s0.rows.map((r) => r.key));
  assert.equal(s1.cursor, 'c0');
  assert.equal(s1.olderRequestID, null);
  const s2 = prependPage(s1, page([item('u1')], null));
  assert.equal(s2.cursor, null);
  assert.equal(s2.reachedStart, true);
});

test('an older page that adds no row, or gives back the cursor it was asked with, stops paging until the reader scrolls', () => {
  const waiting = { ...withRows([item('u1')]), olderRequestID: 'page-1' };
  assert.equal(waiting.cursor, 'c1');
  const stuck = [
    ['no row and a new cursor', page([], 'c0')],
    ['no row and the same cursor', page([], 'c1')],
    ['a row and the same cursor', page([item('u0')], 'c1')],
  ] as const;
  for (const [what, p] of stuck) {
    const s = prependPage(waiting, p);
    assert.equal(s.olderFailed, true, what);
    assert.equal(s.olderRequestID, null, what);
    assert.equal(mayAskOlder(s), false, what);
  }
  // Its rows still go in, and the reader's scroll lets the next page go.
  const same = prependPage(waiting, page([item('u0')], 'c1'));
  assert.deepEqual(shown(same), ['u0:u0', 'u1:u1']);
  assert.equal(mayAskOlder({ ...same, olderFailed: false }), true);
  // A page that moved back, and one that reached the start, with rows or none, do not stop it.
  for (const p of [page([item('u0')], 'c0'), page([], null), page([item('u0')], null)]) {
    assert.equal(prependPage(waiting, p).olderFailed, false);
  }
  assert.equal(mayAskOlder(prependPage(waiting, page([item('u0')], 'c0'))), true);
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

test("an item that replaces a row takes the row's open detail along, as followItem says", () => {
  const running: PhoneItem = { id: 't1', kind: 'tool', truncated: false, toolName: 'Bash', target: 'npm test', toolStatus: 'running' };
  const cut: PhoneItem = { id: 'm1', kind: 'assistant', text: 'The start', truncated: true };
  let s0 = withRows([running, cut, item('m2')]);
  const input: DetailState = { ...DETAIL, parts: ['input'], phase: 'open', text: { input: 'npm test' } };
  const whole: DetailState = { ...DETAIL, parts: ['text'], phase: 'open', text: { text: 'The start, and the rest' } };
  s0 = { ...s0, details: { [keyOf(s0, 0)]: input, [keyOf(s0, 1)]: whole, [keyOf(s0, 2)]: DETAIL } };

  // The tool stopped running: its detail goes on to its result, keeping its input.
  const s1 = applyTranscriptEvent(s0, update([{ ...running, toolStatus: 'ok' }]));
  const tool = s1.details[keyOf(s0, 0)]!;
  assert.deepEqual([tool.parts, tool.partIndex, tool.chunk, tool.phase], [['input', 'result'], 1, 0, 'loading']);
  assert.deepEqual(tool.text, { input: 'npm test' });
  assert.equal(s1.details[keyOf(s0, 1)], whole);

  // The message's text changed, by an update or a same-ID append: its whole text goes.
  for (const e of [update([{ ...cut, text: 'The start, and more' }]), append([{ ...cut, text: 'The start, and more' }])]) {
    const s2 = applyTranscriptEvent(s1, e);
    assert.equal(s2.details[keyOf(s0, 1)], undefined);
    assert.equal(s2.details[keyOf(s0, 0)], tool);
    assert.equal(s2.details[keyOf(s0, 2)], DETAIL);
  }
  // The same text again changes nothing, and another item's change keeps the details.
  assert.equal(applyTranscriptEvent(s1, update([cut])), s1);
  assert.equal(applyTranscriptEvent(s1, update([item('m2', 'other')])).details, s1.details);
});

test('beginOpen keeps the rows of the session it opens again, and starts another with none', () => {
  let s0 = { ...withRows([item('u1')]), olderRequestID: 'page-1', olderFailed: true };
  s0 = { ...s0, details: { [keyOf(s0, 0)]: DETAIL } };
  const again = beginOpen(s0, R, true, 'open-2');
  assert.equal(again.phase, 'opening');
  assert.equal(again.openRequestID, 'open-2');
  assert.equal(again.showDetails, true);
  assert.equal(again.rows, s0.rows);
  assert.equal(again.cursor, 'c1');
  assert.equal(again.details, s0.details);
  // A page still on its way belongs to the open this one replaces.
  assert.equal(again.olderRequestID, null);
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

test('a reset or a resume page while an older page is on its way leaves that page holding the open’s turn', () => {
  const waiting = { ...withRows([item('u1')]), olderRequestID: 'page-1' };
  const after = [
    ['reset', applyTranscriptEvent(waiting, reset(page([item('n1')])))],
    ['resume page', applyPage(waiting, page([item('n1')]))],
  ] as const;
  for (const [what, s] of after) {
    assert.equal(s.olderRequestID, null, what);
    assert.equal(s.heldPageID, 'page-1', what);
    assert.equal(s.stalePages, 1, what);
    assert.equal(staleHolds(s), true, what);
    assert.equal(mayAskOlder(s), false, what);
    // Its settling frees the turn.
    const settled = settleStalePage(s, 'page-1');
    assert.equal(settled.heldPageID, null, what);
    assert.equal(settled.stalePages, 0, what);
    assert.equal(mayAskOlder(settled), true, what);
  }
  // The page landing above its own rows holds nothing.
  const landed = prependPage(waiting, page([item('u0')]));
  assert.equal(landed.heldPageID, null);
  assert.equal(landed.stalePages, 0);
});

test('an open or a close while an older page is on its way counts that page, and the next open may page at once', () => {
  const waiting = { ...withRows([item('u1')]), olderRequestID: 'page-1' };
  const after = [
    ['reopen', applyPage(beginOpen(waiting, R, true, 'open-2'), page([item('n1')]))],
    ['switch', applyPage(beginOpen(waiting, OTHER, false, 'open-2'), page([item('n1')]))],
    ['close, then open', applyPage(beginOpen(clearTranscript(waiting), OTHER, false, 'open-2'), page([item('n1')]))],
  ] as const;
  for (const [what, s] of after) {
    assert.equal(s.olderRequestID, null, what);
    assert.equal(s.heldPageID, null, what);
    assert.equal(s.stalePages, 1, what);
    assert.equal(mayAskOlder(s), true, what);
    // A page this open made stale, whose turn it held, settles first or after, and either way frees what it held only.
    const held = applyPage({ ...s, olderRequestID: 'page-2' }, page([item('n2')]));
    assert.equal(held.heldPageID, 'page-2', what);
    assert.equal(held.stalePages, 2, what);
    const oldFirst = settleStalePage(held, 'page-1');
    assert.equal(oldFirst.heldPageID, 'page-2', what);
    assert.equal(mayAskOlder(oldFirst), false, what);
    assert.equal(mayAskOlder(settleStalePage(oldFirst, 'page-2')), true, what);
  }
  // With no page on its way there is none to count, and a held page an open leaves counts still.
  const quiet = beginOpen(withRows([item('u1')]), R, true, 'open-2');
  assert.equal(quiet.stalePages, 0);
  const reopened = beginOpen({ ...withRows([item('u1')]), heldPageID: 'page-1', stalePages: 1 }, R, true, 'open-2');
  assert.equal(reopened.heldPageID, null);
  assert.equal(reopened.stalePages, 1);
});

test(`once ${MAX_STALE_PAGES} stale pages are unanswered no page is asked for, until one settles`, () => {
  let s: TranscriptState = withRows([item('u1')]);
  for (let n = 1; n <= MAX_STALE_PAGES; n++) {
    assert.equal(mayAskOlder(s), true, `open ${n}`);
    s = applyPage(beginOpen({ ...s, olderRequestID: `page-${n}` }, R, false, `open-${n}`), page([item(`n${n}`)]));
    assert.equal(s.stalePages, n);
  }
  assert.equal(staleHolds(s), true);
  assert.equal(mayAskOlder(s), false);
  // A close and an open keep the count, since the pages are still on the wire.
  s = applyPage(beginOpen(clearTranscript(s), OTHER, false, 'open-x'), page([item('x')]));
  assert.equal(mayAskOlder(s), false);
  s = settleStalePage(s, 'page-2');
  assert.equal(s.stalePages, MAX_STALE_PAGES - 1);
  assert.equal(mayAskOlder(s), true);
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

test("a failed open is reported for its own session only, with the laptop's message", () => {
  const message = 'The remote session did not load. Try again later.';
  const failedOf = (ref: PhoneSessionRef, error: string | null): TranscriptState => ({
    ...beginOpen(emptyTranscript(), ref, false, 'open-1'), phase: 'failed', error,
  });
  assert.equal(openFailure(failedOf(R, message), R), message);
  assert.equal(openFailure(failedOf(REMOTE, message), { kind: 'remote', provider: 'acme-cloud', sessionID: 'S1' }), message);
  assert.equal(openFailure(failedOf(R, null), R), '');
  // Another session's failure is none of this one's: its view shows no note.
  for (const [failed, ref] of [[R, OTHER], [OTHER, R], [R, REMOTE], [REMOTE, R]] as const) {
    assert.equal(openFailure(failedOf(failed, message), ref), null);
  }
  // A slice that is not failed reports nothing, for any session.
  for (const s of [emptyTranscript(), beginOpen(emptyTranscript(), R, false, 'open-1'), withRows([item('u1')])]) {
    assert.equal(openFailure(s, R), null);
  }
});

test('a resume keeps the slice showing, so the events the laptop replays before its reply fold in', () => {
  const shown0 = { ...withRows([item('u1')]), olderRequestID: 'page-1' };
  const resuming = beginResume(shown0, 'open-2');
  assert.equal(resuming.openRequestID, 'open-2');
  assert.equal(resuming.phase, 'open');
  assert.equal(resuming.rows, shown0.rows);
  assert.equal(resuming.cursor, shown0.cursor);
  // An older page on its way still lands, if the resume keeps the feed.
  assert.equal(resuming.olderRequestID, 'page-1');
  const s1 = addReceipt(applyTranscriptEvent(resuming, append([item('u2')])), R, 'p1', 'Answered on the laptop');
  assert.deepEqual(shown(s1), ['u1:u1', 'u2:u2', 'receipt:p1:Answered on the laptop']);
  assert.deepEqual(shown(applyTranscriptEvent(resuming, reset(page([item('u7')])))), ['u7:u7']);
});
