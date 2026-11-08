// Tests transcript.ts: opening and closing the transcript, which reply counts, resuming after a
// dropped channel, and older pages. A fake client records each request and hands back a
// promise the test settles; the store and every action are real, so `openSession`, `back`,
// `setShowDetails` and `onChannelUp` reach the transcript actions as they do in the app. Two
// tests use the real client, for the order of what a channel up posts.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AppClient, AppError, SUPERSEDED_TEXT } from '../client/client.ts';
import type {
  AppEvent, Method, ParamsOf, PhoneItem, PhoneRow, PhoneSession, PhoneSessionRef, ResultOf, SessionsSubscribeResult, TranscriptPage,
} from '../protocol/types.ts';
import { applySnapshot } from '../state/sessionsData.ts';
import { createStore, initialState } from '../state/store.ts';
import type { AppState, Store } from '../state/store.ts';
import type { TranscriptState } from '../state/transcript.ts';
import { createActions } from './index.ts';
import type { Actions } from './index.ts';

const CAN = { available: true };
const R: PhoneSessionRef = { kind: 'local', terminalID: 'T-R' };
const OTHER: PhoneSessionRef = { kind: 'local', terminalID: 'T-other' };

const CHANGED_TEXT = 'The transcript changed while it was opened. Try again.';
const NOT_OPEN_TEXT = 'That transcript is not open. Open it again.';
const STALE_TEXT = 'That part of the transcript has changed. Reopen the transcript to load it again.';

function session(ref: PhoneSessionRef): PhoneSession {
  return {
    ref, agent: 'claude', tabName: 'claude', status: { chip: 'idle', changedAt: 1 },
    capabilities: { transcript: CAN, send: CAN, answer: CAN, switchProfile: CAN, fork: CAN, model: CAN },
  };
}

function row(id: string, refs: PhoneSessionRef[]): PhoneRow {
  return { id, kind: 'worktree', name: id, remote: false, statusChangedAt: 1, sessions: refs.map(session) };
}

/** A subscribe snapshot whose list shows `R` and `OTHER`, so `openSession` opens either. */
function snapshot(): SessionsSubscribeResult {
  const rows = [row('W1', [R]), row('W2', [OTHER])];
  return {
    stream: 's1', seq: 10, replayed: false, omittedRows: 0, more: false, rows,
    layout: [{ id: 'repo:R1', kind: 'repo', name: 'acme', rows: rows.map((r) => ({ id: r.id, depth: 0 })) }],
  };
}

/** A state that shows `snapshot()`'s list. */
function listed(): AppState {
  return { ...initialState(), sessions: applySnapshot(snapshot()) };
}

function item(id: string): PhoneItem {
  return { id, kind: 'assistant', text: id, truncated: false };
}

/** A page of `items`. A null cursor is a page that reached the start. */
function page(items: PhoneItem[], cursor: string | null = 'c1'): TranscriptPage {
  const p: TranscriptPage = { items, reachedStart: cursor === null, omittedItems: 0 };
  if (cursor !== null) p.cursor = cursor;
  return p;
}

function appended(items: PhoneItem[], ref: PhoneSessionRef = R): AppEvent {
  return { event: 'transcript.append', seq: 20, data: { session: ref, items } };
}

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
  const store = createStore(listed());
  const actions = createActions({ store, client, link: { openLink: () => {} }, now: () => 0 });
  const requests = () => sent.map((s): [Method, unknown] => [s.method, s.params]);
  /** The last request sent with `method`. */
  const last = (method: Method): Sent => {
    const found = sent.filter((s) => s.method === method).at(-1);
    assert.ok(found, `no ${method} was sent`);
    return found;
  };
  /** How many requests with `method` were sent. */
  const count = (method: Method): number => sent.filter((s) => s.method === method).length;
  return { sent, requests, last, count, store, actions, t: (): TranscriptState => store.get().transcript };
}

/** Lets the promise handlers run. */
function flush(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

/** Each row as its item's ID, or `receipt:<id>`. */
function ids(t: TranscriptState): string[] {
  return t.rows.map((r) => (r.kind === 'item' ? r.item.id : `receipt:${r.id}`));
}

/** A harness whose channel is up and subscribed, showing `R` with its first page `first`. */
async function showing(first: TranscriptPage = page([item('u1'), item('u2')])) {
  const h = harness();
  h.actions.onChannelUp();
  h.last('sessions.subscribe').resolve({ stream: 's1', seq: 10, replayed: true, omittedRows: 0, more: false });
  h.actions.openSession(R);
  h.last('transcript.open').resolve({ resumed: false, seq: 10, page: first });
  await flush();
  assert.equal(h.t().phase, 'open');
  return h;
}

/** The channel drops and comes back, as the real client reports it: superseding what it held, then calling `onUp`. */
function reconnect(h: ReturnType<typeof harness>, superseded: Sent[] = []): void {
  h.actions.onChannelDown();
  for (const s of superseded) s.reject(new AppError('superseded', SUPERSEDED_TEXT));
  h.actions.onChannelUp();
}

// MARK: - Opening

test('opening sends transcript.open with resume false and the Details switch', async () => {
  const h = harness();
  h.actions.openSession(R);
  assert.deepEqual(h.requests(), [['transcript.open', { session: R, showDetails: false, resume: false }]]);
  assert.equal(h.t().phase, 'opening');
  assert.deepEqual(h.t().ref, R);
  h.sent[0]!.resolve({ resumed: false, seq: 10, page: page([item('u1'), item('u2')]) });
  await flush();
  assert.equal(h.t().phase, 'open');
  assert.deepEqual(ids(h.t()), ['u1', 'u2']);
  assert.equal(h.t().cursor, 'c1');

  h.actions.setShowDetails(true);
  assert.deepEqual(h.requests()[1], ['transcript.open', { session: R, showDetails: true, resume: false }]);
  assert.equal(h.t().showDetails, true);
  // The rows stay on screen until the new page replaces them.
  assert.equal(h.t().phase, 'opening');
  assert.deepEqual(ids(h.t()), ['u1', 'u2']);
  h.sent[1]!.resolve({ resumed: false, seq: 11, page: page([item('u1'), item('th1'), item('u2')]) });
  await flush();
  assert.deepEqual(ids(h.t()), ['u1', 'th1', 'u2']);
});

test('Show details with no transcript open sends nothing', () => {
  const h = harness();
  h.actions.setShowDetails(true);
  assert.deepEqual(h.requests(), []);
});

test('a reply for an open that a later open replaced is ignored', async () => {
  const h = harness();
  h.actions.openSession(R);
  h.actions.openSession(OTHER);
  const [first, second] = h.sent;
  first!.resolve({ resumed: false, seq: 10, page: page([item('r1')]) });
  await flush();
  assert.deepEqual(h.t().ref, OTHER);
  assert.equal(h.t().phase, 'opening');
  assert.deepEqual(ids(h.t()), []);
  second!.resolve({ resumed: false, seq: 11, page: page([item('o1')]) });
  await flush();
  assert.equal(h.t().phase, 'open');
  assert.deepEqual(ids(h.t()), ['o1']);
});

test('an error for an open that a later open replaced is ignored', async () => {
  const h = harness();
  h.actions.openSession(R);
  h.actions.openSession(OTHER);
  h.sent[0]!.reject(new AppError('internal', CHANGED_TEXT));
  await flush();
  assert.equal(h.t().phase, 'opening');
  assert.equal(h.t().error, null);
  assert.equal(h.count('transcript.open'), 2);
});

test("an open that fails shows the laptop's message", async () => {
  const h = harness();
  h.actions.openSession(R);
  h.sent[0]!.reject(new AppError('unsupported', 'Only a Claude session has a transcript.'));
  await flush();
  assert.equal(h.t().phase, 'failed');
  assert.equal(h.t().error, 'Only a Claude session has a transcript.');
  assert.deepEqual(h.t().ref, R);
  assert.deepEqual(ids(h.t()), []);
  // Nothing tries again by itself.
  assert.equal(h.count('transcript.open'), 1);
});

test('a superseded open is silent and leaves the slice opening', async () => {
  const h = harness();
  h.actions.openSession(R);
  h.sent[0]!.reject(new AppError('superseded', SUPERSEDED_TEXT));
  await flush();
  assert.equal(h.t().phase, 'opening');
  assert.equal(h.t().error, null);
});

test('events that come while the transcript opens again are dropped, and its page replaces the rows', async () => {
  const h = await showing();
  h.actions.setShowDetails(true);
  const before = h.t();
  h.actions.onEvent(appended([item('u3')]));
  assert.equal(h.t(), before);
  h.last('transcript.open').resolve({ resumed: false, seq: 21, page: page([item('u2'), item('u3')]) });
  await flush();
  assert.deepEqual(ids(h.t()), ['u2', 'u3']);
});

// MARK: - Resuming

test('channel up resumes the open transcript and keeps its rows when resumed', async () => {
  const h = await showing();
  const keys = h.t().rows.map((r) => r.key);
  reconnect(h);
  // In onUp's turn: the subscribe, then the resume, without waiting for either.
  assert.deepEqual(h.requests().slice(-2), [
    ['sessions.subscribe', {}],
    ['transcript.open', { session: R, showDetails: false, resume: true }],
  ]);
  assert.equal(h.t().phase, 'open');
  h.last('sessions.subscribe').resolve({ stream: 's1', seq: 25, replayed: true, omittedRows: 0, more: false });
  // The replay comes before the resume's reply, and lands on the rows it keeps.
  h.actions.onEvent(appended([item('u3')]));
  h.last('transcript.open').resolve({ resumed: true, seq: 25 });
  await flush();
  assert.equal(h.t().phase, 'open');
  assert.deepEqual(ids(h.t()), ['u1', 'u2', 'u3']);
  assert.deepEqual(h.t().rows.slice(0, 2).map((r) => r.key), keys);
  assert.equal(h.t().cursor, 'c1');
});

test('a resume answered with a page replaces the rows', async () => {
  const h = await showing();
  reconnect(h);
  h.last('transcript.open').resolve({ resumed: false, seq: 30, page: page([item('n1')], 'c7') });
  await flush();
  assert.equal(h.t().phase, 'open');
  assert.deepEqual(ids(h.t()), ['n1']);
  assert.equal(h.t().cursor, 'c7');
});

test('a resume keeps the Details setting its open was sent with', async () => {
  const h = harness();
  h.actions.setShowDetails(true);
  h.actions.openSession(R);
  h.sent[0]!.resolve({ resumed: false, seq: 10, page: page([item('u1')]) });
  await flush();
  reconnect(h);
  assert.deepEqual(h.last('transcript.open').params, { session: R, showDetails: true, resume: true });
});

test('an open the channel dropped before its reply goes out again fresh on the next up', async () => {
  const h = harness();
  h.actions.openSession(R);
  reconnect(h, [h.sent[0]!]);
  // The phone holds no page of it, so there is nothing to resume.
  assert.deepEqual(h.requests().slice(-2), [
    ['sessions.subscribe', {}],
    ['transcript.open', { session: R, showDetails: false, resume: false }],
  ]);
  await flush();
  assert.equal(h.t().phase, 'opening');
  h.last('transcript.open').resolve({ resumed: false, seq: 10, page: page([item('u1')]) });
  await flush();
  assert.deepEqual(ids(h.t()), ['u1']);
});

test('a failed open is tried again, fresh, on the next up', async () => {
  const h = harness();
  h.actions.openSession(R);
  h.sent[0]!.reject(new AppError('unavailable', 'The remote session did not load. Try again later.'));
  await flush();
  reconnect(h);
  assert.deepEqual(h.last('transcript.open').params, { session: R, showDetails: false, resume: false });
  assert.equal(h.t().phase, 'opening');
  assert.equal(h.t().error, null);
});

test('a resume the laptop refuses opens again from the tail, once', async () => {
  const h = await showing();
  reconnect(h);
  h.last('transcript.open').reject(new AppError('internal', CHANGED_TEXT));
  await flush();
  assert.equal(h.count('transcript.open'), 3);
  assert.deepEqual(h.last('transcript.open').params, { session: R, showDetails: false, resume: false });
  // The fresh open's own failure shows, and nothing more is sent.
  h.last('transcript.open').reject(new AppError('not_found', 'That session is not on the laptop.'));
  await flush();
  assert.equal(h.count('transcript.open'), 3);
  assert.equal(h.t().phase, 'failed');
  assert.equal(h.t().error, 'That session is not on the laptop.');
});

test('a resume superseded by another drop is silent, and the next up resumes again', async () => {
  const h = await showing();
  reconnect(h);
  reconnect(h, [h.last('transcript.open')]);
  await flush();
  assert.equal(h.count('transcript.open'), 3);
  assert.deepEqual(h.last('transcript.open').params, { session: R, showDetails: false, resume: true });
  assert.deepEqual(ids(h.t()), ['u1', 'u2']);
});

test('an older page on its way across a drop lands when the resume keeps the feed', async () => {
  const h = await showing();
  const pending = h.actions.loadOlder();
  const older = h.last('transcript.page');
  // The client sends a read again after a drop, so the page is still on its way.
  reconnect(h);
  h.last('transcript.open').resolve({ resumed: true, seq: 25 });
  await flush();
  older.resolve(page([item('u0')], 'c0'));
  await pending;
  assert.deepEqual(ids(h.t()), ['u0', 'u1', 'u2']);
  assert.equal(h.t().cursor, 'c0');
});

test('an older page on its way across a drop changes nothing once the resume brings a page', async () => {
  const h = await showing();
  const pending = h.actions.loadOlder();
  const older = h.last('transcript.page');
  reconnect(h);
  h.last('transcript.open').resolve({ resumed: false, seq: 30, page: page([item('n1')], 'c7') });
  await flush();
  older.resolve(page([item('u0')], 'c0'));
  await pending;
  assert.deepEqual(ids(h.t()), ['n1']);
  assert.equal(h.t().cursor, 'c7');
});

test('channel up with no transcript open sends no transcript request', () => {
  const h = harness();
  h.actions.onChannelUp();
  assert.deepEqual(h.requests(), [['sessions.subscribe', {}]]);
});

// MARK: - Older pages

test('an older page goes above the rows, asked for with the cursor', async () => {
  const h = await showing();
  const pending = h.actions.loadOlder();
  assert.deepEqual(h.last('transcript.page').params, { session: R, cursor: 'c1' });
  assert.equal(h.t().loadingOlder, true);
  h.last('transcript.page').resolve(page([item('u0')], 'c0'));
  await pending;
  assert.deepEqual(ids(h.t()), ['u0', 'u1', 'u2']);
  assert.equal(h.t().cursor, 'c0');
  assert.equal(h.t().loadingOlder, false);
});

test('only one older page is asked for at a time', async () => {
  const h = await showing();
  const first = h.actions.loadOlder();
  await h.actions.loadOlder();
  assert.equal(h.count('transcript.page'), 1);
  h.last('transcript.page').resolve(page([item('u0')], 'c0'));
  await first;
  const second = h.actions.loadOlder();
  assert.equal(h.count('transcript.page'), 2);
  assert.deepEqual(h.last('transcript.page').params, { session: R, cursor: 'c0' });
  h.last('transcript.page').resolve(page([item('u-1')], 'c-1'));
  await second;
  assert.deepEqual(ids(h.t()), ['u-1', 'u0', 'u1', 'u2']);
});

test('a page that reached the start ends the scroll back', async () => {
  const h = await showing();
  const pending = h.actions.loadOlder();
  h.last('transcript.page').resolve(page([item('u0')], null));
  await pending;
  assert.equal(h.t().reachedStart, true);
  assert.equal(h.t().cursor, null);
  await h.actions.loadOlder();
  assert.equal(h.count('transcript.page'), 1);
});

test('a first page that reached the start asks for nothing older', async () => {
  const h = await showing(page([item('u1')], null));
  await h.actions.loadOlder();
  assert.equal(h.count('transcript.page'), 0);
});

test('stale_cursor on an older page reopens from the tail', async () => {
  for (const [code, message] of [['stale_cursor', STALE_TEXT], ['not_open', NOT_OPEN_TEXT]] as const) {
    const h = await showing();
    const pending = h.actions.loadOlder();
    h.last('transcript.page').reject(new AppError(code, message));
    await pending;
    assert.equal(h.count('transcript.open'), 2, code);
    assert.deepEqual(h.last('transcript.open').params, { session: R, showDetails: false, resume: false });
    assert.equal(h.t().phase, 'opening');
    assert.equal(h.t().olderFailed, false);
    assert.equal(h.t().error, null);
    // The rows stay until the new page replaces them.
    assert.deepEqual(ids(h.t()), ['u1', 'u2']);
    h.last('transcript.open').resolve({ resumed: false, seq: 30, page: page([item('u2'), item('u3')], 'c5') });
    await flush();
    assert.deepEqual(ids(h.t()), ['u2', 'u3']);
    assert.equal(h.t().cursor, 'c5');
  }
});

test('a failed older page is not asked for again until the next scroll', async () => {
  const h = await showing();
  const pending = h.actions.loadOlder();
  h.last('transcript.page').reject(new AppError('unavailable', 'The remote provider refused this. Check the laptop.'));
  await pending;
  assert.equal(h.t().loadingOlder, false);
  assert.equal(h.t().olderFailed, true);
  assert.equal(h.t().error, null);
  assert.equal(h.t().phase, 'open');
  assert.deepEqual(ids(h.t()), ['u1', 'u2']);
  await h.actions.loadOlder();
  await h.actions.loadOlder();
  assert.equal(h.count('transcript.page'), 1);
  // The reader scrolls.
  h.actions.clearOlderFailed();
  assert.equal(h.t().olderFailed, false);
  void h.actions.loadOlder();
  assert.equal(h.count('transcript.page'), 2);
});

test('clearOlderFailed with nothing failed changes nothing', async () => {
  const h = await showing();
  const before = h.store.get();
  h.actions.clearOlderFailed();
  assert.equal(h.store.get(), before);
});

/** The slice as the list draws it and pages it, without `stalePage`, which a stale page's settling clears. */
function withoutStale(t: TranscriptState): Omit<TranscriptState, 'stalePage'> {
  const { stalePage: _, ...rest } = t;
  return rest;
}

test('an older page that lands after a newer open replaced the transcript adds no row, and then frees the turn', async () => {
  const h = await showing();
  const pending = h.actions.loadOlder();
  const stale = h.last('transcript.page');
  h.actions.setShowDetails(true);
  h.last('transcript.open').resolve({ resumed: false, seq: 30, page: page([item('n1'), item('n2')], 'c8') });
  await flush();
  // The page still on its way holds the turn: no second transcript.page goes out beside it.
  assert.equal(h.t().stalePage, true);
  await h.actions.loadOlder();
  assert.equal(h.count('transcript.page'), 1);
  const before = h.t();
  stale.resolve(page([item('u0')], 'c0'));
  await pending;
  assert.deepEqual(withoutStale(h.t()), withoutStale(before));
  assert.deepEqual(ids(h.t()), ['n1', 'n2']);
  // Its settling is a change the list sees, so it can ask again, once, with the new cursor.
  assert.equal(h.t().stalePage, false);
  void h.actions.loadOlder();
  void h.actions.loadOlder();
  assert.equal(h.count('transcript.page'), 2);
  assert.deepEqual(h.last('transcript.page').params, { session: R, cursor: 'c8' });
});

test('an older page that fails after a reset adds no row and reopens nothing, and then frees the turn', async () => {
  const h = await showing();
  const pending = h.actions.loadOlder();
  h.actions.onEvent({ event: 'transcript.reset', seq: 21, data: { session: R, reason: 'rewrite', page: page([item('n1')], 'c9') } });
  const before = h.t();
  assert.equal(before.stalePage, true);
  h.last('transcript.page').reject(new AppError('stale_cursor', STALE_TEXT));
  await pending;
  assert.deepEqual(withoutStale(h.t()), withoutStale(before));
  assert.equal(h.t().stalePage, false);
  assert.equal(h.count('transcript.open'), 1);
  void h.actions.loadOlder();
  assert.deepEqual(h.last('transcript.page').params, { session: R, cursor: 'c9' });
});

test('a superseded older page does not touch the slice a newer open made, but frees the turn', async () => {
  const h = await showing();
  const pending = h.actions.loadOlder();
  const stale = h.last('transcript.page');
  h.actions.openSession(OTHER);
  const before = h.t();
  assert.equal(before.stalePage, true);
  stale.reject(new AppError('superseded', SUPERSEDED_TEXT));
  await pending;
  assert.deepEqual(withoutStale(h.t()), withoutStale(before));
  assert.equal(h.t().stalePage, false);
  assert.deepEqual(h.t().ref, OTHER);
});

test('a page made stale by a close still holds the turn for the next transcript until it settles', async () => {
  const h = await showing();
  const pending = h.actions.loadOlder();
  const stale = h.last('transcript.page');
  h.actions.back();
  assert.equal(h.t().stalePage, true);
  h.actions.openSession(OTHER);
  h.last('transcript.open').resolve({ resumed: false, seq: 30, page: page([item('o1')], 'c3') });
  await flush();
  assert.equal(h.t().stalePage, true);
  await h.actions.loadOlder();
  assert.equal(h.count('transcript.page'), 1);
  stale.resolve(page([item('u0')], 'c0'));
  await pending;
  assert.deepEqual(ids(h.t()), ['o1']);
  void h.actions.loadOlder();
  assert.deepEqual(h.last('transcript.page').params, { session: OTHER, cursor: 'c3' });
});

test('a page whose own stale_cursor reopens the transcript does not hold the turn after it', async () => {
  const h = await showing();
  const pending = h.actions.loadOlder();
  h.last('transcript.page').reject(new AppError('stale_cursor', STALE_TEXT));
  await pending;
  assert.equal(h.t().stalePage, false);
  h.last('transcript.open').resolve({ resumed: false, seq: 30, page: page([item('u2')], 'c5') });
  await flush();
  void h.actions.loadOlder();
  assert.equal(h.count('transcript.page'), 2);
  assert.deepEqual(h.last('transcript.page').params, { session: R, cursor: 'c5' });
});

test('an older page that the slice still waits for and is superseded ends the wait without a failure', async () => {
  const h = await showing();
  const pending = h.actions.loadOlder();
  h.last('transcript.page').reject(new AppError('superseded', SUPERSEDED_TEXT));
  await pending;
  assert.equal(h.t().loadingOlder, false);
  assert.equal(h.t().olderFailed, false);
  void h.actions.loadOlder();
  assert.equal(h.count('transcript.page'), 2);
});

test('older pages wait while the transcript opens, and need one open', async () => {
  const idle = harness();
  await idle.actions.loadOlder();
  assert.equal(idle.count('transcript.page'), 0);
  const h = await showing();
  h.actions.setShowDetails(true);
  await h.actions.loadOlder();
  assert.equal(h.count('transcript.page'), 0);
});

// MARK: - Closing

test('leaving the session sends transcript.close {}', async () => {
  const h = await showing();
  h.actions.back();
  assert.deepEqual(h.requests().at(-1), ['transcript.close', {}]);
  assert.equal(h.t().ref, null);
  assert.equal(h.t().phase, 'idle');
  assert.deepEqual(h.t().rows, []);
  assert.equal(h.t().pendingClose, true);
  h.last('transcript.close').resolve({});
  await flush();
  assert.equal(h.t().pendingClose, false);
  // Nothing more goes out on the next up.
  reconnect(h);
  assert.deepEqual(h.requests().at(-1), ['sessions.subscribe', {}]);
});

test("an open's reply that lands after the close changes nothing", async () => {
  const h = harness();
  h.actions.openSession(R);
  h.actions.back();
  const before = h.t();
  h.sent[0]!.resolve({ resumed: false, seq: 10, page: page([item('u1')]) });
  await flush();
  assert.equal(h.t(), before);
});

test('closing with no transcript open sends nothing', () => {
  const h = harness();
  h.actions.closeTranscript();
  assert.deepEqual(h.requests(), []);
});

test('a close lost to a dropped channel is sent again on the next up, after the subscribe', async () => {
  const h = await showing();
  h.actions.back();
  const lost = h.last('transcript.close');
  reconnect(h, [lost]);
  assert.deepEqual(h.requests().slice(-2), [['sessions.subscribe', {}], ['transcript.close', {}]]);
  assert.equal(h.count('transcript.close'), 2);
  await flush();
  // The lost close's rejection does not end the wait for the fresh one.
  assert.equal(h.t().pendingClose, true);
  h.last('transcript.close').resolve({});
  await flush();
  assert.equal(h.t().pendingClose, false);
});

test('a close the laptop answered with an error is not sent again', async () => {
  const h = await showing();
  h.actions.back();
  h.last('transcript.close').reject(new AppError('internal', 'Something went wrong on the laptop.'));
  await flush();
  assert.equal(h.t().pendingClose, false);
  reconnect(h);
  assert.equal(h.count('transcript.close'), 1);
});

test('the reply to an earlier close does not end the wait for a later one', async () => {
  const h = await showing();
  h.actions.back();
  const firstClose = h.last('transcript.close');
  h.actions.openSession(R);
  h.actions.back();
  firstClose.resolve({});
  await flush();
  assert.equal(h.t().pendingClose, true);
  h.last('transcript.close').resolve({});
  await flush();
  assert.equal(h.t().pendingClose, false);
});

test('an open after a lost close replaces it, so the next up opens and does not close', async () => {
  const h = await showing();
  h.actions.back();
  const lost = h.last('transcript.close');
  h.actions.onChannelDown();
  h.actions.openSession(OTHER);
  const opening = h.last('transcript.open');
  reconnect(h, [lost, opening]);
  assert.deepEqual(h.requests().slice(-2), [
    ['sessions.subscribe', {}],
    ['transcript.open', { session: OTHER, showDetails: false, resume: false }],
  ]);
  assert.equal(h.count('transcript.close'), 1);
});

// MARK: - With the real client

/** The real client, wired to the actions as `main.tsx` wires them, posting into `posted`. */
function wired(): { client: AppClient; posted: Array<Record<string, unknown>>; store: Store; actions: Actions } {
  const posted: Array<Record<string, unknown>> = [];
  const store = createStore();
  let actions: Actions | null = null;
  let n = 0;
  const client = new AppClient({
    post: (body) => { posted.push(body); },
    onEvent: (event) => actions!.onEvent(event),
    onUp: () => actions!.onChannelUp(),
    onDown: () => actions!.onChannelDown(),
    now: () => 0,
    newID: () => `r${++n}`,
  });
  actions = createActions({ store, client, link: { openLink: () => {} }, now: () => 0 });
  return { client, posted, store, actions };
}

function replyTo(client: AppClient, body: Record<string, unknown> | undefined, result: unknown): void {
  assert.ok(body, 'no request to answer');
  client.handle({ t: 'app', body: { kind: 'reply', requestID: body.requestID, result } });
}

function methods(posted: Array<Record<string, unknown>>): unknown[] {
  return posted.map((b) => b.method);
}

test('with the real client, a channel up posts the subscribe, then the resume, then the resent page', async () => {
  const { client, posted, actions } = wired();
  client.handle({ t: 'channel', up: true });
  replyTo(client, posted[0], snapshot());
  await flush();
  actions.openSession(R);
  replyTo(client, posted[1], { resumed: false, seq: 10, page: page([item('u1')]) });
  await flush();
  void actions.loadOlder();
  const page1 = posted[2]!;
  assert.equal(page1.method, 'transcript.page');
  client.handle({ t: 'channel', up: false });
  posted.length = 0;
  client.handle({ t: 'channel', up: true });
  // All in the channel up's turn, the resume ahead of the client's resend.
  assert.deepEqual(methods(posted), ['sessions.subscribe', 'transcript.open', 'transcript.page']);
  assert.deepEqual((posted[1]!.params as Record<string, unknown>).resume, true);
  assert.equal(posted[2], page1);
});

test('with the real client, a close the channel dropped goes out again under a new ID', async () => {
  const { client, posted, actions } = wired();
  client.handle({ t: 'channel', up: true });
  replyTo(client, posted[0], snapshot());
  await flush();
  actions.openSession(R);
  actions.back();
  const lost = posted.at(-1)!;
  assert.equal(lost.method, 'transcript.close');
  client.handle({ t: 'channel', up: false });
  posted.length = 0;
  client.handle({ t: 'channel', up: true });
  assert.deepEqual(methods(posted), ['sessions.subscribe', 'transcript.close']);
  assert.notEqual(posted[1]!.requestID, lost.requestID);
});
