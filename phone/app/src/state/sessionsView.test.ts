// Tests sessionsView.ts: rows and groups sort newest first with ties in layout order, a row
// shows and opens its most urgent session, empty repo groups come last while empty scratch
// and provider groups go, and a placement whose row has not arrived is skipped.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { PhoneGroupKind, PhoneGroupLayout, PhoneRow, PhoneSession, PhoneStatusChip } from '../protocol/types.ts';
import { applySessionsChanged, applySnapshot } from './sessionsData.ts';
import { bestSession, repoIDOf, sessionsView } from './sessionsView.ts';
import type { GroupView } from './sessionsView.ts';
import type { SessionsData } from './store.ts';

const CAN = { available: true };
let terminals = 0;

/** A session with status `chip`, changed at `changedAt`. */
function s(chip: PhoneStatusChip, changedAt: number): PhoneSession {
  return {
    ref: { kind: 'local', terminalID: `T${++terminals}` }, agent: 'claude', tabName: 'Claude', status: { chip, changedAt },
    capabilities: { transcript: CAN, send: CAN, answer: CAN, switchProfile: CAN, fork: CAN, model: CAN },
  };
}

/** A row holding `sessions`, whose `statusChangedAt` is their newest change, as the daemon's is. */
function row(sessions: PhoneSession[], id = `R${++terminals}`): PhoneRow {
  const at = Math.max(0, ...sessions.map((x) => x.status.changedAt));
  return { id, kind: 'worktree', name: id, remote: false, statusChangedAt: at, sessions };
}

/** A row with one idle session, changed at `at`. */
function rowAt(id: string, at: number): PhoneRow {
  return row([s('idle', at)], id);
}

function group(id: string, rowIDs: string[], kind: PhoneGroupKind = 'repo'): PhoneGroupLayout {
  return { id, kind, name: id, rows: rowIDs.map((rowID) => ({ id: rowID, depth: 0 })) };
}

function list(layout: PhoneGroupLayout[], rows: PhoneRow[], more = false): SessionsData {
  return applySnapshot({ stream: 's1', seq: 1, replayed: false, layout, rows, omittedRows: 0, more });
}

/** Each group's ID with its rows' IDs, in order. */
function outline(view: GroupView[]): Array<[string, string[]]> {
  return view.map((g) => [g.group.id, g.rows.map((r) => r.row.id)]);
}

test('rows and groups are newest first; ties keep layout order', () => {
  const d = list(
    [
      group('repo:A', ['a1', 'a2', 'a3', 'a4']),
      group('repo:B', ['b1', 'b2']),
      group('repo:C', ['c1']),
      group('repo:D', ['d1']),
    ],
    [
      rowAt('a1', 10), rowAt('a2', 30), rowAt('a3', 20), rowAt('a4', 30),
      rowAt('b1', 5), rowAt('b2', 40),
      rowAt('c1', 30),
      rowAt('d1', 40),
    ],
  );
  const view = sessionsView(d);
  assert.deepEqual(outline(view), [
    // B and D tie at 40, and C ties A at 30: each pair keeps the layout's order.
    ['repo:B', ['b2', 'b1']],
    ['repo:D', ['d1']],
    ['repo:A', ['a2', 'a4', 'a3', 'a1']],
    ['repo:C', ['c1']],
  ]);
  assert.deepEqual(view.map((g) => g.newestAt), [40, 40, 30, 30]);
});

test('depth is ignored: a child row sorts by its own time, ahead of its parent when newer', () => {
  const layout: PhoneGroupLayout[] = [{
    id: 'repo:A', kind: 'repo', name: 'acme-web',
    rows: [{ id: 'parent', depth: 0 }, { id: 'child', depth: 1 }, { id: 'sibling', depth: 0 }],
  }];
  const view = sessionsView(list(layout, [rowAt('parent', 1), rowAt('child', 3), rowAt('sibling', 2)]));
  assert.deepEqual(outline(view), [['repo:A', ['child', 'sibling', 'parent']]]);
});

test('the most urgent session wins; ties go to the most recent change', () => {
  assert.equal(bestSession(row([s('idle', 9), s('waitingForYou', 1), s('error', 5)])).status.chip, 'waitingForYou');
  assert.equal(bestSession(row([s('working', 3), s('working', 7)])).status.changedAt, 7);
  // Every rank in order, listed from least urgent, each newer than the next.
  const chips: PhoneStatusChip[] = ['unknown', 'exited', 'parked', 'idle', 'working', 'rateLimited', 'error', 'waitingForYou'];
  for (let i = 0; i < chips.length; i++) {
    const sessions = chips.slice(0, i + 1).map((chip, j) => s(chip, 100 - j));
    assert.equal(bestSession(row(sessions)).status.chip, chips[i]);
  }
  // A full tie goes to the first.
  const first = s('idle', 4);
  assert.equal(bestSession(row([first, s('idle', 4)])), first);
});

test('a row shows its most urgent session and how many it has', () => {
  const urgent = s('waitingForYou', 1);
  const r = row([s('working', 9), urgent, s('idle', 5)], 'co');
  const [g] = sessionsView(list([group('repo:A', ['co'])], [r]));
  assert.equal(g!.rows[0]!.best, urgent);
  assert.equal(g!.rows[0]!.count, 3);
  assert.equal(g!.rows[0]!.row, r);
});

test('a row with no sessions is not shown, and throws in bestSession', () => {
  const bare: PhoneRow = { id: 'bare', kind: 'worktree', name: 'shell only', remote: false, statusChangedAt: 50, sessions: [] };
  assert.throws(() => bestSession(bare), RangeError);
  const view = sessionsView(list([group('repo:A', ['bare', 'a1']), group('scratch', ['bare'], 'scratch')], [bare, rowAt('a1', 1)]));
  assert.deepEqual(outline(view), [['repo:A', ['a1']]]);
});

test('empty repo groups come last, and empty provider groups are dropped', () => {
  const d = list(
    [
      group('scratch', [], 'scratch'),
      group('repo:E1', []),
      group('repo:A', ['a1']),
      group('repo:E2', []),
      group('provider:acme-cloud', [], 'provider'),
      group('repo:B', ['b1']),
      group('provider:acme-hosted', ['p1'], 'provider'),
    ],
    [rowAt('a1', 1), rowAt('b1', 2), rowAt('p1', 3)],
  );
  const view = sessionsView(d);
  assert.deepEqual(outline(view), [
    ['provider:acme-hosted', ['p1']],
    ['repo:B', ['b1']],
    ['repo:A', ['a1']],
    // In layout order, after every group that shows rows.
    ['repo:E1', []],
    ['repo:E2', []],
  ]);
  assert.deepEqual(view.map((g) => g.repoID), [null, 'B', 'A', 'E1', 'E2']);
  assert.deepEqual(view.slice(3).map((g) => g.newestAt), [0, 0]);
});

test('repoIDOf', () => {
  assert.equal(repoIDOf({ id: 'repo:ABC', kind: 'repo', name: 'acme-web', rows: [] }), 'ABC');
  assert.equal(repoIDOf({ id: 'provider:acme-cloud', kind: 'provider', name: 'acme-cloud', rows: [] }), null);
  assert.equal(repoIDOf({ id: 'scratch', kind: 'scratch', name: 'Scratch', rows: [] }), null);
  // Both the kind and the prefix must say repo.
  assert.equal(repoIDOf({ id: 'repo:ABC', kind: 'provider', name: 'acme-web', rows: [] }), null);
  assert.equal(repoIDOf({ id: 'ABC', kind: 'repo', name: 'acme-web', rows: [] }), null);
  assert.equal(repoIDOf({ id: 'repo:', kind: 'repo', name: 'acme-web', rows: [] }), null);
});

test('a placement whose row has not arrived is skipped', () => {
  const layout = [group('repo:A', ['a1', 'a2']), group('repo:B', ['b1']), group('provider:acme-cloud', ['p1'], 'provider')];
  const partial = list(layout, [rowAt('a2', 5)], true);
  // B waits as an empty repo; the provider group shows nothing yet, so it is dropped.
  assert.deepEqual(outline(sessionsView(partial)), [['repo:A', ['a2']], ['repo:B', []]]);

  const whole = applySessionsChanged(partial, { rows: [rowAt('a1', 9), rowAt('b1', 1), rowAt('p1', 3)], removedRowIDs: [] });
  assert.deepEqual(outline(sessionsView(whole)), [['repo:A', ['a1', 'a2']], ['provider:acme-cloud', ['p1']], ['repo:B', ['b1']]]);
});

test('a row the layout does not place is not shown', () => {
  assert.deepEqual(outline(sessionsView(list([group('repo:A', ['a1'])], [rowAt('a1', 1), rowAt('stray', 9)]))), [['repo:A', ['a1']]]);
});

test('an empty list shows nothing', () => {
  assert.deepEqual(sessionsView(list([], [])), []);
});
