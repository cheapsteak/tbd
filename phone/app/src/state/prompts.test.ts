import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { PhoneCapability, PhonePrompt, PhoneQuestion, PhoneSessionRef, PromptAnswer, PromptChangedData } from '../protocol/types.ts';
import {
  ANSWERED_HERE_LIMIT, ELSEWHERE_LIMIT, answerFits, answerSummary, applyPromptChanged, beginAnswer, beginSend, cardFor, chooseOption, chooseOther, clearStaleRefusals, dismissCard,
  emptyPrompts, emptyQuestionDraft, endSend, isBlankMessage, isSending, mayHaveLanded, openPrompt, permissionAnswer, questionAnswer,
  otherCounts, otherText, questionValue, receiptSource, receiptText, cardKey, refuseAnswer, selectedCount, setOtherText, settleAnswer, textAt,
  trimLikeLaptop, withText,
} from './prompts.ts';
import type { AnsweredHere, AnswerSettlement, CardState, PromptsState, QuestionDraft } from './prompts.ts';
import { applySnapshot } from './sessionsData.ts';
import type { SessionsData } from './store.ts';

// The questions of `app/test/e2e/scenarios/mock.json`.
const Q1: PhoneQuestion = {
  header: 'Tests', text: 'Add a test for open-redirect attempts too?', multiSelect: false,
  options: [{ label: 'Yes, add the test', description: 'Covers next=https://… and next=//… links' }, { label: 'No, this is enough' }],
};
const QT: PhoneQuestion = {
  header: 'Tone', text: 'Which tone should the welcome screen use?', multiSelect: false,
  options: [{ label: 'Friendly and short' }, { label: 'Plain and formal' }, { label: 'Match the current app' }],
};
const QS: PhoneQuestion = {
  header: 'Steps', text: 'How many onboarding steps?', multiSelect: false,
  options: [{ label: '3 steps', description: 'Hello, account, done' }, { label: '4 steps', description: 'Adds permissions' }],
};
const QK: PhoneQuestion = {
  header: 'Skip', text: 'Can people skip onboarding?', multiSelect: false,
  options: [{ label: 'Yes, show a Skip button' }, { label: 'No, every step is required' }],
};
const QM: PhoneQuestion = {
  header: 'Sections', text: 'Which settings should move to the new screen?', multiSelect: true,
  options: [{ label: 'Notifications' }, { label: 'Privacy' }, { label: 'Account' }, { label: 'Appearance' }, { label: 'Storage' }],
};

/** `d` (or an empty draft) with `labels` tapped on `q`, in order. */
function pick(q: PhoneQuestion, ...labels: string[]): QuestionDraft {
  return pickOn(emptyQuestionDraft(), q, ...labels);
}

function pickOn(d: QuestionDraft, q: PhoneQuestion, ...labels: string[]): QuestionDraft {
  return labels.reduce((acc, label) => chooseOption(acc, q, label), d);
}

/** `d` with `text` typed into `q`'s Other. */
function other(d: QuestionDraft, q: PhoneQuestion, text: string): QuestionDraft {
  return setOtherText(d, q, text);
}

/** A draft built by hand, as a plain object, the way a careless caller might build one. */
function rawDraft(q: PhoneQuestion, picks: string[], otherText: string, otherChosen: boolean): QuestionDraft {
  return {
    picks: { [q.text]: picks },
    other: { [q.text]: otherText },
    otherChosen: otherChosen ? { [q.text]: true } : {},
  };
}

/** `a` with its answers copied onto an ordinary object, to compare with a literal. */
function plain(a: PromptAnswer | null): PromptAnswer | null {
  return a !== null && a.kind === 'question' ? { kind: 'question', answers: { ...a.answers } } : a;
}

function valueOf(a: PromptAnswer | null, text: string): string | undefined {
  assert.ok(a !== null && a.kind === 'question', 'a question answer');
  return a.answers[text];
}

// MARK: - Answers

test('single-select: the label, or the Other text, which wins', () => {
  assert.deepEqual(plain(questionAnswer([Q1], pick(Q1, 'Yes, add the test'))), {
    kind: 'question', answers: { [Q1.text]: 'Yes, add the test' },
  });
  assert.equal(valueOf(questionAnswer([Q1], other(pick(Q1, 'No, this is enough'), Q1, 'Only if quick')), Q1.text), 'Only if quick');
  // Other wins even over an option the draft still holds as picked.
  assert.equal(valueOf(questionAnswer([Q1], rawDraft(Q1, ['No, this is enough'], 'Only if quick', true)), Q1.text), 'Only if quick');
  // A later tap on an option takes Other back.
  assert.equal(valueOf(questionAnswer([Q1], pickOn(other(emptyQuestionDraft(), Q1, 'Only if quick'), Q1, 'No, this is enough')), Q1.text), 'No, this is enough');
});

test('a blank Other does not win, and is no value by itself', () => {
  assert.equal(valueOf(questionAnswer([Q1], rawDraft(Q1, ['Yes, add the test'], ' \n\t ', true)), Q1.text), 'Yes, add the test');
  assert.equal(questionAnswer([Q1], rawDraft(Q1, [], '   ', true)), null);
  assert.equal(questionAnswer([Q1], chooseOther(emptyQuestionDraft(), Q1)), null);
  assert.equal(questionAnswer([QM], chooseOther(emptyQuestionDraft(), QM)), null);
});

test('an Other text is sent trimmed', () => {
  assert.equal(valueOf(questionAnswer([Q1], other(emptyQuestionDraft(), Q1, '  Only if it takes under ten minutes.\n')), Q1.text),
    'Only if it takes under ten minutes.');
  assert.equal(valueOf(questionAnswer([QM], other(pick(QM, 'Privacy'), QM, ' Billing ')), QM.text), 'Privacy, Billing');
});

test('an Other text counts only while Other is chosen', () => {
  assert.equal(valueOf(questionAnswer([Q1], rawDraft(Q1, ['Yes, add the test'], 'Only if quick', false)), Q1.text), 'Yes, add the test');
  const untoggled = chooseOther(other(pick(QM, 'Privacy'), QM, 'Billing'), QM);
  assert.equal(valueOf(questionAnswer([QM], untoggled), QM.text), 'Privacy');
});

test('multi-select: labels in option order, then Other, joined with ", "', () => {
  assert.equal(valueOf(questionAnswer([QM], other(pick(QM, 'Privacy', 'Notifications'), QM, 'Billing')), QM.text),
    'Notifications, Privacy, Billing');
  assert.equal(valueOf(questionAnswer([QM], pick(QM, 'Storage', 'Account')), QM.text), 'Account, Storage');
  assert.equal(valueOf(questionAnswer([QM], other(emptyQuestionDraft(), QM, 'Billing')), QM.text), 'Billing');
  assert.equal(questionAnswer([QM], emptyQuestionDraft()), null);
  // A second tap takes an option back.
  assert.equal(questionAnswer([QM], pick(QM, 'Privacy', 'Privacy')), null);
});

test("a picked label that is not one of the question's options counts for nothing", () => {
  assert.equal(questionAnswer([Q1], rawDraft(Q1, ['Maybe'], '', false)), null);
  assert.equal(valueOf(questionAnswer([QM], rawDraft(QM, ['Maybe', 'Privacy'], '', false)), QM.text), 'Privacy');
});

test('every question needs a value', () => {
  assert.equal(questionAnswer([Q1, QS], pick(Q1, 'Yes, add the test')), null);
  assert.equal(questionAnswer([], emptyQuestionDraft()), null);
  const all = pickOn(pickOn(pick(QT, 'Friendly and short'), QS, '4 steps'), QK, 'Yes, show a Skip button');
  assert.deepEqual(plain(questionAnswer([QT, QS, QK], all)), {
    kind: 'question',
    answers: { [QT.text]: 'Friendly and short', [QS.text]: '4 steps', [QK.text]: 'Yes, show a Skip button' },
  });
});

test('answers sit on a null prototype, so any question text is answered under its own key', () => {
  for (const text of ['__proto__', 'constructor', 'toString', 'hasOwnProperty']) {
    const q: PhoneQuestion = { text, multiSelect: false, options: [{ label: 'Yes' }] };
    const a = questionAnswer([q], pick(q, 'Yes'));
    assert.ok(a !== null && a.kind === 'question', text);
    assert.equal(Object.getPrototypeOf(a.answers), null, text);
    assert.deepEqual(Object.keys(a.answers), [text]);
    assert.equal(Object.getOwnPropertyDescriptor(a.answers, text)?.value, 'Yes', text);
    assert.equal(JSON.stringify(a), `{"kind":"question","answers":{"${text}":"Yes"}}`, text);
    // Nothing is read from a prototype, even out of a plain draft.
    assert.equal(questionAnswer([q], { picks: {}, other: {}, otherChosen: {} }), null, text);
    assert.equal(questionValue(q, { picks: {}, other: {}, otherChosen: {} }), null, text);
  }
});

test('a deny message is trimmed, and a blank one is left out', () => {
  assert.deepEqual(permissionAnswer('deny', '  Run only the unit tests for now. '),
    { kind: 'permission', decision: 'deny', message: 'Run only the unit tests for now.' });
  assert.equal('message' in permissionAnswer('deny', '   '), false);
  assert.equal('message' in permissionAnswer('deny', '\u0085\u2028'), false);
  assert.equal('message' in permissionAnswer('deny'), false);
  assert.deepEqual(permissionAnswer('deny', 'Line one\nLine two'), { kind: 'permission', decision: 'deny', message: 'Line one\nLine two' });
});

test('only a deny carries a message', () => {
  assert.deepEqual(permissionAnswer('allow'), { kind: 'permission', decision: 'allow' });
  assert.deepEqual(permissionAnswer('allow', 'ignored'), { kind: 'permission', decision: 'allow' });
  assert.deepEqual(permissionAnswer('allow_always', 'ignored'), { kind: 'permission', decision: 'allow_always' });
});

test('summaries', () => {
  const a = questionAnswer([QS, QK], pickOn(pick(QS, '3 steps'), QK, 'Yes, show a Skip button'))!;
  assert.equal(answerSummary(a, [QS, QK]), '3 steps; Yes, show a Skip button');
  // Values follow the questions' order, not the answer's.
  assert.equal(answerSummary(a, [QK, QS]), 'Yes, show a Skip button; 3 steps');
  assert.equal(answerSummary(questionAnswer([QM], pick(QM, 'Privacy', 'Notifications'))!, [QM]), 'Notifications, Privacy');
  assert.equal(answerSummary(permissionAnswer('allow'), []), 'Allowed');
  assert.equal(answerSummary(permissionAnswer('allow_always'), []), 'Allowed for this session');
  assert.equal(answerSummary(permissionAnswer('deny', 'Run only the unit tests for now.'), []), 'Denied');
});

test("a summary with none of the answer's questions lists the values in the order of their texts, as the laptop does", () => {
  const answers = Object.assign(Object.create(null) as Record<string, string>, { b: 'two', a: 'one', '\u{1F600}': 'four', '\uFF61': 'three' });
  // By scalar value U+FF61 comes before U+1F600, though its UTF-16 unit is the higher.
  assert.equal(answerSummary({ kind: 'question', answers }, []), 'one; two; three; four');
  assert.equal(answerSummary({ kind: 'question', answers }, [QM]), 'one; two; three; four');
  assert.equal(answerSummary({ kind: 'question', answers: { constructor: 'x' } }, [Q1]), 'x');
});

// MARK: - Receipts

test('receipts', () => {
  assert.equal(receiptText(receiptSource({ promptID: 'p', answeredBy: 'laptop' }, true), 'x'), 'Answered on the laptop');
  assert.equal(receiptText(receiptSource({ promptID: 'p', answeredBy: 'unknown' }, true), 'Yes'), 'Answered on this phone: Yes');
  assert.equal(receiptSource({ promptID: 'p', answeredBy: 'phone' }, false), 'anotherPhone');
});

test('the receipt source for every answeredBy, with and without an answer from this phone', () => {
  const by = (answeredBy: 'phone' | 'laptop' | 'unknown', here: boolean) => receiptSource({ promptID: 'p', answeredBy }, here);
  assert.equal(by('laptop', true), 'laptop');
  assert.equal(by('laptop', false), 'laptop');
  assert.equal(by('phone', true), 'thisPhone');
  assert.equal(by('phone', false), 'anotherPhone');
  assert.equal(by('unknown', true), 'thisPhone');
  assert.equal(by('unknown', false), 'unknown');
  assert.equal(receiptSource({ promptID: 'p', answeredBy: 'phone', deviceID: '0000000A-0000-4000-8000-000000000001' }, true), 'thisPhone');
});

test('receipt texts', () => {
  assert.equal(receiptText('thisPhone', 'Yes, add the test'), 'Answered on this phone: Yes, add the test');
  assert.equal(receiptText('thisPhone', null), 'Answered on this phone');
  assert.equal(receiptText('laptop', 'Yes, add the test'), 'Answered on the laptop');
  assert.equal(receiptText('laptop', null), 'Answered on the laptop');
  assert.equal(receiptText('anotherPhone', 'Yes'), 'Answered on another phone');
  assert.equal(receiptText('unknown', 'Yes'), 'Answered elsewhere');
});

// MARK: - Drafts

test('a single-select tap picks that option alone, and takes Other back', () => {
  const d = chooseOption(other(emptyQuestionDraft(), Q1, 'Only if quick'), Q1, 'Yes, add the test');
  assert.deepEqual([...(d.picks[Q1.text] ?? [])], ['Yes, add the test']);
  assert.equal(Object.hasOwn(d.otherChosen, Q1.text), false);
  assert.equal(d.other[Q1.text], 'Only if quick', 'the typed text stays');
  const again = chooseOption(d, Q1, 'No, this is enough');
  assert.deepEqual([...(again.picks[Q1.text] ?? [])], ['No, this is enough']);
});

test("a multi-select tap toggles its option, and leaves Other as it was", () => {
  const d = chooseOption(other(emptyQuestionDraft(), QM, 'Billing'), QM, 'Privacy');
  assert.deepEqual([...(d.picks[QM.text] ?? [])], ['Privacy']);
  assert.equal(d.otherChosen[QM.text], true);
  assert.deepEqual([...(chooseOption(d, QM, 'Privacy').picks[QM.text] ?? [])], []);
});

test('Other: single-select chooses it in place of the options; multi-select toggles it', () => {
  const single = chooseOther(pick(Q1, 'Yes, add the test'), Q1);
  assert.deepEqual([...(single.picks[Q1.text] ?? [])], []);
  assert.equal(single.otherChosen[Q1.text], true);
  const multi = chooseOther(pick(QM, 'Privacy'), QM);
  assert.deepEqual([...(multi.picks[QM.text] ?? [])], ['Privacy']);
  assert.equal(multi.otherChosen[QM.text], true);
  assert.equal(Object.hasOwn(chooseOther(multi, QM).otherChosen, QM.text), false);
});

test('a multi-select Other leaves the answer by its marker or by blank text, and the count follows it', () => {
  const typed = setOtherText(pick(QM, 'Privacy'), QM, '  Billing ');
  assert.equal(otherText(typed, QM), 'Billing');
  assert.equal(otherCounts(typed, QM), true);
  assert.equal(selectedCount(QM, typed), 2);
  // Unticked (the laptop's marker): the text stays, and counts for nothing.
  const unticked = chooseOther(typed, QM);
  assert.equal(otherText(unticked, QM), 'Billing');
  assert.equal(otherCounts(unticked, QM), false);
  assert.equal(selectedCount(QM, unticked), 1);
  assert.equal(questionValue(QM, unticked), 'Privacy');
  assert.equal(selectedCount(QM, chooseOther(unticked, QM)), 2);
  // Cleared: chosen still, but blank text is no value.
  const cleared = setOtherText(typed, QM, ' ');
  assert.equal(otherText(cleared, QM), '');
  assert.equal(otherCounts(cleared, QM), false);
  assert.equal(selectedCount(QM, cleared), 1);
  assert.equal(questionValue(QM, cleared), 'Privacy');
  // A label that is not an option counts for nothing here either.
  assert.equal(selectedCount(QM, pick(QM, 'Billing')), 0);
  assert.equal(otherText(emptyQuestionDraft(), QM), '');
});

test('typing chooses Other unless the text is blank', () => {
  const blank = setOtherText(pick(Q1, 'Yes, add the test'), Q1, '   ');
  assert.equal(Object.hasOwn(blank.otherChosen, Q1.text), false);
  assert.deepEqual([...(blank.picks[Q1.text] ?? [])], ['Yes, add the test']);
  assert.equal(blank.other[Q1.text], '   ');
  const typed = setOtherText(pick(Q1, 'Yes, add the test'), Q1, 'Only if quick');
  assert.equal(typed.otherChosen[Q1.text], true);
  assert.deepEqual([...(typed.picks[Q1.text] ?? [])], []);
  const multi = setOtherText(pick(QM, 'Privacy'), QM, 'Billing');
  assert.deepEqual([...(multi.picks[QM.text] ?? [])], ['Privacy']);
  assert.equal(multi.otherChosen[QM.text], true);
});

test('a draft change leaves the draft it was given as it was, and keys each question apart', () => {
  const d0 = pick(Q1, 'Yes, add the test');
  const d1 = setOtherText(chooseOption(d0, QM, 'Privacy'), Q1, 'Only if quick');
  assert.deepEqual([...(d0.picks[Q1.text] ?? [])], ['Yes, add the test']);
  assert.equal(Object.hasOwn(d0.picks, QM.text), false);
  assert.equal(Object.hasOwn(d0.other, Q1.text), false);
  assert.deepEqual([...(d1.picks[QM.text] ?? [])], ['Privacy']);
  for (const r of [d1.picks, d1.other, d1.otherChosen]) assert.equal(Object.getPrototypeOf(r), null);
  const proto = chooseOption(emptyQuestionDraft(), { text: '__proto__', multiSelect: true, options: [{ label: 'A' }] }, 'A');
  assert.deepEqual(Object.keys(proto.picks), ['__proto__']);
});

test('the review reads each question’s value from the draft', () => {
  const d = other(pick(QT, 'Plain and formal'), QS, '5 steps');
  assert.equal(questionValue(QT, d), 'Plain and formal');
  assert.equal(questionValue(QS, d), '5 steps');
  assert.equal(questionValue(QK, d), null);
});

// MARK: - Trimming

test('text is trimmed as the laptop trims it', () => {
  assert.equal(trimLikeLaptop(' \t\n\r\u000B\u000C x y \u00A0\u3000\u2028\u2029'), 'x y');
  assert.equal(trimLikeLaptop('\u0085x\u0085'), 'x', 'U+0085 is a newline to Swift');
  assert.equal(trimLikeLaptop('\uFEFFx'), '\uFEFFx', 'U+FEFF is not whitespace to Swift');
  assert.equal(trimLikeLaptop('   '), '');
  assert.equal(trimLikeLaptop(''), '');
  assert.equal(trimLikeLaptop('a\n\nb'), 'a\n\nb');
});

// MARK: - The slice

const R: PhoneSessionRef = { kind: 'local', terminalID: 'T-R' };
const OTHER: PhoneSessionRef = { kind: 'remote', provider: 'acme-cloud', sessionID: 'S-1' };

function questionPrompt(id: string, questions: PhoneQuestion[] = [Q1]): PhonePrompt {
  return { id, kind: 'question', toolName: 'AskUserQuestion', targetTruncated: false, allowAlways: false, questions };
}

function permissionPrompt(id: string, allowAlways = true): PhonePrompt {
  return {
    id, kind: 'permission', toolName: 'Bash', summary: 'Run the tests', target: 'npm test', targetTruncated: false, allowAlways,
    suggestions: allowAlways ? ['Bash(npm test:*)'] : [],
  };
}

function changed(s: PromptsState, data: Partial<PromptChangedData>) {
  return applyPromptChanged(s, { session: R, prompts: [], ...data });
}

/** `s` with `ids` open in `R`'s set. */
function withOpen(...ids: string[]): PromptsState {
  return changed(emptyPrompts(), { prompts: ids.map((id) => questionPrompt(id)) }).prompts;
}

/** The card of `id` in `ref`'s session, or undefined. */
function cardOf(s: PromptsState, id: string, ref: PhoneSessionRef = R): CardState | undefined {
  const k = cardKey(ref, id);
  return Object.hasOwn(s.cards, k) ? s.cards[k] : undefined;
}

/** The `answeredHere` entry of `id` in `ref`'s session, or undefined. */
function hereOf(s: PromptsState, id: string, ref: PhoneSessionRef = R): AnsweredHere | undefined {
  const k = cardKey(ref, id);
  return Object.hasOwn(s.answeredHere, k) ? s.answeredHere[k] : undefined;
}

const MAYBE: AnswerSettlement = { error: 'not_confirmed', message: 'Check.', mayHaveLanded: true };

test('the empty slice has its records on a null prototype', () => {
  const s = emptyPrompts();
  for (const r of [s.bySession, s.cards, s.answeredHere]) assert.equal(Object.getPrototypeOf(r), null);
  assert.equal(cardFor(s, R), null);
});

test('a card key keeps the session and the prompt ID apart', () => {
  assert.notEqual(cardKey(R, 'a'), cardKey(OTHER, 'a'));
  assert.notEqual(cardKey(R, 'a'), cardKey(R, 'b'));
  assert.equal(cardKey(R, 'a'), cardKey({ kind: 'local', terminalID: 'T-R' }, 'a'));
  const short: PhoneSessionRef = { kind: 'local', terminalID: 'T' };
  assert.notEqual(cardKey(short, '-Ra'), cardKey(R, 'a'), 'a pair that would run together into another');
});

test('a prompt.changed that changes nothing returns the slice itself and no receipts', () => {
  const s1 = withOpen('a', 'b');
  const again = changed(s1, { prompts: [questionPrompt('a'), questionPrompt('b')] });
  assert.equal(again.prompts, s1);
  assert.deepEqual(again.receipts, []);
  const base = emptyPrompts();
  assert.equal(changed(base, {}).prompts, base);
  assert.equal(changed(base, { prompts: [], resolved: [] }).prompts, base);
});

test('a resolution for a prompt with no card still leaves its receipt', () => {
  const base = emptyPrompts();
  const out = changed(base, { resolved: [{ promptID: 'gone', answeredBy: 'laptop' }] });
  assert.equal(out.prompts, base);
  assert.deepEqual(out.receipts, [{ id: 'gone', text: 'Answered on the laptop' }]);
});

test('prompts replace the set in order, and each new prompt gets an open card for its session', () => {
  const s = withOpen('a', 'b');
  assert.deepEqual(s.bySession['local:T-R']!.map((p) => p.id), ['a', 'b']);
  assert.deepEqual(Object.keys(s.cards), [cardKey(R, 'a'), cardKey(R, 'b')]);
  for (const id of ['a', 'b']) {
    assert.equal(cardOf(s, id)!.phase, 'open');
    assert.deepEqual(cardOf(s, id)!.session, R);
  }
  const next = changed(s, { prompts: [questionPrompt('b'), questionPrompt('c')] }).prompts;
  assert.deepEqual(next.bySession['local:T-R']!.map((p) => p.id), ['b', 'c']);
  assert.equal(cardOf(next, 'a'), undefined);
  assert.equal(cardOf(next, 'b'), cardOf(s, 'b'), 'a card that did not change is the same object');
});

test("a card follows its prompt's latest fields", () => {
  const s = withOpen('a');
  const updated = questionPrompt('a', [Q1, QS]);
  const next = changed(s, { prompts: [updated] }).prompts;
  assert.equal(cardOf(next, 'a')!.prompt, updated);
  assert.equal(cardOf(next, 'a')!.phase, 'open');
});

test('a sending card stays when its prompt leaves the set, and its reply still settles it', () => {
  const s = beginAnswer(withOpen('a'), R, 'a', 'Yes', 't1');
  const gone = changed(s, { prompts: [] }).prompts;
  assert.equal(cardOf(gone, 'a'), cardOf(s, 'a'));
  assert.equal(beginAnswer(gone, R, 'a', 'Again', 't2'), gone, 'no second answer while the first is in flight');
  const back = changed(gone, { prompts: [questionPrompt('a')] }).prompts;
  assert.equal(cardOf(back, 'a')!.phase, 'sending', 'the prompt coming back finds its card sending');
  assert.equal(openPrompt(back, R, 'a'), null);
  const settled = settleAnswer(back, R, 'a', 't1', { outcome: 'delivered' }).prompts;
  assert.equal(cardOf(settled, 'a')!.phase, 'answered');
  assert.deepEqual(hereOf(settled, 'a'), { summary: 'Yes', taken: true });
});

test('a reply that settles a card whose prompt left the set with no resolution takes the card down, and records the answer', () => {
  const left = changed(beginAnswer(withOpen('a', 'b'), R, 'a', 'Yes', 't1'), { prompts: [questionPrompt('b')] }).prompts;
  assert.equal(cardOf(left, 'a')!.phase, 'sending');
  // Delivered: no Answered card for a prompt the set no longer holds, and the open prompt shows.
  const delivered = settleAnswer(left, R, 'a', 't1', { outcome: 'delivered' });
  assert.equal(cardOf(delivered.prompts, 'a'), undefined);
  assert.deepEqual(hereOf(delivered.prompts, 'a'), { summary: 'Yes', taken: true });
  assert.equal(delivered.receipt, null);
  assert.deepEqual(cardFor(delivered.prompts, R)?.prompt.id, 'b');
  // The prompt coming back finds its answer taken.
  const back = changed(delivered.prompts, { prompts: [questionPrompt('a'), questionPrompt('b')] }).prompts;
  assert.equal(cardOf(back, 'a')!.phase, 'answered');
  assert.equal(cardOf(back, 'a')!.summary, 'Yes');
  // An answer that may have landed: the card goes, the answer is kept, not as taken.
  const maybe = settleAnswer(left, R, 'a', 't1', MAYBE).prompts;
  assert.equal(cardOf(maybe, 'a'), undefined);
  assert.deepEqual(hereOf(maybe, 'a'), { summary: 'Yes', taken: false });
  assert.equal(cardOf(changed(maybe, { prompts: [questionPrompt('a'), questionPrompt('b')] }).prompts, 'a')!.phase, 'open');
  // A refusal: the card goes, and nothing is kept.
  const refused = settleAnswer(left, R, 'a', 't1', { error: 'refused', message: 'No.', mayHaveLanded: false }).prompts;
  assert.equal(cardOf(refused, 'a'), undefined);
  assert.equal(hereOf(refused, 'a'), undefined);
  // already_resolved: elsewhere, which stays until OK whatever its set.
  const lost = settleAnswer(left, R, 'a', 't1', { outcome: 'already_resolved' }).prompts;
  assert.equal(cardOf(lost, 'a')!.phase, 'elsewhere');
  assert.equal(cardFor(lost, R)?.prompt.id, 'a');
  // A prompt still in the set keeps its card, as before.
  const kept = settleAnswer(beginAnswer(withOpen('a', 'b'), R, 'a', 'Yes', 't1'), R, 'a', 't1', { outcome: 'delivered' }).prompts;
  assert.equal(cardOf(kept, 'a')!.phase, 'answered');
});

test('the dock shows no open or answered card whose prompt the set no longer holds', () => {
  const answered = settleAnswer(beginAnswer(withOpen('a', 'b'), R, 'a', 'Yes', 't1'), R, 'a', 't1', { outcome: 'delivered' }).prompts;
  assert.equal(cardFor(answered, R)?.card.phase, 'answered');
  // The same cards with the set changed under them, as no reducer leaves them.
  const [key] = Object.keys(answered.bySession);
  const onlyB: PromptsState = { ...answered, bySession: { [key!]: [questionPrompt('b')] } };
  assert.equal(cardFor(onlyB, R)?.prompt.id, 'b');
  assert.equal(cardFor(onlyB, R)?.card.phase, 'open');
  assert.equal(cardFor({ ...answered, bySession: {} }, R), null);
  // An elsewhere card shows with no set at all.
  const elsewhere = changed(withOpen('a'), { prompts: [], resolved: [{ promptID: 'a', answeredBy: 'laptop' }] }).prompts;
  assert.equal(cardFor({ ...elsewhere, bySession: {} }, R)?.card.phase, 'elsewhere');
});

test("a set for another session drops the sets before it, and their cards but an elsewhere or a sending one", () => {
  let s = withOpen('a', 'b', 'c');
  s = changed(s, { prompts: [questionPrompt('b'), questionPrompt('c')], resolved: [{ promptID: 'a', answeredBy: 'laptop' }] }).prompts;
  s = beginAnswer(s, R, 'b', 'x', 't-b');
  s = settleAnswer(s, R, 'b', 't-b', { outcome: 'delivered' }).prompts;
  s = beginAnswer(s, R, 'c', 'y', 't-c');
  const moved = applyPromptChanged(s, { session: OTHER, prompts: [questionPrompt('o')] }).prompts;
  assert.deepEqual(Object.keys(moved.bySession), ['remote:acme-cloud/S-1']);
  assert.equal(cardOf(moved, 'a')!.phase, 'elsewhere', 'an elsewhere card stays until OK');
  assert.equal(cardOf(moved, 'b'), undefined, 'an answered card goes');
  assert.equal(cardOf(moved, 'c'), cardOf(s, 'c'), 'a sending card stays until its reply');
  assert.equal(cardOf(moved, 'o', OTHER)!.phase, 'open');
  assert.equal(cardFor(moved, R)?.card.phase, 'elsewhere');
  assert.equal(cardFor(moved, OTHER)?.prompt.id, 'o');
  // The reply settles the card all the same: its set is gone, so the card goes with the reply, and
  // the answer is recorded for when the feed comes back.
  const settled = settleAnswer(moved, R, 'c', 't-c', { outcome: 'delivered' }).prompts;
  assert.equal(cardOf(settled, 'c'), undefined, 'an answered card outside the set goes as its reply settles it');
  assert.deepEqual(hereOf(settled, 'c'), { summary: 'y', taken: true }, 'and its entry stays');
  assert.equal(cardFor(settled, R)?.card.phase, 'elsewhere');
  const swept = applyPromptChanged(settled, { session: OTHER, prompts: [questionPrompt('o')] }).prompts;
  assert.deepEqual(hereOf(swept, 'c'), { summary: 'y', taken: true }, 'and stays after the next event');
});

test("a prompt that enters a set starts answered when this phone's answer to it was taken", () => {
  let s = beginAnswer(withOpen('a'), R, 'a', 'Yes', 't1');
  s = settleAnswer(s, R, 'a', 't1', { outcome: 'delivered' }).prompts;
  s = applyPromptChanged(s, { session: OTHER, prompts: [] }).prompts;
  assert.equal(cardOf(s, 'a'), undefined);
  s = changed(s, { prompts: [questionPrompt('a'), questionPrompt('b')] }).prompts;
  assert.equal(cardOf(s, 'a')!.phase, 'answered');
  assert.equal(cardOf(s, 'a')!.summary, 'Yes');
  assert.equal(cardOf(s, 'b')!.phase, 'open');
  assert.equal(openPrompt(s, R, 'a'), null, 'an answered card takes no second answer');
  assert.equal(cardFor(s, R)?.prompt.id, 'a');
  const out = changed(s, { prompts: [questionPrompt('b')], resolved: [{ promptID: 'a', answeredBy: 'phone' }] });
  assert.deepEqual(out.receipts, [{ id: 'a', text: 'Answered on this phone: Yes' }]);
  assert.equal(cardOf(out.prompts, 'a'), undefined);
  assert.equal(hereOf(out.prompts, 'a'), undefined);
});

test('a prompt that enters a set starts open when an answer to it only may have landed', () => {
  let s = beginAnswer(withOpen('a'), R, 'a', 'Yes', 't1');
  s = settleAnswer(s, R, 'a', 't1', MAYBE).prompts;
  s = changed(s, { prompts: [] }).prompts;
  assert.equal(cardOf(s, 'a'), undefined);
  s = changed(s, { prompts: [questionPrompt('a')] }).prompts;
  assert.equal(cardOf(s, 'a')!.phase, 'open');
  assert.equal(cardOf(s, 'a')!.refusal, null);
  assert.deepEqual(hereOf(s, 'a'), { summary: 'Yes', taken: false });
  const out = changed(s, { prompts: [], resolved: [{ promptID: 'a', answeredBy: 'unknown' }] });
  assert.deepEqual(out.receipts, [{ id: 'a', text: 'Answered on this phone: Yes' }]);
  assert.equal(cardOf(out.prompts, 'a'), undefined);
});

test('a resolution for one session never touches a card of another with the same prompt ID', () => {
  const s = applyPromptChanged(emptyPrompts(), { session: OTHER, prompts: [questionPrompt('a')] }).prompts;
  const out = applyPromptChanged(s, { session: OTHER, prompts: [questionPrompt('a')], resolved: [] });
  assert.equal(out.prompts, s);
  const wrong = changed(s, { prompts: [], resolved: [{ promptID: 'a', answeredBy: 'laptop' }] });
  // The feed moved to R, so OTHER's set and its open card go; the resolution does not make it elsewhere.
  assert.equal(cardOf(wrong.prompts, 'a', OTHER), undefined);
  assert.equal(cardOf(wrong.prompts, 'a'), undefined);
  assert.deepEqual(wrong.receipts, [{ id: 'a', text: 'Answered on the laptop' }]);
  // A sending card of OTHER's and an open one of R's with the same ID live side by side.
  let both = beginAnswer(s, OTHER, 'a', 'x', 't-o');
  both = changed(both, { prompts: [questionPrompt('a')] }).prompts;
  assert.equal(cardOf(both, 'a')!.phase, 'open');
  assert.equal(cardOf(both, 'a', OTHER)!.phase, 'sending');
  assert.equal(openPrompt(both, R, 'a')?.id, 'a');
  const resolved = changed(both, { prompts: [], resolved: [{ promptID: 'a', answeredBy: 'laptop' }] }).prompts;
  assert.equal(cardOf(resolved, 'a')!.phase, 'elsewhere');
  assert.equal(cardOf(resolved, 'a', OTHER), cardOf(both, 'a', OTHER));
  assert.equal(cardFor(resolved, OTHER)?.card.phase, 'sending');
  const settled = settleAnswer(resolved, OTHER, 'a', 't-o', { outcome: 'delivered' }).prompts;
  assert.equal(cardOf(settled, 'a', OTHER), undefined, "OTHER's set is gone, so its card goes as the reply settles it");
  assert.equal(cardOf(settled, 'a'), cardOf(resolved, 'a'));
  assert.deepEqual(hereOf(settled, 'a', OTHER), { summary: 'x', taken: true });
  assert.equal(hereOf(settled, 'a'), undefined);
});

test('the dock shows elsewhere first, then sending, then answered, then open, each in set order', () => {
  let s = withOpen('a', 'b', 'c', 'd');
  assert.equal(cardFor(s, R)?.prompt.id, 'a');
  s = beginAnswer(s, R, 'c', 'x', 't-c');
  s = settleAnswer(s, R, 'c', 't-c', { outcome: 'delivered' }).prompts;
  assert.equal(cardFor(s, R)?.prompt.id, 'c', 'answered over open');
  s = beginAnswer(s, R, 'd', 'y', 't-d');
  assert.equal(cardFor(s, R)?.prompt.id, 'd', 'sending over answered');
  s = changed(s, { prompts: [questionPrompt('a'), questionPrompt('c'), questionPrompt('d')], resolved: [{ promptID: 'b', answeredBy: 'laptop' }] }).prompts;
  const shown = cardFor(s, R);
  assert.equal(shown?.prompt.id, 'b', 'elsewhere over sending');
  assert.equal(shown?.card.phase, 'elsewhere');
  assert.equal(shown?.prompt.kind, 'question', 'the card keeps the prompt that left the set');
  assert.equal(cardFor(s, OTHER), null);
});

test('only an open card in the set takes an answer', () => {
  let s = withOpen('a', 'b');
  assert.equal(openPrompt(s, R, 'a')?.id, 'a');
  assert.equal(openPrompt(s, OTHER, 'a'), null);
  assert.equal(openPrompt(s, R, 'zzz'), null);
  assert.equal(openPrompt(s, R, 'constructor'), null);
  s = beginAnswer(s, R, 'a', 'x', 't');
  assert.equal(openPrompt(s, R, 'a'), null);
  assert.equal(beginAnswer(s, R, 'a', 'x', 't2'), s, 'a sending card does not begin again');
  assert.equal(beginAnswer(s, R, 'zzz', 'x', 't2'), s);
  assert.equal(beginAnswer(s, OTHER, 'b', 'x', 't2'), s, "another session's prompt with the ID of an open card");
  s = dismissCard(withOpen('a'), R, 'a');
  assert.equal(openPrompt(s, R, 'a'), null, 'a prompt whose card was taken down');
});

test('a reply settles only the answer whose token it carries', () => {
  const s = beginAnswer(withOpen('a'), R, 'a', 'x', 't1');
  assert.deepEqual(settleAnswer(s, R, 'a', 't0', { outcome: 'delivered' }), { prompts: s, receipt: null });
  assert.deepEqual(settleAnswer(s, R, 'b', 't1', { outcome: 'delivered' }), { prompts: s, receipt: null });
  assert.deepEqual(settleAnswer(s, OTHER, 'a', 't1', { outcome: 'delivered' }), { prompts: s, receipt: null });
  const settled = settleAnswer(s, R, 'a', 't1', { outcome: 'delivered' }).prompts;
  assert.equal(cardOf(settled, 'a')!.phase, 'answered');
  assert.equal(cardOf(settled, 'a')!.answerID, null);
  assert.equal(settleAnswer(settled, R, 'a', 't1', { outcome: 'delivered' }).prompts, settled, 'a second reply changes nothing');
});

test('already_resolved turns the card elsewhere, or answered with an earlier answer that may have landed', () => {
  const s = beginAnswer(withOpen('a'), R, 'a', 'Yes', 't1');
  const none = settleAnswer(s, R, 'a', 't1', { outcome: 'already_resolved' });
  assert.equal(none.receipt, null);
  assert.equal(cardOf(none.prompts, 'a')!.phase, 'elsewhere');
  assert.equal(cardOf(none.prompts, 'a')!.elsewhereBy, null);
  assert.equal(cardOf(none.prompts, 'a')!.summary, null);
  assert.equal(hereOf(none.prompts, 'a'), undefined);
  let e = settleAnswer(s, R, 'a', 't1', MAYBE).prompts;
  e = beginAnswer(e, R, 'a', 'No', 't2');
  const earlier = settleAnswer(e, R, 'a', 't2', { outcome: 'already_resolved' }).prompts;
  assert.equal(cardOf(earlier, 'a')!.phase, 'answered');
  assert.equal(cardOf(earlier, 'a')!.summary, 'Yes', "the earlier answer's summary");
  assert.deepEqual(hereOf(earlier, 'a'), { summary: 'Yes', taken: false }, 'the entry stays');
});

test('a held resolution gives its receipt for the session the card is in', () => {
  let s = beginAnswer(withOpen('a'), R, 'a', 'Yes', 't1');
  s = changed(s, { prompts: [], resolved: [{ promptID: 'a', answeredBy: 'unknown' }] }).prompts;
  assert.notEqual(cardOf(s, 'a')!.held, null);
  const { prompts, receipt } = settleAnswer(s, R, 'a', 't1', { outcome: 'unknown' });
  assert.deepEqual(receipt, { session: R, id: 'a', text: 'Answered on this phone: Yes' });
  assert.equal(cardOf(prompts, 'a'), undefined);
});

test('a laptop resolution of a sending card drops its answeredHere entry, and its reply then changes nothing', () => {
  let s = beginAnswer(withOpen('a'), R, 'a', 'First', 't1');
  s = settleAnswer(s, R, 'a', 't1', MAYBE).prompts;
  s = beginAnswer(s, R, 'a', 'Second', 't2');
  const out = changed(s, { prompts: [], resolved: [{ promptID: 'a', answeredBy: 'laptop' }] });
  assert.deepEqual(out.receipts, [{ id: 'a', text: 'Answered on the laptop' }]);
  assert.equal(hereOf(out.prompts, 'a'), undefined);
  assert.equal(cardOf(out.prompts, 'a')!.phase, 'elsewhere');
  assert.equal(cardOf(out.prompts, 'a')!.elsewhereBy, 'laptop');
  assert.equal(cardOf(out.prompts, 'a')!.answerID, null);
  assert.deepEqual(settleAnswer(out.prompts, R, 'a', 't2', { outcome: 'delivered' }), { prompts: out.prompts, receipt: null });
});

test("a held resolution's reply drops the prompt's answeredHere entry, however it ends", () => {
  const cases: ReadonlyArray<[AnswerSettlement, string]> = [
    [{ outcome: 'delivered' }, 'Answered on this phone: Second'],
    [{ outcome: 'already_resolved' }, 'Answered on this phone: First'],
    [{ error: 'refused', message: 'No.', mayHaveLanded: false }, 'Answered on this phone: First'],
  ];
  for (const [settled, text] of cases) {
    // An answer that may have landed, then its prompt gone with no resolution and back: its
    // entry stays, and its card comes back open.
    let s = beginAnswer(withOpen('a'), R, 'a', 'First', 't1');
    s = settleAnswer(s, R, 'a', 't1', MAYBE).prompts;
    s = changed(s, { prompts: [] }).prompts;
    s = changed(s, { prompts: [questionPrompt('a')] }).prompts;
    assert.deepEqual(hereOf(s, 'a'), { summary: 'First', taken: false });
    s = beginAnswer(s, R, 'a', 'Second', 't2');
    s = changed(s, { prompts: [], resolved: [{ promptID: 'a', answeredBy: 'phone' }] }).prompts;
    const after = settleAnswer(s, R, 'a', 't2', settled);
    assert.equal(hereOf(after.prompts, 'a'), undefined, JSON.stringify(settled));
    assert.equal(after.receipt?.text, text, JSON.stringify(settled));
    assert.equal(cardOf(after.prompts, 'a'), undefined, JSON.stringify(settled));
  }
});

test('answeredHere keeps the newest entries only, and an answer given again moves to the end', () => {
  const ids = Array.from({ length: ANSWERED_HERE_LIMIT + 6 }, (_, i) => `p${i}`);
  let s = withOpen(...ids);
  for (const id of ids) {
    s = beginAnswer(s, R, id, `summary ${id}`, `t-${id}`);
    s = settleAnswer(s, R, id, `t-${id}`, { outcome: 'delivered' }).prompts;
  }
  const kept = Object.keys(s.answeredHere);
  assert.equal(kept.length, ANSWERED_HERE_LIMIT);
  assert.deepEqual(kept, ids.slice(6).map((id) => cardKey(R, id)));
  assert.equal(Object.getPrototypeOf(s.answeredHere), null);
  // A resolution for an entry that was dropped still reads as this phone's, from its answered card.
  const out = changed(s, { prompts: ids.slice(1).map((id) => questionPrompt(id)), resolved: [{ promptID: 'p0', answeredBy: 'phone' }] });
  assert.deepEqual(out.receipts, [{ id: 'p0', text: 'Answered on this phone: summary p0' }]);
  // An answer given again after one that may have landed moves its entry to the end.
  let again = beginAnswer(withOpen('x', 'y'), R, 'x', 'X1', 't-x1');
  again = settleAnswer(again, R, 'x', 't-x1', MAYBE).prompts;
  again = beginAnswer(again, R, 'y', 'Y', 't-y');
  again = settleAnswer(again, R, 'y', 't-y', { outcome: 'delivered' }).prompts;
  again = beginAnswer(again, R, 'x', 'X2', 't-x2');
  again = settleAnswer(again, R, 'x', 't-x2', { outcome: 'delivered' }).prompts;
  assert.deepEqual(Object.keys(again.answeredHere), [cardKey(R, 'y'), cardKey(R, 'x')]);
  assert.deepEqual(hereOf(again, 'x'), { summary: 'X2', taken: true });
});

test('refuseAnswer marks only an open card', () => {
  const s = withOpen('a');
  const refused = refuseAnswer(s, R, 'a', 'No.');
  assert.equal(cardOf(refused, 'a')!.refusal, 'No.');
  assert.equal(refuseAnswer(refused, R, 'a', 'No.'), refused);
  const sending = beginAnswer(s, R, 'a', 'x', 't');
  assert.equal(refuseAnswer(sending, R, 'a', 'No.'), sending);
  assert.equal(refuseAnswer(s, R, 'zzz', 'No.'), s);
  assert.equal(refuseAnswer(s, OTHER, 'a', 'No.'), s);
});

/** A list with one row holding `R`, its `answer` capability `answer`, or with no row at all for null. */
function listWith(answer: PhoneCapability | null): SessionsData {
  const can = { available: true };
  const rows = answer === null ? [] : [{
    id: 'W1', kind: 'worktree' as const, name: 'acme', remote: false, statusChangedAt: 1,
    sessions: [{
      ref: R, agent: 'claude' as const, tabName: 'claude', status: { chip: 'idle' as const, changedAt: 1 },
      capabilities: { transcript: can, send: can, answer, switchProfile: can, fork: can, model: can },
    }],
  }];
  return applySnapshot({
    stream: 's1', seq: 1, replayed: false, omittedRows: 0, more: false, rows,
    layout: [{ id: 'repo:R1', kind: 'repo', name: 'acme', rows: rows.map((r) => ({ id: r.id, depth: 0 })) }],
  });
}

test("clearStaleRefusals clears a refusal when its session's answers turn from off to on, and only then", () => {
  const on = listWith({ available: true });
  const off = listWith({ available: false, reason: 'Answering prompts is turned off on the laptop.' });
  const refusal = (s: PromptsState): string | null | undefined => cardOf(s, 'a')?.refusal;
  const refused = refuseAnswer(withOpen('a', 'b'), R, 'a', 'Answering prompts is turned off.');
  // The same list, or one with the same setting, keeps the refusal; the cards record the setting once.
  assert.equal(clearStaleRefusals(refused, on, on), refused);
  const seen = clearStaleRefusals(refused, on, listWith({ available: true }));
  assert.equal(refusal(seen), 'Answering prompts is turned off.');
  assert.equal(cardOf(seen, 'a')!.answerAvailable, true);
  assert.equal(cardOf(seen, 'b')!.answerAvailable, true);
  assert.equal(clearStaleRefusals(seen, on, listWith({ available: true })), seen);
  // Turned off, it stays: a refusal may say something else than that answering is off.
  const turnedOff = clearStaleRefusals(seen, on, off);
  assert.equal(refusal(turnedOff), 'Answering prompts is turned off.');
  assert.equal(cardOf(turnedOff, 'a')!.answerAvailable, false);
  // Back on, it goes, and stays gone.
  const back = clearStaleRefusals(turnedOff, off, on);
  assert.equal(refusal(back), null);
  assert.equal(clearStaleRefusals(back, on, listWith({ available: true })), back);
  assert.equal(Object.getPrototypeOf(back.cards), null);
  // Another reason while answering stays off is no change that clears it.
  const refusedOff = refuseAnswer(turnedOff, R, 'a', 'Not now.');
  assert.equal(refusal(clearStaleRefusals(refusedOff, off, listWith({ available: false, reason: 'Answering is paused.' }))), 'Not now.');
  // A card that recorded nothing yet takes what it was from the earlier list.
  const fresh = refuseAnswer(withOpen('a'), R, 'a', 'Not now.');
  assert.equal(refusal(clearStaleRefusals(fresh, off, on)), null);
  assert.equal(refusal(clearStaleRefusals(fresh, on, listWith({ available: true }))), 'Not now.');
});

test('a row the list does not hold tells clearStaleRefusals nothing: its card keeps its refusal and what it recorded', () => {
  const on = listWith({ available: true });
  const off = listWith({ available: false });
  const away = listWith(null);
  const refusal = (s: PromptsState): string | null | undefined => cardOf(s, 'a')?.refusal;
  const refused = refuseAnswer(withOpen('a'), R, 'a', 'Claude Code did not take the answer.');
  // Off, then the row is away for a list: nothing changes.
  const wasOff = clearStaleRefusals(refused, on, off);
  assert.equal(clearStaleRefusals(wasOff, off, away), wasOff);
  // Back with answers on: they turned on while the row was away, so the refusal goes.
  assert.equal(refusal(clearStaleRefusals(wasOff, away, on)), null);
  // On, away, then on again: nothing turned on, so the refusal stays.
  const wasOn = clearStaleRefusals(refused, on, listWith({ available: true }));
  assert.equal(clearStaleRefusals(wasOn, on, away), wasOn);
  assert.equal(refusal(clearStaleRefusals(wasOn, away, on)), 'Claude Code did not take the answer.');
  // A card that recorded nothing, its row away in the earlier list too, keeps its refusal.
  assert.equal(refusal(clearStaleRefusals(refused, away, on)), 'Claude Code did not take the answer.');
});

test('each card the slice makes has its own serial, which the card keeps while it stays', () => {
  const s = withOpen('a', 'b');
  const a = cardOf(s, 'a')!.serial;
  const b = cardOf(s, 'b')!.serial;
  assert.notEqual(a, b);
  assert.equal(s.made, 2);
  // A card that changes keeps it.
  assert.equal(cardOf(refuseAnswer(s, R, 'a', 'No.'), 'a')!.serial, a);
  assert.equal(cardOf(beginAnswer(s, R, 'a', 'x', 't'), 'a')!.serial, a);
  assert.equal(cardOf(changed(s, { prompts: [questionPrompt('a', [QT]), questionPrompt('b')] }).prompts, 'a')!.serial, a);
  // A prompt that leaves its set with no resolution and comes back gets a new card, numbered anew.
  const gone = changed(s, { prompts: [questionPrompt('b')] }).prompts;
  assert.equal(cardOf(gone, 'a'), undefined);
  const back = changed(gone, { prompts: [questionPrompt('a'), questionPrompt('b')] }).prompts;
  assert.equal(cardOf(back, 'a')!.serial, 2);
  assert.equal(cardOf(back, 'b')!.serial, b);
  assert.equal(back.made, 3);
});

/** The session numbered `i`, for the tests that fill the slice with cards. */
function nth(i: number): PhoneSessionRef {
  return { kind: 'local', terminalID: `T-${i}` };
}

/** `s` with prompt `id` opened in session `i`'s set and then answered on the laptop, so its card waits for OK. */
function answeredOnLaptop(s: PromptsState, i: number, id = 'p'): PromptsState {
  const opened = applyPromptChanged(s, { session: nth(i), prompts: [questionPrompt(id)] }).prompts;
  return applyPromptChanged(opened, { session: nth(i), prompts: [], resolved: [{ promptID: id, answeredBy: 'laptop' }] }).prompts;
}

function elsewhereCount(s: PromptsState): number {
  return Object.values(s.cards).filter((c) => c.phase === 'elsewhere').length;
}

test('the slice keeps at most ELSEWHERE_LIMIT elsewhere cards, the oldest going first', () => {
  let s = emptyPrompts();
  for (let i = 0; i < ELSEWHERE_LIMIT + 6; i++) s = answeredOnLaptop(s, i);
  assert.equal(elsewhereCount(s), ELSEWHERE_LIMIT);
  for (let i = 0; i < 6; i++) assert.equal(cardOf(s, 'p', nth(i)), undefined, `session ${i}`);
  for (let i = 6; i < ELSEWHERE_LIMIT + 6; i++) assert.equal(cardOf(s, 'p', nth(i))?.phase, 'elsewhere', `session ${i}`);
  assert.equal(Object.getPrototypeOf(s.cards), null);
});

test("the open session's elsewhere cards stay whatever the limit, and others go in their place", () => {
  // Session 0's card is the oldest, then the others fill the slice to the limit.
  let s = answeredOnLaptop(emptyPrompts(), 0, 'k1');
  for (let i = 1; i < ELSEWHERE_LIMIT; i++) s = answeredOnLaptop(s, i);
  assert.equal(elsewhereCount(s), ELSEWHERE_LIMIT);
  // Session 0 is open again, and another of its prompts is answered on the laptop.
  s = answeredOnLaptop(s, 0, 'k2');
  assert.equal(elsewhereCount(s), ELSEWHERE_LIMIT);
  assert.equal(cardOf(s, 'k1', nth(0))?.phase, 'elsewhere');
  assert.equal(cardOf(s, 'k2', nth(0))?.phase, 'elsewhere');
  assert.equal(cardOf(s, 'p', nth(1)), undefined);
  // So in a reply: an answer that finds its prompt answered elsewhere keeps its card, and another goes.
  const opened = applyPromptChanged(s, { session: nth(0), prompts: [questionPrompt('k3')] }).prompts;
  const sending = beginAnswer(opened, nth(0), 'k3', 'x', 't');
  const settled = settleAnswer(sending, nth(0), 'k3', 't', { outcome: 'already_resolved' }).prompts;
  assert.equal(elsewhereCount(settled), ELSEWHERE_LIMIT);
  for (const id of ['k1', 'k2', 'k3']) assert.equal(cardOf(settled, id, nth(0))?.phase, 'elsewhere', id);
  assert.equal(cardOf(settled, 'p', nth(2)), undefined);
});

test('dismissCard takes down any card but a sending one', () => {
  const s = withOpen('a', 'b');
  const down = dismissCard(s, R, 'a');
  assert.deepEqual(Object.keys(down.cards), [cardKey(R, 'b')]);
  const sending = beginAnswer(s, R, 'a', 'x', 't');
  assert.equal(dismissCard(sending, R, 'a'), sending);
  assert.equal(dismissCard(s, R, 'zzz'), s);
  assert.equal(dismissCard(s, OTHER, 'a'), s);
});

test('which failures may mean the answer landed', () => {
  for (const code of ['not_confirmed', 'bad_reply', 'internal']) {
    assert.equal(mayHaveLanded(code, true), true, code);
    assert.equal(mayHaveLanded(code, false), true, code);
  }
  assert.equal(mayHaveLanded('too_large', true), true, "the loader's, after posting");
  assert.equal(mayHaveLanded('too_large', false), false, "the client's, before posting");
  for (const code of ['refused', 'not_found', 'bad_request', 'unsupported', 'unavailable', 'phone_control_off', 'not_open', 'superseded', 'constructor']) {
    assert.equal(mayHaveLanded(code, true), false, code);
  }
});

test('an error that may have landed records the answer, and the card goes back open', () => {
  const s = beginAnswer(withOpen('a'), R, 'a', 'Yes', 't1');
  const after = settleAnswer(s, R, 'a', 't1', MAYBE).prompts;
  assert.equal(cardOf(after, 'a')!.phase, 'open');
  assert.equal(cardOf(after, 'a')!.refusal, 'Check.');
  assert.deepEqual(hereOf(after, 'a'), { summary: 'Yes', taken: false });
  const refused = settleAnswer(s, R, 'a', 't1', { error: 'refused', message: 'No.', mayHaveLanded: false }).prompts;
  assert.equal(hereOf(refused, 'a'), undefined);
  assert.equal(cardOf(refused, 'a')!.refusal, 'No.');
  const superseded = settleAnswer(s, R, 'a', 't1', { error: 'superseded', message: 'Replaced.', mayHaveLanded: false }).prompts;
  assert.equal(cardOf(superseded, 'a')!.phase, 'open');
  assert.equal(cardOf(superseded, 'a')!.refusal, null, 'superseded leaves no refusal');
});

// MARK: - answerFits

test('a question answer fits with a value under exactly each question text', () => {
  const p = questionPrompt('a', [Q1, QM]);
  assert.equal(answerFits(p, { kind: 'question', answers: { [Q1.text]: 'Yes, add the test', [QM.text]: 'Privacy' } }), true);
  assert.equal(answerFits(p, { kind: 'question', answers: { [Q1.text]: 'Yes, add the test' } }), false, 'a question missing');
  assert.equal(answerFits(p, { kind: 'question', answers: { [Q1.text]: 'Yes', [QM.text]: 'Privacy', extra: 'x' } }), false, 'a question added');
  assert.equal(answerFits(p, { kind: 'question', answers: { [Q1.text]: 'Yes', [QS.text]: 'x' } }), false, 'another question');
  assert.equal(answerFits(p, { kind: 'question', answers: { [Q1.text]: 'Yes', [QM.text]: ' \n' } }), false, 'a blank value');
  assert.equal(answerFits(questionPrompt('b', []), { kind: 'question', answers: {} }), false, 'no questions');
  assert.equal(answerFits(p, { kind: 'permission', decision: 'allow' }), false, 'the wrong kind');
  const built = questionAnswer([Q1, QM], pickOn(pick(Q1, 'No, this is enough'), QM, 'Account'));
  assert.ok(built !== null);
  assert.equal(answerFits(p, built), true, 'what questionAnswer builds fits');
});

test('a permission answer fits its prompt', () => {
  const always = permissionPrompt('a', true);
  const once = permissionPrompt('b', false);
  for (const d of ['allow', 'allow_always', 'deny'] as const) assert.equal(answerFits(always, permissionAnswer(d)), true, d);
  assert.equal(answerFits(once, permissionAnswer('allow_always')), false);
  assert.equal(answerFits(once, permissionAnswer('allow')), true);
  assert.equal(answerFits(once, permissionAnswer('deny', 'Run only the unit tests for now.')), true);
  assert.equal(answerFits(once, { kind: 'permission', decision: 'deny', message: '  ' }), false);
  assert.equal(answerFits(once, { kind: 'permission', decision: 'allow', message: 'Go.' }), false);
  assert.equal(answerFits(once, { kind: 'permission', decision: 'maybe' as 'allow' }), false);
  assert.equal(answerFits(once, { kind: 'question', answers: { [Q1.text]: 'Yes' } }), false);
});

// MARK: - Messages

test("isBlankMessage is the laptop's blank rule: whitespace, format and default-ignorable scalars only", () => {
  const blank = ['', ' ', '  \n ', '\t\r\n', String.fromCodePoint(0x85, 0xa0, 0x2028, 0x2029, 0x3000), String.fromCodePoint(0x200b, 0x2060, 0xfeff),
    String.fromCodePoint(0x3164, 0x34f, 0xfe0f)];
  for (const text of blank) assert.equal(isBlankMessage(text), true, JSON.stringify(text));
  const visible = ['a', '  Run the unit tests.\n', String.fromCodePoint(0x1f44d, 0xfe0f), String.fromCodePoint(0x200b) + '.'];
  for (const text of visible) assert.equal(isBlankMessage(text), false, JSON.stringify(text));
});

test('beginSend marks a session once, endSend clears it, and each returns its input when nothing changes', () => {
  const s = emptyPrompts();
  assert.equal(isSending(s, R), false);
  const one = beginSend(s, R);
  assert.equal(isSending(one, R), true);
  assert.equal(isSending(one, OTHER), false);
  assert.equal(beginSend(one, R), one);
  assert.equal(Object.getPrototypeOf(one.sending), null);
  const none = endSend(one, R);
  assert.equal(isSending(none, R), false);
  assert.equal(endSend(none, R), none);
});

test('a prompt.changed keeps the sessions marked as sending', () => {
  const s = beginSend(emptyPrompts(), OTHER);
  const after = applyPromptChanged(s, { session: R, prompts: [questionPrompt('a')] }).prompts;
  assert.notEqual(after, s);
  assert.equal(isSending(after, OTHER), true);
});

test('withText sets, replaces and removes a text by key, on a null prototype', () => {
  const empty = Object.create(null) as Readonly<Record<string, string>>;
  const one = withText(empty, 'k', 'Run');
  assert.equal(textAt(one, 'k'), 'Run');
  assert.equal(Object.getPrototypeOf(one), null);
  assert.equal(withText(one, 'k', 'Run'), one);
  assert.equal(textAt(withText(one, 'k', 'Run it'), 'k'), 'Run it');
  assert.equal(Object.hasOwn(withText(one, 'k', ''), 'k'), false);
  assert.equal(Object.hasOwn(withText(one, 'k', null), 'k'), false);
  assert.equal(withText(empty, 'k', null), empty);
  assert.equal(textAt(empty, 'constructor'), null);
});
