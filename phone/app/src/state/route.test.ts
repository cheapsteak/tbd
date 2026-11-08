// Tests route.ts: finding a session in the list, sending a session route back to the list
// when its session leaves every row, and pending opens that wait for the list to show them.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { PhoneGroupLayout, PhoneRow, PhoneSession, PhoneSessionRef } from '../protocol/types.ts';
import { findSession, resolvePendingOpen, resolveRoute, sameRoute } from './route.ts';
import { applySessionsChanged, applySnapshot } from './sessionsData.ts';
import { SESSIONS_ROUTE } from './store.ts';
import type { Route, SessionsData } from './store.ts';

const CAN = { available: true };

function session(ref: PhoneSessionRef): PhoneSession {
  return {
    ref, agent: ref.kind === 'remote' ? 'remote' : 'claude', tabName: 'claude', status: { chip: 'idle', changedAt: 1 },
    capabilities: { transcript: CAN, send: CAN, answer: CAN, switchProfile: CAN, fork: CAN, model: CAN },
  };
}

function row(id: string, refs: PhoneSessionRef[], name = id): PhoneRow {
  return { id, kind: 'worktree', name, remote: false, statusChangedAt: 1, sessions: refs.map(session) };
}

function list(rows: PhoneRow[], layout: PhoneGroupLayout[] = [{ id: 'repo:R1', kind: 'repo', name: 'acme', rows: rows.map((r) => ({ id: r.id, depth: 0 })) }]): SessionsData {
  return applySnapshot({ stream: 's1', seq: 1, replayed: false, layout, rows, omittedRows: 0, more: false });
}

const R: PhoneSessionRef = { kind: 'local', terminalID: 'T-R' };
const R2: PhoneSessionRef = { kind: 'local', terminalID: 'T-R2' };
const OTHER: PhoneSessionRef = { kind: 'local', terminalID: 'T-other' };
const REMOTE: PhoneSessionRef = { kind: 'remote', provider: 'acme-cloud', sessionID: 'rs-1' };
const WT = '8A1E503C-B1A3-59EE-9AFE-5DE564EE906B';

const without = list([row('W1', [OTHER])]);
const withR = list([row('W1', [OTHER]), row('W2', [R2, R])]);

test('findSession finds the row and the session for a ref', () => {
  const found = findSession(withR, { kind: 'local', terminalID: 'T-R' });
  assert.equal(found?.row.id, 'W2');
  assert.equal(found?.session, withR.rows.W2!.sessions[1]);
  assert.equal(findSession(without, R), null);
});

test('findSession compares every field of a ref', () => {
  const d = list([row('remote:acme-cloud/rs-1', [REMOTE])]);
  assert.equal(findSession(d, { kind: 'remote', provider: 'acme-cloud', sessionID: 'rs-1' })?.row.id, 'remote:acme-cloud/rs-1');
  assert.equal(findSession(d, { kind: 'remote', provider: 'acme-batch', sessionID: 'rs-1' }), null);
  assert.equal(findSession(d, { kind: 'local', terminalID: 'rs-1' }), null);
});

test('a session that leaves every row sends the route back to sessions', () => {
  const route: Route = { screen: 'session', ref: R };
  assert.equal(resolveRoute(route, withR), route);
  const gone = applySessionsChanged(withR, { rows: [row('W2', [R2])], removedRowIDs: [] });
  assert.deepEqual(resolveRoute(route, gone), { screen: 'sessions' });
  const rowGone = applySessionsChanged(withR, { rows: [], removedRowIDs: ['W2'] });
  assert.equal(resolveRoute(route, rowGone), SESSIONS_ROUTE);
});

test('a route that stands is returned as the same object', () => {
  const route: Route = { screen: 'session', ref: R };
  assert.equal(resolveRoute(route, withR), route);
  assert.equal(resolveRoute(SESSIONS_ROUTE, without), SESSIONS_ROUTE);
  // A session that moved to another row still stands.
  const moved = applySessionsChanged(withR, { rows: [row('W1', [OTHER, R]), row('W2', [R2])], removedRowIDs: [] });
  assert.equal(resolveRoute(route, moved), route);
});

test('a layout placement whose row has not arrived is passed over', () => {
  const layout: PhoneGroupLayout[] = [{ id: 'repo:R1', kind: 'repo', name: 'acme', rows: [{ id: 'W1', depth: 0 }, { id: 'W9', depth: 0 }] }];
  const d = list([row('W1', [OTHER])], layout);
  assert.equal(findSession(d, R), null);
  assert.equal(findSession(d, OTHER)?.row.id, 'W1');
  assert.equal(resolveRoute({ screen: 'session', ref: R }, d), SESSIONS_ROUTE);
  assert.equal(resolvePendingOpen({ worktreeID: 'W9', toast: null }, d), null);
});

test('a pending open becomes the route once its session appears', () => {
  assert.equal(resolvePendingOpen({ ref: R }, without), null);
  assert.deepEqual(resolvePendingOpen({ ref: R }, withR), { screen: 'session', ref: R });
});

test('a pending worktree open waits for the row with that ID and opens its first session', () => {
  const p = { worktreeID: WT, toast: 'Created {name}' };
  assert.equal(resolvePendingOpen(p, without), null);
  // The row can arrive before its first session.
  const empty = applySessionsChanged(without, { rows: [row(WT, [])], removedRowIDs: [] });
  assert.equal(resolvePendingOpen(p, empty), null);
  const ready = applySessionsChanged(empty, { rows: [row(WT, [R2, R])], removedRowIDs: [] });
  assert.deepEqual(resolvePendingOpen(p, ready), { screen: 'session', ref: R2 });
  // A session in another row is not the worktree's.
  assert.equal(resolvePendingOpen({ worktreeID: 'W1', toast: null }, list([row('W2', [R])])), null);
});

test('a pending worktree open never reads an inherited member as a row', () => {
  for (const worktreeID of ['constructor', '__proto__', 'toString']) {
    assert.equal(resolvePendingOpen({ worktreeID, toast: null }, withR), null, worktreeID);
  }
});

test('sameRoute compares screens and sessions', () => {
  assert.equal(sameRoute(SESSIONS_ROUTE, { screen: 'sessions' }), true);
  assert.equal(sameRoute({ screen: 'session', ref: R }, { screen: 'session', ref: { kind: 'local', terminalID: 'T-R' } }), true);
  assert.equal(sameRoute({ screen: 'session', ref: R }, { screen: 'session', ref: R2 }), false);
  assert.equal(sameRoute({ screen: 'session', ref: R }, SESSIONS_ROUTE), false);
  assert.equal(sameRoute(SESSIONS_ROUTE, { screen: 'session', ref: R }), false);
});
