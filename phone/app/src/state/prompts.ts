// Filled by plan 6 part 6d
//
// The prompt slice of `AppState`: each session's open prompts, the answers this phone sent,
// and the card's own state. Task 6d-2 gives it fields. Until then it is empty.
//
// Contract of the slice, once filled:
// - `emptyPrompts()`: the slice with no prompts.
// - `applyPromptChanged(s, d)`: one `prompt.changed` folded into the slice. It returns the new
//   slice, and one receipt for each prompt in `d.resolved` that should leave a line in the
//   transcript, `id` being the prompt ID and `text` the line ("Answered on this phone: …",
//   "Answered on the laptop", …). `applyEvent` passes each receipt to `addReceipt` in
//   `state/transcript.ts`, in order. When nothing changed it returns `s` itself and no receipts.
//
// The stub: an empty slice, and `applyPromptChanged` returns `{ prompts: s, receipts: [] }`.
//
// Below the slice are the pure rules the prompt card and the slice use: how an answer is built
// from what the user picked, what an answer's one-line summary reads, and which receipt a
// resolution leaves. They are the laptop's rules (`PromptAnswerController` in
// `Sources/TBDApp/Panes/Transcript/PromptAnswerController.swift`), as 4b states them for the
// phone (`PhonePromptAnswerParams` in `PhoneAppMessages.swift`), so the phone sends exactly
// the answer the laptop's card would.

import type {
  PermissionDecision, PhonePromptResolution, PhoneQuestion, PromptAnswer, PromptChangedData,
} from '../protocol/types.ts';
import { emptyRecord } from './store.ts';

// Empty until task 6d-2 gives it fields.
export interface PromptsState {}

export function emptyPrompts(): PromptsState {
  return {};
}

export function applyPromptChanged(
  s: PromptsState,
  d: PromptChangedData,
): { prompts: PromptsState; receipts: ReadonlyArray<{ id: string; text: string }> } {
  return { prompts: s, receipts: [] };
}

// MARK: - Drafts

/**
 * What the user picked on a question card so far, each record keyed by a question's text, on a
 * null prototype (the laptop's `PromptAnswerController.Draft`):
 * - `picks`: the option labels chosen;
 * - `other`: the text typed into "Other";
 * - `otherChosen`: the questions whose "Other" is chosen.
 *
 * Build one with `emptyQuestionDraft` and change it with `chooseOption`, `chooseOther` and
 * `setOtherText`, which keep the records on a null prototype. The readers below read only a
 * record's own keys, so a question whose text is `constructor` or `__proto__` reads nothing
 * inherited whatever draft they are given.
 */
export interface QuestionDraft {
  picks: Readonly<Record<string, readonly string[]>>;
  other: Readonly<Record<string, string>>;
  otherChosen: Readonly<Record<string, true>>;
}

/** A draft with nothing picked. */
export function emptyQuestionDraft(): QuestionDraft {
  return { picks: emptyRecord(), other: emptyRecord(), otherChosen: emptyRecord() };
}

/**
 * `d` after a tap on the option `label` of `q` (the laptop's `Draft.choose`). Single-select:
 * that option alone, and "Other" no longer chosen. Multi-select: the option toggles.
 */
export function chooseOption(d: QuestionDraft, q: PhoneQuestion, label: string): QuestionDraft {
  if (q.multiSelect) {
    const chosen = own(d.picks, q.text) ?? [];
    const picks = chosen.includes(label) ? chosen.filter((l) => l !== label) : [...chosen, label];
    return { ...d, picks: withKey(d.picks, q.text, picks) };
  }
  return { ...d, picks: withKey(d.picks, q.text, [label]), otherChosen: withoutKey(d.otherChosen, q.text) };
}

/**
 * `d` after a tap on the "Other" of `q` (the laptop's `Draft.chooseOther`). Single-select:
 * "Other" is chosen and no option is. Multi-select: "Other" toggles, and the options stay.
 */
export function chooseOther(d: QuestionDraft, q: PhoneQuestion): QuestionDraft {
  if (q.multiSelect) {
    const otherChosen = own(d.otherChosen, q.text) === true ? withoutKey(d.otherChosen, q.text) : withKey(d.otherChosen, q.text, true);
    return { ...d, otherChosen };
  }
  return { ...d, picks: withKey(d.picks, q.text, []), otherChosen: withKey(d.otherChosen, q.text, true) };
}

/**
 * `d` with `text` typed into the "Other" of `q` (the laptop's `Draft.setOtherText`). Text that
 * is not blank also chooses "Other", and for a single-select question unchooses its options.
 * Blank text leaves what is chosen as it was.
 */
export function setOtherText(d: QuestionDraft, q: PhoneQuestion, text: string): QuestionDraft {
  const next: QuestionDraft = { ...d, other: withKey(d.other, q.text, text) };
  if (trimLikeLaptop(text) === '') return next;
  return {
    ...next,
    picks: q.multiSelect ? next.picks : withKey(next.picks, q.text, []),
    otherChosen: withKey(next.otherChosen, q.text, true),
  };
}

// MARK: - Answers

/**
 * The value `d` gives question `q`, or null while it gives none (the laptop's `value(for:draft:)`).
 * - **Single-select:** the "Other" text, trimmed, when "Other" is chosen and the text is not
 *   blank: "Other" wins. Otherwise the first of `q`'s options, in option order, that is picked.
 * - **Multi-select:** the picked labels in option order, then the "Other" text, trimmed, when
 *   "Other" is chosen and the text is not blank, joined with ", ".
 *
 * A picked label that is not one of `q`'s options counts for nothing.
 */
export function questionValue(q: PhoneQuestion, d: QuestionDraft): string | null {
  const chosen = own(d.picks, q.text) ?? [];
  const other = trimLikeLaptop(own(d.other, q.text) ?? '');
  const otherCounts = own(d.otherChosen, q.text) === true && other !== '';
  const labels = q.options.map((o) => o.label);
  if (q.multiSelect) {
    const parts = labels.filter((l) => chosen.includes(l));
    if (otherCounts) parts.push(other);
    return parts.length === 0 ? null : parts.join(', ');
  }
  if (otherCounts) return other;
  return labels.find((l) => chosen.includes(l)) ?? null;
}

/**
 * The answer `d` makes to `questions`, each question's value (`questionValue`) under its text,
 * or null until every question has one. A prompt with no questions has no answer. The answers
 * are on a null prototype, so a question whose text is `__proto__` is answered like any other.
 */
export function questionAnswer(questions: readonly PhoneQuestion[], d: QuestionDraft): PromptAnswer | null {
  if (questions.length === 0) return null;
  const answers = emptyRecord<string>();
  for (const q of questions) {
    const value = questionValue(q, d);
    if (value === null) return null;
    answers[q.text] = value;
  }
  return { kind: 'question', answers };
}

/**
 * The answer a permission card's choice makes. Only a deny carries a message: the message
 * trimmed, and none at all when it is blank once trimmed.
 */
export function permissionAnswer(decision: PermissionDecision, message?: string): PromptAnswer {
  if (decision !== 'deny') return { kind: 'permission', decision };
  const trimmed = trimLikeLaptop(message ?? '');
  return trimmed === '' ? { kind: 'permission', decision } : { kind: 'permission', decision, message: trimmed };
}

/**
 * What an answered card and the receipt "Answered on this phone: …" show of `answer`:
 * - a question answer's values in the order of `questions`, joined with "; ". When none of
 *   `questions` is answered, the values in the order of their questions' texts instead, as the
 *   laptop does;
 * - a permission answer's decision: "Allowed", "Allowed for this session" or "Denied".
 */
export function answerSummary(answer: PromptAnswer, questions: readonly PhoneQuestion[]): string {
  if (answer.kind === 'permission') return PERMISSION_SUMMARIES[answer.decision];
  const ordered: string[] = [];
  for (const q of questions) {
    const value = own(answer.answers, q.text);
    if (value !== undefined) ordered.push(value);
  }
  if (ordered.length > 0) return ordered.join('; ');
  return Object.keys(answer.answers).sort(byCodePoint).map((text) => answer.answers[text]!).join('; ');
}

const PERMISSION_SUMMARIES: Readonly<Record<PermissionDecision, string>> = {
  allow: 'Allowed',
  allow_always: 'Allowed for this session',
  deny: 'Denied',
};

// MARK: - Receipts

/**
 * Who a closed prompt's receipt says answered it:
 * - `laptop` when the laptop says it did, whatever this phone sent;
 * - `thisPhone` otherwise when this phone's answer to it was delivered, or may have been
 *   (`answeredHere`). The phone never learns its own device ID, so `phone` cannot say which
 *   phone it was, and the laptop sends `unknown` when it stops waiting to attribute an answer;
 * - `anotherPhone` otherwise when the laptop says a phone did;
 * - `unknown` otherwise.
 */
export type ReceiptSource = 'thisPhone' | 'laptop' | 'anotherPhone' | 'unknown';

/** The receipt source for resolution `r`, `answeredHere` saying whether this phone's answer to it was delivered or may have been. */
export function receiptSource(r: PhonePromptResolution, answeredHere: boolean): ReceiptSource {
  if (r.answeredBy === 'laptop') return 'laptop';
  if (answeredHere) return 'thisPhone';
  return r.answeredBy === 'phone' ? 'anotherPhone' : 'unknown';
}

/**
 * The receipt line the transcript shows for `source`: "Answered on this phone: <summary>",
 * "Answered on the laptop", "Answered on another phone" or "Answered elsewhere". A `thisPhone`
 * receipt with no summary reads "Answered on this phone".
 */
export function receiptText(source: ReceiptSource, summary: string | null): string {
  switch (source) {
    case 'thisPhone':
      return summary === null || summary === '' ? 'Answered on this phone' : `Answered on this phone: ${summary}`;
    case 'laptop':
      return 'Answered on the laptop';
    case 'anotherPhone':
      return 'Answered on another phone';
    case 'unknown':
      return 'Answered elsewhere';
  }
}

// MARK: - Helpers

/**
 * A run of the characters Swift's `.whitespacesAndNewlines` holds, at either end: the space
 * separators (Zs), U+2028 and U+2029, U+0009 to U+000D, and U+0085. JavaScript's `trim`
 * differs on two of them: it keeps U+0085, and it also drops U+FEFF, which Swift keeps.
 */
const LAPTOP_TRIM = /^[\p{Zs}\u2028\u2029\t-\r\u0085]+|[\p{Zs}\u2028\u2029\t-\r\u0085]+$/gu;

/**
 * `text` trimmed as the laptop trims it (`trimmingCharacters(in: .whitespacesAndNewlines)`), so
 * the phone and the laptop agree on which text is blank: the laptop refuses a blank value.
 */
export function trimLikeLaptop(text: string): string {
  return text.replace(LAPTOP_TRIM, '');
}

/** `r[key]` when it is `r`'s own, or undefined: never an inherited member such as `constructor`. */
function own<V>(r: Readonly<Record<string, V>>, key: string): V | undefined {
  return Object.hasOwn(r, key) ? r[key] : undefined;
}

/** A copy of `r` on a null prototype with `key` set to `value`. */
function withKey<V>(r: Readonly<Record<string, V>>, key: string, value: V): Record<string, V> {
  const next = copy(r);
  next[key] = value;
  return next;
}

/** A copy of `r` on a null prototype without `key`, or `r` itself when it has no such key. */
function withoutKey<V>(r: Readonly<Record<string, V>>, key: string): Readonly<Record<string, V>> {
  if (!Object.hasOwn(r, key)) return r;
  const next = copy(r);
  delete next[key];
  return next;
}

function copy<V>(r: Readonly<Record<string, V>>): Record<string, V> {
  const next = emptyRecord<V>();
  for (const k of Object.keys(r)) next[k] = r[k]!;
  return next;
}

/**
 * Orders strings by Unicode scalar value, as Swift orders them, not by UTF-16 unit as `sort`
 * does by default. Swift also compares canonically equivalent strings as equal; this does not,
 * which matters only to texts that differ in normalization alone.
 */
function byCodePoint(a: string, b: string): number {
  const x = [...a];
  const y = [...b];
  for (let i = 0; i < Math.min(x.length, y.length); i++) {
    const d = x[i]!.codePointAt(0)! - y[i]!.codePointAt(0)!;
    if (d !== 0) return d;
  }
  return x.length - y.length;
}
