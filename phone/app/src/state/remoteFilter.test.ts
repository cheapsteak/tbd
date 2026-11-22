// Tests remoteFilter.ts: the value a chip shows, a tap's pending value, and how a reply and a
// layout settle it, whichever comes first; and that a new layout, from an event or a snapshot,
// reaches it through `applySessions`.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { PhoneGroupLayout } from '../protocol/types.ts';
import { applyEvent, applySessions } from './events.ts';
import { followLayout, layoutFilterOn, pendingValues, shownFilterOn, tapFailed, tapTaken, withTap } from './remoteFilter.ts';
import { applySnapshot } from './sessionsData.ts';
import { initialState } from './store.ts';
import type { AppState, SessionsData, UIState } from './store.ts';

const A = '16E7737E-5C20-548E-81FC-5DD3F9A51D36';
const B = '8A1E503C-B1A3-59EE-9AFE-5DE564EE906B';

function repo(id: string, on: boolean): PhoneGroupLayout {
  const g: PhoneGroupLayout = { id: `repo:${id}`, kind: 'repo', name: id, rows: [] };
  return on ? { ...g, remoteFilterOn: true } : g;
}

function list(layout: PhoneGroupLayout[]): SessionsData {
  return applySnapshot({ stream: 's1', seq: 1, replayed: false, layout, rows: [], omittedRows: 0, more: false });
}

function ui(): UIState {
  return initialState().ui;
}

test("layoutFilterOn reads a repo group's flag, and nothing from other groups", () => {
  const layout: PhoneGroupLayout[] = [
    repo(A, true), repo(B, false),
    { id: 'scratch', kind: 'scratch', name: 'Scratch', rows: [], remoteFilterOn: true },
    { id: 'provider:acme-box', kind: 'provider', name: 'acme-box', rows: [], remoteFilterOn: true },
  ];
  assert.equal(layoutFilterOn(layout, A), true);
  assert.equal(layoutFilterOn(layout, B), false);
  assert.equal(layoutFilterOn(layout, 'acme-box'), null);
  assert.equal(layoutFilterOn(layout, 'C'), null);
});

test("the chip shows the phone's value while a tap waits, else the layout's", () => {
  const d = list([repo(A, false), repo(B, true)]);
  assert.equal(shownFilterOn(ui(), d, A), false);
  assert.equal(shownFilterOn(ui(), d, B), true);
  const tapped = withTap(ui(), A, true, 1);
  assert.equal(shownFilterOn(tapped, d, A), true);
  assert.equal(shownFilterOn(tapped, d, B), true);
  assert.equal(shownFilterOn(tapped, d, 'C'), null);
  assert.deepEqual({ ...pendingValues(tapped.remoteFilterPending) }, { [A]: true });
  assert.equal(Object.getPrototypeOf(pendingValues(tapped.remoteFilterPending)), null);
});

test('a tap replaces the repo\'s pending value and keeps the others\'', () => {
  const two = withTap(withTap(ui(), A, true, 1), B, false, 2);
  const again = withTap(two, A, false, 3);
  assert.deepEqual({ ...again.remoteFilterPending }, {
    [A]: { value: false, seq: 3, confirmed: false },
    [B]: { value: false, seq: 2, confirmed: false },
  });
  assert.equal(Object.getPrototypeOf(again.remoteFilterPending), null);
  assert.notEqual(again.remoteFilterPending, two.remoteFilterPending);
});

test('a success marks its own tap confirmed, or ends the wait when the layout agrees already', () => {
  const tapped = withTap(ui(), A, true, 1);
  assert.deepEqual(tapTaken(tapped, list([repo(A, false)]), A, 1).remoteFilterPending[A], { value: true, seq: 1, confirmed: true });
  assert.deepEqual(Object.keys(tapTaken(tapped, list([repo(A, true)]), A, 1).remoteFilterPending), []);
  // Another tap's success, or one for a repo with no wait, changes nothing.
  assert.equal(tapTaken(tapped, list([repo(A, false)]), A, 2), tapped);
  assert.equal(tapTaken(tapped, list([repo(B, false)]), B, 1), tapped);
});

test('a failure ends its own tap\'s wait with a toast; another tap\'s failure changes nothing', () => {
  const tapped = withTap(ui(), A, true, 2);
  const failed = tapFailed(tapped, A, 2, 'That repo is no longer on this laptop.');
  assert.deepEqual(Object.keys(failed.remoteFilterPending), []);
  assert.deepEqual(failed.toast, { id: 1, text: 'That repo is no longer on this laptop.' });
  const silent = tapFailed(tapped, A, 2, null);
  assert.deepEqual(Object.keys(silent.remoteFilterPending), []);
  assert.equal(silent.toast, null);
  assert.equal(tapFailed(tapped, A, 1, 'stale'), tapped);
  assert.equal(tapFailed(tapped, B, 2, 'other repo'), tapped);
});

test('a layout ends each wait it agrees with, each the laptop took, and each for a repo it lacks', () => {
  let u = withTap(ui(), A, true, 1);
  u = withTap(u, B, true, 2);
  u = tapTaken(u, list([repo(B, false)]), B, 2);
  u = withTap(u, 'C', true, 3);
  // A: the layout says off, and the laptop has not answered, so A waits. B: taken, so this
  // layout settles it, though it says off. C: the layout has no such repo.
  const next = followLayout(u, [repo(A, false), repo(B, false)]);
  assert.deepEqual({ ...next.remoteFilterPending }, { [A]: { value: true, seq: 1, confirmed: false } });
  assert.deepEqual(Object.keys(followLayout(next, [repo(A, true)]).remoteFilterPending), []);
  // A layout that settles nothing leaves `ui` as it is.
  assert.equal(followLayout(next, [repo(A, false)]), next);
});

test('a new layout reaches the waits, from an event or a snapshot; an event without one does not', () => {
  const base: AppState = initialState();
  const listed: AppState = applySessions(base, list([repo(A, false)]));
  const waiting: AppState = { ...listed, ui: withTap(listed.ui, A, true, 1) };

  const noLayout = applyEvent(waiting, { event: 'sessions.changed', seq: 2, data: { rows: [], removedRowIDs: [] } });
  assert.equal(noLayout.ui.remoteFilterPending, waiting.ui.remoteFilterPending);

  const agreeing = applyEvent(waiting, { event: 'sessions.changed', seq: 2, data: { layout: [repo(A, true)], rows: [], removedRowIDs: [] } });
  assert.deepEqual(Object.keys(agreeing.ui.remoteFilterPending), []);

  const snapshot = applySessions(waiting, list([repo(A, true)]));
  assert.deepEqual(Object.keys(snapshot.ui.remoteFilterPending), []);
  const disagreeing = applySessions(waiting, list([repo(A, false)]));
  assert.equal(disagreeing.ui.remoteFilterPending, waiting.ui.remoteFilterPending);
});
