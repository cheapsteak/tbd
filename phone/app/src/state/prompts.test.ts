import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { PhonePrompt, PhoneQuestion, PhoneSessionRef, PromptAnswer, PromptChangedData } from '../protocol/types.ts';
import {
  ANSWERED_HERE_LIMIT, answerFits, answerSummary, applyPromptChanged, beginAnswer, cardFor, chooseOption, chooseOther, dismissCard,
  emptyPrompts, emptyQuestionDraft, mayHaveLanded, openPrompt, permissionAnswer, questionAnswer, questionValue, receiptSource, receiptText,
  refuseAnswer, setOtherText, settleAnswer, trimLikeLaptop,
} from './prompts.ts';
import type { PromptsState, QuestionDraft } from './prompts.ts';

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

test('the empty slice has its records on a null prototype', () => {
  const s = emptyPrompts();
  for (const r of [s.bySession, s.cards, s.answeredHere]) assert.equal(Object.getPrototypeOf(r), null);
  assert.equal(cardFor(s, R), null);
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
  for (const id of ['a', 'b']) {
    assert.equal(s.cards[id]!.phase, 'open');
    assert.deepEqual(s.cards[id]!.session, R);
  }
  const next = changed(s, { prompts: [questionPrompt('b'), questionPrompt('c')] }).prompts;
  assert.deepEqual(next.bySession['local:T-R']!.map((p) => p.id), ['b', 'c']);
  assert.equal(Object.hasOwn(next.cards, 'a'), false);
  assert.equal(next.cards['b'], s.cards['b'], 'a card that did not change is the same object');
});

test("a card follows its prompt's latest fields", () => {
  const s = withOpen('a');
  const updated = questionPrompt('a', [Q1, QS]);
  const next = changed(s, { prompts: [updated] }).prompts;
  assert.equal(next.cards['a']!.prompt, updated);
  assert.equal(next.cards['a']!.phase, 'open');
});

test("a set for another session drops the sets before it, and their cards but an elsewhere one", () => {
  let s = withOpen('a', 'b', 'c');
  s = changed(s, { prompts: [questionPrompt('b'), questionPrompt('c')], resolved: [{ promptID: 'a', answeredBy: 'laptop' }] }).prompts;
  s = beginAnswer(s, 'b', 'x', 't-b');
  s = settleAnswer(s, 'b', 't-b', { outcome: 'delivered' }).prompts;
  s = beginAnswer(s, 'c', 'y', 't-c');
  const moved = applyPromptChanged(s, { session: OTHER, prompts: [questionPrompt('o')] }).prompts;
  assert.deepEqual(Object.keys(moved.bySession), ['remote:acme-cloud/S-1']);
  assert.equal(moved.cards['a']!.phase, 'elsewhere', 'an elsewhere card stays until OK');
  assert.equal(Object.hasOwn(moved.cards, 'b'), false, 'an answered card goes');
  assert.equal(Object.hasOwn(moved.cards, 'c'), false, 'a sending card with no resolution held goes');
  assert.equal(moved.cards['o']!.phase, 'open');
  assert.equal(cardFor(moved, R)?.card.phase, 'elsewhere');
  assert.equal(cardFor(moved, OTHER)?.prompt.id, 'o');
});

test('a resolution for one session never touches a card of another with the same prompt ID', () => {
  const s = applyPromptChanged(emptyPrompts(), { session: OTHER, prompts: [questionPrompt('a')] }).prompts;
  const out = applyPromptChanged(s, { session: OTHER, prompts: [questionPrompt('a')], resolved: [] });
  assert.equal(out.prompts, s);
  const wrong = changed(s, { prompts: [], resolved: [{ promptID: 'a', answeredBy: 'laptop' }] });
  // The feed moved to R, so OTHER's set and its open card go; the resolution does not make it elsewhere.
  assert.equal(Object.hasOwn(wrong.prompts.cards, 'a'), false);
  assert.deepEqual(wrong.receipts, [{ id: 'a', text: 'Answered on the laptop' }]);
});

test('the dock shows elsewhere first, then sending, then answered, then open, each in set order', () => {
  let s = withOpen('a', 'b', 'c', 'd');
  assert.equal(cardFor(s, R)?.prompt.id, 'a');
  s = beginAnswer(s, 'c', 'x', 't-c');
  s = settleAnswer(s, 'c', 't-c', { outcome: 'delivered' }).prompts;
  assert.equal(cardFor(s, R)?.prompt.id, 'c', 'answered over open');
  s = beginAnswer(s, 'd', 'y', 't-d');
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
  s = beginAnswer(s, 'a', 'x', 't');
  assert.equal(openPrompt(s, R, 'a'), null);
  assert.equal(beginAnswer(s, 'a', 'x', 't2'), s, 'a sending card does not begin again');
  assert.equal(beginAnswer(s, 'zzz', 'x', 't2'), s);
  s = dismissCard(withOpen('a'), 'a');
  assert.equal(openPrompt(s, R, 'a'), null, 'a prompt whose card was taken down');
});

test('a reply settles only the answer whose token it carries', () => {
  const s = beginAnswer(withOpen('a'), 'a', 'x', 't1');
  assert.deepEqual(settleAnswer(s, 'a', 't0', { outcome: 'delivered' }), { prompts: s, receipt: null });
  assert.deepEqual(settleAnswer(s, 'b', 't1', { outcome: 'delivered' }), { prompts: s, receipt: null });
  const settled = settleAnswer(s, 'a', 't1', { outcome: 'delivered' }).prompts;
  assert.equal(settled.cards['a']!.phase, 'answered');
  assert.equal(settled.cards['a']!.answerID, null);
  assert.equal(settleAnswer(settled, 'a', 't1', { outcome: 'delivered' }).prompts, settled, 'a second reply changes nothing');
});

test('a held resolution gives its receipt for the session the card is in', () => {
  let s = beginAnswer(withOpen('a'), 'a', 'Yes', 't1');
  s = changed(s, { prompts: [], resolved: [{ promptID: 'a', answeredBy: 'unknown' }] }).prompts;
  assert.notEqual(s.cards['a']!.held, null);
  const { prompts, receipt } = settleAnswer(s, 'a', 't1', { outcome: 'unknown' });
  assert.deepEqual(receipt, { session: R, id: 'a', text: 'Answered on this phone: Yes' });
  assert.equal(Object.hasOwn(prompts.cards, 'a'), false);
});

test("a held resolution's reply drops the prompt's answeredHere entry, however it ends", () => {
  for (const settled of [{ outcome: 'delivered' }, { outcome: 'already_resolved' }, { error: 'refused', message: 'No.', mayHaveLanded: false }] as const) {
    // An answer delivered, then its prompt gone with no resolution and back: its entry stays.
    let s = beginAnswer(withOpen('a'), 'a', 'First', 't1');
    s = settleAnswer(s, 'a', 't1', { outcome: 'delivered' }).prompts;
    s = changed(s, { prompts: [] }).prompts;
    s = changed(s, { prompts: [questionPrompt('a')] }).prompts;
    assert.equal(s.answeredHere['a'], 'First');
    s = beginAnswer(s, 'a', 'Second', 't2');
    s = changed(s, { prompts: [], resolved: [{ promptID: 'a', answeredBy: 'phone' }] }).prompts;
    const after = settleAnswer(s, 'a', 't2', settled).prompts;
    assert.equal(Object.hasOwn(after.answeredHere, 'a'), false, JSON.stringify(settled));
  }
});

test('answeredHere keeps the newest entries only, and an answer given again moves to the end', () => {
  const ids = Array.from({ length: ANSWERED_HERE_LIMIT + 6 }, (_, i) => `p${i}`);
  let s = withOpen(...ids);
  for (const id of ids) {
    s = beginAnswer(s, id, `summary ${id}`, `t-${id}`);
    s = settleAnswer(s, id, `t-${id}`, { outcome: 'delivered' }).prompts;
  }
  const kept = Object.keys(s.answeredHere);
  assert.equal(kept.length, ANSWERED_HERE_LIMIT);
  assert.deepEqual(kept, ids.slice(6));
  assert.equal(Object.getPrototypeOf(s.answeredHere), null);
  // A resolution for an entry that was dropped still reads as this phone's, from its answered card.
  const out = changed(s, { prompts: ids.slice(1).map((id) => questionPrompt(id)), resolved: [{ promptID: 'p0', answeredBy: 'phone' }] });
  assert.deepEqual(out.receipts, [{ id: 'p0', text: 'Answered on this phone: summary p0' }]);
});

test('refuseAnswer marks only an open card', () => {
  const s = withOpen('a');
  const refused = refuseAnswer(s, 'a', 'No.');
  assert.equal(refused.cards['a']!.refusal, 'No.');
  assert.equal(refuseAnswer(refused, 'a', 'No.'), refused);
  const sending = beginAnswer(s, 'a', 'x', 't');
  assert.equal(refuseAnswer(sending, 'a', 'No.'), sending);
  assert.equal(refuseAnswer(s, 'zzz', 'No.'), s);
});

test('dismissCard takes down any card but a sending one', () => {
  const s = withOpen('a', 'b');
  const down = dismissCard(s, 'a');
  assert.deepEqual(Object.keys(down.cards), ['b']);
  const sending = beginAnswer(s, 'a', 'x', 't');
  assert.equal(dismissCard(sending, 'a'), sending);
  assert.equal(dismissCard(s, 'zzz'), s);
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
  const s = beginAnswer(withOpen('a'), 'a', 'Yes', 't1');
  const after = settleAnswer(s, 'a', 't1', { error: 'not_confirmed', message: 'Check.', mayHaveLanded: true }).prompts;
  assert.equal(after.cards['a']!.phase, 'open');
  assert.equal(after.cards['a']!.refusal, 'Check.');
  assert.equal(after.answeredHere['a'], 'Yes');
  const refused = settleAnswer(s, 'a', 't1', { error: 'refused', message: 'No.', mayHaveLanded: false }).prompts;
  assert.equal(Object.hasOwn(refused.answeredHere, 'a'), false);
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
