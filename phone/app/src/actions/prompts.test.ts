// Tests prompts.ts: answering a prompt, taking its card down, and sending a message. A fake
// client records each request and hands back a promise the test settles; the store and every
// action are real, so the transcript opens through `openSession` and `prompt.changed` events fold
// in through `onEvent`, and each receipt lands in the transcript as it does in the app.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AppError, BAD_PARAMS_TEXT, NOT_CONFIRMED_TEXT, SUPERSEDED_TEXT } from '../client/client.ts';
import { MAX_BODY_BYTES } from '../limits.ts';
import type {
  Method, ParamsOf, PhoneAnsweredBy, PhonePrompt, PhoneRow, PhoneSession, PhoneSessionRef, PhoneStatusChip, PromptAnswer, PromptChangedData,
  ResultOf, SessionsSubscribeResult,
} from '../protocol/types.ts';
import { refKey } from '../protocol/wire.ts';
import { applySnapshot } from '../state/sessionsData.ts';
import { cardKey, ELSEWHERE_LIMIT, isSending } from '../state/prompts.ts';
import type { AnsweredHere, CardState } from '../state/prompts.ts';
import { createStore, initialState } from '../state/store.ts';
import type { AppState } from '../state/store.ts';
import { createActions } from './index.ts';
import { WAKING_TEXT } from './prompts.ts';

const CAN = { available: true };
const OFF_REASON = "Answering prompts is turned off in TBD's settings on the laptop.";
const REFUSED_TEXT = 'The laptop refused the answer.';
const TOO_LONG = 'That message is too long to send from a phone.';
const R: PhoneSessionRef = { kind: 'local', terminalID: 'T-R' };
const OTHER: PhoneSessionRef = { kind: 'local', terminalID: 'T-other' };

const QUESTION = 'Add a test for open-redirect attempts too?';
const Q: PhonePrompt = {
  id: '00000000-0000-4000-8000-0000000000E1', kind: 'question', toolName: 'AskUserQuestion', targetTruncated: false, allowAlways: false,
  questions: [{ header: 'Tests', text: QUESTION, multiSelect: false, options: [{ label: 'Yes, add the test' }, { label: 'No, this is enough' }] }],
};
const P: PhonePrompt = {
  id: '00000000-0000-4000-8000-0000000000E2', kind: 'permission', toolName: 'Bash', summary: 'Run the reconnect integration tests',
  target: 'npm run test:integration', targetTruncated: false, allowAlways: true, suggestions: ['Bash(npm run test:integration:*)'],
};
/** A permission prompt that offers no "don't ask again". */
const P_ONCE: PhonePrompt = { ...P, id: '00000000-0000-4000-8000-0000000000E5', allowAlways: false, suggestions: [] };
/** A prompt of the other session. */
const QO: PhonePrompt = { ...Q, id: '00000000-0000-4000-8000-0000000000E9' };

const YES: PromptAnswer = { kind: 'question', answers: { [QUESTION]: 'Yes, add the test' } };
const ALLOW: PromptAnswer = { kind: 'permission', decision: 'allow' };

function session(ref: PhoneSessionRef, answer: { available: boolean; reason?: string } = CAN): PhoneSession {
  return {
    ref, agent: 'claude', tabName: 'claude', status: { chip: 'waiting', changedAt: 1 },
    capabilities: { transcript: CAN, send: CAN, answer, switchProfile: CAN, fork: CAN, model: CAN },
  };
}

function snapshot(answer?: { available: boolean; reason?: string }): SessionsSubscribeResult {
  const rows: PhoneRow[] = [
    { id: 'W1', kind: 'worktree', name: 'W1', remote: false, statusChangedAt: 1, sessions: [session(R, answer)] },
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

function harness(answer?: { available: boolean; reason?: string }) {
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
  const store = createStore({ ...initialState(), sessions: applySnapshot(snapshot(answer)) });
  const actions = createActions({ store, client, link: { openLink: () => {} }, now: () => 0 });
  const last = (method: Method): Sent => {
    const found = sent.filter((s) => s.method === method).at(-1);
    assert.ok(found, `no ${method} was sent`);
    return found;
  };
  const answers = (): Sent[] => sent.filter((s) => s.method === 'prompt.answer');
  const state = (): AppState => store.get();
  const card = (id: string, ref: PhoneSessionRef = R): CardState | undefined => {
    const cards = store.get().prompts.cards;
    const k = cardKey(ref, id);
    return Object.hasOwn(cards, k) ? cards[k] : undefined;
  };
  /** This phone's recorded answer to `id` in `ref`'s session. */
  const here = (id: string, ref: PhoneSessionRef = R): AnsweredHere | undefined => {
    const r = store.get().prompts.answeredHere;
    const k = cardKey(ref, id);
    return Object.hasOwn(r, k) ? r[k] : undefined;
  };
  const receipts = (): string[] => store.get().transcript.rows.flatMap((r) => (r.kind === 'receipt' ? [r.text] : []));
  let seq = 20;
  const changed = (data: Omit<PromptChangedData, 'session'> & { session?: PhoneSessionRef }): void => {
    actions.onEvent({ event: 'prompt.changed', seq: seq++, data: { session: R, ...data } });
  };
  return { sent, last, answers, store, actions, state, card, here, receipts, changed };
}

/** Lets the promise handlers run. */
function flush(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

/** A harness subscribed, showing `R` with its transcript open and `prompts` open in it. */
async function showing(prompts: PhonePrompt[] = [Q, P], answer?: { available: boolean; reason?: string }) {
  const h = harness(answer);
  h.actions.onChannelUp();
  h.last('sessions.subscribe').resolve({ stream: 's1', seq: 10, replayed: true, omittedRows: 0, more: false });
  h.actions.openSession(R);
  h.last('transcript.open').resolve({ resumed: false, seq: 10, page: { items: [], reachedStart: true, omittedItems: 0 } });
  await flush();
  assert.equal(h.state().transcript.phase, 'open');
  h.changed({ prompts });
  for (const p of prompts) assert.equal(h.card(p.id)?.phase, 'open', p.id);
  return h;
}

function resolved(promptID: string, answeredBy: PhoneAnsweredBy) {
  return [{ promptID, answeredBy }];
}

// MARK: - Answering

test('an answer goes to the open session once, with the prompt and the answer as given', async () => {
  const h = await showing();
  const pending = h.actions.answerPrompt(Q.id, YES);
  assert.deepEqual(h.answers().map((s) => s.params), [{ session: R, promptID: Q.id, answer: YES }]);
  assert.equal(h.card(Q.id)?.phase, 'sending');
  assert.equal(h.card(Q.id)?.summary, 'Yes, add the test');
  h.last('prompt.answer').resolve({ outcome: 'delivered' });
  await pending;
  assert.equal(h.card(Q.id)?.phase, 'answered');
});

test('a delivered answer shows Answered, and its resolution leaves "Answered on this phone: …"', async () => {
  for (const [outcome, by] of [['delivered', 'phone'], ['delivered', 'unknown'], ['unknown', 'phone'], ['unknown', 'unknown']] as const) {
    const h = await showing();
    const pending = h.actions.answerPrompt(Q.id, YES);
    h.last('prompt.answer').resolve({ outcome });
    await pending;
    assert.equal(h.card(Q.id)?.phase, 'answered', outcome);
    assert.equal(h.card(Q.id)?.summary, 'Yes, add the test');
    assert.equal(h.here(Q.id)?.summary, 'Yes, add the test');
    assert.deepEqual(h.receipts(), [], 'no receipt before the resolution');
    h.changed({ prompts: [P], resolved: resolved(Q.id, by) });
    assert.equal(h.card(Q.id), undefined, `${outcome}, ${by}: the card is taken down`);
    assert.deepEqual(h.receipts(), ['Answered on this phone: Yes, add the test'], `${outcome}, ${by}`);
    assert.equal((h.here(Q.id) !== undefined), false, 'the entry goes once its resolution is applied');
    assert.equal(h.card(P.id)?.phase, 'open', 'the other prompt stays');
  }
});

test("already_resolved and a laptop resolution never read 'Answered on this phone'", async () => {
  const h = await showing();
  const pending = h.actions.answerPrompt(Q.id, YES);
  h.last('prompt.answer').resolve({ outcome: 'already_resolved' });
  await pending;
  assert.equal(h.card(Q.id)?.phase, 'elsewhere');
  assert.equal(h.card(Q.id)?.elsewhereBy, null);
  assert.equal((h.here(Q.id) !== undefined), false);
  h.changed({ prompts: [], resolved: resolved(Q.id, 'laptop') });
  const card = h.card(Q.id);
  assert.equal(card?.phase, 'elsewhere');
  assert.equal(card?.elsewhereBy, 'laptop');
  assert.deepEqual(h.receipts(), ['Answered on the laptop']);
});

test('a delivered answer that the laptop says it answered reads "Answered on the laptop"', async () => {
  const h = await showing();
  const pending = h.actions.answerPrompt(Q.id, YES);
  h.last('prompt.answer').resolve({ outcome: 'delivered' });
  await pending;
  h.changed({ prompts: [P], resolved: resolved(Q.id, 'laptop') });
  assert.equal(h.card(Q.id), undefined);
  assert.deepEqual(h.receipts(), ['Answered on the laptop']);
});

test('already_resolved, then a resolution by a phone or by no one known, reads as another phone or elsewhere', async () => {
  for (const [by, text, elsewhereBy] of [['phone', 'Answered on another phone', 'phone'], ['unknown', 'Answered elsewhere', null]] as const) {
    const h = await showing();
    const pending = h.actions.answerPrompt(Q.id, YES);
    h.last('prompt.answer').resolve({ outcome: 'already_resolved' });
    await pending;
    h.changed({ prompts: [P], resolved: resolved(Q.id, by) });
    assert.deepEqual(h.receipts(), [text], by);
    assert.equal(h.card(Q.id)?.phase, 'elsewhere', by);
    assert.equal(h.card(Q.id)?.elsewhereBy, elsewhereBy, by);
  }
});

test('a resolution while the card is open shows the elsewhere card until OK', async () => {
  for (const [by, text, elsewhereBy] of [
    ['laptop', 'Answered on the laptop', 'laptop'], ['phone', 'Answered on another phone', 'phone'], ['unknown', 'Answered elsewhere', null],
  ] as const) {
    const h = await showing();
    h.changed({ prompts: [P], resolved: resolved(Q.id, by) });
    assert.deepEqual(h.receipts(), [text], by);
    const card = h.card(Q.id);
    assert.equal(card?.phase, 'elsewhere', by);
    assert.equal(card?.elsewhereBy, elsewhereBy, by);
    // The card keeps the prompt, whose kind the dock's copy needs, after the prompt left the set.
    assert.equal(card?.prompt.kind, 'question');
    h.changed({ prompts: [] });
    h.changed({ prompts: [P] });
    assert.equal(h.card(Q.id)?.phase, 'elsewhere', `${by}: the card stays until OK`);
    h.actions.dismissPrompt(Q.id);
    assert.equal(h.card(Q.id), undefined, by);
    assert.equal(h.card(P.id)?.phase, 'open', 'dismissing takes down that card only');
    assert.equal(h.answers().length, 0, 'nothing is sent');
  }
});

test("a refused answer keeps the card open with the daemon's message", async () => {
  const h = await showing();
  const pending = h.actions.answerPrompt(P.id, ALLOW);
  h.last('prompt.answer').reject(new AppError('refused', REFUSED_TEXT));
  await pending;
  assert.equal(h.card(P.id)?.phase, 'open');
  assert.equal(h.card(P.id)?.refusal, REFUSED_TEXT);
  assert.equal(h.card(P.id)?.summary, null);
  assert.equal((h.here(P.id) !== undefined), false);
  assert.equal(h.answers().length, 1, 'nothing is sent again by itself');
  // A new tap is a new answer, and its sending clears the refusal.
  void h.actions.answerPrompt(P.id, ALLOW);
  assert.equal(h.answers().length, 2);
  assert.equal(h.card(P.id)?.phase, 'sending');
  assert.equal(h.card(P.id)?.refusal, null);
});

test('the unsupported reply of a setting turned off shows its reason', async () => {
  const h = await showing();
  const pending = h.actions.answerPrompt(P.id, ALLOW);
  h.last('prompt.answer').reject(new AppError('unsupported', OFF_REASON));
  await pending;
  assert.equal(h.card(P.id)?.phase, 'open');
  assert.equal(h.card(P.id)?.refusal, OFF_REASON);
});

test('a superseded answer turns the card back open with no refusal', async () => {
  const h = await showing();
  const pending = h.actions.answerPrompt(P.id, ALLOW);
  h.last('prompt.answer').reject(new AppError('superseded', SUPERSEDED_TEXT));
  await pending;
  assert.equal(h.card(P.id)?.phase, 'open');
  assert.equal(h.card(P.id)?.refusal, null);
});

test('an answer that may have happened shows its error and is not sent again', async () => {
  for (const [code, message] of [
    ['not_confirmed', NOT_CONFIRMED_TEXT], ['bad_reply', 'The laptop sent a reply this app cannot read.'],
    ['internal', 'Something went wrong.'], ['too_large', 'That message is too long to send from a phone.'],
  ] as const) {
    const h = await showing();
    const pending = h.actions.answerPrompt(P.id, ALLOW);
    h.last('prompt.answer').reject(new AppError(code, message));
    await pending;
    await flush();
    assert.equal(h.card(P.id)?.phase, 'open', code);
    assert.equal(h.card(P.id)?.refusal, message, code);
    assert.equal(h.answers().length, 1, `${code}: nothing is sent again`);
    assert.equal(h.here(P.id)?.summary, 'Allowed', `${code}: recorded as this phone's`);
  }
});

test("a rejection that is no AppError still settles the card, with the client's words for a request it could not send", async () => {
  const h = await showing();
  const pending = h.actions.answerPrompt(P.id, ALLOW);
  h.last('prompt.answer').reject(new Error('AppClient: request ID 1 is already in use'));
  await pending;
  assert.equal(h.card(P.id)?.phase, 'open');
  assert.equal(h.card(P.id)?.refusal, BAD_PARAMS_TEXT, "the client's own words, not its log line");
  assert.equal(h.here(P.id), undefined, 'the client posted nothing');
});

test('a prompt that closes with no resolution leaves no receipt', async () => {
  const h = await showing();
  const pending = h.actions.answerPrompt(P.id, ALLOW);
  h.last('prompt.answer').resolve({ outcome: 'delivered' });
  await pending;
  h.changed({ prompts: [] });
  assert.equal(h.card(Q.id), undefined, 'an open card goes');
  assert.equal(h.card(P.id), undefined, 'an answered card goes');
  assert.deepEqual(h.receipts(), []);
  assert.deepEqual(Object.keys(h.state().prompts.bySession), [], 'an empty set is not kept');
});

// MARK: - One answer per gesture

test('two answers back to back post one prompt.answer', async () => {
  const h = await showing();
  const first = h.actions.answerPrompt(Q.id, YES);
  const second = h.actions.answerPrompt(Q.id, YES);
  assert.equal(h.answers().length, 1);
  await second;
  assert.equal(h.answers().length, 1, 'the second resolves at once, having sent nothing');
  h.last('prompt.answer').resolve({ outcome: 'delivered' });
  await first;
  assert.equal(h.answers().length, 1);
});

test('an answered or elsewhere card sends nothing', async () => {
  const h = await showing();
  const pending = h.actions.answerPrompt(Q.id, YES);
  h.last('prompt.answer').resolve({ outcome: 'delivered' });
  await pending;
  void h.actions.answerPrompt(Q.id, YES);
  h.changed({ prompts: [Q, P], resolved: [] });
  void h.actions.answerPrompt(Q.id, YES);
  assert.equal(h.answers().length, 1, 'answered');
  h.changed({ prompts: [], resolved: resolved(P.id, 'laptop') });
  assert.equal(h.card(P.id)?.phase, 'elsewhere');
  const before = h.state();
  void h.actions.answerPrompt(P.id, ALLOW);
  assert.equal(h.answers().length, 1, 'elsewhere');
  assert.equal(h.state(), before, 'and nothing changes');
});

// MARK: - The right target

test('a prompt ID the open session does not hold sends nothing', async () => {
  const h = await showing();
  const before = h.state();
  void h.actions.answerPrompt('00000000-0000-4000-8000-0000000000FF', YES);
  void h.actions.answerPrompt('constructor', YES);
  assert.equal(h.answers().length, 0);
  assert.equal(h.state(), before);
});

test("a prompt of another session sends nothing, even while the slice holds it", async () => {
  const h = await showing();
  // The laptop's feed moved to OTHER while the route still shows R, as after a refused open.
  h.changed({ session: OTHER, prompts: [QO] });
  assert.equal(h.card(QO.id, OTHER)?.phase, 'open');
  void h.actions.answerPrompt(QO.id, YES);
  assert.equal(h.answers().length, 0);
});

test('an answer after the route moved sends nothing', async () => {
  const h = await showing();
  h.actions.back();
  void h.actions.answerPrompt(Q.id, YES);
  h.actions.openSession(OTHER);
  void h.actions.answerPrompt(Q.id, YES);
  assert.equal(h.answers().length, 0);
});

test('an answer for a session the list does not show sends nothing', async () => {
  const h = await showing();
  // A partial list: the layout places W1, whose row has not come yet, so the route stays on R.
  h.store.update((s) => ({
    ...s,
    sessions: { layout: s.sessions.layout, rows: Object.assign(Object.create(null) as Record<string, PhoneRow>, { W2: s.sessions.rows['W2']! }) },
  }));
  assert.equal(h.state().ui.route.screen, 'session');
  void h.actions.answerPrompt(Q.id, YES);
  assert.equal(h.answers().length, 0);
});

// MARK: - The answer fits the prompt

test("an answer of the wrong kind, or that misses or adds a question, sends nothing", async () => {
  const h = await showing([Q, P, P_ONCE]);
  void h.actions.answerPrompt(Q.id, ALLOW);
  void h.actions.answerPrompt(P.id, YES);
  void h.actions.answerPrompt(Q.id, { kind: 'question', answers: {} });
  void h.actions.answerPrompt(Q.id, { kind: 'question', answers: { [QUESTION]: '  ' } });
  void h.actions.answerPrompt(Q.id, { kind: 'question', answers: { [QUESTION]: 'Yes', 'Another question?': 'No' } });
  void h.actions.answerPrompt(Q.id, { kind: 'question', answers: { 'Another question?': 'Yes' } });
  void h.actions.answerPrompt(P_ONCE.id, { kind: 'permission', decision: 'allow_always' });
  void h.actions.answerPrompt(P.id, { kind: 'permission', decision: 'allow', message: 'Go ahead.' });
  void h.actions.answerPrompt(P.id, { kind: 'permission', decision: 'deny', message: '  ' });
  assert.equal(h.answers().length, 0);
  for (const p of [Q, P, P_ONCE]) assert.equal(h.card(p.id)?.phase, 'open', p.id);
});

test('allow_always goes where the prompt offers it, and a deny carries its message', async () => {
  const h = await showing([P, P_ONCE]);
  void h.actions.answerPrompt(P.id, { kind: 'permission', decision: 'allow_always' });
  const deny: PromptAnswer = { kind: 'permission', decision: 'deny', message: 'Run only the unit tests for now.' };
  void h.actions.answerPrompt(P_ONCE.id, deny);
  assert.deepEqual(h.answers().map((s) => s.params), [
    { session: R, promptID: P.id, answer: { kind: 'permission', decision: 'allow_always' } },
    { session: R, promptID: P_ONCE.id, answer: deny },
  ]);
});

// MARK: - The answer capability

test('with the answer capability off, nothing is sent and the card shows the reason', async () => {
  const h = await showing([Q, P], { available: false, reason: OFF_REASON });
  void h.actions.answerPrompt(P.id, ALLOW);
  assert.equal(h.answers().length, 0);
  assert.equal(h.card(P.id)?.phase, 'open');
  assert.equal(h.card(P.id)?.refusal, OFF_REASON);
  // With no reason given, nothing changes at all.
  const quiet = await showing([Q, P], { available: false });
  const before = quiet.state();
  void quiet.actions.answerPrompt(P.id, ALLOW);
  assert.equal(quiet.answers().length, 0);
  assert.equal(quiet.state(), before);
});

// MARK: - A resolution while the answer is on its way

test('a laptop resolution while sending reads "Answered on the laptop" at once, and the reply changes nothing', async () => {
  for (const outcome of ['delivered', 'unknown', 'already_resolved'] as const) {
    const h = await showing();
    const pending = h.actions.answerPrompt(Q.id, YES);
    h.changed({ prompts: [P], resolved: resolved(Q.id, 'laptop') });
    assert.deepEqual(h.receipts(), ['Answered on the laptop'], outcome);
    assert.equal(h.card(Q.id)?.phase, 'elsewhere');
    assert.equal(h.card(Q.id)?.elsewhereBy, 'laptop');
    const before = h.state();
    h.last('prompt.answer').resolve({ outcome });
    await pending;
    assert.equal(h.state(), before, `${outcome}: the reply changes nothing`);
    assert.equal((h.here(Q.id) !== undefined), false);
  }
});

test('a laptop resolution while sending stands over an error reply too', async () => {
  const h = await showing();
  const pending = h.actions.answerPrompt(Q.id, YES);
  h.changed({ prompts: [P], resolved: resolved(Q.id, 'laptop') });
  h.last('prompt.answer').reject(new AppError('refused', REFUSED_TEXT));
  await pending;
  assert.equal(h.card(Q.id)?.phase, 'elsewhere');
  assert.equal(h.card(Q.id)?.refusal, null);
  assert.deepEqual(h.receipts(), ['Answered on the laptop']);
});

test('a phone or unknown resolution while sending waits for the reply, which delivered makes "Answered on this phone"', async () => {
  for (const by of ['phone', 'unknown'] as const) {
    for (const outcome of ['delivered', 'unknown'] as const) {
      const h = await showing();
      const pending = h.actions.answerPrompt(Q.id, YES);
      h.changed({ prompts: [P], resolved: resolved(Q.id, by) });
      assert.deepEqual(h.receipts(), [], `${by}: no receipt while the reply is on its way`);
      assert.equal(h.card(Q.id)?.phase, 'sending', 'the card stays though its prompt left the set');
      h.changed({ prompts: [P] });
      assert.equal(h.card(Q.id)?.phase, 'sending', 'and a later event keeps it');
      h.last('prompt.answer').resolve({ outcome });
      await pending;
      assert.deepEqual(h.receipts(), ['Answered on this phone: Yes, add the test'], `${by}, ${outcome}`);
      assert.equal(h.card(Q.id), undefined);
      assert.equal((h.here(Q.id) !== undefined), false);
    }
  }
});

test('a phone or unknown resolution while sending reads as if this phone had not answered when the reply says it did not', async () => {
  const cases = [
    ['phone', 'already_resolved', 'Answered on another phone', 'phone'],
    ['unknown', 'already_resolved', 'Answered elsewhere', null],
    ['phone', new AppError('refused', REFUSED_TEXT), 'Answered on another phone', 'phone'],
    ['unknown', new AppError('unsupported', OFF_REASON), 'Answered elsewhere', null],
    ['phone', new AppError('not_found', 'That session is not on the laptop.'), 'Answered on another phone', 'phone'],
    ['unknown', new AppError('superseded', SUPERSEDED_TEXT), 'Answered elsewhere', null],
  ] as const;
  for (const [by, reply, text, elsewhereBy] of cases) {
    const h = await showing();
    const pending = h.actions.answerPrompt(Q.id, YES);
    h.changed({ prompts: [P], resolved: resolved(Q.id, by) });
    if (reply instanceof AppError) h.last('prompt.answer').reject(reply);
    else h.last('prompt.answer').resolve({ outcome: reply });
    await pending;
    const label = `${by}, ${reply instanceof AppError ? reply.code : reply}`;
    assert.deepEqual(h.receipts(), [text], label);
    assert.equal(h.card(Q.id)?.phase, 'elsewhere', label);
    assert.equal(h.card(Q.id)?.elsewhereBy, elsewhereBy, label);
    assert.equal(h.card(Q.id)?.refusal, null, label);
    h.actions.dismissPrompt(Q.id);
    assert.equal(h.card(Q.id), undefined, label);
  }
});

test('a sending card stays when its prompt leaves the set unresolved, and its reply still settles it', async () => {
  const h = await showing();
  const pending = h.actions.answerPrompt(Q.id, YES);
  h.changed({ prompts: [P] });
  assert.equal(h.card(Q.id)?.phase, 'sending', 'the card stays until its reply');
  h.changed({ prompts: [Q, P] });
  assert.equal(h.card(Q.id)?.phase, 'sending', 'the prompt back gets no new card');
  void h.actions.answerPrompt(Q.id, YES);
  assert.equal(h.answers().length, 1, 'so no second answer goes out');
  h.last('prompt.answer').resolve({ outcome: 'delivered' });
  await pending;
  assert.equal(h.card(Q.id)?.phase, 'answered');
  assert.deepEqual(h.here(Q.id), { summary: 'Yes, add the test', taken: true });
  h.changed({ prompts: [P], resolved: resolved(Q.id, 'phone') });
  assert.deepEqual(h.receipts(), ['Answered on this phone: Yes, add the test']);
});

/** `h` showing OTHER and then R again, each transcript opened afresh, with the feed sending `others` for OTHER and `back` for R. */
async function roundTrip(h: Awaited<ReturnType<typeof showing>>, others: PhonePrompt[], back: PhonePrompt[]): Promise<void> {
  h.actions.openSession(OTHER);
  h.last('transcript.open').resolve({ resumed: false, seq: 11, page: { items: [], reachedStart: true, omittedItems: 0 } });
  await flush();
  h.changed({ session: OTHER, prompts: others });
  h.actions.openSession(R);
  h.last('transcript.open').resolve({ resumed: false, seq: 12, page: { items: [], reachedStart: true, omittedItems: 0 } });
  await flush();
  h.changed({ prompts: back });
}

test('an answer in flight while the feed moves away and back keeps its card, and no second answer goes out', async () => {
  const h = await showing([Q]);
  const pending = h.actions.answerPrompt(Q.id, YES);
  await roundTrip(h, [{ ...P, id: '00000000-0000-4000-8000-0000000000F7' }], [Q]);
  assert.equal(h.card(Q.id)?.phase, 'sending');
  void h.actions.answerPrompt(Q.id, YES);
  assert.equal(h.answers().length, 1);
  h.answers()[0]!.resolve({ outcome: 'delivered' });
  await pending;
  assert.equal(h.card(Q.id)?.phase, 'answered');
  assert.deepEqual(h.here(Q.id), { summary: 'Yes, add the test', taken: true });
  h.changed({ prompts: [], resolved: resolved(Q.id, 'phone') });
  assert.deepEqual(h.receipts(), ['Answered on this phone: Yes, add the test']);
  assert.equal(h.card(Q.id), undefined);
});

test('an answer delivered after the feed moved away and back reads as this phone\'s', async () => {
  const h = await showing([Q]);
  const pending = h.actions.answerPrompt(Q.id, YES);
  await roundTrip(h, [], [Q]);
  h.answers()[0]!.resolve({ outcome: 'delivered' });
  await pending;
  h.changed({ prompts: [], resolved: resolved(Q.id, 'phone') });
  assert.deepEqual(h.receipts(), ['Answered on this phone: Yes, add the test']);
  assert.equal(h.card(Q.id), undefined);
});

test('a delivered answer whose prompt is still open after a round trip comes back answered, not open', async () => {
  const h = await showing([Q]);
  const pending = h.actions.answerPrompt(Q.id, YES);
  h.answers()[0]!.resolve({ outcome: 'delivered' });
  await pending;
  await roundTrip(h, [], [Q]);
  assert.equal(h.card(Q.id)?.phase, 'answered');
  assert.equal(h.card(Q.id)?.summary, 'Yes, add the test');
  void h.actions.answerPrompt(Q.id, YES);
  assert.equal(h.answers().length, 1);
  h.changed({ prompts: [], resolved: resolved(Q.id, 'unknown') });
  assert.deepEqual(h.receipts(), ['Answered on this phone: Yes, add the test']);
});

test('an answer that may have landed comes back open after a round trip, still read as this phone\'s', async () => {
  const h = await showing([Q]);
  const pending = h.actions.answerPrompt(Q.id, YES);
  h.answers()[0]!.reject(new AppError('not_confirmed', NOT_CONFIRMED_TEXT));
  await pending;
  await roundTrip(h, [], [Q]);
  assert.equal(h.card(Q.id)?.phase, 'open', 'the laptop never took it, so it can be answered again');
  h.changed({ prompts: [], resolved: resolved(Q.id, 'phone') });
  assert.deepEqual(h.receipts(), ['Answered on this phone: Yes, add the test']);
});

test('a laptop resolution while sending drops an earlier answer that may have landed', async () => {
  const h = await showing();
  const first = h.actions.answerPrompt(Q.id, YES);
  h.last('prompt.answer').reject(new AppError('not_confirmed', NOT_CONFIRMED_TEXT));
  await first;
  assert.notEqual(h.here(Q.id), undefined);
  const second = h.actions.answerPrompt(Q.id, YES);
  h.changed({ prompts: [P], resolved: resolved(Q.id, 'laptop') });
  assert.equal(h.here(Q.id), undefined);
  assert.deepEqual(h.receipts(), ['Answered on the laptop']);
  h.last('prompt.answer').resolve({ outcome: 'delivered' });
  await second;
  assert.equal(h.here(Q.id), undefined);
  assert.equal(h.card(Q.id)?.phase, 'elsewhere');
});

test("another session's prompt with the same ID gets its own card, and leaves this one's as it was", async () => {
  const h = await showing([Q]);
  h.changed({ prompts: [], resolved: resolved(Q.id, 'laptop') });
  assert.equal(h.card(Q.id)?.phase, 'elsewhere');
  h.changed({ session: OTHER, prompts: [Q] });
  assert.equal(h.card(Q.id, OTHER)?.phase, 'open');
  assert.equal(h.card(Q.id)?.phase, 'elsewhere');
  assert.equal(h.card(Q.id)?.elsewhereBy, 'laptop');
});

// MARK: - The transcript holds the session

test('an answer goes out only while the transcript shows the session open', async () => {
  // Opening again: the same session, its transcript on its way.
  const reopening = await showing();
  reopening.actions.setShowDetails(true);
  assert.equal(reopening.state().transcript.phase, 'opening');
  void reopening.actions.answerPrompt(P.id, ALLOW);
  assert.equal(reopening.answers().length, 0, 'opening');
  reopening.last('transcript.open').resolve({ resumed: false, seq: 11, page: { items: [], reachedStart: true, omittedItems: 0 } });
  await flush();
  void reopening.actions.answerPrompt(P.id, ALLOW);
  assert.equal(reopening.answers().length, 1, 'open again');
  // A failed open: the laptop's feed stayed where it was, and the set may be stale.
  const failed = await showing();
  failed.actions.setShowDetails(true);
  failed.last('transcript.open').reject(new AppError('refused', 'No.'));
  await flush();
  assert.equal(failed.state().transcript.phase, 'failed');
  void failed.actions.answerPrompt(P.id, ALLOW);
  assert.equal(failed.answers().length, 0, 'failed');
  // A transcript open for another session than the route shows.
  const elsewhere = await showing();
  elsewhere.store.update((s) => ({ ...s, transcript: { ...s.transcript, ref: OTHER } }));
  assert.equal(elsewhere.state().transcript.phase, 'open');
  void elsewhere.actions.answerPrompt(P.id, ALLOW);
  assert.equal(elsewhere.answers().length, 0, "another session's transcript");
});

test('dismissPrompt acts on the session the route shows', async () => {
  const h = await showing();
  h.changed({ prompts: [P], resolved: resolved(Q.id, 'laptop') });
  h.actions.back();
  h.actions.dismissPrompt(Q.id);
  assert.equal(h.card(Q.id)?.phase, 'elsewhere', 'on the list, nothing is dismissed');
});

test('the summary comes from the answer and the prompt, not from the caller', async () => {
  const h = await showing([P]);
  const pending = h.actions.answerPrompt(P.id, { kind: 'permission', decision: 'deny', message: 'Run only the unit tests for now.' });
  assert.equal(h.card(P.id)?.summary, 'Denied');
  h.last('prompt.answer').resolve({ outcome: 'delivered' });
  await pending;
  h.changed({ prompts: [], resolved: resolved(P.id, 'phone') });
  assert.deepEqual(h.receipts(), ['Answered on this phone: Denied']);
});

// MARK: - An answer that may have landed

const MAYBE: ReadonlyArray<readonly [string, string]> = [
  ['not_confirmed', NOT_CONFIRMED_TEXT], ['bad_reply', 'The laptop sent a reply this app cannot read.'],
  ['internal', 'Something went wrong.'], ['too_large', TOO_LONG],
];
const NOT_LANDED: ReadonlyArray<readonly [string, string]> = [
  ['refused', REFUSED_TEXT], ['not_found', 'That session is not on the laptop.'], ['bad_request', 'That reason is too long to send from a phone.'],
  ['unsupported', OFF_REASON], ['superseded', SUPERSEDED_TEXT],
];

test("an answer that may have landed reads as this phone's when its prompt resolves, and its card goes", async () => {
  for (const [code, message] of MAYBE) {
    for (const by of ['phone', 'unknown'] as const) {
      const h = await showing();
      const pending = h.actions.answerPrompt(P.id, ALLOW);
      h.last('prompt.answer').reject(new AppError(code as 'internal', message));
      await pending;
      h.changed({ prompts: [Q], resolved: resolved(P.id, by) });
      assert.deepEqual(h.receipts(), ['Answered on this phone: Allowed'], `${code}, ${by}`);
      assert.equal(h.card(P.id), undefined, `${code}, ${by}: no elsewhere card`);
      assert.equal((h.here(P.id) !== undefined), false);
    }
    const h = await showing();
    const pending = h.actions.answerPrompt(P.id, ALLOW);
    h.last('prompt.answer').reject(new AppError(code as 'internal', message));
    await pending;
    h.changed({ prompts: [Q], resolved: resolved(P.id, 'laptop') });
    assert.deepEqual(h.receipts(), ['Answered on the laptop'], `${code}, laptop`);
    assert.equal(h.card(P.id)?.phase, 'elsewhere');
    assert.equal(h.card(P.id)?.elsewhereBy, 'laptop');
  }
});

test('an answer the laptop refused records nothing, so its resolution reads as someone else\'s', async () => {
  for (const [code, message] of NOT_LANDED) {
    const h = await showing();
    const pending = h.actions.answerPrompt(P.id, ALLOW);
    h.last('prompt.answer').reject(new AppError(code as 'refused', message));
    await pending;
    assert.equal((h.here(P.id) !== undefined), false, code);
    h.changed({ prompts: [Q], resolved: resolved(P.id, 'phone') });
    assert.deepEqual(h.receipts(), ['Answered on another phone'], code);
    assert.equal(h.card(P.id)?.phase, 'elsewhere', code);
    assert.equal(h.card(P.id)?.elsewhereBy, 'phone', code);
  }
});

test('a too_large answer that does not fit one frame was never posted, and records nothing', async () => {
  const h = await showing();
  const huge: PromptAnswer = { kind: 'question', answers: { [QUESTION]: 'x'.repeat(70_000) } };
  const pending = h.actions.answerPrompt(Q.id, huge);
  h.last('prompt.answer').reject(new AppError('too_large', TOO_LONG));
  await pending;
  assert.equal(h.card(Q.id)?.phase, 'open');
  assert.equal(h.card(Q.id)?.refusal, TOO_LONG);
  assert.equal((h.here(Q.id) !== undefined), false);
  h.changed({ prompts: [P], resolved: resolved(Q.id, 'unknown') });
  assert.deepEqual(h.receipts(), ['Answered elsewhere']);
});

/** A harness whose first answer to `Q`, "Yes, add the test", failed `not_confirmed`, and whose second, "No, this is enough", is on its way. */
async function answeredTwice() {
  const h = await showing();
  const first = h.actions.answerPrompt(Q.id, YES);
  h.last('prompt.answer').reject(new AppError('not_confirmed', NOT_CONFIRMED_TEXT));
  await first;
  assert.equal(h.card(Q.id)?.phase, 'open');
  const second = h.actions.answerPrompt(Q.id, { kind: 'question', answers: { [QUESTION]: 'No, this is enough' } });
  assert.equal(h.answers().length, 2);
  return { h, second };
}

test('a second answer after one that may have landed: already_resolved keeps the first as the likely winner', async () => {
  const { h, second } = await answeredTwice();
  h.last('prompt.answer').resolve({ outcome: 'already_resolved' });
  await second;
  assert.equal(h.card(Q.id)?.phase, 'answered', 'not "Already answered on the laptop"');
  assert.equal(h.card(Q.id)?.summary, 'Yes, add the test');
  assert.equal(h.here(Q.id)?.summary, 'Yes, add the test');
  h.changed({ prompts: [P], resolved: resolved(Q.id, 'phone') });
  assert.deepEqual(h.receipts(), ['Answered on this phone: Yes, add the test']);
  assert.equal(h.card(Q.id), undefined);
});

test('a second answer after one that may have landed: a laptop resolution still reads "Answered on the laptop"', async () => {
  const { h, second } = await answeredTwice();
  h.last('prompt.answer').resolve({ outcome: 'already_resolved' });
  await second;
  h.changed({ prompts: [P], resolved: resolved(Q.id, 'laptop') });
  assert.deepEqual(h.receipts(), ['Answered on the laptop']);
  assert.equal(h.card(Q.id), undefined);
});

test('a second answer after one that may have landed: delivered makes the second the one recorded', async () => {
  const { h, second } = await answeredTwice();
  h.last('prompt.answer').resolve({ outcome: 'delivered' });
  await second;
  assert.equal(h.here(Q.id)?.summary, 'No, this is enough');
  h.changed({ prompts: [P], resolved: resolved(Q.id, 'unknown') });
  assert.deepEqual(h.receipts(), ['Answered on this phone: No, this is enough']);
});

test('a second answer after one that may have landed: a refusal keeps the first, and the card open', async () => {
  const { h, second } = await answeredTwice();
  h.last('prompt.answer').reject(new AppError('refused', REFUSED_TEXT));
  await second;
  assert.equal(h.card(Q.id)?.phase, 'open');
  assert.equal(h.card(Q.id)?.refusal, REFUSED_TEXT);
  assert.equal(h.here(Q.id)?.summary, 'Yes, add the test');
  h.changed({ prompts: [P], resolved: resolved(Q.id, 'unknown') });
  assert.deepEqual(h.receipts(), ['Answered on this phone: Yes, add the test']);
  assert.equal(h.card(Q.id), undefined);
});

test('a held resolution with a reply that may have landed reads as this phone\'s', async () => {
  for (const [code, message] of MAYBE) {
    const h = await showing();
    const pending = h.actions.answerPrompt(Q.id, YES);
    h.changed({ prompts: [P], resolved: resolved(Q.id, 'phone') });
    h.last('prompt.answer').reject(new AppError(code as 'internal', message));
    await pending;
    assert.deepEqual(h.receipts(), ['Answered on this phone: Yes, add the test'], code);
    assert.equal(h.card(Q.id), undefined, code);
    assert.equal((h.here(Q.id) !== undefined), false, code);
  }
});

test('a held resolution after an earlier answer that may have landed reads as that answer, however the second ends', async () => {
  for (const reply of ['already_resolved', new AppError('refused', REFUSED_TEXT)] as const) {
    const { h, second } = await answeredTwice();
    h.changed({ prompts: [P], resolved: resolved(Q.id, 'phone') });
    if (reply instanceof AppError) h.last('prompt.answer').reject(reply);
    else h.last('prompt.answer').resolve({ outcome: reply });
    await second;
    const label = reply instanceof AppError ? reply.code : reply;
    assert.deepEqual(h.receipts(), ['Answered on this phone: Yes, add the test'], label);
    assert.equal(h.card(Q.id), undefined, label);
    assert.equal((h.here(Q.id) !== undefined), false, label);
  }
});

// MARK: - Dismissing

test('dismissPrompt takes down an answered card and sends nothing; a sending card stays', async () => {
  const h = await showing();
  const pending = h.actions.answerPrompt(Q.id, YES);
  h.actions.dismissPrompt(Q.id);
  assert.equal(h.card(Q.id)?.phase, 'sending');
  h.last('prompt.answer').resolve({ outcome: 'delivered' });
  await pending;
  h.actions.dismissPrompt(Q.id);
  assert.equal(h.card(Q.id), undefined);
  assert.equal(h.card(P.id)?.phase, 'open');
  assert.equal(h.sent.filter((s) => s.method !== 'sessions.subscribe' && s.method !== 'transcript.open').length, 1, 'only the answer was sent');
  // The prompt is still open on the laptop: it gets no second card, and its resolution still reads as this phone's.
  h.changed({ prompts: [Q, P] });
  assert.equal(h.card(Q.id), undefined);
  h.changed({ prompts: [P], resolved: resolved(Q.id, 'phone') });
  assert.deepEqual(h.receipts(), ['Answered on this phone: Yes, add the test']);
});

test('dismissing a prompt with no card changes nothing', async () => {
  const h = await showing();
  const before = h.state();
  h.actions.dismissPrompt('no-such-prompt');
  h.actions.dismissPrompt('constructor');
  assert.equal(h.state(), before);
});

/** The session numbered `i`, for the tests that fill the slice with cards. */
function nth(i: number): PhoneSessionRef {
  return { kind: 'local', terminalID: `T-${i}` };
}

/** Prompt `id` of `ref`'s session, opened and then answered on the laptop, so its card waits for OK. */
function answeredOnLaptop(h: ReturnType<typeof harness>, ref: PhoneSessionRef, id: string): void {
  h.changed({ session: ref, prompts: [{ ...Q, id }] });
  h.changed({ session: ref, prompts: [], resolved: resolved(id, 'laptop') });
}

function elsewhereCount(h: ReturnType<typeof harness>): number {
  return Object.values(h.state().prompts.cards).filter((c) => c.phase === 'elsewhere').length;
}

test('the elsewhere cards of the session on screen wait for OK however many others a prompt.changed adds', async () => {
  // R's card is the oldest, and R's set is empty once its prompt is answered.
  const h = await showing([Q]);
  h.changed({ prompts: [], resolved: resolved(Q.id, 'laptop') });
  for (let i = 1; i <= ELSEWHERE_LIMIT; i++) answeredOnLaptop(h, nth(i), `p-${i}`);
  assert.equal(elsewhereCount(h), ELSEWHERE_LIMIT);
  assert.equal(h.card(Q.id)?.phase, 'elsewhere', 'the card on screen stays');
  assert.equal(h.card('p-1', nth(1)), undefined, 'the oldest of the others goes');
  // On the sessions list no screen shows R, so its card goes as the oldest.
  h.actions.back();
  answeredOnLaptop(h, nth(ELSEWHERE_LIMIT + 1), 'p-next');
  assert.equal(h.card(Q.id), undefined);
  assert.equal(h.card('p-2', nth(2))?.phase, 'elsewhere');
});

test('the elsewhere cards of the session on screen wait for OK however many others a late reply adds to', async () => {
  // An answer in OTHER's session is on its way when the user opens R.
  const h = harness();
  h.actions.onChannelUp();
  h.last('sessions.subscribe').resolve({ stream: 's1', seq: 10, replayed: true, omittedRows: 0, more: false });
  h.actions.openSession(OTHER);
  h.last('transcript.open').resolve({ resumed: false, seq: 10, page: { items: [], reachedStart: true, omittedItems: 0 } });
  await flush();
  h.changed({ session: OTHER, prompts: [QO] });
  const pending = h.actions.answerPrompt(QO.id, YES);
  assert.equal(h.card(QO.id, OTHER)?.phase, 'sending');
  h.actions.openSession(R);
  h.last('transcript.open').resolve({ resumed: false, seq: 10, page: { items: [], reachedStart: true, omittedItems: 0 } });
  await flush();
  // R's prompt is answered on the laptop, leaving R's set empty, and others fill the slice.
  answeredOnLaptop(h, R, Q.id);
  for (let i = 1; i < ELSEWHERE_LIMIT; i++) answeredOnLaptop(h, nth(i), `p-${i}`);
  assert.equal(elsewhereCount(h), ELSEWHERE_LIMIT);
  // OTHER's reply comes: its prompt was answered elsewhere, one card more than the slice keeps.
  h.last('prompt.answer').resolve({ outcome: 'already_resolved' });
  await pending;
  assert.equal(h.card(QO.id, OTHER)?.phase, 'elsewhere');
  assert.equal(elsewhereCount(h), ELSEWHERE_LIMIT);
  assert.equal(h.card(Q.id)?.phase, 'elsewhere', 'the card on screen stays');
  assert.equal(h.card('p-1', nth(1)), undefined, 'the oldest of the others goes');
});

// MARK: - Receipts land in the transcript of their session only

test("a held receipt goes to its prompt's session, not to the transcript the phone shows by then", async () => {
  const h = await showing();
  const pending = h.actions.answerPrompt(Q.id, YES);
  h.changed({ prompts: [P], resolved: resolved(Q.id, 'phone') });
  h.actions.openSession(OTHER);
  h.last('transcript.open').resolve({ resumed: false, seq: 11, page: { items: [], reachedStart: true, omittedItems: 0 } });
  await flush();
  assert.equal(h.state().transcript.phase, 'open');
  assert.deepEqual(h.state().transcript.ref, OTHER);
  h.last('prompt.answer').resolve({ outcome: 'delivered' });
  await pending;
  assert.equal(h.card(Q.id), undefined);
  assert.deepEqual(h.receipts(), []);
});

// MARK: - Sending messages

const WORKING_REFUSAL = 'Not sent. Claude is still working. Send again when it stops.';

/**
 * A store showing `R` on the session screen, whose list shows `R` with status `chip` and the
 * `send` capability `send`, and `OTHER`. No channel or transcript is needed: a send asks for
 * neither.
 */
function sendHarness(opts: { chip?: PhoneStatusChip; send?: { available: boolean; reason?: string } } = {}) {
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
  const r: PhoneSession = { ...session(R), status: { chip: opts.chip ?? 'idle', changedAt: 1 } };
  r.capabilities = { ...r.capabilities, send: opts.send ?? CAN };
  const rows: PhoneRow[] = [
    { id: 'W1', kind: 'worktree', name: 'W1', remote: false, statusChangedAt: 1, sessions: [r] },
    { id: 'W2', kind: 'worktree', name: 'W2', remote: false, statusChangedAt: 1, sessions: [{ ...session(OTHER), status: { chip: 'idle', changedAt: 1 } }] },
  ];
  const sessions = applySnapshot({
    stream: 's1', seq: 10, replayed: false, omittedRows: 0, more: false, rows,
    layout: [{ id: 'repo:R1', kind: 'repo', name: 'acme', rows: rows.map((row) => ({ id: row.id, depth: 0 })) }],
  });
  const initial = initialState();
  const store = createStore({ ...initial, sessions, ui: { ...initial.ui, route: { screen: 'session', ref: R } } });
  const actions = createActions({ store, client, link: { openLink: () => {} }, now: () => 0 });
  const state = (): AppState => store.get();
  const sends = (): Sent[] => sent.filter((s) => s.method === 'message.send');
  const own = (r: Readonly<Record<string, string>>, ref: PhoneSessionRef): string | undefined => {
    const k = refKey(ref);
    return Object.hasOwn(r, k) ? r[k] : undefined;
  };
  const draft = (ref: PhoneSessionRef = R): string | undefined => own(store.get().ui.drafts, ref);
  const refusal = (ref: PhoneSessionRef = R): string | undefined => own(store.get().ui.refusal, ref);
  const sending = (ref: PhoneSessionRef = R): boolean => isSending(store.get().prompts, ref);
  /** Puts `text` in `ref`'s refusal slot, as a refused model change would. */
  const refuse = (text: string, ref: PhoneSessionRef = R): void => {
    store.update((s) => {
      const r2 = Object.assign(Object.create(null) as Record<string, string>, s.ui.refusal);
      r2[refKey(ref)] = text;
      return { ...s, ui: { ...s.ui, refusal: r2 } };
    });
  };
  /** Shows `ref`'s session, as a navigation would, without the transcript it opens. */
  const show = (ref: PhoneSessionRef): void => store.update((s) => ({ ...s, ui: { ...s.ui, route: { screen: 'session', ref } } }));
  return { sent, sends, store, actions, state, draft, refusal, sending, refuse, show };
}

test('a blank or whitespace-only draft sends nothing', async () => {
  const invisible = String.fromCodePoint(0x200b, 0x3164, 0xfe0f, 0xfeff);
  for (const text of ['', '  \n ', '\t\r\n', invisible]) {
    const h = sendHarness();
    h.actions.setDraft(text);
    const before = h.state();
    // Checked before awaiting, so a send that went out fails the test rather than waiting on its reply.
    const pending = h.actions.sendMessage();
    assert.deepEqual(h.sends(), [], JSON.stringify(text));
    await pending;
    assert.equal(h.state(), before, 'and nothing changes');
  }
});

test('Send sends the draft as typed to the session the route shows', async () => {
  const h = sendHarness();
  h.actions.setDraft('  Run the unit tests.\n');
  const pending = h.actions.sendMessage();
  assert.deepEqual(h.sends().map((s) => s.params), [{ session: R, text: '  Run the unit tests.\n' }]);
  assert.equal(h.sending(), true);
  h.sends()[0]!.resolve({ outcome: 'sent' });
  await pending;
  assert.equal(h.sending(), false);
  assert.equal(h.draft(), undefined, 'the draft is cleared');
});

test('two sendMessage calls back to back post one message.send', async () => {
  const h = sendHarness();
  h.actions.setDraft('Run the unit tests.');
  const first = h.actions.sendMessage();
  const second = h.actions.sendMessage();
  assert.equal(h.sends().length, 1);
  for (const s of h.sends()) s.resolve({ outcome: 'sent' });
  await Promise.all([first, second]);
  // Once the first settled, a new gesture sends again.
  h.actions.setDraft('And the lint.');
  const third = h.actions.sendMessage();
  assert.deepEqual(h.sends().map((s) => s.params), [{ session: R, text: 'Run the unit tests.' }, { session: R, text: 'And the lint.' }]);
  h.sends()[1]!.resolve({ outcome: 'sent' });
  await third;
});

test('the app never refuses a message on status: the laptop decides', async () => {
  for (const chip of ['working', 'waitingForYou', 'idle', 'rateLimited', 'error', 'exited', 'unknown'] as const) {
    const h = sendHarness({ chip });
    h.actions.setDraft('Also add a progress bar above the steps.');
    const pending = h.actions.sendMessage();
    assert.deepEqual(h.sends().map((s) => s.params), [{ session: R, text: 'Also add a progress bar above the steps.' }], chip);
    assert.equal(h.state().ui.toast, null, `${chip}: no toast`);
    h.sends()[0]!.resolve({ outcome: 'sent' });
    await pending;
  }
});

test('a parked session toasts "Waking the session, then sending…" as the message goes out', async () => {
  const h = sendHarness({ chip: 'parked' });
  h.actions.setDraft('Pick this up again.');
  const pending = h.actions.sendMessage();
  assert.equal(h.sends().length, 1);
  assert.equal(WAKING_TEXT, 'Waking the session, then sending…');
  assert.equal(h.state().ui.toast?.text, WAKING_TEXT, 'before the laptop replies');
  h.sends()[0]!.resolve({ outcome: 'woken' });
  await pending;
  assert.equal(h.draft(), undefined);
});

test('a reply clears the draft and the refusal, whatever its outcome', async () => {
  for (const outcome of ['sent', 'woken', 'unknown']) {
    const h = sendHarness();
    h.actions.setDraft('Run the unit tests.');
    h.refuse(WORKING_REFUSAL);
    const pending = h.actions.sendMessage();
    h.sends()[0]!.resolve({ outcome });
    await pending;
    assert.equal(h.draft(), undefined, outcome);
    assert.equal(h.refusal(), undefined, outcome);
  }
});

test('what the user types while the message is on its way stays once the laptop takes it', async () => {
  const h = sendHarness();
  h.actions.setDraft('Run the unit tests.');
  const pending = h.actions.sendMessage();
  h.actions.setDraft('Run the unit tests. Then the lint.');
  h.sends()[0]!.resolve({ outcome: 'sent' });
  await pending;
  assert.equal(h.draft(), 'Run the unit tests. Then the lint.');
  assert.equal(h.sends().length, 1);
});

test("an error keeps the draft and shows its message as it came, and nothing is sent again", async () => {
  const errors: ReadonlyArray<readonly [string, string]> = [
    ['refused', WORKING_REFUSAL], ['not_confirmed', NOT_CONFIRMED_TEXT], ['bad_reply', 'The laptop sent a reply this app cannot read.'],
    ['internal', 'Something went wrong.'], ['too_large', TOO_LONG], ['bad_request', 'Write a message first.'],
    ['not_found', 'That session is no longer on this laptop.'], ['unavailable', 'The remote provider refused this. Check the laptop.'],
  ];
  for (const [code, message] of errors) {
    const h = sendHarness();
    h.actions.setDraft('Also add a progress bar above the steps.');
    const pending = h.actions.sendMessage();
    h.sends()[0]!.reject(new AppError(code as 'internal', message));
    await pending;
    assert.equal(h.draft(), 'Also add a progress bar above the steps.', code);
    assert.equal(h.refusal(), message, code);
    assert.equal(h.sending(), false, `${code}: the mark goes`);
    await flush();
    assert.equal(h.sends().length, 1, `${code}: no resend`);
  }
});

test('superseded is silent and keeps the draft', async () => {
  const h = sendHarness();
  h.actions.setDraft('Run the unit tests.');
  const pending = h.actions.sendMessage();
  h.sends()[0]!.reject(new AppError('superseded', SUPERSEDED_TEXT));
  await pending;
  assert.equal(h.draft(), 'Run the unit tests.');
  assert.equal(h.refusal(), undefined);
  assert.equal(h.sending(), false);
});

test("an error that is no AppError shows the client's words", async () => {
  const h = sendHarness();
  h.actions.setDraft('Run the unit tests.');
  const pending = h.actions.sendMessage();
  h.sends()[0]!.reject(new TypeError('a fault in the client'));
  await pending;
  assert.equal(h.refusal(), BAD_PARAMS_TEXT);
  assert.equal(h.draft(), 'Run the unit tests.');
});

test('a send takes down the refusal as it goes out, and a new refusal replaces it', async () => {
  const h = sendHarness();
  h.actions.setDraft('Run the unit tests.');
  h.refuse('The laptop refused the model change.');
  const pending = h.actions.sendMessage();
  assert.equal(h.refusal(), undefined);
  h.sends()[0]!.reject(new AppError('refused', WORKING_REFUSAL));
  await pending;
  assert.equal(h.refusal(), WORKING_REFUSAL);
});

test('nothing goes out unless the list shows the session the route shows, with send available', async () => {
  const unavailable = sendHarness({ send: { available: false, reason: 'This session cannot take messages.' } });
  unavailable.actions.setDraft('Run the unit tests.');
  const toUnavailable = unavailable.actions.sendMessage();
  assert.deepEqual(unavailable.sends(), []);
  await toUnavailable;
  assert.equal(unavailable.refusal(), undefined, 'and shows no refusal: the composer shows the note');

  const list = sendHarness();
  list.actions.setDraft('Run the unit tests.');
  list.store.update((s) => ({ ...s, ui: { ...s.ui, route: { screen: 'sessions' } } }));
  const fromList = list.actions.sendMessage();
  assert.deepEqual(list.sends(), []);
  await fromList;

  const gone = sendHarness();
  const missing: PhoneSessionRef = { kind: 'local', terminalID: 'T-gone' };
  gone.show(missing);
  gone.actions.setDraft('Run the unit tests.');
  const toGone = gone.actions.sendMessage();
  assert.deepEqual(gone.sends(), []);
  await toGone;
  assert.equal(gone.sending(missing), false);
});

test('each session has its own draft, refusal and message on its way', async () => {
  const h = sendHarness();
  h.actions.setDraft('For R.');
  const toR = h.actions.sendMessage();
  // The user moves to the other session while R's message is on its way, and sends there.
  h.show(OTHER);
  assert.equal(h.draft(OTHER), undefined);
  h.actions.setDraft('For the other.');
  const toOther = h.actions.sendMessage();
  assert.deepEqual(h.sends().map((s) => s.params), [{ session: R, text: 'For R.' }, { session: OTHER, text: 'For the other.' }]);
  h.sends()[0]!.reject(new AppError('refused', WORKING_REFUSAL));
  await toR;
  // R's refusal lands on R, though the route shows the other session.
  assert.equal(h.refusal(R), WORKING_REFUSAL);
  assert.equal(h.refusal(OTHER), undefined);
  assert.equal(h.draft(R), 'For R.');
  assert.equal(h.sending(OTHER), true);
  h.sends()[1]!.resolve({ outcome: 'sent' });
  await toOther;
  assert.equal(h.draft(OTHER), undefined);
  assert.equal(h.draft(R), 'For R.');
});

test("a reply that comes after the user moved clears the sending session's draft, never the one shown", async () => {
  const h = sendHarness();
  h.actions.setDraft('Run the unit tests.');
  const toR = h.actions.sendMessage();
  // The user moves to the other session and types the same words there.
  h.show(OTHER);
  h.actions.setDraft('Run the unit tests.');
  h.sends()[0]!.resolve({ outcome: 'sent' });
  await toR;
  assert.equal(h.draft(R), undefined, "R's draft goes: R's laptop took it");
  assert.equal(h.draft(OTHER), 'Run the unit tests.', "the other session's draft stays");
  assert.equal(h.sends().length, 1);
});

test('a parked session gets no waking toast for a message the client refuses before posting', async () => {
  const h = sendHarness({ chip: 'parked' });
  // A body over one frame: the client refuses it `too_large` and posts nothing.
  h.actions.setDraft('a'.repeat(MAX_BODY_BYTES));
  const pending = h.actions.sendMessage();
  assert.equal(h.sends().length, 1, 'handed to the client, which refuses it');
  assert.equal(h.state().ui.toast, null, 'no toast: nothing goes to the session');
  h.sends()[0]!.reject(new AppError('too_large', TOO_LONG));
  await pending;
  assert.equal(h.refusal(), TOO_LONG);
  assert.equal(h.draft(), 'a'.repeat(MAX_BODY_BYTES));
  // A message that fits still toasts.
  h.actions.setDraft('Pick this up again.');
  const fits = h.actions.sendMessage();
  assert.equal(h.state().ui.toast?.text, WAKING_TEXT);
  h.sends()[1]!.resolve({ outcome: 'woken' });
  await fits;
});

test('setDraft keeps the text by session and takes down its refusal; on the sessions list it does nothing', () => {
  const h = sendHarness();
  h.refuse(WORKING_REFUSAL);
  h.refuse('Other refusal.', OTHER);
  h.actions.setDraft('Run');
  assert.equal(h.draft(), 'Run');
  assert.equal(h.refusal(), undefined, "typing takes the session's refusal down (mock 1492)");
  assert.equal(h.refusal(OTHER), 'Other refusal.');
  h.actions.setDraft('');
  assert.equal(Object.hasOwn(h.state().ui.drafts, refKey(R)), false, 'an empty draft leaves no entry');
  for (const record of [h.state().ui.drafts, h.state().ui.refusal]) assert.equal(Object.getPrototypeOf(record), null);
  h.store.update((s) => ({ ...s, ui: { ...s.ui, route: { screen: 'sessions' } } }));
  const before = h.state();
  h.actions.setDraft('Lost');
  assert.equal(h.state(), before);
});

test('a prompt.changed while a message is on its way keeps the mark', async () => {
  const h = sendHarness();
  h.actions.setDraft('Run the unit tests.');
  const pending = h.actions.sendMessage();
  h.actions.onEvent({ event: 'prompt.changed', seq: 30, data: { session: R, prompts: [Q] } });
  assert.equal(h.state().prompts.cards[cardKey(R, Q.id)]?.phase, 'open');
  assert.equal(h.sending(), true);
  const again = h.actions.sendMessage();
  assert.equal(h.sends().length, 1, 'still one message on its way');
  await again;
  h.sends()[0]!.resolve({ outcome: 'sent' });
  await pending;
  assert.equal(h.sending(), false);
});
