// Tests sessionsView.ts: rows and groups sort newest first with ties in layout order, a row
// shows and opens its most urgent session, empty repo groups come last while empty scratch
// and provider groups go, and a placement whose row has not arrived is skipped. Then the
// registry-provider filter: which rows a filtered repo hides and keeps, the selected row's
// exception, and when its header's chip shows, with what count and providers.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { PhoneGroupKind, PhoneGroupLayout, PhoneRow, PhoneSession, PhoneStatusChip } from '../protocol/types.ts';
import { applySessionsChanged, applySnapshot } from './sessionsData.ts';
import { bestSession, CLOUD_PROVIDER, isRegistryRow, repoIDOf, sessionsView } from './sessionsView.ts';
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

// MARK: - The registry-provider filter

const BOX = 'acme-box';

/** A remote session of `provider`, idle, changed at `changedAt`. */
function rs(provider: string, changedAt: number): PhoneSession {
  return {
    ref: { kind: 'remote', provider, sessionID: `S${++terminals}` }, agent: 'remote', tabName: provider,
    status: { chip: 'idle', changedAt },
    capabilities: { transcript: CAN, send: CAN, answer: CAN, switchProfile: CAN, fork: CAN, model: CAN },
  };
}

/** A remote lane's worktree row: a worktree whose sessions are `provider`'s remote sessions. */
function lane(id: string, at: number, provider = BOX): PhoneRow {
  return { id, kind: 'worktree', name: id, remote: true, statusChangedAt: at, sessions: [rs(provider, at)] };
}

/** A loose remote session's row, `remote:<provider>/<sessionID>` as the daemon makes it. */
function loose(provider: string, at: number): PhoneRow {
  const session = rs(provider, at);
  const id = session.ref.kind === 'remote' ? `remote:${provider}/${session.ref.sessionID}` : '';
  return { id, kind: 'remoteSession', name: id, remote: true, statusChangedAt: at, sessions: [session] };
}

/** Repo group `id` with the filter on when `on` is set, as the daemon writes it: `remoteFilterOn` present only when on. */
function repo(id: string, rowIDs: string[], on = false): PhoneGroupLayout {
  const g = group(id, rowIDs);
  return on ? { ...g, remoteFilterOn: true } : g;
}

test('isRegistryRow: every session remote, and none of them the cloud provider', () => {
  assert.equal(CLOUD_PROVIDER, 'claude-cloud');
  assert.equal(isRegistryRow(lane('l1', 1)), true);
  assert.equal(isRegistryRow(loose(BOX, 1)), true);
  assert.equal(isRegistryRow(loose(CLOUD_PROVIDER, 1)), false);
  assert.equal(isRegistryRow(rowAt('local', 1)), false);
  // A row that mixes in a local or a cloud session is not one, nor is a row with no sessions.
  assert.equal(isRegistryRow(row([rs(BOX, 1), s('idle', 2)])), false);
  assert.equal(isRegistryRow(row([rs(BOX, 1), rs(CLOUD_PROVIDER, 2)])), false);
  assert.equal(isRegistryRow({ id: 'bare', kind: 'worktree', name: 'bare', remote: true, statusChangedAt: 1, sessions: [] }), false);
});

test("a filtered repo hides its remote lane and loose registry rows, and keeps its local and cloud rows", () => {
  const boxLane = lane('box-lane', 50);
  const boxLoose = loose(BOX, 40);
  const cloud = loose(CLOUD_PROVIDER, 30);
  const rows = [rowAt('local', 20), boxLane, boxLoose, cloud, row([rs(BOX, 10), s('idle', 10)], 'mixed')];
  const ids = rows.map((r) => r.id);
  const off = sessionsView(list([repo('repo:A', ids)], rows));
  assert.deepEqual(outline(off), [['repo:A', ['box-lane', boxLoose.id, cloud.id, 'local', 'mixed']]]);
  assert.deepEqual(off[0]!.filter, { on: false, count: 2, providers: [BOX] });

  const on = sessionsView(list([repo('repo:A', ids, true)], rows));
  assert.deepEqual(outline(on), [['repo:A', [cloud.id, 'local', 'mixed']]]);
  assert.deepEqual(on[0]!.filter, { on: true, count: 2, providers: [BOX] });
  // The group's time is its newest shown row's.
  assert.equal(on[0]!.newestAt, 30);
});

test('the selected row is kept; the count drops by one and the chip stays', () => {
  const rows = [rowAt('local', 5), lane('l1', 30), lane('l2', 20)];
  const d = list([repo('repo:A', ['local', 'l1', 'l2'], true)], rows);
  const view = sessionsView(d, { lastRowID: 'l2' });
  assert.deepEqual(outline(view), [['repo:A', ['l2', 'local']]]);
  assert.deepEqual(view[0]!.filter, { on: true, count: 1, providers: [BOX] });
  // When the only registry row is the selected one, the chip still shows, with nothing hidden.
  const one = sessionsView(list([repo('repo:A', ['local', 'l1'], true)], rows), { lastRowID: 'l1' });
  assert.deepEqual(outline(one), [['repo:A', ['l1', 'local']]]);
  assert.deepEqual(one[0]!.filter, { on: true, count: 0, providers: [BOX] });
  // Selecting a local row changes nothing.
  assert.deepEqual(sessionsView(d, { lastRowID: 'local' })[0]!.filter, { on: true, count: 2, providers: [BOX] });
});

test('an unfiltered repo, the scratch group and provider groups are unchanged; only repo groups get a chip', () => {
  const rows = [lane('a1', 9), lane('s1', 8), loose(BOX, 7), lane('b1', 6)];
  const p1 = rows[2]!.id;
  const d = list([
    // Even marked on, a scratch or provider group is never filtered.
    { ...group('scratch', ['s1'], 'scratch'), remoteFilterOn: true },
    { ...group(`provider:${BOX}`, [p1], 'provider'), remoteFilterOn: true },
    repo('repo:A', ['a1']),
    repo('repo:B', ['b1'], true),
  ], rows);
  const view = sessionsView(d);
  assert.deepEqual(outline(view), [['repo:A', ['a1']], ['scratch', ['s1']], [`provider:${BOX}`, [p1]], ['repo:B', []]]);
  assert.deepEqual(view.map((g) => g.filter), [
    { on: false, count: 1, providers: [BOX] }, null, null, { on: true, count: 1, providers: [BOX] },
  ]);
});

test('a repo the filter empties keeps its header, among the empty repo groups', () => {
  const rows = [lane('a1', 9), rowAt('b1', 1)];
  const view = sessionsView(list([repo('repo:A', ['a1'], true), repo('repo:B', ['b1']), repo('repo:E', [])], rows));
  assert.deepEqual(outline(view), [['repo:B', ['b1']], ['repo:A', []], ['repo:E', []]]);
  assert.equal(view[1]!.newestAt, 0);
  assert.deepEqual(view[1]!.filter, { on: true, count: 1, providers: [BOX] });
});

test('the chip shows only while the repo has a registry row', () => {
  const chip = (layout: PhoneGroupLayout, rows: PhoneRow[]) => sessionsView(list([layout], rows))[0]!.filter;
  // None with local rows only, or with cloud rows only, on or off.
  assert.equal(chip(repo('repo:A', ['a1']), [rowAt('a1', 1)]), null);
  const cloud = loose(CLOUD_PROVIDER, 1);
  assert.equal(chip(repo('repo:A', [cloud.id]), [cloud]), null);
  assert.equal(chip(repo('repo:A', [cloud.id], true), [cloud]), null);
  // Off, with one registry row.
  assert.deepEqual(chip(repo('repo:A', ['l1']), [lane('l1', 1)]), { on: false, count: 1, providers: [BOX] });
  // On, with nothing left to hide: the chip goes, though the setting stays on.
  assert.equal(chip(repo('repo:A', ['a1'], true), [rowAt('a1', 1)]), null);
  // A registry row whose placement has not arrived counts for nothing yet.
  assert.equal(chip(repo('repo:A', ['a1', 'l1']), [rowAt('a1', 1)]), null);
});

test('the chip lists each registry provider once, sorted', () => {
  const rows = [lane('l1', 4, 'acme-zeta'), lane('l2', 3), loose(BOX, 2), loose(CLOUD_PROVIDER, 1)];
  const view = sessionsView(list([repo('repo:A', rows.map((r) => r.id))], rows));
  assert.deepEqual(view[0]!.filter, { on: false, count: 3, providers: [BOX, 'acme-zeta'] });
});

test("the phone's pending value wins over the layout's, in both directions, for its repo alone", () => {
  const rows = [lane('a1', 4), rowAt('a2', 3), lane('b1', 2), rowAt('b2', 1)];
  const d = list([repo('repo:A', ['a1', 'a2']), repo('repo:B', ['b1', 'b2'], true)], rows);
  const flipped = sessionsView(d, { pending: { A: true, B: false } });
  assert.deepEqual(outline(flipped), [['repo:A', ['a2']], ['repo:B', ['b1', 'b2']]]);
  assert.deepEqual(flipped.map((g) => g.filter?.on), [true, false]);
  // A pending value for another repo changes nothing here.
  const other = sessionsView(d, { pending: { C: true } });
  assert.deepEqual(outline(other), [['repo:A', ['a1', 'a2']], ['repo:B', ['b2']]]);
  // An inherited member is no pending value: the layout's value stands.
  const inherited = sessionsView(list([repo('repo:constructor', ['a1'], true)], rows), { pending: {} });
  assert.deepEqual(outline(inherited), [['repo:constructor', []]]);
  assert.equal(inherited[0]!.filter?.on, true);
});

test('the filter changes only the view: the list keeps every row', () => {
  const rows = [lane('a1', 2), rowAt('a2', 1)];
  const d = list([repo('repo:A', ['a1', 'a2'], true)], rows);
  sessionsView(d);
  assert.deepEqual(Object.keys(d.rows).sort(), ['a1', 'a2']);
  assert.deepEqual(d.layout[0]!.rows.map((r) => r.id), ['a1', 'a2']);
});
