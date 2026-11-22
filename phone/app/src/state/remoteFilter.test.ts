// Tests remoteFilter.ts: the value a chip shows, a tap's pending value, and how a reply, a
// layout, any `sessions.changed` and the wait's timer settle it; that a new layout, from an event
// or a snapshot, reaches it through `applySessions`, and any `sessions.changed` through
// `applyEvent`; and that the wait is twice the daemon's publisher debounce.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import type { PhoneGroupLayout } from '../protocol/types.ts';
import { applyEvent, applySessions } from './events.ts';
import {
  followLayout, followSessionsChanged, layoutFilterOn, pendingValues, SESSIONS_DEBOUNCE_MS, shownFilterOn, TAKEN_WAIT_MS, tapExpired,
  tapFailed, tapTaken, withTap,
} from './remoteFilter.ts';
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
  const tapped = withTap(ui(), A, true, 1, false);
  assert.equal(shownFilterOn(tapped, d, A), true);
  assert.equal(shownFilterOn(tapped, d, B), true);
  assert.equal(shownFilterOn(tapped, d, 'C'), null);
  assert.deepEqual({ ...pendingValues(tapped.remoteFilterPending) }, { [A]: true });
  assert.equal(Object.getPrototypeOf(pendingValues(tapped.remoteFilterPending)), null);
});

test('a tap replaces the repo\'s pending value and keeps the others\'; one behind an unanswered request is queued', () => {
  const two = withTap(withTap(ui(), A, true, 1, false), B, false, 2, false);
  const again = withTap(two, A, false, 3, true);
  assert.deepEqual({ ...again.remoteFilterPending }, {
    [A]: { value: false, seq: 3, stage: 'queued' },
    [B]: { value: false, seq: 2, stage: 'sent' },
  });
  assert.equal(Object.getPrototypeOf(again.remoteFilterPending), null);
  assert.notEqual(again.remoteFilterPending, two.remoteFilterPending);
});

test('a success marks its own tap taken, or ends the wait when the layout agrees already', () => {
  const tapped = withTap(ui(), A, true, 1, false);
  assert.deepEqual(tapTaken(tapped, list([repo(A, false)]), A, 1).remoteFilterPending[A], { value: true, seq: 1, stage: 'taken' });
  assert.deepEqual(Object.keys(tapTaken(tapped, list([repo(A, true)]), A, 1).remoteFilterPending), []);
  // A queued tap's own reply settles it the same way.
  const queued = withTap(ui(), A, true, 1, true);
  assert.deepEqual(tapTaken(queued, list([repo(A, false)]), A, 1).remoteFilterPending[A], { value: true, seq: 1, stage: 'taken' });
  assert.deepEqual(Object.keys(tapTaken(queued, list([repo(A, true)]), A, 1).remoteFilterPending), []);
  // Another tap's success, or one for a repo with no wait, changes nothing.
  assert.equal(tapTaken(tapped, list([repo(A, false)]), A, 2), tapped);
  assert.equal(tapTaken(tapped, list([repo(B, false)]), B, 1), tapped);
});

test('a failure ends its own tap\'s wait with a toast; another tap\'s failure changes nothing', () => {
  const tapped = withTap(ui(), A, true, 2, false);
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
  let u = withTap(ui(), A, true, 1, false);
  u = withTap(u, B, true, 2, false);
  u = tapTaken(u, list([repo(B, false)]), B, 2);
  u = withTap(u, 'C', true, 3, false);
  // A: the layout says off, and the laptop has not answered, so A waits. B: taken, so this
  // layout settles it, though it says off. C: the layout has no such repo.
  const next = followLayout(u, [repo(A, false), repo(B, false)]);
  assert.deepEqual({ ...next.remoteFilterPending }, { [A]: { value: true, seq: 1, stage: 'sent' } });
  assert.deepEqual(Object.keys(followLayout(next, [repo(A, true)]).remoteFilterPending), []);
  // A layout that settles nothing leaves `ui` as it is.
  assert.equal(followLayout(next, [repo(A, false)]), next);
});

test('a layout that agrees with a queued tap leaves it waiting for its own reply; one without its repo ends the wait', () => {
  // Off; a tap on went out, and a tap off waits behind it. A layout that still says off may be
  // from before the first write, which can still turn the filter on: the off tap waits.
  const queued = withTap(ui(), A, false, 2, true);
  assert.equal(followLayout(queued, [repo(A, false)]), queued);
  assert.equal(followLayout(queued, [repo(A, true)]), queued);
  assert.deepEqual(Object.keys(followLayout(queued, [repo(B, false)]).remoteFilterPending), []);
  // Once its own reply came, the next layout settles it, whatever it says.
  const taken = tapTaken(queued, list([repo(A, true)]), A, 2);
  assert.deepEqual(Object.keys(followLayout(taken, [repo(A, true)]).remoteFilterPending), []);
});

test('any sessions.changed ends each wait the laptop took, and only those', () => {
  let u = withTap(ui(), A, true, 1, false);
  u = tapTaken(u, list([repo(A, false)]), A, 1);
  u = withTap(u, B, true, 2, false);
  u = withTap(u, 'C', true, 3, true);
  const next = followSessionsChanged(u);
  assert.deepEqual({ ...next.remoteFilterPending }, {
    [B]: { value: true, seq: 2, stage: 'sent' },
    C: { value: true, seq: 3, stage: 'queued' },
  });
  assert.equal(followSessionsChanged(next), next);
});

test('the wait for a taken value ends when its time is up, and only its own tap\'s', () => {
  const sent = withTap(ui(), A, true, 1, false);
  const taken = tapTaken(sent, list([repo(A, false)]), A, 1);
  assert.deepEqual(Object.keys(tapExpired(taken, A, 1).remoteFilterPending), []);
  // A newer tap's wait, one not yet taken, and a repo with no wait stay as they are.
  assert.equal(tapExpired(taken, A, 2), taken);
  assert.equal(tapExpired(sent, A, 1), sent);
  const queued = withTap(ui(), A, true, 1, true);
  assert.equal(tapExpired(queued, A, 1), queued);
  assert.equal(tapExpired(taken, B, 1), taken);
});

test("the wait is twice the daemon's publisher debounce", () => {
  const swift = readFileSync(new URL('../../../../Sources/TBDDaemon/PhoneBridge/App/PhoneAppConstants.swift', import.meta.url), 'utf8');
  const digits = /static let sessionsDebounce: Duration = \.milliseconds\(([\d_]+)\)/.exec(swift)?.[1];
  assert.notEqual(digits, undefined, 'PhoneAppConstants.swift has no sessionsDebounce in milliseconds');
  assert.equal(SESSIONS_DEBOUNCE_MS, Number(digits!.replaceAll('_', '')));
  assert.equal(TAKEN_WAIT_MS, 2 * SESSIONS_DEBOUNCE_MS);
});

test('a new layout reaches the waits, from an event or a snapshot; an event without one does not', () => {
  const base: AppState = initialState();
  const listed: AppState = applySessions(base, list([repo(A, false)]));
  const waiting: AppState = { ...listed, ui: withTap(listed.ui, A, true, 1, false) };

  const noLayout = applyEvent(waiting, { event: 'sessions.changed', seq: 2, data: { rows: [], removedRowIDs: [] } });
  assert.equal(noLayout.ui.remoteFilterPending, waiting.ui.remoteFilterPending);

  const agreeing = applyEvent(waiting, { event: 'sessions.changed', seq: 2, data: { layout: [repo(A, true)], rows: [], removedRowIDs: [] } });
  assert.deepEqual(Object.keys(agreeing.ui.remoteFilterPending), []);

  const snapshot = applySessions(waiting, list([repo(A, true)]));
  assert.deepEqual(Object.keys(snapshot.ui.remoteFilterPending), []);
  const disagreeing = applySessions(waiting, list([repo(A, false)]));
  assert.equal(disagreeing.ui.remoteFilterPending, waiting.ui.remoteFilterPending);
});

test('a sessions.changed without a layout ends a taken wait, and leaves a wait not yet taken', () => {
  const listed: AppState = applySessions(initialState(), list([repo(A, false), repo(B, false)]));
  let u = withTap(listed.ui, A, true, 1, false);
  u = tapTaken(u, listed.sessions, A, 1);
  u = withTap(u, B, true, 2, false);
  const waiting: AppState = { ...listed, ui: u };
  const next = applyEvent(waiting, { event: 'sessions.changed', seq: 2, data: { rows: [], removedRowIDs: [] } });
  assert.deepEqual({ ...next.ui.remoteFilterPending }, { [B]: { value: true, seq: 2, stage: 'sent' } });
  assert.equal(shownFilterOn(next.ui, next.sessions, A), false);
});
