// Tests events.ts: each event reaches its slice, the route follows the list, pending opens
// open with their toast, and prompt.changed receipts reach the transcript through addReceipt.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AppEvent, PhoneRow, PhoneSession, PhoneSessionRef, PromptChangedData, SessionsChangedData } from '../protocol/types.ts';
import { applyEvent, applyEventWith, applySessions, withPendingOpen } from './events.ts';
import type { EventSlices } from './events.ts';
import { applyPromptChanged } from './prompts.ts';
import { applySnapshot } from './sessionsData.ts';
import { initialState, SESSIONS_ROUTE } from './store.ts';
import type { AppState, UIState } from './store.ts';
import { addReceipt, applyTranscriptEvent } from './transcript.ts';
import type { TranscriptState } from './transcript.ts';

const CAN = { available: true };

function session(ref: PhoneSessionRef): PhoneSession {
  return {
    ref, agent: 'claude', tabName: 'claude', status: { chip: 'idle', changedAt: 1 },
    capabilities: { transcript: CAN, send: CAN, answer: CAN, switchProfile: CAN, fork: CAN, model: CAN },
  };
}

function row(id: string, refs: PhoneSessionRef[], name = id): PhoneRow {
  return { id, kind: 'worktree', name, remote: false, statusChangedAt: 1, sessions: refs.map(session) };
}

const R: PhoneSessionRef = { kind: 'local', terminalID: 'T-R' };
const R2: PhoneSessionRef = { kind: 'local', terminalID: 'T-R2' };
const OTHER: PhoneSessionRef = { kind: 'local', terminalID: 'T-other' };
const WT = '8A1E503C-B1A3-59EE-9AFE-5DE564EE906B';

/** A state whose list holds `rows`, with `ui` laid over the initial UI. */
function stateWith(rows: PhoneRow[], ui: Partial<UIState> = {}): AppState {
  const s = initialState();
  const sessions = applySnapshot({
    stream: 's1', seq: 1, replayed: false, omittedRows: 0, more: false, rows,
    layout: [{ id: 'repo:R1', kind: 'repo', name: 'acme', rows: rows.map((r) => ({ id: r.id, depth: 0 })) }],
  });
  return { ...s, sessions, ui: { ...s.ui, ...ui } };
}

/**
 * A `sessions.changed`. With `placed`, it carries a layout whose one group places those rows,
 * as the daemon's does whenever it removes a row.
 */
function changed(rows: PhoneRow[], removedRowIDs: string[] = [], placed?: string[]): AppEvent {
  const data: SessionsChangedData = { rows, removedRowIDs };
  if (placed !== undefined) data.layout = [{ id: 'repo:R1', kind: 'repo', name: 'acme', rows: placed.map((id) => ({ id, depth: 0 })) }];
  return { event: 'sessions.changed', seq: 2, data };
}

test('a session that leaves every row sends the route back to sessions', () => {
  const s0 = stateWith([row('W1', [OTHER]), row('W2', [R])], { route: { screen: 'session', ref: R } });
  const s1 = applyEvent(s0, changed([], ['W2'], ['W1']));
  assert.deepEqual(s1.ui.route, { screen: 'sessions' });
  assert.deepEqual(Object.keys(s1.sessions.rows), ['W1']);
});

test('a route that stands keeps the same object', () => {
  const route = { screen: 'session', ref: R } as const;
  const s0 = stateWith([row('W2', [R])], { route });
  const s1 = applyEvent(s0, changed([row('W2', [R], 'renamed')]));
  assert.equal(s1.ui.route, route);
  assert.equal(s1.ui, s0.ui);
});

test("leaving the session closes its menu and its sheets, but not New's", () => {
  const route = { screen: 'session', ref: R } as const;
  const s0 = stateWith([row('W2', [R])], { route, menu: { name: 'model' }, sheet: { name: 'switch-confirm', profileID: 'P1' } });
  const s1 = applyEvent(s0, changed([], ['W2'], []));
  assert.equal(s1.ui.menu, null);
  assert.equal(s1.ui.sheet, null);
  const sheet = { name: 'new', repoID: 'R1', repoName: 'acme' } as const;
  const s2 = applyEvent({ ...s0, ui: { ...s0.ui, sheet } }, changed([], ['W2'], []));
  assert.equal(s2.ui.sheet, sheet);
  // While the route stands, the menu and the sheet stay.
  const s3 = applyEvent(s0, changed([row('W2', [R], 'renamed')]));
  assert.deepEqual(s3.ui.menu, { name: 'model' });
  assert.deepEqual(s3.ui.sheet, { name: 'switch-confirm', profileID: 'P1' });
});

test('New stays open when the route goes back to the list, and closes when it goes to a session', () => {
  const sheet = { name: 'new', repoID: 'R1', repoName: 'acme' } as const;
  // The open session leaves the list while New is up: the list shows, and New stays over it.
  const s0 = stateWith([row('W1', [OTHER]), row('W2', [R])], { route: { screen: 'session', ref: R }, sheet });
  const s1 = applyEvent(s0, changed([], ['W2'], ['W1']));
  assert.equal(s1.ui.route, SESSIONS_ROUTE);
  assert.equal(s1.ui.sheet, sheet);
  // The worktree New created lists its session: it opens, and New closes.
  const s2 = applyEvent({ ...s1, ui: { ...s1.ui, pendingOpen: { worktreeID: WT, toast: 'Created {name}' } } }, changed([row(WT, [R2], 'fix-login')]));
  assert.deepEqual(s2.ui.route, { screen: 'session', ref: R2 });
  assert.equal(s2.ui.sheet, null);
  // So does a { ref } open, and one the list shows already.
  const s3 = applyEvent(stateWith([row('W1', [OTHER])], { sheet, pendingOpen: { ref: R } }), changed([row('W3', [R])]));
  assert.deepEqual(s3.ui.route, { screen: 'session', ref: R });
  assert.equal(s3.ui.sheet, null);
  const s4 = withPendingOpen(stateWith([row('W1', [R])], { sheet }), { ref: R });
  assert.deepEqual(s4.ui.route, { screen: 'session', ref: R });
  assert.equal(s4.ui.sheet, null);
});

test('a pending open becomes the route once its session appears', () => {
  const s0 = stateWith([row('W1', [OTHER])], { pendingOpen: { ref: R }, menu: { name: 'model' } });
  const s1 = applyEvent(s0, changed([row('W1', [OTHER])]));
  assert.deepEqual(s1.ui.pendingOpen, { ref: R });
  assert.equal(s1.ui.route, SESSIONS_ROUTE);
  const s2 = applyEvent(s1, changed([row('W3', [R])]));
  assert.deepEqual(s2.ui.route, { screen: 'session', ref: R });
  assert.equal(s2.ui.pendingOpen, null);
  assert.equal(s2.ui.lastRowID, 'W3');
  assert.equal(s2.ui.menu, null);
  // A { ref } open toasts nothing.
  assert.equal(s2.ui.toast, null);
});

test('a pending worktree open opens its first session and toasts its name', () => {
  const s0 = stateWith([row('W1', [OTHER])], { pendingOpen: { worktreeID: WT, toast: 'Created {name}' } });
  const s1 = applyEvent(s0, changed([row(WT, [], 'fix-login')]));
  assert.notEqual(s1.ui.pendingOpen, null, 'the row has no session yet');
  assert.equal(s1.ui.toast, null);
  const s2 = applyEvent(s1, changed([row(WT, [R2, R], 'fix-login')]));
  assert.deepEqual(s2.ui.route, { screen: 'session', ref: R2 });
  assert.equal(s2.ui.pendingOpen, null);
  assert.equal(s2.ui.lastRowID, WT);
  assert.deepEqual(s2.ui.toast, { id: 1, text: 'Created fix-login' });
});

test('the toast template takes the name as it is, and follows the toast showing', () => {
  const s0 = stateWith([], { pendingOpen: { worktreeID: WT, toast: '{name}: Created {name}' }, toast: { id: 7, text: 'older' } });
  const s1 = applyEvent(s0, changed([row(WT, [R], "fix-$&-$1-$$-$'")]));
  assert.deepEqual(s1.ui.toast, { id: 8, text: "fix-$&-$1-$$-$': Created fix-$&-$1-$$-$'" });
});

test('a pending worktree open with no toast template shows none', () => {
  const s0 = stateWith([], { pendingOpen: { worktreeID: WT, toast: null } });
  const s1 = applyEvent(s0, changed([row(WT, [R])]));
  assert.deepEqual(s1.ui.route, { screen: 'session', ref: R });
  assert.equal(s1.ui.toast, null);
});

test('a pending open for the session already shown keeps the route and clears the open', () => {
  const route = { screen: 'session', ref: R } as const;
  const s0 = stateWith([row('W2', [R])], { route, pendingOpen: { ref: R } });
  const s1 = applyEvent(s0, changed([row('W2', [R], 'renamed')]));
  assert.equal(s1.ui.route, route);
  assert.equal(s1.ui.pendingOpen, null);
});

test('a snapshot resolves the route and a pending open too', () => {
  const s0 = stateWith([row('W2', [R])], { route: { screen: 'session', ref: R }, pendingOpen: { ref: R2 } });
  const s1 = applySessions(s0, applySnapshot({ stream: 's2', seq: 1, replayed: false, omittedRows: 0, more: false, rows: [row('W1', [OTHER])] }));
  assert.equal(s1.ui.route, SESSIONS_ROUTE);
  assert.deepEqual(s1.ui.pendingOpen, { ref: R2 });
  const s2 = applySessions(s1, applySnapshot({ stream: 's2', seq: 1, replayed: false, omittedRows: 0, more: false, rows: [row('W4', [R2])] }));
  assert.deepEqual(s2.ui.route, { screen: 'session', ref: R2 });
  assert.equal(s2.ui.lastRowID, 'W4');
});

test('a pending open the list already shows opens at once, and one it does not waits', () => {
  const s0 = stateWith([row('W2', [R])]);
  const s1 = withPendingOpen(s0, { ref: R });
  assert.deepEqual(s1.ui.route, { screen: 'session', ref: R });
  assert.equal(s1.ui.pendingOpen, null);
  const s2 = withPendingOpen(s0, { ref: R2 });
  assert.equal(s2.ui.route, SESSIONS_ROUTE);
  assert.deepEqual(s2.ui.pendingOpen, { ref: R2 });
});

/** Slices that record their calls and return a new transcript slice, so a change shows. */
function recording(receipts: ReadonlyArray<{ id: string; text: string }>) {
  const calls: unknown[][] = [];
  const slices: EventSlices = {
    applyTranscriptEvent: (s, e) => { calls.push(['applyTranscriptEvent', e.event]); return { ...s }; },
    applyPromptChanged: (s, d) => { calls.push(['applyPromptChanged', d]); return { prompts: { ...s }, receipts }; },
    addReceipt: (s, ref, id, text) => {
      calls.push(['addReceipt', ref, id, text]);
      return { ...s, receipts: [...((s as TranscriptState & { receipts?: string[] }).receipts ?? []), text] } as TranscriptState;
    },
  };
  return { calls, slices };
}

const PROMPT_DATA: PromptChangedData = { session: R, prompts: [], resolved: [{ promptID: 'p1', answeredBy: 'laptop' }] };

test('prompt.changed receipts reach the transcript through addReceipt', () => {
  const { calls, slices } = recording([{ id: 'p1', text: 'Answered on the laptop' }]);
  const s0 = initialState();
  const s1 = applyEventWith(s0, { event: 'prompt.changed', seq: 3, data: PROMPT_DATA }, slices);
  assert.deepEqual(calls, [['applyPromptChanged', PROMPT_DATA], ['addReceipt', R, 'p1', 'Answered on the laptop']]);
  assert.notEqual(s1.prompts, s0.prompts);
  assert.deepEqual((s1.transcript as TranscriptState & { receipts?: string[] }).receipts, ['Answered on the laptop']);
});

test('several receipts reach addReceipt in order', () => {
  const { calls, slices } = recording([{ id: 'p1', text: 'one' }, { id: 'p2', text: 'two' }]);
  const s1 = applyEventWith(initialState(), { event: 'prompt.changed', seq: 3, data: PROMPT_DATA }, slices);
  assert.deepEqual(calls.slice(1), [['addReceipt', R, 'p1', 'one'], ['addReceipt', R, 'p2', 'two']]);
  assert.deepEqual((s1.transcript as TranscriptState & { receipts?: string[] }).receipts, ['one', 'two']);
});

test('transcript events reach the transcript slice', () => {
  const page = { items: [], reachedStart: true, omittedItems: 0 };
  const events: AppEvent[] = [
    { event: 'transcript.append', seq: 4, data: { session: R, items: [] } },
    { event: 'transcript.update', seq: 5, data: { session: R, items: [] } },
    { event: 'transcript.reset', seq: 6, data: { session: R, reason: 'rollover', page } },
  ];
  for (const e of events) {
    const { calls, slices } = recording([]);
    const s0 = initialState();
    const s1 = applyEventWith(s0, e, slices);
    assert.deepEqual(calls, [['applyTranscriptEvent', e.event]]);
    assert.notEqual(s1.transcript, s0.transcript);
    assert.equal(s1.sessions, s0.sessions);
    assert.equal(s1.ui, s0.ui);
  }
});

test('an event no slice changes returns the state itself', () => {
  // Slices that change nothing, so the test holds whatever parts 6c and 6d make of the real ones.
  const unchanged: EventSlices = {
    applyTranscriptEvent: (s) => s,
    applyPromptChanged: (s) => ({ prompts: s, receipts: [] }),
    addReceipt: (s) => s,
  };
  const s0 = initialState();
  assert.equal(applyEventWith(s0, { event: 'transcript.append', seq: 4, data: { session: R, items: [] } }, unchanged), s0);
  assert.equal(applyEventWith(s0, { event: 'prompt.changed', seq: 5, data: PROMPT_DATA }, unchanged), s0);
});

test('applyEvent uses the real slices', () => {
  // The real slices are the modules' own functions, whatever parts 6c and 6d make of them.
  const s0 = initialState();
  const e: AppEvent = { event: 'prompt.changed', seq: 5, data: PROMPT_DATA };
  const real = applyEventWith(s0, e, { applyTranscriptEvent, applyPromptChanged, addReceipt });
  assert.deepEqual(applyEvent(s0, e), real);
});
