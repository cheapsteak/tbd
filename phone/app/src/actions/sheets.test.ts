// Tests sheets.ts: loading the profiles, switching a session's account, forking it, and changing
// its model; then New: loading the providers, creating a worktree or a remote session, and the
// New sheet's form rules. A fake client records each request and hands back a promise the test settles; the
// store and every action are real, so the route moves through `openSession` and `back`, the list
// changes through `onEvent`, and a fork's new tab opens through `openPending` as in the app.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AppError, NOT_CONFIRMED_TEXT, SUPERSEDED_TEXT } from '../client/client.ts';
import type {
  Method, ParamsOf, PhoneCapability, PhoneFormField, PhoneProfile, PhoneProvider, PhoneRemoteCreateParams, PhoneRow, PhoneSession,
  PhoneSessionRef, ResultOf, SessionsSubscribeResult,
} from '../protocol/types.ts';
import { refKey } from '../protocol/wire.ts';
import { applySnapshot } from '../state/sessionsData.ts';
import {
  currentProfileID, enumChoices, fieldOn, fieldText, forkOrder, isActing, kindWords, NO_EDITS, profileDetail, providerDetail,
  remoteCreateParams, remoteParamsReady, restartNote, withFieldOn, withFieldText,
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

test('a switch to the current profile sends nothing and says why; one to a profile the list did not show sends nothing', async () => {
  const h = await harness();
  await h.actions.switchProfile('P-gone', R);
  assert.deepEqual(h.acting(), []);
  assert.equal(h.refusal(), undefined);
  await h.actions.switchProfile(WORK.id, R);
  assert.deepEqual(h.acting(), []);
  assert.equal(h.refusal(), 'This session already runs under acme-work.');
  assert.equal(isActing(h.state().sheets, R), false);
  const noList = await harness({ profiles: null });
  await noList.actions.switchProfile(PERSONAL.id, R);
  assert.deepEqual(noList.acting(), []);
  assert.equal(noList.refusal(), undefined);
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

test('nothing goes out for a session the list no longer shows, and nothing is said', async () => {
  const h = await harness();
  h.actions.onEvent({ event: 'sessions.changed', seq: 30, data: { rows: [], removedRowIDs: ['W1'] } });
  await h.actions.switchProfile(PERSONAL.id, R);
  await h.actions.fork(null, R);
  await h.actions.fork(PERSONAL.id, R);
  await h.actions.setModel('sonnet', R);
  assert.deepEqual(h.acting(), []);
  assert.equal(h.refusal(), undefined);
  assert.equal(h.state().sheets.failed, null);
});

test('a fork under a profile the loaded list does not hold, or with no list loaded, sends nothing', async () => {
  const h = await harness();
  await h.actions.fork('P-gone', R);
  assert.deepEqual(h.acting(), []);
  const noList = await harness({ profiles: null });
  await noList.actions.fork(PERSONAL.id, R);
  assert.deepEqual(noList.acting(), []);
  assert.equal(noList.refusal(), undefined);
});

test('a gesture whose capability is unavailable sends nothing, and the reason goes to the composer', async () => {
  const off: PhoneCapability = { available: false, reason: 'Not available for remote sessions.' };
  const caps = { ...session(R).capabilities, switchProfile: off, fork: off, model: off };
  for (const act of [
    (h: Awaited<ReturnType<typeof harness>>) => h.actions.switchProfile(PERSONAL.id, R),
    (h: Awaited<ReturnType<typeof harness>>) => h.actions.fork(null, R),
    (h: Awaited<ReturnType<typeof harness>>) => h.actions.fork(PERSONAL.id, R),
    (h: Awaited<ReturnType<typeof harness>>) => h.actions.setModel('sonnet', R),
  ]) {
    const h = await harness({ sessions: [session(R, { capabilities: caps })] });
    await act(h);
    assert.deepEqual(h.acting(), []);
    assert.equal(h.refusal(), 'Not available for remote sessions.');
    assert.equal(isActing(h.state().sheets, R), false);
  }
  // No reason given: nothing to say.
  const bare = await harness({ sessions: [session(R, { capabilities: { ...caps, fork: { available: false } } })] });
  await bare.actions.fork(null, R);
  assert.deepEqual(bare.acting(), []);
  assert.equal(bare.refusal(), undefined);
});

test("a parked session's fork from switch-confirm sends nothing; the laptop's reason shows in the sheet and the composer", async () => {
  const parked = 'This session is parked. Send it a message to wake it, then fork it.';
  const h = await harness({
    sessions: [session(R, { status: { chip: 'parked', changedAt: 1 }, capabilities: { ...session(R).capabilities, fork: { available: false, reason: parked } } })],
  });
  h.actions.openSheet({ name: 'switch-confirm', profileID: PERSONAL.id });
  const sheet = h.state().ui.sheet as SheetState;
  await h.actions.fork(PERSONAL.id, R);
  assert.deepEqual(h.acting(), []);
  assert.equal(h.refusal(), parked);
  assert.deepEqual(h.state().sheets.failed, { sheet, text: parked });
  // The switch itself still goes out.
  const pending = h.actions.switchProfile(PERSONAL.id, R);
  assert.deepEqual(h.acting().map((r) => r.params), [{ session: R, profileID: PERSONAL.id }]);
  h.last('session.switchProfile').resolve({ session: R });
  await pending;
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

test('fork(null) on a session with no profile toasts the default profile the row showed, or "Default account" with no list', async () => {
  const bare = session(R, { profileID: undefined, profileName: undefined });
  const h = await harness({ sessions: [bare] });
  let pending = h.actions.fork(null, R);
  h.last('session.fork').resolve({ session: { kind: 'local', terminalID: 'T-new' } });
  await pending;
  assert.equal(h.state().ui.toast?.text, 'Forked into a new tab, under Personal');
  const noList = await harness({ sessions: [bare], profiles: null });
  pending = noList.actions.fork(null, R);
  noList.last('session.fork').resolve({ session: { kind: 'local', terminalID: 'T-new' } });
  await pending;
  assert.equal(noList.state().ui.toast?.text, 'Forked into a new tab, under Default account');
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

test("a fork's error never lands in a sheet the user moved to: it goes to the composer", async () => {
  const forkSheet = async (move: (h: Awaited<ReturnType<typeof harness>>) => void) => {
    const h = await harness();
    h.actions.openSheet({ name: 'fork' });
    const pending = h.actions.fork(PERSONAL.id, R);
    move(h);
    h.last('session.fork').reject(new AppError('not_confirmed', NOT_CONFIRMED_TEXT));
    await pending;
    return h;
  };
  // Back to the session menu, which shows no failure.
  let h = await forkSheet((x) => x.actions.openSheet({ name: 'menu' }));
  assert.equal(h.refusal(), NOT_CONFIRMED_TEXT);
  assert.equal(h.state().sheets.failed, null);
  // On to the Model sheet, which does show failures, but did not ask.
  h = await forkSheet((x) => {
    x.actions.openSheet({ name: 'menu' });
    x.actions.openSheet({ name: 'model' });
  });
  assert.equal(h.refusal(), NOT_CONFIRMED_TEXT);
  assert.equal(h.state().sheets.failed, null);
  // From the account menu, then the session menu sheet opened.
  h = await harness();
  h.actions.openMenu({ name: 'account', askProfileID: PERSONAL.id });
  const pending = h.actions.fork(PERSONAL.id, R);
  h.actions.closeMenu();
  h.actions.openSheet({ name: 'menu' });
  h.last('session.fork').reject(new AppError('internal', 'TBD could not copy this conversation.'));
  await pending;
  assert.equal(h.refusal(), 'TBD could not copy this conversation.');
  assert.equal(h.state().sheets.failed, null);
  assert.equal(isActing(h.state().sheets, R), false);
});

test('a switch error while switch-confirm asks about another profile goes to the composer only', async () => {
  const h = await harness();
  h.actions.openSheet({ name: 'switch-confirm', profileID: PERSONAL.id });
  const pending = h.actions.switchProfile(PERSONAL.id, R);
  h.actions.openSheet({ name: 'switch-confirm', profileID: BEDROCK.id });
  h.last('session.switchProfile').reject(new AppError('refused', REFUSED));
  await pending;
  assert.equal(h.refusal(), REFUSED);
  assert.equal(h.state().sheets.failed, null);
  assert.deepEqual(h.state().ui.sheet, { name: 'switch-confirm', profileID: BEDROCK.id });
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


// MARK: - New

const REPO = '00000000-0000-4000-8000-0000000000A1';
const OTHER_REPO = '00000000-0000-4000-8000-0000000000A2';
const MESSAGE = 'Add a dark mode toggle to the settings screen.';

const BRANCH: PhoneFormField = { name: 'branch', type: 'string', label: 'Branch', required: true, prefill: 'main' };
const SIZE: PhoneFormField = { name: 'size', type: 'enum', label: 'Machine size', required: true, values: ['Small', 'Medium', 'Large'], prefill: 'Medium' };
const SETUP: PhoneFormField = { name: 'setup', type: 'bool', label: 'Run the setup script', required: false, prefill: 'true' };
const HOURS: PhoneFormField = { name: 'hours', type: 'int', label: 'Time limit, hours', required: false, prefill: '4' };
const NOTES: PhoneFormField = { name: 'notes', type: 'text', label: 'Notes for the agent', required: false };
const CLOUD: PhoneProvider = { name: 'acme-cloud', available: true, acceptsPrompt: true, fields: [BRANCH, SIZE, SETUP, HOURS, NOTES] };
const SANDBOX: PhoneProvider = { name: 'acme-sandbox', available: true, acceptsPrompt: true, fields: [] };
const SILENT: PhoneProvider = { name: 'acme-silent', available: true, acceptsPrompt: false, fields: [] };
const SIGNED_OUT: PhoneProvider = { name: 'acme-signed-out', available: false, reason: 'Sign in to this provider on your laptop.', acceptsPrompt: true, fields: [] };
const PROVIDERS = [CLOUD, SANDBOX, SILENT, SIGNED_OUT];

/** A plain copy of `r`, so a record on a null prototype compares with an object literal. */
function plain<V>(r: Readonly<Record<string, V>>): Record<string, V> {
  return { ...r };
}

/** `params` with plain records, for `deepEqual`. */
function plainParams(params: unknown): unknown {
  const p = params as PhoneRemoteCreateParams;
  return { ...p, strings: plain(p.strings), bools: plain(p.bools) };
}

/** A harness on the sessions list with the New sheet open for `repoID`, and `providers` loaded for it unless null. */
async function newHarness(options: { repoID?: string; providers?: PhoneProvider[] | null } = {}) {
  const h = await harness();
  h.actions.back();
  const repoID = options.repoID ?? REPO;
  h.actions.openSheet({ name: 'new', repoID, repoName: 'acme-web' });
  const providers = options.providers === undefined ? PROVIDERS : options.providers;
  if (providers !== null) {
    const loading = h.actions.loadProviders(repoID);
    h.last('remote.providers').resolve({ providers });
    await loading;
  }
  const creates = (): Sent[] => h.sent.filter((x) => x.method === 'worktree.create' || x.method === 'remote.create');
  /** The laptop lists a new worktree row `id` in repo `REPO`, with one session. */
  const listRow = (id: string, name: string, ref: PhoneSessionRef): void => {
    const rows: PhoneRow[] = [{ id, kind: 'worktree', name, remote: false, statusChangedAt: 3, sessions: [session(ref)] }];
    const layout = snapshot().layout.map((g) => ({ ...g, rows: [...g.rows, { id, depth: 0 }] }));
    h.actions.onEvent({ event: 'sessions.changed', seq: 50, data: { layout, rows, removedRowIDs: [] } });
  };
  return { ...h, creates, listRow, sheet: (): SheetState | null => h.state().ui.sheet };
}

test('loadProviders asks for the repo, shows loading at once, then the providers for that repo; only the newest lands', async () => {
  const h = await newHarness({ providers: null });
  const first = h.actions.loadProviders(REPO);
  assert.deepEqual(h.last('remote.providers').params, { repoID: REPO });
  assert.deepEqual(h.state().sheets.providers, { phase: 'loading', id: 1, repoID: REPO });
  const second = h.actions.loadProviders(REPO);
  const [a, b] = h.of('remote.providers');
  b!.reject(new AppError('internal', 'TBD could not read the remote providers.'));
  await second;
  assert.deepEqual(h.state().sheets.providers, { phase: 'failed', repoID: REPO, message: 'TBD could not read the remote providers.' });
  a!.resolve({ providers: PROVIDERS });
  await first;
  assert.equal(h.state().sheets.providers.phase, 'failed');
  const third = h.actions.loadProviders(REPO);
  h.last('remote.providers').resolve({ providers: PROVIDERS });
  await third;
  assert.deepEqual(h.state().sheets.providers, { phase: 'loaded', repoID: REPO, providers: PROVIDERS });
});

test('createWorktree sends the repo of the New sheet, as the daemon wrote it, and the message as typed', async () => {
  const h = await newHarness();
  const pending = h.actions.createWorktree(REPO, `  ${MESSAGE}\n`);
  assert.deepEqual(h.last('worktree.create').params, { repoID: REPO, message: `  ${MESSAGE}\n` });
  assert.deepEqual(h.state().sheets.creating, { repoID: REPO, mode: 'local' });
  h.last('worktree.create').resolve({ worktreeID: 'W-new' });
  await pending;
  assert.equal(h.state().sheets.creating, null);
});

test('back-to-back creates post one, whichever kind, until the first settles', async () => {
  const h = await newHarness();
  const params = remoteCreateParams(REPO, SANDBOX, MESSAGE, NO_EDITS);
  const pending = [h.actions.createWorktree(REPO, MESSAGE), h.actions.createWorktree(REPO, MESSAGE), h.actions.createRemote(params)];
  assert.equal(h.creates().length, 1);
  h.last('worktree.create').reject(new AppError('refused', 'The worktree could not be created. Check the laptop.'));
  await Promise.all(pending);
  // Settled: the next gesture may go out.
  const again = h.actions.createRemote(params);
  assert.equal(h.creates().length, 2);
  h.last('remote.create').resolve({ session: { kind: 'remote', provider: 'acme-sandbox', sessionID: 'rs-1' } });
  await again;
});

test('a create goes out only from the New sheet of its repo, and never with a blank message', async () => {
  const h = await newHarness();
  await h.actions.createWorktree(OTHER_REPO, MESSAGE);
  await h.actions.createWorktree(REPO, '');
  await h.actions.createWorktree(REPO, ' \n​ ');
  await h.actions.createRemote(remoteCreateParams(OTHER_REPO, SANDBOX, MESSAGE, NO_EDITS));
  h.actions.closeSheet();
  await h.actions.createWorktree(REPO, MESSAGE);
  assert.deepEqual(h.creates(), []);
  assert.equal(h.state().sheets.creating, null);
});

test('a local reply closes the sheet, and the new session opens once its row appears, toasting its name', async () => {
  const h = await newHarness();
  const made: PhoneSessionRef = { kind: 'local', terminalID: 'T-made' };
  const pending = h.actions.createWorktree(REPO, MESSAGE);
  h.last('worktree.create').resolve({ worktreeID: 'W-new', session: made });
  await pending;
  assert.equal(h.sheet(), null);
  assert.deepEqual(h.state().ui.route, { screen: 'sessions' });
  assert.deepEqual(h.state().ui.pendingOpen, { worktreeID: 'W-new', toast: 'Created {name}' });
  assert.equal(h.state().ui.toast, null);
  h.listRow('W-new', 'new-worktree-1', made);
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: made });
  assert.equal(h.state().ui.toast?.text, 'Created new-worktree-1');
});

test('a create the user navigated away from while it was on its way opens nothing; a closed sheet does not stop it', async () => {
  let h = await newHarness();
  const made: PhoneSessionRef = { kind: 'local', terminalID: 'T-made' };
  let pending = h.actions.createWorktree(REPO, MESSAGE);
  h.actions.closeSheet();
  h.actions.openSession(OTHER);
  h.listRow('W-new', 'new-worktree-1', made);
  h.last('worktree.create').resolve({ worktreeID: 'W-new', session: made });
  await pending;
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: OTHER });
  assert.equal(h.state().ui.pendingOpen, null);
  // Closing the sheet is no navigation: the reply still opens the session.
  h = await newHarness();
  pending = h.actions.createWorktree(REPO, MESSAGE);
  h.actions.closeSheet();
  h.listRow('W-new', 'new-worktree-1', made);
  h.last('worktree.create').resolve({ worktreeID: 'W-new', session: made });
  await pending;
  assert.deepEqual(h.state().ui.route, { screen: 'session', ref: made });
  assert.equal(h.state().ui.toast?.text, 'Created new-worktree-1');
});

test("a create's error shows in its New sheet, which stays open; superseded shows nothing", async () => {
  const h = await newHarness();
  const sheet = h.sheet();
  let pending = h.actions.createWorktree(REPO, MESSAGE);
  h.last('worktree.create').reject(new AppError('not_confirmed', NOT_CONFIRMED_TEXT));
  await pending;
  assert.deepEqual(h.state().sheets.failed, { sheet, text: NOT_CONFIRMED_TEXT });
  assert.equal(h.sheet(), sheet);
  assert.equal(h.state().ui.toast, null);
  assert.equal(h.state().sheets.creating, null);
  // The next create takes the words down; a superseded one shows none.
  pending = h.actions.createWorktree(REPO, MESSAGE);
  assert.equal(h.state().sheets.failed, null);
  h.last('worktree.create').reject(new AppError('superseded', SUPERSEDED_TEXT));
  await pending;
  assert.equal(h.state().sheets.failed, null);
  assert.equal(h.state().sheets.lostCreate, null);
  assert.equal(h.sheet(), sheet);
});

test('the error of a create whose sheet closed toasts nothing, and shows in the next New sheet of its repo only', async () => {
  const h = await newHarness();
  const pending = h.actions.createWorktree(REPO, MESSAGE);
  h.actions.closeSheet();
  h.last('worktree.create').reject(new AppError('refused', 'The worktree could not be created. Check the laptop.'));
  await pending;
  assert.equal(h.state().ui.toast, null);
  assert.deepEqual(h.state().sheets.lostCreate, { repoID: REPO, text: 'The worktree could not be created. Check the laptop.' });
  // Another repo's sheet does not take them.
  h.actions.openSheet({ name: 'new', repoID: OTHER_REPO, repoName: 'acme-api' });
  h.actions.claimLostCreate(h.sheet()!);
  assert.equal(h.state().sheets.failed, null);
  h.actions.closeSheet();
  // The repo's next sheet does, once.
  h.actions.openSheet({ name: 'new', repoID: REPO, repoName: 'acme-web' });
  const sheet = h.sheet()!;
  h.actions.claimLostCreate(sheet);
  assert.deepEqual(h.state().sheets.failed, { sheet, text: 'The worktree could not be created. Check the laptop.' });
  assert.equal(h.state().sheets.lostCreate, null);
});

test('a New sheet open for the repo when the create fails shows the error, even one opened again meanwhile', async () => {
  const h = await newHarness();
  const pending = h.actions.createWorktree(REPO, MESSAGE);
  h.actions.closeSheet();
  h.actions.openSheet({ name: 'new', repoID: REPO, repoName: 'acme-web' });
  const again = h.sheet();
  h.last('worktree.create').reject(new AppError('refused', 'The worktree could not be created. Check the laptop.'));
  await pending;
  assert.deepEqual(h.state().sheets.failed, { sheet: again, text: 'The worktree could not be created. Check the laptop.' });
  assert.equal(h.state().sheets.lostCreate, null);
});

test('a success closes only a New sheet of its own repo', async () => {
  const h = await newHarness();
  const pending = h.actions.createWorktree(REPO, MESSAGE);
  h.actions.closeSheet();
  h.actions.openSheet({ name: 'new', repoID: OTHER_REPO, repoName: 'acme-api' });
  const other = h.sheet();
  h.last('worktree.create').resolve({ worktreeID: 'W-new' });
  await pending;
  assert.equal(h.sheet(), other);
});

test('createRemote sends the params, toasts the provider after the reply, and opens the session once listed', async () => {
  const h = await newHarness();
  const made: PhoneSessionRef = { kind: 'remote', provider: 'acme-cloud', sessionID: 'rs-1' };
  const params = remoteCreateParams(REPO, CLOUD, MESSAGE, NO_EDITS);
  const pending = h.actions.createRemote(params);
  assert.deepEqual(h.state().sheets.creating, { repoID: REPO, mode: 'remote' });
  assert.deepEqual(plainParams(h.last('remote.create').params), {
    provider: 'acme-cloud', repoID: REPO, message: MESSAGE, strings: { branch: 'main', size: 'Medium', hours: '4' }, bools: { setup: true },
  });
  assert.equal(h.state().ui.toast, null);
  h.last('remote.create').resolve({ session: made });
  await pending;
  assert.equal(h.state().ui.toast?.text, 'Remote session started on acme-cloud');
  assert.equal(h.sheet(), null);
  assert.deepEqual(h.state().ui.pendingOpen, { ref: made });
});

test('createRemote sends nothing for a provider the loaded list does not offer, or a form Create would not send', async () => {
  const h = await newHarness({ providers: [CLOUD, SIGNED_OUT] });
  await h.actions.createRemote(remoteCreateParams(REPO, SANDBOX, MESSAGE, NO_EDITS));
  await h.actions.createRemote(remoteCreateParams(REPO, { ...SIGNED_OUT, available: true }, MESSAGE, NO_EDITS));
  await h.actions.createRemote(remoteCreateParams(REPO, CLOUD, '  ', NO_EDITS));
  await h.actions.createRemote(remoteCreateParams(REPO, CLOUD, MESSAGE, withFieldText(NO_EDITS, 'branch', ' ')));
  await h.actions.createRemote({ ...remoteCreateParams(REPO, CLOUD, MESSAGE, NO_EDITS), strings: { branch: 'main', size: 'Huge' } });
  assert.deepEqual(h.creates(), []);
  // No list loaded for the repo: nothing.
  const bare = await newHarness({ providers: null });
  await bare.actions.createRemote(remoteCreateParams(REPO, SANDBOX, MESSAGE, NO_EDITS));
  assert.deepEqual(bare.creates(), []);
});

test("a remote refusal shows the laptop's words in the sheet as they come", async () => {
  const h = await newHarness();
  const sheet = h.sheet();
  const pending = h.actions.createRemote(remoteCreateParams(REPO, SANDBOX, MESSAGE, NO_EDITS));
  h.last('remote.create').reject(new AppError('refused', 'The remote provider refused this. Check the laptop.'));
  await pending;
  assert.deepEqual(h.state().sheets.failed, { sheet, text: 'The remote provider refused this. Check the laptop.' });
  assert.equal(h.state().ui.toast, null);
});

test('remote.create params: strings by type, trimmed, empty optional ones left out; bools for every switch', () => {
  let edits = withFieldText(NO_EDITS, 'branch', '  release/1.2 \n');
  edits = withFieldText(edits, 'size', 'Large');
  edits = withFieldOn(edits, 'setup', false);
  edits = withFieldText(edits, 'hours', '');
  edits = withFieldText(edits, 'notes', '  Use the staging data.  ');
  const params = remoteCreateParams(REPO, CLOUD, ` ${MESSAGE}`, edits);
  assert.deepEqual(plainParams(params), {
    provider: 'acme-cloud', repoID: REPO, message: ` ${MESSAGE}`,
    strings: { branch: 'release/1.2', size: 'Large', notes: 'Use the staging data.' }, bools: { setup: false },
  });
  assert.equal(remoteParamsReady(params, CLOUD), true);
  // A required field left blank holds Create.
  assert.equal(remoteParamsReady(remoteCreateParams(REPO, CLOUD, MESSAGE, withFieldText(NO_EDITS, 'branch', ' \t')), CLOUD), false);
  // A blank message holds it, unless the provider takes none, which gets "".
  assert.equal(remoteParamsReady(remoteCreateParams(REPO, SANDBOX, '​', NO_EDITS), SANDBOX), false);
  const silent = remoteCreateParams(REPO, SILENT, MESSAGE, NO_EDITS);
  assert.equal(silent.message, '');
  assert.equal(remoteParamsReady(silent, SILENT), true);
  assert.equal(remoteParamsReady({ ...silent, message: MESSAGE }, SILENT), false);
  // An unavailable provider never.
  assert.equal(remoteParamsReady(remoteCreateParams(REPO, SIGNED_OUT, MESSAGE, NO_EDITS), SIGNED_OUT), false);
  // A field named __proto__ is a field.
  const odd: PhoneProvider = { ...SANDBOX, fields: [{ name: '__proto__', type: 'string', required: true, prefill: 'x' }] };
  const oddParams = remoteCreateParams(REPO, odd, MESSAGE, NO_EDITS);
  assert.deepEqual(Object.keys(oddParams.strings), ['__proto__']);
  assert.equal(remoteParamsReady(oddParams, odd), true);
});

test('a field shows its prefill: an enum only one of its values, a switch on for "true"', () => {
  assert.equal(fieldText(BRANCH, NO_EDITS), 'main');
  assert.equal(fieldText(NOTES, NO_EDITS), '');
  assert.equal(fieldText({ ...SIZE, prefill: 'Huge' }, NO_EDITS), '');
  assert.equal(fieldText(BRANCH, withFieldText(NO_EDITS, 'branch', '')), '');
  assert.equal(fieldOn(SETUP, NO_EDITS), true);
  assert.equal(fieldOn({ ...SETUP, prefill: undefined }, NO_EDITS), false);
  assert.equal(fieldOn(SETUP, withFieldOn(NO_EDITS, 'setup', false)), false);
  // A required enum with a prefill among its values offers no blank; otherwise the blank comes first.
  assert.deepEqual(enumChoices(SIZE), ['Small', 'Medium', 'Large']);
  assert.deepEqual(enumChoices({ ...SIZE, required: false }), ['', 'Small', 'Medium', 'Large']);
  assert.deepEqual(enumChoices({ ...SIZE, prefill: undefined }), ['', 'Small', 'Medium', 'Large']);
});

test("a provider's line: how many fields it adds, nothing else, or the laptop's reason", () => {
  assert.equal(providerDetail(CLOUD), '5 more fields');
  assert.equal(providerDetail({ ...SANDBOX, fields: [BRANCH] }), '1 more field');
  assert.equal(providerDetail(SANDBOX), 'Needs nothing else');
  assert.equal(providerDetail(SIGNED_OUT), 'Sign in to this provider on your laptop.');
  assert.equal(providerDetail({ ...SIGNED_OUT, reason: undefined }), null);
});
