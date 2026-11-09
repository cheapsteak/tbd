// Tests sheets.ts: loading the profiles, switching a session's account, forking it, and changing
// its model. A fake client records each request and hands back a promise the test settles; the
// store and every action are real, so the route moves through `openSession` and `back`, the list
// changes through `onEvent`, and a fork's new tab opens through `openPending` as in the app.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AppError, NOT_CONFIRMED_TEXT, SUPERSEDED_TEXT } from '../client/client.ts';
import type {
  Method, ParamsOf, PhoneCapability, PhoneProfile, PhoneRow, PhoneSession, PhoneSessionRef, ResultOf, SessionsSubscribeResult,
} from '../protocol/types.ts';
import { refKey } from '../protocol/wire.ts';
import { applySnapshot } from '../state/sessionsData.ts';
import {
  currentProfileID, forkOrder, isActing, kindWords, profileDetail, restartNote,
} from '../state/sheets.ts';
import { createStore, initialState } from '../state/store.ts';
import type { AppState, SheetState } from '../state/store.ts';
import { createActions } from './index.ts';

const CAN: PhoneCapability = { available: true };
const R: PhoneSessionRef = { kind: 'local', terminalID: 'T-R' };
const OTHER: PhoneSessionRef = { kind: 'local', terminalID: 'T-other' };
const REFUSED = 'The laptop refused the switch.';

const PERSONAL: PhoneProfile = { id: 'P-personal', name: 'Personal', kind: 'oauth', isDefault: true };
const WORK: PhoneProfile = { id: 'P-work', name: 'acme-work', kind: 'oauth', isDefault: false };
const BEDROCK: PhoneProfile = { id: 'P-bedrock', name: 'acme-bedrock', kind: 'bedrock', isDefault: false };
const PROFILES = [PERSONAL, WORK, BEDROCK];

function session(ref: PhoneSessionRef, extra: Partial<PhoneSession> = {}): PhoneSession {
  return {
    ref, agent: 'claude', tabName: 'Claude', status: { chip: 'idle', changedAt: 1 }, profileID: WORK.id, profileName: WORK.name, model: 'opus',
    capabilities: { transcript: CAN, send: CAN, answer: CAN, switchProfile: CAN, fork: CAN, model: CAN },
    ...extra,
  };
}

function snapshot(sessions: PhoneSession[] = [session(R)]): SessionsSubscribeResult {
  const rows: PhoneRow[] = [
    { id: 'W1', kind: 'worktree', name: 'Checkout v2', remote: false, statusChangedAt: 1, sessions },
    { id: 'W2', kind: 'worktree', name: 'W2', remote: false, statusChangedAt: 1, sessions: [session(OTHER)] },
  ];
  return {
    stream: 's1', seq: 10, replayed: false, omittedRows: 0, more: false, rows,
    layout: [{ id: 'repo:R1', kind: 'repo', name: 'acme', rows: rows.map((r) => ({ id: r.id, depth: 0 })) }],
  };
}

interface Sent {
  method: Method;
  params: unknown;
  resolve(result: unknown): void;
  reject(error: unknown): void;
}

/** A harness on `R`'s session, with `profiles` loaded unless it is null. */
async function harness(options: { sessions?: PhoneSession[]; profiles?: PhoneProfile[] | null } = {}) {
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
  const store = createStore({ ...initialState(), sessions: applySnapshot(snapshot(options.sessions)) });
  const actions = createActions({ store, client, link: { openLink: () => {} }, now: () => 0 });
  const of = (method: Method): Sent[] => sent.filter((s) => s.method === method);
  const last = (method: Method): Sent => {
    const found = of(method).at(-1);
    assert.ok(found, `no ${method} was sent`);
    return found;
  };
  const state = (): AppState => store.get();
  const acting = (): Sent[] => sent.filter((s) => s.method === 'session.switchProfile' || s.method === 'session.fork' || s.method === 'session.setModel');
  const refusal = (ref: PhoneSessionRef = R): string | undefined => {
    const r = store.get().ui.refusal;
    return Object.hasOwn(r, refKey(ref)) ? r[refKey(ref)] : undefined;
  };
  let seq = 20;
  const listed = (rows: PhoneRow[]): void => {
    actions.onEvent({ event: 'sessions.changed', seq: seq++, data: { rows, removedRowIDs: [] } });
  };
  actions.openSession(R);
  const profiles = options.profiles === undefined ? PROFILES : options.profiles;
  if (profiles !== null) {
    const loading = actions.loadProfiles();
    last('profiles.list').resolve({ profiles });
    await loading;
  }
  return { sent, of, last, acting, store, actions, state, refusal, listed };
}

/** Lets the promise handlers run. */
function flush(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

// MARK: - Profiles

test('loadProfiles shows loading at once, then the laptop\'s profiles in its order', async () => {
  const h = await harness({ profiles: null });
  const pending = h.actions.loadProfiles();
  assert.deepEqual(h.last('profiles.list').params, {});
  assert.equal(h.state().sheets.profiles.phase, 'loading');
  h.last('profiles.list').resolve({ profiles: PROFILES });
  await pending;
  assert.deepEqual(h.state().sheets.profiles, { phase: 'loaded', profiles: PROFILES });
});

test('a failed load shows its message, and only the newest load lands', async () => {
  const h = await harness({ profiles: null });
  const first = h.actions.loadProfiles();
  const second = h.actions.loadProfiles();
  const [a, b] = h.of('profiles.list');
  b!.reject(new AppError('internal', 'TBD could not read its profiles.'));
  await second;
  assert.deepEqual(h.state().sheets.profiles, { phase: 'failed', message: 'TBD could not read its profiles.' });
  // The older load's late reply changes nothing.
  a!.resolve({ profiles: PROFILES });
  await first;
  assert.deepEqual(h.state().sheets.profiles, { phase: 'failed', message: 'TBD could not read its profiles.' });
});

test('a superseded load changes nothing', async () => {
  const h = await harness({ profiles: null });
  const pending = h.actions.loadProfiles();
  h.last('profiles.list').reject(new AppError('superseded', SUPERSEDED_TEXT));
  await pending;
  assert.equal(h.state().sheets.profiles.phase, 'loading');
});

// MARK: - Switch

test('a switch sends session.switchProfile once with the picked profile, and toasts only after the reply', async () => {
  const h = await harness();
  h.actions.openMenu({ name: 'account', askProfileID: PERSONAL.id });
  const pending = h.actions.switchProfile(PERSONAL.id, R);
  // A second call while the first is on its way sends nothing.
  await h.actions.switchProfile(PERSONAL.id, R);
  assert.deepEqual(h.acting().map((s) => [s.method, s.params]), [['session.switchProfile', { session: R, profileID: PERSONAL.id }]]);
  assert.equal(isActing(h.state().sheets, R), true);
  assert.equal(h.state().ui.toast, null);
  assert.notEqual(h.state().ui.menu, null);
  h.last('session.switchProfile').resolve({ session: R });
  await pending;
  assert.equal(isActing(h.state().sheets, R), false);
  assert.equal(h.state().ui.toast?.text, 'Restarted under Personal');
  assert.equal(h.state().ui.menu, null);
});

test('a switch to the current profile, or to one the list did not show, sends nothing', async () => {
  const h = await harness();
  await h.actions.switchProfile(WORK.id, R);
  await h.actions.switchProfile('P-gone', R);
  assert.deepEqual(h.acting(), []);
  const noList = await harness({ profiles: null });
  await noList.actions.switchProfile(PERSONAL.id, R);
  assert.deepEqual(noList.acting(), []);
});

test('a refused switch shows in the composer and keeps the menu open; a later one may go out', async () => {
  const h = await harness();
  h.actions.openMenu({ name: 'account', askProfileID: PERSONAL.id });
  const pending = h.actions.switchProfile(PERSONAL.id, R);
  h.last('session.switchProfile').reject(new AppError('refused', REFUSED));
  await pending;
  assert.equal(h.refusal(), REFUSED);
  assert.deepEqual(h.state().ui.menu, { name: 'account', askProfileID: PERSONAL.id });
  assert.equal(h.state().ui.toast, null);
  assert.equal(h.state().sheets.failed, null);
  const again = h.actions.switchProfile(PERSONAL.id, R);
  assert.equal(h.of('session.switchProfile').length, 2);
  h.last('session.switchProfile').resolve({ session: R });
  await again;
});

test('a switch refused while a sheet is open shows in that sheet and in the composer', async () => {
  const h = await harness();
  h.actions.openSheet({ name: 'switch-confirm', profileID: PERSONAL.id });
  const sheet = h.state().ui.sheet;
  const pending = h.actions.switchProfile(PERSONAL.id, R);
  h.last('session.switchProfile').reject(new AppError('not_confirmed', NOT_CONFIRMED_TEXT));
  await pending;
  assert.equal(h.state().ui.sheet, sheet);
  assert.deepEqual(h.state().sheets.failed, { sheet, text: NOT_CONFIRMED_TEXT });
  assert.equal(h.refusal(), NOT_CONFIRMED_TEXT);
});

test('a switch that succeeds closes the sheet it came from, but not one opened since', async () => {
  const h = await harness();
  h.actions.openSheet({ name: 'switch-confirm', profileID: PERSONAL.id });
  const pending = h.actions.switchProfile(PERSONAL.id, R);
  h.actions.openSheet({ name: 'switch' });
  const since = h.state().ui.sheet;
  h.last('session.switchProfile').resolve({ session: R });
  await pending;
  assert.equal(h.state().ui.sheet, since);
  assert.equal(h.state().ui.toast?.text, 'Restarted under Personal');
});

// MARK: - The target

test('nothing goes out for a session other than the one the route shows', async () => {
  const h = await harness();
  await h.actions.switchProfile(PERSONAL.id, OTHER);
  await h.actions.fork(null, OTHER);
  await h.actions.setModel('sonnet', OTHER);
  assert.deepEqual(h.acting(), []);
  // Nor once the route has moved on: the sheet still on screen names the session it showed.
  h.actions.back();
  await h.actions.fork(PERSONAL.id, R);
  await h.actions.setModel('sonnet', R);
  assert.deepEqual(h.acting(), []);
});

test('nothing goes out for a session the list no longer shows, or whose capability is unavailable', async () => {
  const off: PhoneCapability = { available: false, reason: 'Not available for remote sessions.' };
  const h = await harness({ sessions: [session(R, { capabilities: { ...session(R).capabilities, switchProfile: off, fork: off, model: off } })] });
  await h.actions.switchProfile(PERSONAL.id, R);
  await h.actions.fork(null, R);
  await h.actions.setModel('sonnet', R);
  assert.deepEqual(h.acting(), []);
});

test('one acting request per session at a time, whichever of the three', async () => {
  const h = await harness();
  const pending = h.actions.setModel('sonnet', R);
  await h.actions.switchProfile(PERSONAL.id, R);
  await h.actions.fork(null, R);
  await h.actions.setModel('haiku', R);
  assert.deepEqual(h.acting().map((s) => s.method), ['session.setModel']);
  h.last('session.setModel').reject(new AppError('internal', 'TBD could not send /model.'));
  await pending;
  assert.equal(isActing(h.state().sheets, R), false);
});

// MARK: - Fork

test('fork(null) sends no profileID, and toasts under the session\'s own account', async () => {
  const h = await harness();
  const pending = h.actions.fork(null, R);
  await h.actions.fork(null, R);
  assert.deepEqual(h.acting().map((s) => s.params), [{ session: R }]);
  assert.equal(Object.hasOwn(h.last('session.fork').params as object, 'profileID'), false);
  h.last('session.fork').resolve({ session: { kind: 'local', terminalID: 'T-new' } });
  await pending;
  assert.equal(h.state().ui.toast?.text, 'Forked into a new tab, under acme-work');
});

test('fork(null) on a session with no profile toasts "Default account"', async () => {
  const h = await harness({ sessions: [session(R, { profileID: undefined, profileName: undefined })] });
  const pending = h.actions.fork(null, R);
  h.last('session.fork').resolve({ session: { kind: 'local', terminalID: 'T-new' } });
  await pending;
  assert.equal(h.state().ui.toast?.text, 'Forked into a new tab, under Default account');
});

test('a fork under a profile sends its ID, and the new tab opens only once the list shows it', async () => {
  const h = await harness();
  const made: PhoneSessionRef = { kind: 'local', terminalID: 'T-new' };
  h.actions.openSheet({ name: 'fork' });
  const pending = h.actions.fork(PERSONAL.id, R);
  assert.deepEqual(h.last('session.fork').params, { session: R, profileID: PERSONAL.id });
  h.last('session.fork').resolve({ session: made });
  await pending;
  assert.equal(h.state().ui.toast?.text, 'Forked into a new tab, under Personal');
  assert.equal(h.state().ui.sheet, null);
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: R });
  assert.deepEqual(h.state().ui.pendingOpen, { ref: made });
  h.listed([{ id: 'W1', kind: 'worktree', name: 'Checkout v2', remote: false, statusChangedAt: 2, sessions: [session(R), session(made)] }]);
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: made });
  assert.deepEqual(h.last('transcript.open').params, { session: made, showDetails: false, resume: false });
});

test('a fork the user navigated away from while it was on its way opens nothing', async () => {
  const h = await harness();
  const made: PhoneSessionRef = { kind: 'local', terminalID: 'T-new' };
  const pending = h.actions.fork(PERSONAL.id, R);
  h.actions.back();
  h.listed([{ id: 'W1', kind: 'worktree', name: 'Checkout v2', remote: false, statusChangedAt: 2, sessions: [session(R), session(made)] }]);
  h.last('session.fork').resolve({ session: made });
  await pending;
  assert.deepEqual(h.state().ui.route, { screen: 'sessions' });
  assert.equal(h.state().ui.pendingOpen, null);
});

test("a fork's error shows in the sheet open over the session, else in the composer", async () => {
  const h = await harness();
  h.actions.openSheet({ name: 'fork' });
  const sheet = h.state().ui.sheet as SheetState;
  let pending = h.actions.fork(BEDROCK.id, R);
  h.last('session.fork').reject(new AppError('refused', 'This session is parked. Send it a message to wake it, then fork it.'));
  await pending;
  assert.deepEqual(h.state().sheets.failed, { sheet, text: 'This session is parked. Send it a message to wake it, then fork it.' });
  assert.equal(h.refusal(), undefined);
  assert.equal(h.state().ui.sheet, sheet);
  // The sheet closed meanwhile: the composer shows it.
  pending = h.actions.fork(BEDROCK.id, R);
  assert.equal(h.state().sheets.failed, null);
  h.actions.closeSheet();
  h.last('session.fork').reject(new AppError('not_confirmed', NOT_CONFIRMED_TEXT));
  await pending;
  assert.equal(h.refusal(), NOT_CONFIRMED_TEXT);
  assert.equal(h.state().sheets.failed, null);
});

test('a superseded failure shows nothing and clears the mark', async () => {
  const h = await harness();
  const pending = h.actions.fork(null, R);
  h.last('session.fork').reject(new AppError('superseded', SUPERSEDED_TEXT));
  await pending;
  assert.equal(h.refusal(), undefined);
  assert.equal(isActing(h.state().sheets, R), false);
});

test('an error that is no AppError shows the client\'s words', async () => {
  const h = await harness();
  const pending = h.actions.setModel('sonnet', R);
  h.last('session.setModel').reject(new TypeError('boom'));
  await pending;
  assert.equal(h.refusal(), "The request's params are not valid.");
});

// MARK: - Model

test('setModel sends the name trimmed, toasts after the reply, and goes out while the session works', async () => {
  const h = await harness({ sessions: [session(R, { status: { chip: 'working', changedAt: 1 } })] });
  h.actions.openMenu({ name: 'model' });
  const pending = h.actions.setModel('  claude-opus-5-5\n', R);
  assert.deepEqual(h.last('session.setModel').params, { session: R, model: 'claude-opus-5-5' });
  assert.equal(h.state().ui.toast, null);
  h.last('session.setModel').resolve({ outcome: 'sent' });
  await pending;
  assert.equal(h.state().ui.toast?.text, 'Model set to claude-opus-5-5');
  assert.equal(h.state().ui.menu, null);
});

test('a blank model name sends nothing', async () => {
  const h = await harness();
  await h.actions.setModel(' \t ', R);
  assert.deepEqual(h.acting(), []);
});

test('a refused model change goes to the composer', async () => {
  const h = await harness();
  h.actions.openMenu({ name: 'model' });
  const pending = h.actions.setModel('opus-9', R);
  h.last('session.setModel').reject(new AppError('bad_request', 'That is not a model name.'));
  await pending;
  assert.equal(h.refusal(), 'That is not a model name.');
  assert.deepEqual(h.state().ui.menu, { name: 'model' });
});

test('every action resolves while the laptop refuses everything', async () => {
  const h = await harness();
  const pending = [h.actions.loadProfiles(), h.actions.switchProfile(PERSONAL.id, R)];
  for (const s of h.sent) s.reject(new AppError('internal', 'no'));
  await Promise.all(pending);
  await flush();
});

// MARK: - Shared rules

test('the current profile is the session\'s, or the default when it has none', () => {
  assert.equal(currentProfileID(session(R), PROFILES), WORK.id);
  assert.equal(currentProfileID(session(R, { profileID: undefined }), PROFILES), PERSONAL.id);
  assert.equal(currentProfileID(session(R, { profileID: undefined }), [WORK]), null);
});

test('the Fork sheet lists the current profile first', () => {
  assert.deepEqual(forkOrder(PROFILES, WORK.id).map((p) => p.id), [WORK.id, PERSONAL.id, BEDROCK.id]);
  assert.deepEqual(forkOrder(PROFILES, null).map((p) => p.id), [PERSONAL.id, WORK.id, BEDROCK.id]);
});

test('kind words come from PROFILE_KIND_WORDS, and an unknown kind shows as sent', () => {
  assert.equal(profileDetail(PERSONAL), 'Claude subscription · default');
  assert.equal(profileDetail(BEDROCK), 'Amazon Bedrock');
  assert.equal(kindWords('vertex'), 'vertex');
  assert.equal(kindWords('constructor'), 'constructor');
});

test('the restart note says when a running turn stops', () => {
  assert.equal(restartNote(session(R, { status: { chip: 'working', changedAt: 1 } })), 'The conversation stays. The turn that is running now stops.');
  assert.equal(restartNote(session(R)), 'The conversation stays. Claude restarts in this tab.');
});
