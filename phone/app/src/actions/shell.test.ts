// Tests shell.ts and createActions: subscribing on channel up, a refused subscribe and "Try
// again", events that move the route opening or closing the transcript, navigation and the
// history entries it asks the loader for, route messages from the loader, sheets, menus, toasts
// and links, and the sessions list's filter chips. A fake client records each request and hands
// back a promise the test settles; the transcript actions are replaced on the actions object,
// which `self()` returns, so the test sees each call. A fake `entries` records what the shell asks of the loader's history, and a test
// plays the loader's answers by calling `onRoute`.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AppClient, AppError, SUPERSEDED_TEXT } from '../client/client.ts';
import type {
  AppEvent, Method, ParamsOf, PhoneGroupLayout, PhoneRow, PhoneSession, PhoneSessionRef, ResultOf, SessionsChangedData,
  SessionsSubscribeResult,
} from '../protocol/types.ts';
import { refKey } from '../protocol/wire.ts';
import { pendingValues } from '../state/remoteFilter.ts';
import { encodeRoute } from '../state/routeState.ts';
import { applySnapshot } from '../state/sessionsData.ts';
import { sessionsView } from '../state/sessionsView.ts';
import { createStore, emptyRecord, initialState, SESSIONS_ROUTE } from '../state/store.ts';
import type { AppState, Route } from '../state/store.ts';
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

/** The loader's history, for the tests that never look at what the shell asks of it. */
const NO_ENTRIES: ActionContext['entries'] = { push() {}, replace() {}, back() {} };

/** What the shell asked of the loader's history: an entry added or rewritten for a route, or the chevron's back. */
type EntryCall = ['push' | 'replace', Route] | ['back'];

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
  const entryCalls: EntryCall[] = [];
  const entries: ActionContext['entries'] = {
    push(route) { entryCalls.push(['push', route]); },
    replace(route) { entryCalls.push(['replace', route]); },
    back() { entryCalls.push(['back']); },
  };
  const store = createStore();
  const ctx: ActionContext = { store, client, link: { openLink: (url) => { links.push(url); } }, entries, now: () => 0 };
  const actions = createActions(ctx);
  const calls: unknown[][] = [];
  actions.openTranscript = (ref) => { calls.push(['openTranscript', ref]); };
  actions.closeTranscript = () => { calls.push(['closeTranscript']); };
  actions.resumeTranscriptOnUp = () => { calls.push(['resumeTranscriptOnUp', sent.length]); };
  actions.onShowDetailsChanged = () => { calls.push(['onShowDetailsChanged', store.get().ui.showDetails]); };
  const requests = () => sent.map((s): [Method, unknown] => [s.method, s.params]);
  return { sent, requests, client, store, actions, calls, links, entryCalls, state: (): AppState => store.get() };
}

type Harness = ReturnType<typeof harness>;

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
  h.entryCalls.length = 0;
  return h;
}

/**
 * The back chevron, then the loader's answer to it: a route message for the entry it went back
 * to, the list unless `to` says otherwise.
 */
function goBack(h: Harness, to: Route = SESSIONS_ROUTE): void {
  h.actions.back();
  h.actions.onRoute(encodeRoute(to));
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

test('a partial snapshot that leaves the open session waiting closes its sheet and menu for good', async () => {
  const h = await subscribed([row('W1', [R]), row('W2', [OTHER])]);
  h.actions.openSession(R);
  h.actions.openSheet({ name: 'fork' });
  h.actions.onChannelDown();
  h.actions.onChannelUp();
  // A new stream's snapshot that holds only W2; W1 follows as a sessions.changed.
  h.sent[1]!.resolve({
    stream: 's2', seq: 1, replayed: false, omittedRows: 0, more: true, rows: [row('W2', [OTHER])],
    layout: [{ id: 'repo:R1', kind: 'repo', name: 'acme', rows: [{ id: 'W1', depth: 0 }, { id: 'W2', depth: 0 }] }],
  });
  await flush();
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: R });
  assert.equal(h.state().ui.sheet, null);
  h.actions.onEvent(changed([row('W1', [R])]));
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: R });
  assert.equal(h.state().ui.sheet, null);
  // The same for a menu, which would otherwise open again over the session when its row came.
  h.actions.openMenu({ name: 'model' });
  h.actions.onChannelDown();
  h.actions.onChannelUp();
  h.sent[2]!.resolve({
    stream: 's3', seq: 1, replayed: false, omittedRows: 0, more: true, rows: [],
    layout: [{ id: 'repo:R1', kind: 'repo', name: 'acme', rows: [{ id: 'W1', depth: 0 }, { id: 'W2', depth: 0 }] }],
  });
  await flush();
  assert.equal(h.state().ui.menu, null);
  h.actions.onEvent(changed([row('W1', [R]), row('W2', [OTHER])]));
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: R });
  assert.equal(h.state().ui.menu, null);
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

test('Try again while the channel is down sends nothing and keeps the message, and the next channel up subscribes', async () => {
  const h = harness();
  h.actions.onChannelUp();
  h.sent[0]!.reject(new AppError('refused', 'Too many requests are in progress.'));
  await flush();
  h.actions.onChannelDown();
  h.actions.retrySubscribe();
  // No subscribe, and the message and its Try again stay, under the loader's "Reconnecting…".
  assert.equal(h.sent.length, 1);
  assert.equal(h.state().conn.error, 'Too many requests are in progress.');
  assert.equal(h.state().conn.subscribed, false);
  // The channel comes back: its own subscribe goes out and the message clears.
  h.actions.onChannelUp();
  assert.equal(h.state().conn.error, null);
  assert.deepEqual(h.requests(), [['sessions.subscribe', {}], ['sessions.subscribe', {}]]);
  // Refused again with the channel up, Try again sends one subscribe, as before.
  h.sent[1]!.reject(new AppError('refused', 'Too many requests are in progress.'));
  await flush();
  h.actions.retrySubscribe();
  h.actions.retrySubscribe();
  assert.equal(h.state().conn.error, null);
  assert.deepEqual(h.requests(), [['sessions.subscribe', {}], ['sessions.subscribe', {}], ['sessions.subscribe', {}]]);
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

test('a subscribe the client refuses before posting still resumes the transcript, and Try again subscribes', async () => {
  // The real client, whose `newID` gives the ID of a read still queued: the subscribe that
  // channel up makes collides with it.
  const ids = ['dup', 'dup', 'fresh'];
  const posted: Array<Record<string, unknown>> = [];
  const store = createStore();
  let actions: Actions | null = null;
  const client = new AppClient({
    post: (body) => { posted.push(body); },
    onEvent: () => {},
    onUp: () => actions!.onChannelUp(),
    onDown: () => actions!.onChannelDown(),
    now: () => 0,
    newID: () => ids.shift() ?? 'spent',
  });
  actions = createActions({ store, client, link: { openLink: () => {} }, entries: NO_ENTRIES, now: () => 0 });
  const calls: string[] = [];
  actions.resumeTranscriptOnUp = () => { calls.push('resumeTranscriptOnUp'); };
  client.request('profiles.list', {}).catch(() => {});
  assert.doesNotThrow(() => client.handle({ t: 'channel', up: true }));
  assert.deepEqual(calls, ['resumeTranscriptOnUp']);
  await flush();
  assert.match(store.get().conn.error ?? '', /request ID dup is already in use/);
  // The refused subscribe is not in flight, so Try again sends a new one.
  actions.retrySubscribe();
  assert.equal(store.get().conn.error, null);
  assert.deepEqual(posted.map((b) => [b.requestID, b.method]), [['dup', 'profiles.list'], ['fresh', 'sessions.subscribe']]);
});

// MARK: - Events

/**
 * A `sessions.changed`. With `placed`, it carries a layout whose one group places those rows,
 * as the daemon's does whenever it adds or removes a row. A row the layout does not place shows
 * nowhere, so nothing opens it.
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
  h.actions.onEvent(changed([row('W3', [R])], [], ['W2', 'W3']));
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: R });
  assert.equal(h.state().ui.lastRowID, 'W3');
  assert.equal(h.state().ui.pendingOpen, null);
  assert.deepEqual(h.calls, [['openTranscript', R]]);
});

test('a pending worktree open toasts once its row lists a session', async () => {
  const h = await subscribed([row('W2', [OTHER])]);
  h.actions.openPending({ worktreeID: WT, toast: 'Created {name}' });
  h.actions.onEvent(changed([row(WT, [R], 'fix-login')], [], ['W2', WT]));
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

test('going back clears a pending open, so a worktree the user moved away from never opens or toasts', async () => {
  const h = await subscribed([row('W1', [R])]);
  h.actions.openSession(R);
  h.actions.openPending({ worktreeID: WT, toast: 'Created {name}' });
  goBack(h);
  assert.equal(h.state().ui.pendingOpen, null);
  h.calls.length = 0;
  h.actions.onEvent(changed([row(WT, [R2], 'fix-login')], [], ['W1', WT]));
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
  goBack(h);
  h.actions.openPending({ worktreeID: WT, toast: 'Created {name}' }, createMark);
  assert.equal(h.state().ui.pendingOpen, null);
  h.calls.length = 0;
  h.actions.onEvent(changed([row('W1', [R, R2]), row(WT, [R2], 'fix-login')], [], ['W1', 'W2', WT]));
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
  goBack(h);
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
  goBack(h);
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
  goBack(h);
  h.actions.toggleRepo('repo:R1');
  h.actions.openSheet({ name: 'new', repoID: 'R1', repoName: 'acme' });
  h.actions.openPending({ worktreeID: WT, toast: null });
  const before = h.state().ui;
  h.actions.onEvent(changed([row(WT, [R2])], [], ['W1', WT]));
  const ui = h.state().ui;
  assert.deepEqual(ui.route, { screen: 'session', ref: R2 });
  assert.equal(ui.pendingOpen, null);
  for (const key of ['showDetails', 'collapsed', 'toast', 'nav', 'refusal', 'drafts'] as const) {
    assert.equal(ui[key], before[key], key);
  }
  // New closes, so it does not stay over the session it created.
  assert.equal(ui.sheet, null);
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

test('back on the sessions list changes nothing, closes no transcript, and asks nothing of the history', async () => {
  const h = await subscribed([row('W1', [R])]);
  h.actions.openPending({ worktreeID: WT, toast: 'Created {name}' });
  const before = h.state();
  h.actions.back();
  assert.equal(h.state(), before);
  assert.deepEqual(h.calls, []);
  assert.deepEqual(h.entryCalls, []);
  // The user stayed put, so the worktree still opens and toasts.
  h.actions.onEvent(changed([row(WT, [R2], 'fix-login')], [], ['W1', WT]));
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: R2 });
  assert.deepEqual(h.state().ui.toast, { id: 1, text: 'Created fix-login' });
});

test('back on a session asks the history to go back and changes nothing itself; the route message that answers shows the list', async () => {
  const h = await subscribed([row('W1', [R])]);
  h.actions.openSession(R);
  h.actions.openSheet({ name: 'menu' });
  h.actions.openPending({ ref: R2 });
  h.calls.length = 0;
  h.entryCalls.length = 0;
  const before = h.state();
  h.actions.back();
  assert.deepEqual(h.entryCalls, [['back']]);
  assert.equal(h.state(), before);
  assert.deepEqual(h.calls, []);
  h.actions.onRoute(null);
  assert.equal(h.state().ui.route, SESSIONS_ROUTE);
  assert.equal(h.state().ui.sheet, null);
  assert.equal(h.state().ui.pendingOpen, null);
  assert.equal(h.state().ui.lastRowID, 'W1');
  assert.deepEqual(h.calls, [['closeTranscript']]);
  assert.deepEqual(h.entryCalls, [['back']], 'the route message asks for no entry');
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

// MARK: - The loader's history

function shows(ref: PhoneSessionRef): Route {
  return { screen: 'session', ref };
}

test('a move from the list to a session adds an entry', async () => {
  const h = await subscribed([row('W1', [R]), row('W2', [OTHER])]);
  h.actions.openSession(R);
  assert.deepEqual(h.entryCalls, [['push', shows(R)]]);
});

test('a move to a session in another worktree adds an entry, and a remote session is a worktree of its own', async () => {
  const h = await subscribed([row('W1', [R]), row('W2', [OTHER])]);
  h.actions.openSession(R);
  h.actions.openSession(OTHER);
  assert.deepEqual(h.entryCalls, [['push', shows(R)], ['push', shows(OTHER)]]);
  const REMOTE: PhoneSessionRef = { kind: 'remote', provider: 'acme-cloud', sessionID: 'rs-1' };
  const remote: PhoneRow = { ...row('remote:acme-cloud/rs-1', [REMOTE]), kind: 'remoteSession', remote: true };
  const h2 = await subscribed([row('W1', [R]), remote]);
  h2.actions.openSession(R);
  h2.actions.openSession(REMOTE);
  assert.deepEqual(h2.entryCalls, [['push', shows(R)], ['push', shows(REMOTE)]]);
});

test('a move to another tab of the same worktree rewrites the entry, and a tap on the tab that shows asks nothing', async () => {
  const h = await subscribed([row('W1', [R, R2]), row('W2', [OTHER])]);
  h.actions.openSession(R);
  h.actions.openSession(R2);
  h.actions.openSession(R);
  h.actions.openSession(R);
  assert.deepEqual(h.entryCalls, [['push', shows(R)], ['replace', shows(R2)], ['replace', shows(R)]]);
});

test('an event that takes the shown session off the list rewrites the entry, and one that leaves the route asks nothing', async () => {
  const h = await subscribed([row('W1', [R]), row('W2', [OTHER])]);
  h.actions.openSession(R);
  h.actions.onEvent(changed([], ['W1'], ['W2']));
  assert.equal(h.state().ui.route, SESSIONS_ROUTE);
  assert.deepEqual(h.entryCalls, [['push', shows(R)], ['replace', SESSIONS_ROUTE]]);
  h.actions.onEvent(changed([row('W2', [OTHER], 'renamed')]));
  assert.equal(h.entryCalls.length, 2);
});

test('a pending open adds an entry when it lands in another worktree, and rewrites it when it lands beside its session', async () => {
  // A fork opens beside the session it forked, in the same worktree.
  const h = await subscribed([row('W1', [R]), row('W2', [OTHER])]);
  h.actions.openSession(R);
  h.actions.openPending({ ref: R2 }, h.actions.navMark());
  h.actions.onEvent(changed([row('W1', [R, R2])]));
  assert.deepEqual(h.state().ui.route, shows(R2));
  assert.deepEqual(h.entryCalls, [['push', shows(R)], ['replace', shows(R2)]]);
  // One that lands in another worktree, whether it waits for the list or the list shows it already.
  h.actions.openPending({ worktreeID: WT, toast: 'Created {name}' }, h.actions.navMark());
  const R3: PhoneSessionRef = { kind: 'local', terminalID: 'T-R3' };
  h.actions.onEvent(changed([row(WT, [R3], 'fix-login')], [], ['W1', 'W2', WT]));
  assert.deepEqual(h.state().ui.route, shows(R3));
  h.actions.openPending({ ref: R }, h.actions.navMark());
  assert.deepEqual(h.state().ui.route, shows(R));
  assert.deepEqual(h.entryCalls, [['push', shows(R)], ['replace', shows(R2)], ['push', shows(R3)], ['push', shows(R)]]);
  // And a create from the list lands in a worktree the list did not show.
  const fromList = await subscribed([row('W1', [R])]);
  fromList.actions.openPending({ worktreeID: WT, toast: null }, fromList.actions.navMark());
  fromList.actions.onEvent(changed([row(WT, [R2])], [], ['W1', WT]));
  assert.deepEqual(fromList.entryCalls, [['push', shows(R2)]]);
});

test('a pending open beside its session rewrites the entry when the row comes back after a partial snapshot', async () => {
  const h = await subscribed([row('W1', [R]), row('W2', [OTHER])]);
  h.actions.openSession(R);
  h.actions.openPending({ ref: R2 }, h.actions.navMark());
  h.actions.onChannelDown();
  h.actions.onChannelUp();
  // A new stream's snapshot that holds only W2; W1 follows as a sessions.changed.
  h.sent[1]!.resolve({
    stream: 's2', seq: 1, replayed: false, omittedRows: 0, more: true, rows: [row('W2', [OTHER])],
    layout: [{ id: 'repo:R1', kind: 'repo', name: 'acme', rows: [{ id: 'W1', depth: 0 }, { id: 'W2', depth: 0 }] }],
  });
  await flush();
  assert.deepEqual(h.state().ui.route, shows(R));
  // W1 comes back with the fork beside R: the list that showed R did not hold W1, the new one does.
  h.actions.onEvent(changed([row('W1', [R, R2])]));
  assert.deepEqual(h.state().ui.route, shows(R2));
  assert.deepEqual(h.entryCalls, [['push', shows(R)], ['replace', shows(R2)]]);
  // And when the newer list no longer holds the session that showed, the list that showed it says where it was.
  const gone = await subscribed([row('W1', [R]), row('W2', [OTHER])]);
  gone.actions.openSession(R);
  gone.actions.openPending({ ref: R2 }, gone.actions.navMark());
  gone.actions.onEvent(changed([row('W1', [R2])]));
  assert.deepEqual(gone.state().ui.route, shows(R2));
  assert.deepEqual(gone.entryCalls, [['push', shows(R)], ['replace', shows(R2)]]);
});

test("a route message shows its entry's screen as a tap would, and asks for no entry", async () => {
  const h = await subscribed([row('W1', [R]), row('W2', [OTHER])]);
  h.actions.openSession(R);
  h.actions.openSession(OTHER);
  h.actions.openSheet({ name: 'menu' });
  h.actions.openPending({ ref: R2 });
  h.calls.length = 0;
  h.entryCalls.length = 0;
  const nav = h.actions.navMark();
  h.actions.onRoute(encodeRoute(shows(R)));
  let ui = h.state().ui;
  assert.deepEqual(ui.route, shows(R));
  assert.equal(ui.lastRowID, 'W1');
  assert.equal(ui.sheet, null);
  assert.equal(ui.pendingOpen, null);
  assert.equal(h.actions.navMark(), nav + 1);
  assert.deepEqual(h.calls, [['openTranscript', R]]);
  // The menu closes too.
  h.actions.openMenu({ name: 'model' });
  h.actions.onRoute(null);
  ui = h.state().ui;
  assert.equal(ui.route, SESSIONS_ROUTE);
  assert.equal(ui.menu, null);
  assert.deepEqual(h.calls, [['openTranscript', R], ['closeTranscript']]);
  h.actions.onRoute(encodeRoute(shows(R)));
  h.actions.onRoute(encodeRoute(shows(OTHER)));
  assert.deepEqual(h.state().ui.route, shows(OTHER));
  assert.equal(h.state().ui.lastRowID, 'W2');
  assert.deepEqual(h.calls, [['openTranscript', R], ['closeTranscript'], ['openTranscript', R], ['openTranscript', OTHER]]);
  assert.equal(h.actions.navMark(), nav + 4);
  assert.deepEqual(h.entryCalls, []);
});

test("a route message ends a fork's wait for its reply, so the fork never takes the user away", async () => {
  const h = await subscribed([row('W1', [R]), row('W2', [OTHER])]);
  h.actions.openSession(R);
  h.actions.openSession(OTHER);
  const forkMark = h.actions.navMark();
  h.actions.onRoute(encodeRoute(shows(R)));
  h.actions.openPending({ ref: R2 }, forkMark);
  assert.equal(h.state().ui.pendingOpen, null);
  h.actions.onEvent(changed([row('W2', [OTHER, R2])]));
  assert.deepEqual(h.state().ui.route, shows(R));
});

test('a route message for the screen that shows keeps it, and does the rest as any route message does', async () => {
  const h = await subscribed([row('W1', [R]), row('W2', [OTHER])]);
  h.actions.openSheet({ name: 'new', repoID: 'R1', repoName: 'acme' });
  h.actions.openPending({ worktreeID: WT, toast: null }, h.actions.navMark());
  const nav = h.actions.navMark();
  h.actions.onRoute(null);
  assert.equal(h.state().ui.route, SESSIONS_ROUTE);
  assert.equal(h.state().ui.sheet, null);
  assert.equal(h.state().ui.pendingOpen, null, 'a pending open is cleared');
  assert.equal(h.actions.navMark(), nav + 1, 'and it counts as a navigation');
  // So the worktree the create made takes the user nowhere when its row comes.
  h.actions.onEvent(changed([row(WT, [R2])], [], ['W1', 'W2', WT]));
  assert.equal(h.state().ui.route, SESSIONS_ROUTE);
  // On a session too: its transcript stays as it is.
  h.actions.openSession(R);
  h.actions.openMenu({ name: 'model' });
  // A fork whose session no row lists yet.
  const forked: PhoneSessionRef = { kind: 'local', terminalID: 'T-forked' };
  h.actions.openPending({ ref: forked });
  assert.deepEqual(h.state().ui.pendingOpen, { ref: forked });
  h.calls.length = 0;
  h.entryCalls.length = 0;
  h.actions.onRoute(encodeRoute(shows(R)));
  assert.deepEqual(h.state().ui.route, shows(R));
  assert.equal(h.state().ui.menu, null);
  assert.equal(h.state().ui.pendingOpen, null);
  assert.equal(h.actions.navMark(), nav + 3);
  // With nothing open or waiting, it still counts, so a fork in flight never takes the user away.
  const forkMark = h.actions.navMark();
  h.actions.onRoute(encodeRoute(shows(R)));
  assert.deepEqual(h.state().ui.route, shows(R));
  assert.equal(h.actions.navMark(), forkMark + 1);
  h.actions.openPending({ ref: OTHER }, forkMark);
  assert.equal(h.state().ui.pendingOpen, null);
  assert.deepEqual(h.state().ui.route, shows(R));
  assert.deepEqual(h.calls, []);
  assert.deepEqual(h.entryCalls, []);
});

test('a route message for a session no row of the complete list holds shows the list and rewrites the entry', async () => {
  // Forward onto a session that has since left the list.
  const h = await subscribed([row('W1', [R]), row('W2', [OTHER])]);
  h.actions.openSession(R);
  h.actions.openSession(OTHER);
  h.actions.onRoute(encodeRoute(shows(R)));
  h.actions.onEvent(changed([row('W1', [R])], ['W2'], ['W1']));
  h.calls.length = 0;
  h.entryCalls.length = 0;
  const nav = h.actions.navMark();
  h.actions.onRoute(encodeRoute(shows(OTHER)));
  assert.equal(h.state().ui.route, SESSIONS_ROUTE);
  assert.equal(h.state().ui.pendingOpen, null);
  assert.equal(h.actions.navMark(), nav + 1);
  assert.deepEqual(h.calls, [['closeTranscript']]);
  assert.deepEqual(h.entryCalls, [['replace', SESSIONS_ROUTE]]);
  // From the list, it only rewrites the entry.
  h.calls.length = 0;
  h.entryCalls.length = 0;
  h.actions.onRoute(encodeRoute(shows(OTHER)));
  assert.equal(h.state().ui.route, SESSIONS_ROUTE);
  assert.deepEqual(h.calls, []);
  assert.deepEqual(h.entryCalls, [['replace', SESSIONS_ROUTE]]);
});

test('a route message whose string is not a route this app reads shows the list and rewrites the entry', async () => {
  for (const state of ['', '{', '{"screen":"session"}', '{"screen":"sessions"}', '{"screen":"session","ref":{"kind":"local"}}', 'null']) {
    const h = await subscribed([row('W1', [R])]);
    h.actions.openSession(R);
    h.calls.length = 0;
    h.entryCalls.length = 0;
    h.actions.onRoute(state);
    assert.equal(h.state().ui.route, SESSIONS_ROUTE, state);
    assert.deepEqual(h.calls, [['closeTranscript']], state);
    assert.deepEqual(h.entryCalls, [['replace', SESSIONS_ROUTE]], state);
  }
});

test('the chevron then forward: back changes nothing until the route message, and forward returns to the session', async () => {
  const h = await subscribed([row('W1', [R]), row('W2', [OTHER])]);
  h.actions.openSession(R);
  h.actions.openSession(OTHER);
  h.calls.length = 0;
  h.entryCalls.length = 0;
  goBack(h, shows(R));
  assert.deepEqual(h.state().ui.route, shows(R));
  assert.deepEqual(h.entryCalls, [['back']]);
  // The browser's forward reaches the entry the chevron left.
  h.actions.onRoute(encodeRoute(shows(OTHER)));
  assert.deepEqual(h.state().ui.route, shows(OTHER));
  assert.deepEqual(h.calls, [['openTranscript', R], ['openTranscript', OTHER]]);
  assert.deepEqual(h.entryCalls, [['back']]);
});

// A restore: a route message for a session the list may still bring.

test('a route message before the first snapshot waits for the list, then opens its session without adding an entry', async () => {
  const h = harness();
  h.actions.onRoute(encodeRoute(shows(R)));
  assert.equal(h.state().ui.route, SESSIONS_ROUTE);
  assert.deepEqual(h.state().ui.pendingOpen, { ref: R, restore: true });
  assert.deepEqual(h.calls, []);
  assert.deepEqual(h.entryCalls, []);
  h.actions.onChannelUp();
  assert.deepEqual(h.requests(), [['sessions.subscribe', {}]], 'no transcript is asked for before the list lists the session');
  h.sent[0]!.resolve(snapshot([row('W1', [R]), row('W2', [OTHER])]));
  await flush();
  assert.deepEqual(h.state().ui.route, shows(R));
  assert.equal(h.state().ui.lastRowID, 'W1');
  assert.equal(h.state().ui.pendingOpen, null);
  assert.deepEqual(h.calls, [['resumeTranscriptOnUp', 1], ['openTranscript', R]]);
  // The entry names the session already: rewritten, never pushed.
  assert.deepEqual(h.entryCalls, [['replace', shows(R)]]);
});

test('a restore whose session the complete list does not hold is dropped, and the entry rewritten to the list', async () => {
  const h = harness();
  h.actions.onRoute(encodeRoute(shows(R)));
  h.actions.onChannelUp();
  h.sent[0]!.resolve(snapshot([row('W2', [OTHER])]));
  await flush();
  assert.equal(h.state().ui.route, SESSIONS_ROUTE);
  assert.equal(h.state().ui.pendingOpen, null);
  assert.deepEqual(h.entryCalls, [['replace', SESSIONS_ROUTE]]);
  // The session showing up later takes the user nowhere.
  h.actions.onEvent(changed([row('W1', [R])], [], ['W1', 'W2']));
  assert.equal(h.state().ui.route, SESSIONS_ROUTE);
  assert.deepEqual(h.entryCalls, [['replace', SESSIONS_ROUTE]]);
});

test('a restore waits through a partial snapshot until the row with its session arrives', async () => {
  const h = harness();
  h.actions.onRoute(encodeRoute(shows(R)));
  h.actions.onChannelUp();
  h.sent[0]!.resolve({ ...snapshot([row('W2', [OTHER])]), more: true,
    layout: [{ id: 'repo:R1', kind: 'repo', name: 'acme', rows: [{ id: 'W1', depth: 0 }, { id: 'W2', depth: 0 }] }] });
  await flush();
  assert.equal(h.state().ui.route, SESSIONS_ROUTE);
  assert.deepEqual(h.state().ui.pendingOpen, { ref: R, restore: true });
  assert.deepEqual(h.entryCalls, []);
  h.actions.onEvent(changed([row('W1', [R])]));
  assert.deepEqual(h.state().ui.route, shows(R));
  assert.deepEqual(h.entryCalls, [['replace', shows(R)]]);
});

test("the user's own move cancels a restore", async () => {
  const h = harness();
  h.actions.onRoute(encodeRoute(shows(R)));
  h.actions.onChannelUp();
  h.sent[0]!.resolve({ ...snapshot([row('W2', [OTHER])]), more: true,
    layout: [{ id: 'repo:R1', kind: 'repo', name: 'acme', rows: [{ id: 'W1', depth: 0 }, { id: 'W2', depth: 0 }] }] });
  await flush();
  h.actions.openSession(OTHER);
  assert.equal(h.state().ui.pendingOpen, null);
  assert.deepEqual(h.entryCalls, [['push', shows(OTHER)]]);
  h.actions.onEvent(changed([row('W1', [R])]));
  assert.deepEqual(h.state().ui.route, shows(OTHER));
  assert.deepEqual(h.entryCalls, [['push', shows(OTHER)]]);
  // So does a later route message, even one for the screen that shows.
  const h2 = harness();
  h2.actions.onRoute(encodeRoute(shows(R)));
  h2.actions.onRoute(null);
  assert.equal(h2.state().ui.pendingOpen, null);
  h2.actions.onChannelUp();
  h2.sent[0]!.resolve(snapshot([row('W1', [R])]));
  await flush();
  assert.equal(h2.state().ui.route, SESSIONS_ROUTE);
  assert.deepEqual(h2.entryCalls, []);
});

test('a route message while a row is on its way leaves the session that shows, and waits for its own', async () => {
  const h = await subscribed([row('W1', [R]), row('W2', [OTHER])]);
  h.actions.openSession(OTHER);
  // A reconnect's snapshot brings W2 and leaves W1 to follow.
  h.actions.onChannelDown();
  h.actions.onChannelUp();
  h.sent[1]!.resolve({ ...snapshot([row('W2', [OTHER])], 's2', 1), more: true,
    layout: [{ id: 'repo:R1', kind: 'repo', name: 'acme', rows: [{ id: 'W1', depth: 0 }, { id: 'W2', depth: 0 }] }] });
  await flush();
  h.calls.length = 0;
  h.entryCalls.length = 0;
  const nav = h.actions.navMark();
  h.actions.onRoute(encodeRoute(shows(R)));
  assert.equal(h.state().ui.route, SESSIONS_ROUTE);
  assert.deepEqual(h.state().ui.pendingOpen, { ref: R, restore: true });
  assert.equal(h.actions.navMark(), nav + 1);
  assert.deepEqual(h.calls, [['closeTranscript']]);
  h.actions.onEvent(changed([row('W1', [R])]));
  assert.deepEqual(h.state().ui.route, shows(R));
  assert.deepEqual(h.calls, [['closeTranscript'], ['openTranscript', R]]);
  assert.deepEqual(h.entryCalls, [['replace', shows(R)]]);
});

test('a restore counts as the navigation it is, so a create in flight never replaces it', async () => {
  const h = harness();
  const mark = h.actions.navMark();
  h.actions.onRoute(encodeRoute(shows(R)));
  h.actions.openPending({ worktreeID: WT, toast: null }, mark);
  assert.deepEqual(h.state().ui.pendingOpen, { ref: R, restore: true });
});

// MARK: - The filter chip

const REPO = '16E7737E-5C20-548E-81FC-5DD3F9A51D36';
const BOX: PhoneSessionRef = { kind: 'remote', provider: 'acme-box', sessionID: 'run-1' };

/** The repo group of `REPO`, placing a local row and a registry row, with the filter on when `on` is set. */
function filterLayout(on: boolean): PhoneGroupLayout[] {
  const g: PhoneGroupLayout = { id: `repo:${REPO}`, kind: 'repo', name: 'acme', rows: [{ id: 'W1', depth: 0 }, { id: 'BOX', depth: 0 }] };
  return [on ? { ...g, remoteFilterOn: true } : g];
}

/** A `sessions.changed` that carries the layout, its filter on when `on` is set. */
function layoutEvent(on: boolean): AppEvent {
  return { event: 'sessions.changed', seq: 12, data: { layout: filterLayout(on), rows: [], removedRowIDs: [] } };
}

/** A harness subscribed to a list whose repo `REPO` has a registry row, its filter on when `on` is set. */
async function filterHarness(on = false) {
  const h = harness();
  h.actions.onChannelUp();
  h.sent[0]!.resolve({
    stream: 's1', seq: 10, replayed: false, omittedRows: 0, more: false, layout: filterLayout(on),
    rows: [row('W1', [R]), { ...row('BOX', [BOX]), remote: true }],
  });
  await flush();
  h.sent.length = 0;
  return h;
}

/** What the chip shows for `REPO` now: the phone's own value while a tap waits, else the layout's. */
function chipOn(h: Harness): boolean | undefined {
  const groups = sessionsView(h.state().sessions, { pending: pendingValues(h.state().ui.remoteFilterPending) });
  return groups.find((g) => g.repoID === REPO)?.filter?.on;
}

/** The rows the list shows for `REPO`, by ID. */
function shownRows(h: Harness): string[] {
  const groups = sessionsView(h.state().sessions, { pending: pendingValues(h.state().ui.remoteFilterPending) });
  return groups.find((g) => g.repoID === REPO)?.rows.map((r) => r.row.id) ?? [];
}

test('a tap flips the chip at once and sends the flipped value', async () => {
  const h = await filterHarness();
  assert.equal(chipOn(h), false);
  const done = h.actions.toggleRemoteFilter(REPO);
  assert.equal(chipOn(h), true);
  assert.deepEqual(shownRows(h), ['W1']);
  assert.deepEqual(h.requests(), [['repo.setRemoteFilter', { repoID: REPO, hidden: true }]]);
  assert.deepEqual(h.state().ui.remoteFilterPending[REPO], { value: true, seq: 1, confirmed: false });
  // The store keeps every row.
  assert.deepEqual(Object.keys(h.state().sessions.rows).sort(), ['BOX', 'W1']);
  h.sent[0]!.resolve({});
  await done;
});

test('a tap on a filter that is on sends it off', async () => {
  const h = await filterHarness(true);
  assert.equal(chipOn(h), true);
  void h.actions.toggleRemoteFilter(REPO);
  assert.equal(chipOn(h), false);
  assert.deepEqual(h.requests(), [['repo.setRemoteFilter', { repoID: REPO, hidden: false }]]);
});

test('a tap for a repo the list does not show sends nothing', async () => {
  const h = await filterHarness();
  await h.actions.toggleRemoteFilter('8A1E503C-B1A3-59EE-9AFE-5DE564EE906B');
  assert.deepEqual(h.requests(), []);
  assert.deepEqual(Object.keys(h.state().ui.remoteFilterPending), []);
});

test('the chip stays flipped until a layout agrees, which ends the wait', async () => {
  const h = await filterHarness();
  const done = h.actions.toggleRemoteFilter(REPO);
  // An event with no layout, and a layout that still says off, change nothing: the laptop may not have written yet.
  h.actions.onEvent(changed([]));
  h.actions.onEvent(layoutEvent(false));
  assert.equal(chipOn(h), true);
  h.actions.onEvent(layoutEvent(true));
  assert.deepEqual(Object.keys(h.state().ui.remoteFilterPending), []);
  assert.equal(chipOn(h), true);
  // The reply after it finds nothing to settle.
  h.sent[0]!.resolve({});
  await done;
  assert.deepEqual(Object.keys(h.state().ui.remoteFilterPending), []);
  assert.equal(h.state().ui.toast, null);
});

test('a reply ends the wait at once when the list shows its value already', async () => {
  const h = await filterHarness();
  const first = h.actions.toggleRemoteFilter(REPO);
  const second = h.actions.toggleRemoteFilter(REPO);
  h.sent[0]!.resolve({});
  await first;
  await flush();
  // On, then off: the laptop's list never changed, so no layout comes. The second reply finds the
  // list saying off already, and ends the wait.
  h.sent[1]!.resolve({});
  await second;
  assert.deepEqual(Object.keys(h.state().ui.remoteFilterPending), []);
  assert.equal(chipOn(h), false);
});

test('a layout after a successful reply wins over the pending value', async () => {
  const h = await filterHarness();
  const done = h.actions.toggleRemoteFilter(REPO);
  h.sent[0]!.resolve({});
  await done;
  // The laptop took it; the chip waits for the next layout.
  assert.deepEqual(h.state().ui.remoteFilterPending[REPO], { value: true, seq: 1, confirmed: true });
  assert.equal(chipOn(h), true);
  // Another client turned it off since: the layout says off, and the chip follows it.
  h.actions.onEvent(layoutEvent(false));
  assert.deepEqual(Object.keys(h.state().ui.remoteFilterPending), []);
  assert.equal(chipOn(h), false);
  assert.deepEqual(shownRows(h), ['BOX', 'W1']);
});

test('a refused reply flips the chip back and toasts the laptop\'s reason', async () => {
  const h = await filterHarness();
  const done = h.actions.toggleRemoteFilter(REPO);
  assert.equal(chipOn(h), true);
  h.sent[0]!.reject(new AppError('not_found', 'That repo is no longer on this laptop.'));
  await done;
  assert.equal(chipOn(h), false);
  assert.deepEqual(Object.keys(h.state().ui.remoteFilterPending), []);
  assert.deepEqual(h.state().ui.toast, { id: 1, text: 'That repo is no longer on this laptop.' });
});

test('a superseded request flips the chip back without a toast', async () => {
  const h = await filterHarness();
  const done = h.actions.toggleRemoteFilter(REPO);
  h.sent[0]!.reject(new AppError('superseded', SUPERSEDED_TEXT));
  await done;
  assert.equal(chipOn(h), false);
  assert.equal(h.state().ui.toast, null);
});

test('a stale failure does not undo a newer tap', async () => {
  const h = await filterHarness();
  const first = h.actions.toggleRemoteFilter(REPO);
  const second = h.actions.toggleRemoteFilter(REPO);
  assert.equal(chipOn(h), false);
  assert.deepEqual(h.state().ui.remoteFilterPending[REPO], { value: false, seq: 2, confirmed: false });
  // The first request fails: the second tap stands, and says nothing yet.
  h.sent[0]!.reject(new AppError('refused', 'The laptop refused the change.'));
  await first;
  await flush();
  assert.deepEqual(h.state().ui.remoteFilterPending[REPO], { value: false, seq: 2, confirmed: false });
  assert.equal(h.state().ui.toast, null);
  // The second succeeds, and the list says off already, so the wait ends.
  h.sent[1]!.resolve({});
  await second;
  assert.deepEqual(Object.keys(h.state().ui.remoteFilterPending), []);
  assert.equal(chipOn(h), false);
});

test('a stale success does not settle a newer tap', async () => {
  const h = await filterHarness();
  const first = h.actions.toggleRemoteFilter(REPO);
  const second = h.actions.toggleRemoteFilter(REPO);
  h.sent[0]!.resolve({});
  await first;
  await flush();
  // Still the second tap's, and not confirmed: a layout that says on, from the first request, leaves it.
  assert.deepEqual(h.state().ui.remoteFilterPending[REPO], { value: false, seq: 2, confirmed: false });
  h.actions.onEvent(layoutEvent(true));
  assert.equal(chipOn(h), false);
  // The second's own failure flips it back to what the list says.
  h.sent[1]!.reject(new AppError('refused', 'The laptop refused the change.'));
  await second;
  assert.equal(chipOn(h), true);
  assert.deepEqual(h.state().ui.toast, { id: 1, text: 'The laptop refused the change.' });
});

test('two quick taps send one after another', async () => {
  const h = await filterHarness();
  const first = h.actions.toggleRemoteFilter(REPO);
  const second = h.actions.toggleRemoteFilter(REPO);
  // The chip shows the second tap at once, but its request waits for the first one's reply: the
  // laptop could write two in flight together in either order.
  assert.equal(chipOn(h), false);
  await flush();
  assert.deepEqual(h.requests(), [['repo.setRemoteFilter', { repoID: REPO, hidden: true }]]);
  h.sent[0]!.resolve({});
  await first;
  await flush();
  assert.deepEqual(h.requests(), [
    ['repo.setRemoteFilter', { repoID: REPO, hidden: true }],
    ['repo.setRemoteFilter', { repoID: REPO, hidden: false }],
  ]);
  h.sent[1]!.resolve({});
  await second;
  assert.deepEqual(Object.keys(h.state().ui.remoteFilterPending), []);
  assert.equal(chipOn(h), false);
});

test('each queued request carries its own tap\'s value, not the chip\'s when it goes', async () => {
  const h = await filterHarness();
  const taps = [h.actions.toggleRemoteFilter(REPO), h.actions.toggleRemoteFilter(REPO), h.actions.toggleRemoteFilter(REPO)];
  // On, off, on: the chip shows on while the second tap's off waits its turn.
  assert.equal(chipOn(h), true);
  for (let i = 0; i < 3; i++) {
    await flush();
    assert.equal(h.sent.length, i + 1);
    h.sent[i]!.resolve({});
    await taps[i];
  }
  assert.deepEqual(h.requests(), [
    ['repo.setRemoteFilter', { repoID: REPO, hidden: true }],
    ['repo.setRemoteFilter', { repoID: REPO, hidden: false }],
    ['repo.setRemoteFilter', { repoID: REPO, hidden: true }],
  ]);
  assert.deepEqual(h.state().ui.remoteFilterPending[REPO], { value: true, seq: 3, confirmed: true });
});

test('a failed first send still sends the second', async () => {
  const h = await filterHarness();
  const first = h.actions.toggleRemoteFilter(REPO);
  const second = h.actions.toggleRemoteFilter(REPO);
  await flush();
  assert.equal(h.sent.length, 1);
  h.sent[0]!.reject(new AppError('not_confirmed', 'The laptop may not have done that.'));
  await first;
  await flush();
  assert.deepEqual(h.requests(), [
    ['repo.setRemoteFilter', { repoID: REPO, hidden: true }],
    ['repo.setRemoteFilter', { repoID: REPO, hidden: false }],
  ]);
  // The failure is the first tap's, so the second tap stands and nothing is toasted.
  assert.deepEqual(h.state().ui.remoteFilterPending[REPO], { value: false, seq: 2, confirmed: false });
  assert.equal(h.state().ui.toast, null);
  h.sent[1]!.resolve({});
  await second;
  assert.deepEqual(Object.keys(h.state().ui.remoteFilterPending), []);
  assert.equal(chipOn(h), false);
});

test('a tap after the last reply sends at once', async () => {
  const h = await filterHarness();
  const first = h.actions.toggleRemoteFilter(REPO);
  h.sent[0]!.reject(new AppError('refused', 'The laptop refused the change.'));
  await first;
  const second = h.actions.toggleRemoteFilter(REPO);
  assert.deepEqual(h.requests(), [
    ['repo.setRemoteFilter', { repoID: REPO, hidden: true }],
    ['repo.setRemoteFilter', { repoID: REPO, hidden: true }],
  ]);
  h.sent[1]!.resolve({});
  await second;
});

test('a tap on another repo is not held behind this repo\'s unanswered request', async () => {
  const OTHER_REPO = '4C2B9A71-0D3E-5F48-9A6B-7E1D2C3B4A50';
  const h = harness();
  h.actions.onChannelUp();
  h.sent[0]!.resolve({
    stream: 's1', seq: 10, replayed: false, omittedRows: 0, more: false,
    layout: [...filterLayout(false), { id: `repo:${OTHER_REPO}`, kind: 'repo', name: 'acme-prod', rows: [{ id: 'W2', depth: 0 }] }],
    rows: [row('W1', [R]), { ...row('BOX', [BOX]), remote: true }, row('W2', [R2])],
  });
  await flush();
  h.sent.length = 0;
  const first = h.actions.toggleRemoteFilter(REPO);
  const other = h.actions.toggleRemoteFilter(OTHER_REPO);
  assert.deepEqual(h.requests(), [
    ['repo.setRemoteFilter', { repoID: REPO, hidden: true }],
    ['repo.setRemoteFilter', { repoID: OTHER_REPO, hidden: true }],
  ]);
  h.sent[1]!.resolve({});
  await other;
  h.sent[0]!.resolve({});
  await first;
});

test('a layout that no longer lists the repo ends its wait', async () => {
  const h = await filterHarness();
  void h.actions.toggleRemoteFilter(REPO);
  h.actions.onEvent({ event: 'sessions.changed', seq: 12, data: { layout: [], rows: [], removedRowIDs: [] } });
  assert.deepEqual(Object.keys(h.state().ui.remoteFilterPending), []);
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
    entries: NO_ENTRIES,
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
    'onEvent', 'onChannelUp', 'onChannelDown', 'retrySubscribe', 'openSession', 'back', 'onRoute', 'navMark', 'openPending', 'openSheet',
    'closeSheet', 'openMenu', 'closeMenu', 'toast', 'clearToast', 'setShowDetails', 'setLastRow', 'toggleRepo', 'toggleRemoteFilter', 'openLink',
    'openTranscript', 'closeTranscript', 'resumeTranscriptOnUp', 'onShowDetailsChanged', 'loadOlder', 'toggleDetail',
    'answerPrompt', 'dismissPrompt', 'setDraft', 'sendMessage',
    'loadProfiles', 'switchProfile', 'fork', 'setModel', 'loadProviders', 'loadNewSheetProfiles', 'createWorktree', 'createRemote',
  ];
  for (const name of names) assert.equal(typeof (actions as unknown as Record<string, unknown>)[name], 'function', name);
});

test('every action that returns a Promise resolves, even when the laptop refuses each request', async () => {
  const actions = createActions(refusingContext());
  const pending = [
    actions.loadOlder(), actions.toggleDetail(0, 'input'), actions.answerPrompt('p1', { kind: 'permission', decision: 'allow' }, 'Allow'),
    actions.sendMessage(), actions.loadProfiles(), actions.switchProfile('P1'), actions.fork(null), actions.setModel('opus'),
    actions.loadProviders('R1'), actions.loadNewSheetProfiles('R1'), actions.createWorktree('R1', 'hi'), actions.createWorktree('R1', 'hi', 'P1'),
    actions.createRemote({ provider: 'acme-cloud', repoID: 'R1', message: 'hi', strings: {}, bools: {} }),
    actions.toggleRemoteFilter('R1'),
  ];
  await Promise.all(pending);
});
