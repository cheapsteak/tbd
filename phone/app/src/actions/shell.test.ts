// Tests shell.ts and createActions: subscribing on channel up, a refused subscribe and "Try
// again", events that move the route opening or closing the transcript, navigation, sheets,
// menus, toasts and links. A fake client records each request and hands back a promise the
// test settles; the transcript actions are replaced on the actions object, which `self()`
// returns, so the test sees each call.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AppError, SUPERSEDED_TEXT } from '../client/client.ts';
import type {
  AppEvent, Method, ParamsOf, PhoneRow, PhoneSession, PhoneSessionRef, ResultOf, SessionsChangedData, SessionsSubscribeResult,
} from '../protocol/types.ts';
import { refKey } from '../protocol/wire.ts';
import { applySnapshot } from '../state/sessionsData.ts';
import { createStore, emptyRecord, initialState, SESSIONS_ROUTE } from '../state/store.ts';
import type { AppState } from '../state/store.ts';
import { createActions } from './index.ts';
import type { ActionContext, Actions } from './index.ts';
import { promptActions } from './prompts.ts';
import { sheetActions } from './sheets.ts';
import { shellActions } from './shell.ts';
import { transcriptActions } from './transcript.ts';

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

function snapshot(rows: PhoneRow[], stream = 's1', seq = 10): SessionsSubscribeResult {
  return {
    stream, seq, replayed: false, omittedRows: 0, more: false, rows,
    layout: [{ id: 'repo:R1', kind: 'repo', name: 'acme', rows: rows.map((r) => ({ id: r.id, depth: 0 })) }],
  };
}

const R: PhoneSessionRef = { kind: 'local', terminalID: 'T-R' };
const R2: PhoneSessionRef = { kind: 'local', terminalID: 'T-R2' };
const OTHER: PhoneSessionRef = { kind: 'local', terminalID: 'T-other' };
const WT = '8A1E503C-B1A3-59EE-9AFE-5DE564EE906B';

interface Sent {
  method: Method;
  params: unknown;
  resolve(result: unknown): void;
  reject(error: unknown): void;
}

function harness() {
  const sent: Sent[] = [];
  const client = {
    stream: null as string | null,
    lastSeq: null as number | null,
    request<M extends Method>(method: M, params: ParamsOf<M>): Promise<ResultOf<M>> {
      return new Promise<ResultOf<M>>((resolve, reject) => {
        sent.push({ method, params, resolve: resolve as (result: unknown) => void, reject });
      });
    },
  };
  const links: string[] = [];
  const store = createStore();
  const ctx: ActionContext = { store, client, link: { openLink: (url) => { links.push(url); } }, now: () => 0 };
  const actions = createActions(ctx);
  const calls: unknown[][] = [];
  actions.openTranscript = (ref) => { calls.push(['openTranscript', ref]); };
  actions.closeTranscript = () => { calls.push(['closeTranscript']); };
  actions.resumeTranscriptOnUp = () => { calls.push(['resumeTranscriptOnUp', sent.length]); };
  actions.onShowDetailsChanged = () => { calls.push(['onShowDetailsChanged', store.get().ui.showDetails]); };
  const requests = () => sent.map((s): [Method, unknown] => [s.method, s.params]);
  return { sent, requests, client, store, actions, calls, links, state: (): AppState => store.get() };
}

/** Lets the promise handlers run. */
function flush(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

/** A harness whose channel came up and whose subscribe got `result`. */
async function subscribed(rows: PhoneRow[]) {
  const h = harness();
  h.actions.onChannelUp();
  h.sent[0]!.resolve(snapshot(rows));
  await flush();
  h.calls.length = 0;
  return h;
}

// MARK: - The channel and the subscription

test('channel up subscribes with the stream and the last seq it saw', () => {
  const { client, actions, requests } = harness();
  client.stream = 's1';
  client.lastSeq = 41;
  actions.onChannelUp();
  assert.deepEqual(requests()[0], ['sessions.subscribe', { stream: 's1', sinceSeq: 41 }]);
});

test('the first channel up subscribes with {}', () => {
  const { actions, requests } = harness();
  actions.onChannelUp();
  assert.deepEqual(requests(), [['sessions.subscribe', {}]]);
});

test('a client with a stream but no seq, or a seq but no stream, subscribes with {}', () => {
  for (const [stream, lastSeq] of [['s1', null], [null, 3]] as const) {
    const h = harness();
    h.client.stream = stream;
    h.client.lastSeq = lastSeq;
    h.actions.onChannelUp();
    assert.deepEqual(h.requests(), [['sessions.subscribe', {}]]);
  }
});

test('channel up marks the channel up and resumes the transcript after the subscribe, without waiting', () => {
  const { actions, calls, state } = harness();
  actions.onChannelUp();
  assert.equal(state().conn.up, true);
  // resumeTranscriptOnUp ran with one request sent: the subscribe, still unanswered.
  assert.deepEqual(calls, [['resumeTranscriptOnUp', 1]]);
  actions.onChannelDown();
  assert.equal(state().conn.up, false);
});

test('a snapshot reply marks the app subscribed and replaces the list', async () => {
  const { actions, sent, state } = harness();
  actions.onChannelUp();
  assert.equal(state().conn.subscribed, false);
  sent[0]!.resolve(snapshot([row('W1', [R])]));
  await flush();
  assert.equal(state().conn.subscribed, true);
  assert.equal(state().conn.error, null);
  assert.deepEqual(Object.keys(state().sessions.rows), ['W1']);
  assert.deepEqual(state().sessions.layout.map((g) => g.id), ['repo:R1']);
});

test('a replayed reply leaves the list to the events it replays', async () => {
  const h = await subscribed([row('W1', [R])]);
  const before = h.state().sessions;
  h.actions.onChannelDown();
  h.actions.onChannelUp();
  h.sent[1]!.resolve({ stream: 's1', seq: 12, replayed: true, omittedRows: 0, more: false });
  await flush();
  assert.equal(h.state().sessions, before);
  assert.equal(h.state().conn.subscribed, true);
});

test('a snapshot after a reconnect resolves the route and closes a transcript whose session is gone', async () => {
  const h = await subscribed([row('W1', [R]), row('W2', [OTHER])]);
  h.actions.openSession(R);
  h.calls.length = 0;
  h.actions.onChannelDown();
  h.actions.onChannelUp();
  h.sent[1]!.resolve(snapshot([row('W2', [OTHER])], 's2', 1));
  await flush();
  assert.equal(h.state().ui.route, SESSIONS_ROUTE);
  assert.deepEqual(h.calls, [['resumeTranscriptOnUp', 2], ['closeTranscript']]);
});

test('a partial snapshot after a reconnect keeps the open session until its row arrives', async () => {
  const h = await subscribed([row('W1', [R]), row('W2', [OTHER])]);
  h.actions.openSession(R);
  h.calls.length = 0;
  h.actions.onChannelDown();
  h.actions.onChannelUp();
  // A new stream's snapshot that holds only W2; W1 and W3 follow as sessions.changed.
  h.sent[1]!.resolve({
    stream: 's2', seq: 1, replayed: false, omittedRows: 0, more: true, rows: [row('W2', [OTHER])],
    layout: [{ id: 'repo:R1', kind: 'repo', name: 'acme', rows: [{ id: 'W1', depth: 0 }, { id: 'W2', depth: 0 }, { id: 'W3', depth: 0 }] }],
  });
  await flush();
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: R });
  h.actions.onEvent(changed([row('W1', [R])]));
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: R });
  assert.deepEqual(h.calls, [['resumeTranscriptOnUp', 2]]);
  // The list completes, with the session gone from its row: back to the list.
  h.actions.onEvent(changed([row('W3', []), row('W1', [R2])]));
  assert.equal(h.state().ui.route, SESSIONS_ROUTE);
  assert.deepEqual(h.calls, [['resumeTranscriptOnUp', 2], ['closeTranscript']]);
});

test("a refused subscribe shows the daemon's message", async () => {
  const { actions, sent, state } = harness();
  actions.onChannelUp();
  sent[0]!.reject(new AppError('refused', 'Too many requests are in progress. Try again in a moment.'));
  await flush();
  assert.equal(state().conn.error, 'Too many requests are in progress. Try again in a moment.');
  assert.equal(state().conn.subscribed, false);
});

test('a refused subscribe after a reconnect shows again with Try again', async () => {
  const h = await subscribed([row('W1', [R])]);
  h.actions.onChannelDown();
  h.actions.onChannelUp();
  h.sent[1]!.reject(new AppError('phone_control_off', 'Phone control is off on this laptop.'));
  await flush();
  assert.equal(h.state().conn.subscribed, false);
  assert.equal(h.state().conn.error, 'Phone control is off on this laptop.');
});

test('a superseded subscribe is silent', async () => {
  const h = await subscribed([row('W1', [R])]);
  h.actions.onChannelDown();
  h.actions.onChannelUp();
  h.sent[1]!.reject(new AppError('superseded', SUPERSEDED_TEXT));
  await flush();
  assert.equal(h.state().conn.error, null);
  assert.equal(h.state().conn.subscribed, true);
  // And before the first reply, too: the replacing subscribe is on its way.
  const fresh = harness();
  fresh.actions.onChannelUp();
  fresh.sent[0]!.reject(new AppError('superseded', SUPERSEDED_TEXT));
  await flush();
  assert.equal(fresh.state().conn.error, null);
  assert.equal(fresh.state().conn.subscribed, false);
});

test('Try again clears the error and subscribes the same way, and its reply clears the error', async () => {
  const h = harness();
  h.client.stream = 's1';
  h.client.lastSeq = 7;
  h.actions.onChannelUp();
  h.sent[0]!.reject(new AppError('refused', 'Too many requests are in progress.'));
  await flush();
  h.actions.retrySubscribe();
  assert.equal(h.state().conn.error, null);
  assert.deepEqual(h.requests()[1], ['sessions.subscribe', { stream: 's1', sinceSeq: 7 }]);
  // A second tap while it runs sends nothing more.
  h.actions.retrySubscribe();
  assert.equal(h.sent.length, 2);
  h.sent[1]!.resolve(snapshot([row('W1', [R])]));
  await flush();
  assert.equal(h.state().conn.subscribed, true);
  assert.equal(h.state().conn.error, null);
});

test('a channel up after a refused subscribe clears the error while its subscribe is in flight', async () => {
  const h = harness();
  h.actions.onChannelUp();
  h.sent[0]!.reject(new AppError('phone_control_off', 'Phone control is off on this laptop.'));
  await flush();
  h.actions.onChannelDown();
  assert.equal(h.state().conn.error, 'Phone control is off on this laptop.');
  h.actions.onChannelUp();
  assert.equal(h.state().conn.error, null);
  assert.equal(h.state().conn.subscribed, false);
  // So no "Try again" shows, and a tap on the one that showed sends no second subscribe.
  h.actions.retrySubscribe();
  assert.deepEqual(h.requests(), [['sessions.subscribe', {}], ['sessions.subscribe', {}]]);
  h.sent[1]!.resolve(snapshot([row('W1', [R])]));
  await flush();
  assert.equal(h.state().conn.subscribed, true);
});

test('Try again sends nothing while a subscribe is in flight, even with an error showing', async () => {
  const h = harness();
  h.actions.onChannelUp();
  h.actions.onChannelDown();
  h.actions.onChannelUp();
  // The first subscribe's refusal comes while the second is still in flight.
  h.sent[0]!.reject(new AppError('refused', 'Too many requests are in progress.'));
  await flush();
  assert.equal(h.state().conn.error, 'Too many requests are in progress.');
  h.actions.retrySubscribe();
  assert.equal(h.sent.length, 2);
  // Once the second is refused too, nothing is in flight, and Try again subscribes.
  h.sent[1]!.reject(new AppError('refused', 'Too many requests are in progress.'));
  await flush();
  h.actions.retrySubscribe();
  assert.equal(h.sent.length, 3);
  // A reconnect supersedes that one and sends its own; once both settle, Try again works again.
  h.actions.onChannelDown();
  h.actions.onChannelUp();
  h.sent[2]!.reject(new AppError('superseded', SUPERSEDED_TEXT));
  h.sent[3]!.reject(new AppError('refused', 'Too many requests are in progress.'));
  await flush();
  h.actions.retrySubscribe();
  assert.equal(h.sent.length, 5);
});

test('Try again with no error showing sends nothing', () => {
  const h = harness();
  h.actions.retrySubscribe();
  assert.equal(h.sent.length, 0);
});

test('Try again with a first-time client subscribes with {}', async () => {
  const h = harness();
  h.actions.onChannelUp();
  h.sent[0]!.reject(new AppError('internal', 'Something went wrong on the laptop.'));
  await flush();
  h.actions.retrySubscribe();
  assert.deepEqual(h.requests()[1], ['sessions.subscribe', {}]);
});

// MARK: - Events

/**
 * A `sessions.changed`. With `placed`, it carries a layout whose one group places those rows,
 * as the daemon's does whenever it removes a row.
 */
function changed(rows: PhoneRow[], removedRowIDs: string[] = [], placed?: string[]): AppEvent {
  const data: SessionsChangedData = { rows, removedRowIDs };
  if (placed !== undefined) data.layout = [{ id: 'repo:R1', kind: 'repo', name: 'acme', rows: placed.map((id) => ({ id, depth: 0 })) }];
  return { event: 'sessions.changed', seq: 11, data };
}

test('an event that sends the open session away closes its transcript', async () => {
  const h = await subscribed([row('W1', [R]), row('W2', [OTHER])]);
  h.actions.openSession(R);
  h.calls.length = 0;
  h.actions.onEvent(changed([], ['W1'], ['W2']));
  assert.equal(h.state().ui.route, SESSIONS_ROUTE);
  assert.deepEqual(h.calls, [['closeTranscript']]);
});

test('a pending open that an event resolves opens its transcript and marks its row', async () => {
  const h = await subscribed([row('W2', [OTHER])]);
  h.actions.openPending({ ref: R });
  assert.deepEqual(h.calls, []);
  h.actions.onEvent(changed([row('W3', [R])]));
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: R });
  assert.equal(h.state().ui.lastRowID, 'W3');
  assert.equal(h.state().ui.pendingOpen, null);
  assert.deepEqual(h.calls, [['openTranscript', R]]);
});

test('a pending worktree open toasts once its row lists a session', async () => {
  const h = await subscribed([row('W2', [OTHER])]);
  h.actions.openPending({ worktreeID: WT, toast: 'Created {name}' });
  h.actions.onEvent(changed([row(WT, [R], 'fix-login')]));
  assert.deepEqual(h.state().ui.toast, { id: 1, text: 'Created fix-login' });
  assert.deepEqual(h.calls, [['openTranscript', R]]);
});

test('a pending open from another session switches the transcript to the new one', async () => {
  const h = await subscribed([row('W1', [R])]);
  h.actions.openSession(R);
  h.actions.openPending({ ref: R2 });
  h.calls.length = 0;
  h.actions.onEvent(changed([row('W1', [R, R2])]));
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: R2 });
  assert.deepEqual(h.calls, [['openTranscript', R2]]);
});

test('a pending open the list already shows opens at once', async () => {
  const h = await subscribed([row('W2', [R])]);
  h.actions.openPending({ ref: R });
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: R });
  assert.equal(h.state().ui.pendingOpen, null);
  assert.deepEqual(h.calls, [['openTranscript', R]]);
});

test('openSession clears a pending open, so a fork the user moved away from never takes them to it', async () => {
  const h = await subscribed([row('W1', [R]), row('W2', [OTHER])]);
  h.actions.openSession(R);
  h.actions.openPending({ ref: R2 });   // a fork of R that the list does not show yet
  h.actions.openSession(OTHER);
  assert.equal(h.state().ui.pendingOpen, null);
  h.calls.length = 0;
  h.actions.onEvent(changed([row('W1', [R, R2])]));
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: OTHER });
  assert.deepEqual(h.calls, []);
});

test('back clears a pending open, so a worktree the user moved away from never opens or toasts', async () => {
  const h = await subscribed([row('W1', [R])]);
  h.actions.openSession(R);
  h.actions.openPending({ worktreeID: WT, toast: 'Created {name}' });
  h.actions.back();
  assert.equal(h.state().ui.pendingOpen, null);
  h.calls.length = 0;
  h.actions.onEvent(changed([row(WT, [R2], 'fix-login')]));
  assert.equal(h.state().ui.route, SESSIONS_ROUTE);
  assert.equal(h.state().ui.toast, null);
  assert.deepEqual(h.calls, []);
});

test('a navigation between the mark and the reply drops the open', async () => {
  // openSession while a fork of R is in flight, then back while a create is.
  const h = await subscribed([row('W1', [R]), row('W2', [OTHER])]);
  h.actions.openSession(R);
  const forkMark = h.actions.navMark();
  h.actions.openSession(OTHER);
  h.actions.openPending({ ref: R2 }, forkMark);
  assert.equal(h.state().ui.pendingOpen, null);
  const createMark = h.actions.navMark();
  h.actions.back();
  h.actions.openPending({ worktreeID: WT, toast: 'Created {name}' }, createMark);
  assert.equal(h.state().ui.pendingOpen, null);
  h.calls.length = 0;
  h.actions.onEvent(changed([row('W1', [R, R2]), row(WT, [R2], 'fix-login')]));
  assert.equal(h.state().ui.route, SESSIONS_ROUTE);
  assert.equal(h.state().ui.toast, null);
  assert.deepEqual(h.calls, []);
});

test('a reply whose user stayed put opens at its mark', async () => {
  const h = await subscribed([row('W1', [R])]);
  h.actions.openSession(R);
  const mark = h.actions.navMark();
  // The same session again, a menu and a sheet are none of them a navigation.
  h.actions.openSession(R);
  h.actions.openMenu({ name: 'model' });
  h.actions.openSheet({ name: 'fork' });
  h.actions.openPending({ ref: R2 }, mark);
  assert.deepEqual(h.state().ui.pendingOpen, { ref: R2 });
  h.calls.length = 0;
  h.actions.onEvent(changed([row('W1', [R, R2])]));
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: R2 });
  assert.deepEqual(h.calls, [['openTranscript', R2]]);
  // One the list shows already opens at once.
  const h2 = await subscribed([row('W1', [R]), row('W2', [R2])]);
  h2.actions.openSession(R);
  h2.actions.openPending({ ref: R2 }, h2.actions.navMark());
  assert.deepEqual(h2.state().ui.route, { screen: 'session', ref: R2 });
});

test('openPending with no mark waits whatever the user did before', async () => {
  const h = await subscribed([row('W1', [R]), row('W2', [OTHER])]);
  h.actions.openSession(R);
  h.actions.openSession(OTHER);
  h.actions.back();
  h.actions.openPending({ ref: R2 });
  assert.deepEqual(h.state().ui.pendingOpen, { ref: R2 });
  h.actions.onEvent(changed([row('W1', [R, R2])]));
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: R2 });
});

test("only the user's navigations move the mark", async () => {
  const h = await subscribed([row('W1', [R]), row('W2', [OTHER])]);
  assert.equal(h.actions.navMark(), 0);
  h.actions.back();                     // on the list already
  h.actions.openSession(R2);            // no row lists it
  assert.equal(h.actions.navMark(), 0);
  h.actions.openSession(R);
  h.actions.openSession(R);             // shown already
  assert.equal(h.actions.navMark(), 1);
  h.actions.openSession(OTHER);
  h.actions.back();
  assert.equal(h.actions.navMark(), 3);
  // A pending open that opens, and an event that sends the route back, are not the user's.
  h.actions.openPending({ ref: R });
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: R });
  h.actions.onEvent(changed([], ['W1'], ['W2']));
  assert.equal(h.state().ui.route, SESSIONS_ROUTE);
  assert.equal(h.actions.navMark(), 3);
});

test("a pending open that opens is not the user's navigation: the user's own state stays", async () => {
  const h = await subscribed([row('W1', [R])]);
  h.actions.openSession(R);
  h.actions.setShowDetails(true);
  h.actions.toggleRepo('repo:R1');
  h.actions.openSheet({ name: 'new', repoID: 'R1', repoName: 'acme' });
  h.actions.openPending({ worktreeID: WT, toast: null });
  const before = h.state().ui;
  h.actions.onEvent(changed([row(WT, [R2])]));
  const ui = h.state().ui;
  assert.deepEqual(ui.route, { screen: 'session', ref: R2 });
  assert.equal(ui.pendingOpen, null);
  for (const key of ['sheet', 'showDetails', 'collapsed', 'toast', 'nav', 'refusal', 'drafts'] as const) {
    assert.equal(ui[key], before[key], key);
  }
});

test('an event that leaves the route as it was opens and closes nothing', async () => {
  const h = await subscribed([row('W1', [R])]);
  h.actions.openSession(R);
  h.calls.length = 0;
  h.actions.onEvent(changed([row('W1', [R], 'renamed')]));
  h.actions.onEvent({ event: 'transcript.append', seq: 12, data: { session: R, items: [] } });
  assert.deepEqual(h.calls, []);
  assert.equal(h.state().sessions.rows.W1!.name, 'renamed');
});

// MARK: - Navigation, sheets, menus, toasts and links

test('openSession shows the session, marks its row, clears the menu and the sheet, and opens its transcript', async () => {
  const h = await subscribed([row('W1', [OTHER]), row('W2', [R2, R])]);
  h.actions.openMenu({ name: 'model' });
  h.actions.openSession(R);
  const ui = h.state().ui;
  assert.deepEqual(ui.route, { screen: 'session', ref: R });
  assert.equal(ui.lastRowID, 'W2');
  assert.equal(ui.menu, null);
  assert.equal(ui.sheet, null);
  assert.deepEqual(h.calls, [['openTranscript', R]]);
});

test('openSession for a session no row lists does nothing', async () => {
  const h = await subscribed([row('W1', [OTHER])]);
  const before = h.state();
  h.actions.openSession(R);
  assert.equal(h.state(), before);
  assert.deepEqual(h.calls, []);
});

test('openSession on the session already shown changes nothing and keeps its transcript', async () => {
  const h = await subscribed([row('W1', [R])]);
  h.actions.openSession(R);
  h.actions.openMenu({ name: 'model' });
  h.actions.openPending({ ref: R2 });   // a fork of R that the list does not show yet
  h.calls.length = 0;
  const before = h.state();
  h.actions.openSession({ kind: 'local', terminalID: 'T-R' });
  assert.equal(h.state(), before);
  assert.deepEqual(h.calls, []);
  // The tap went nowhere, so the fork still opens once the list shows it.
  h.actions.onEvent(changed([row('W1', [R, R2])]));
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: R2 });
  assert.deepEqual(h.calls, [['openTranscript', R2]]);
});

test('back on the sessions list changes nothing and closes no transcript', async () => {
  const h = await subscribed([row('W1', [R])]);
  h.actions.openPending({ worktreeID: WT, toast: 'Created {name}' });
  const before = h.state();
  h.actions.back();
  assert.equal(h.state(), before);
  assert.deepEqual(h.calls, []);
  // The user stayed put, so the worktree still opens and toasts.
  h.actions.onEvent(changed([row(WT, [R2], 'fix-login')]));
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: R2 });
  assert.deepEqual(h.state().ui.toast, { id: 1, text: 'Created fix-login' });
});

test('back shows the sessions list and closes the transcript', async () => {
  const h = await subscribed([row('W1', [R])]);
  h.actions.openSession(R);
  h.actions.openSheet({ name: 'menu' });
  h.calls.length = 0;
  h.actions.back();
  assert.equal(h.state().ui.route, SESSIONS_ROUTE);
  assert.equal(h.state().ui.sheet, null);
  assert.equal(h.state().ui.lastRowID, 'W1');
  assert.deepEqual(h.calls, [['closeTranscript']]);
});

test('setLastRow marks a row, and null marks none', () => {
  const h = harness();
  h.actions.setLastRow('W1');
  assert.equal(h.state().ui.lastRowID, 'W1');
  const before = h.state();
  h.actions.setLastRow('W1');
  assert.equal(h.state(), before);
  h.actions.setLastRow(null);
  assert.equal(h.state().ui.lastRowID, null);
});

test('a sheet and a menu never show together', () => {
  const h = harness();
  h.actions.openMenu({ name: 'account', askProfileID: null });
  h.actions.openSheet({ name: 'new', repoID: 'R1', repoName: 'acme' });
  assert.equal(h.state().ui.menu, null);
  assert.deepEqual(h.state().ui.sheet, { name: 'new', repoID: 'R1', repoName: 'acme' });
  h.actions.openMenu({ name: 'account', askProfileID: 'P2' });
  assert.equal(h.state().ui.sheet, null);
  assert.deepEqual(h.state().ui.menu, { name: 'account', askProfileID: 'P2' });
  h.actions.closeMenu();
  assert.equal(h.state().ui.menu, null);
  h.actions.openSheet({ name: 'fork' });
  h.actions.closeSheet();
  assert.equal(h.state().ui.sheet, null);
});

test('closing what is closed changes nothing', () => {
  const h = harness();
  const before = h.state();
  h.actions.closeSheet();
  h.actions.closeMenu();
  assert.equal(h.state(), before);
});

test('each toast has a new ID, and clearToast takes down only its own', () => {
  const h = harness();
  h.actions.toast('Copied');
  assert.deepEqual(h.state().ui.toast, { id: 1, text: 'Copied' });
  h.actions.toast('Copied');
  assert.deepEqual(h.state().ui.toast, { id: 2, text: 'Copied' });
  h.actions.clearToast(1);
  assert.deepEqual(h.state().ui.toast, { id: 2, text: 'Copied' });
  h.actions.clearToast(2);
  assert.equal(h.state().ui.toast, null);
});

test('setShowDetails sets the switch and tells the transcript, only when it changes', () => {
  const h = harness();
  h.actions.setShowDetails(true);
  assert.equal(h.state().ui.showDetails, true);
  assert.deepEqual(h.calls, [['onShowDetailsChanged', true]]);
  h.actions.setShowDetails(true);
  assert.equal(h.calls.length, 1);
  h.actions.setShowDetails(false);
  assert.deepEqual(h.calls[1], ['onShowDetailsChanged', false]);
});

test('toggleRepo collapses a group and expands it again', () => {
  const h = harness();
  h.actions.toggleRepo('repo:R1');
  h.actions.toggleRepo('repo:R2');
  assert.deepEqual(Object.keys(h.state().ui.collapsed).sort(), ['repo:R1', 'repo:R2']);
  h.actions.toggleRepo('repo:R1');
  assert.deepEqual(Object.keys(h.state().ui.collapsed), ['repo:R2']);
  assert.equal(h.state().ui.collapsed['repo:R2'], true);
  assert.equal(Object.getPrototypeOf(h.state().ui.collapsed), null);
});

test('openLink asks the loader to open the URL', () => {
  const h = harness();
  h.actions.openLink('https://acme.example/docs');
  assert.deepEqual(h.links, ['https://acme.example/docs']);
});

// MARK: - createActions

const NO_SELF = (): Actions => { throw new Error('unused'); };

/**
 * A context whose laptop refuses every request, and whose store shows session `R` with a
 * draft, so a filled action that sends something sends it and meets the refusal. These tests
 * outlive the stubs: once parts 6c and 6d fill their modules, they still hold.
 */
function refusingContext(): ActionContext {
  const s = initialState();
  const sessions = applySnapshot(snapshot([row('W1', [R])]));
  const drafts = emptyRecord<string>();
  drafts[refKey(R)] = 'Run the unit tests.';
  return {
    store: createStore({ ...s, sessions, ui: { ...s.ui, route: { screen: 'session', ref: R }, lastRowID: 'W1', drafts } }),
    client: {
      stream: null,
      lastSeq: null,
      request: () => Promise.reject(new AppError('unavailable', 'The laptop cannot do that now.')),
    },
    link: { openLink: () => {} },
    now: () => 0,
  };
}

test('no two action modules share an action name', () => {
  const ctx = refusingContext();
  const modules = {
    shell: shellActions(ctx, NO_SELF),
    transcript: transcriptActions(ctx, NO_SELF),
    prompts: promptActions(ctx, NO_SELF),
    sheets: sheetActions(ctx, NO_SELF),
  };
  const owner = new Map<string, string>();
  for (const [name, actions] of Object.entries(modules)) {
    for (const key of Object.keys(actions)) {
      assert.equal(owner.get(key), undefined, `${key} is in both ${owner.get(key)} and ${name}`);
      owner.set(key, name);
    }
  }
});

test('createActions holds every action the plan names', () => {
  const actions = createActions(refusingContext());
  const names = [
    'onEvent', 'onChannelUp', 'onChannelDown', 'retrySubscribe', 'openSession', 'back', 'navMark', 'openPending', 'openSheet',
    'closeSheet', 'openMenu', 'closeMenu', 'toast', 'clearToast', 'setShowDetails', 'setLastRow', 'toggleRepo', 'openLink',
    'openTranscript', 'closeTranscript', 'resumeTranscriptOnUp', 'onShowDetailsChanged', 'loadOlder', 'toggleDetail',
    'answerPrompt', 'dismissPrompt', 'setDraft', 'sendMessage',
    'loadProfiles', 'switchProfile', 'fork', 'setModel', 'loadProviders', 'createWorktree', 'createRemote',
  ];
  for (const name of names) assert.equal(typeof (actions as unknown as Record<string, unknown>)[name], 'function', name);
});

test('every action that returns a Promise resolves, even when the laptop refuses each request', async () => {
  const actions = createActions(refusingContext());
  const pending = [
    actions.loadOlder(), actions.toggleDetail(0, 'input'), actions.answerPrompt('p1', { kind: 'permission', decision: 'allow' }, 'Allow'),
    actions.sendMessage(), actions.loadProfiles(), actions.switchProfile('P1'), actions.fork(null), actions.setModel('opus'),
    actions.loadProviders('R1'), actions.createWorktree('R1', 'hi'), actions.createRemote({ provider: 'acme-cloud', repoID: 'R1', message: 'hi', strings: {}, bools: {} }),
  ];
  await Promise.all(pending);
});
