// Tests sessionsData.ts: a subscribe snapshot replaces the list, each sessions.changed
// upserts rows, removes rows and replaces the layout only when it carries one, and a list is
// complete once every row its layout places has arrived.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { decodeEventData, decodeResult } from '../protocol/wire.ts';
import type { PhoneGroupLayout, PhoneRow, PhoneSession, PhoneSessionRef, SessionsSubscribeResult } from '../protocol/types.ts';
import { applySessionsChanged, applySnapshot, isComplete, rowByID } from './sessionsData.ts';

const PROTOCOL_DIR = new URL('../../../protocol/', import.meta.url);

function fixture(name: string): Record<string, any> {
  return JSON.parse(readFileSync(new URL(name, PROTOCOL_DIR), 'utf8'));
}

const CAN = { available: true };

function session(terminalID: string): PhoneSession {
  const ref: PhoneSessionRef = { kind: 'local', terminalID };
  return {
    ref, agent: 'claude', tabName: 'claude', status: { chip: 'idle', changedAt: 1 },
    capabilities: { transcript: CAN, send: CAN, answer: CAN, switchProfile: CAN, fork: CAN, model: CAN },
  };
}

function row(id: string, name = id, sessions: PhoneSession[] = [session(`T-${id}`)]): PhoneRow {
  return { id, kind: 'worktree', name, remote: false, statusChangedAt: 1, sessions };
}

function group(id: string, rowIDs: string[]): PhoneGroupLayout {
  return { id, kind: 'repo', name: id, rows: rowIDs.map((rowID) => ({ id: rowID, depth: 0 })) };
}

function snapshot(layout: PhoneGroupLayout[], rows: PhoneRow[], more = false): SessionsSubscribeResult {
  return { stream: 's1', seq: 1, replayed: false, layout, rows, omittedRows: 0, more };
}

const rowA = row('A');
const rowB = row('B');
const rowB2 = row('B', 'B renamed');
const layout0 = [group('repo:R1', ['A', 'B'])];
const d0 = applySnapshot(snapshot(layout0, [rowA, rowB]));

test('a snapshot replaces the layout and rows', () => {
  const layout1 = [group('repo:R2', ['C'])];
  const rowC = row('C');
  const d1 = applySnapshot(snapshot(layout1, [rowC]));
  assert.equal(d1.layout, layout1);
  assert.deepEqual(Object.keys(d1.rows), ['C']);
  assert.equal(d1.rows.C, rowC);
  // The old list is not consulted: nothing of d0 reaches d1.
  assert.equal(rowByID(d1, 'A'), null);
  assert.deepEqual(Object.keys(d0.rows), ['A', 'B']);
});

test('a snapshot with no layout or rows gives an empty list', () => {
  const d = applySnapshot({ stream: 's1', seq: 1, replayed: false, omittedRows: 0, more: false });
  assert.deepEqual(d.layout, []);
  assert.deepEqual(Object.keys(d.rows), []);
});

test('a snapshot with more keeps a layout that names rows still to come', () => {
  const d = applySnapshot(snapshot([group('repo:R1', ['A', 'B', 'C'])], [rowA], true));
  assert.deepEqual(d.layout[0]!.rows.map((p) => p.id), ['A', 'B', 'C']);
  assert.deepEqual(Object.keys(d.rows), ['A']);
  assert.equal(rowByID(d, 'B'), null);
  // The rows still to come arrive as sessions.changed with no layout.
  const d1 = applySessionsChanged(d, { rows: [rowB, row('C')], removedRowIDs: [] });
  assert.deepEqual(Object.keys(d1.rows).sort(), ['A', 'B', 'C']);
  assert.equal(d1.layout, d.layout);
});

test('a list is complete once every row its layout places has arrived', () => {
  assert.equal(isComplete(d0), true);
  assert.equal(isComplete(applySnapshot({ stream: 's1', seq: 1, replayed: false, omittedRows: 0, more: false })), true);
  // An empty group, and a row no group places, leave it complete.
  assert.equal(isComplete(applySnapshot(snapshot([group('repo:R1', ['A']), group('repo:R2', [])], [rowA, rowB]))), true);
  const partial = applySnapshot(snapshot([group('repo:R1', ['A']), group('repo:R2', ['B', 'C'])], [rowA], true));
  assert.equal(isComplete(partial), false);
  const half = applySessionsChanged(partial, { rows: [rowB], removedRowIDs: [] });
  assert.equal(isComplete(half), false);
  assert.equal(isComplete(applySessionsChanged(half, { rows: [row('C')], removedRowIDs: [] })), true);
  // A placement never reads an inherited member as a row.
  assert.equal(isComplete(applySnapshot(snapshot([group('repo:R1', ['constructor'])], []))), false);
});

test('sessions.changed upserts rows, removes removedRowIDs, and keeps the layout when it has none', () => {
  const d1 = applySessionsChanged(d0, { rows: [rowB2], removedRowIDs: ['A'] });
  assert.deepEqual(Object.keys(d1.rows).sort(), ['B']);
  assert.equal(d1.rows.B, rowB2);
  assert.equal(d1.layout, d0.layout);
  // d0 is left as it was.
  assert.deepEqual(Object.keys(d0.rows), ['A', 'B']);
  assert.equal(d0.rows.B, rowB);
});

test('sessions.changed adds a new row and keeps the rows it does not name', () => {
  const rowC = row('C');
  const d1 = applySessionsChanged(d0, { rows: [rowC], removedRowIDs: [] });
  assert.deepEqual(Object.keys(d1.rows).sort(), ['A', 'B', 'C']);
  assert.equal(d1.rows.A, rowA);
  assert.equal(d1.rows.C, rowC);
});

test('sessions.changed with a layout replaces it', () => {
  const layout1 = [group('repo:R1', ['B']), group('repo:R2', [])];
  const d1 = applySessionsChanged(d0, { layout: layout1, rows: [], removedRowIDs: ['A'] });
  assert.equal(d1.layout, layout1);
  // An empty repo group stays, as the laptop keeps it.
  assert.deepEqual(d1.layout.map((g) => g.id), ['repo:R1', 'repo:R2']);
});

test('removing a row the list does not hold changes nothing else', () => {
  const d1 = applySessionsChanged(d0, { rows: [], removedRowIDs: ['Z'] });
  assert.deepEqual(Object.keys(d1.rows), ['A', 'B']);
});

test('row IDs are looked up as own keys only', () => {
  for (const id of ['constructor', 'toString', '__proto__', 'hasOwnProperty']) {
    assert.equal(rowByID(d0, id), null, id);
    assert.equal((d0.rows as Record<string, unknown>)[id], undefined, id);
  }
  const odd = row('constructor');
  const d1 = applySessionsChanged(d0, { rows: [odd, row('__proto__')], removedRowIDs: [] });
  assert.equal(rowByID(d1, 'constructor'), odd);
  assert.equal(rowByID(d1, '__proto__')?.id, '__proto__');
  assert.equal(Object.getPrototypeOf(d1.rows), null);
  const d2 = applySessionsChanged(d1, { rows: [], removedRowIDs: ['__proto__'] });
  assert.equal(rowByID(d2, '__proto__'), null);
});

test('the fixtures merge: a snapshot, then a sessions.changed', () => {
  const d = applySnapshot(decodeResult('sessions.subscribe', fixture('sessions.subscribe.reply.json').result));
  const changed = decodeEventData('sessions.changed', fixture('sessions.changed.event.json').data);
  const d1 = applySessionsChanged(d, changed);
  for (const r of changed.rows) assert.equal(d1.rows[r.id], r);
  for (const id of changed.removedRowIDs) assert.equal(rowByID(d1, id), null);
  assert.equal(d1.layout, changed.layout ?? d.layout);
  // Every repo group in the fixture is named the daemon's way.
  for (const g of d1.layout) {
    if (g.kind === 'repo') assert.match(g.id, /^repo:[0-9A-F-]{36}$/);
    if (g.kind === 'provider') assert.match(g.id, /^provider:/);
    if (g.kind === 'scratch') assert.equal(g.id, 'scratch');
  }
});
