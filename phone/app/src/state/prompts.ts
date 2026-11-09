/**
 * The prompt slice of `AppState`: the open session's prompts, each prompt's card in the dock,
 * and the answers this phone sent (spec section 4.4, "Open prompts"). Everything here is pure.
 * `applyEvent` (`events.ts`) folds each `prompt.changed` in with `applyPromptChanged`; the
 * prompt actions (`actions/prompts.ts`) send an answer with `beginAnswer` and fold its reply in
 * with `settleAnswer`; the dock reads `cardFor`.
 *
 * **Where prompts come from.** The laptop sends `prompt.changed` only for the session whose
 * transcript is open on this phone: the session's whole open set, after the transcript opens and
 * on every change, with a resolution for each prompt that closed since the last event, saying who
 * answered it (`answeredBy`). So the slice holds one session's set at a time: a set for another
 * session means the laptop's feed moved there, and the sets it held before are dropped. The feed
 * says nothing when it stops, so the slice can hold a set the laptop no longer sends; the prompt
 * actions answer only while the transcript slice shows the session open.
 *
 * **Keys.** Cards and `answeredHere` are keyed by session and prompt ID together (`cardKey`), so
 * a prompt of another session with the same ID never takes a card's place.
 *
 * **Cards.** A prompt that enters a set gets a card: `answered`, with the summary, when
 * `answeredHere` holds this phone's answer to it and the laptop took that answer (`taken`), and
 * `open` otherwise. A prompt that leaves a set with no resolution loses its card and leaves no
 * receipt, whatever the card showed, with two exceptions: an `elsewhere` card stays until
 * `dismissPrompt`, and a `sending` card stays until its reply settles, whatever happens to its
 * set. A sending card is the record of an answer in flight, so no second answer goes out for its
 * prompt. Once its reply settles, the rule applies: a card whose prompt is no longer in its set
 * goes then, unless it turned `elsewhere`, and `answeredHere` still records the answer when it
 * landed or may have, so the prompt comes back `answered` (or `open`) if it enters the set again.
 * A card keeps the prompt it shows, so it can outlive its prompt's set. A prompt still in the set
 * whose card was taken down does not get a new one.
 *
 * **Answering.** `beginAnswer` turns an `open` card `sending`, and nothing else does, so one
 * gesture sends one answer. Its reply (`settleAnswer`):
 * - `delivered` or `unknown` turns the card `answered`, and records the answer's summary in
 *   `answeredHere`, as taken;
 * - `already_resolved` turns it `elsewhere`, unless `answeredHere` holds an earlier answer of
 *   this phone's to the prompt, which may have landed: that is the likely winner, so the card
 *   turns `answered` with the earlier summary, and the entry stays;
 * - an error turns it back `open`, with the laptop's message as its `refusal`, except
 *   `superseded`, which leaves no refusal. An error that may mean the answer landed all the same
 *   (`mayHaveLanded`) records it in `answeredHere` too, not as taken, so its resolution reads as
 *   this phone's while its card stays answerable; any other records nothing.
 *
 * **A resolution** (`applyPromptChanged`) leaves a receipt, `receiptText(receiptSource(…))`,
 * and then:
 * - an `answered` card is taken down;
 * - an `open` card is taken down when the receipt is this phone's (an answer that may have
 *   landed), and otherwise turns `elsewhere`, `elsewhereBy` saying who answered;
 * - an `elsewhere` card stays, and takes `elsewhereBy` from the resolution when it names one;
 * - a `sending` card with a laptop resolution turns `elsewhere` (`laptop`) with the receipt "Answered
 *   on the laptop" at once, and its reply then changes nothing. With a `phone` or `unknown`
 *   resolution the card holds it (`held`), with no receipt yet, since the laptop may be naming this
 *   phone's own answer: `settleAnswer` writes the receipt once the reply comes. It reads "Answered
 *   on this phone: <summary>", and the card is taken down, when the reply says the answer landed
 *   or may have, or when an earlier answer of this phone's may have; otherwise the receipt reads
 *   as if this phone had not answered, and the card turns `elsewhere`.
 *
 * A resolution's `answeredHere` entry goes once the resolution is applied, and the record keeps
 * at most `ANSWERED_HERE_LIMIT` entries, the oldest going first, for answers whose resolution
 * never comes (a feed that moved to another session sends none for the old one).
 *
 * **Messages.** `sending` marks each session whose `message.send` is on its way, by `refKey`:
 * `beginSend` marks it, and nothing else does, so one gesture sends one message, and `endSend`
 * clears it once the request settles, whatever the outcome. A `prompt.changed` leaves it as it
 * is. `isBlankMessage` is the laptop's rule for a message that types nothing, which it refuses.
 *
 * Records are on a null prototype, so an ID such as `constructor` reads nothing inherited. Each
 * function returns a new object when it changes anything and `s` itself when it does not.
 *
 * Below the slice are the pure rules the card and the slice use: how an answer is built from
 * what the user picked, what an answer's one-line summary reads, and which receipt a resolution
 * leaves. They are the laptop's rules (`PromptAnswerController` in
 * `Sources/TBDApp/Panes/Transcript/PromptAnswerController.swift`), as 4b states them for the
 * phone (`PhonePromptAnswerParams` in `PhoneAppMessages.swift`), so the phone sends exactly the
 * answer the laptop's card would.
 */

import type {
  PermissionDecision, PhonePrompt, PhonePromptResolution, PhoneQuestion, PhoneSessionRef, PromptAnswer, PromptAnswerOutcome,
  PromptChangedData,
} from '../protocol/types.ts';
import { refKey, sameRef } from '../protocol/wire.ts';
import { emptyRecord } from './store.ts';

// MARK: - The slice

/**
 * A card's phase:
 * - `open`: the prompt waits for an answer, and the card offers its choices;
 * - `sending`: this phone's answer is on its way;
 * - `answered`: the laptop took this phone's answer (`delivered`, or `unknown`), and the prompt
 *   has not closed yet;
 * - `elsewhere`: someone else answered first. The card says so until `dismissPrompt`.
 */
export type CardPhase = 'open' | 'sending' | 'answered' | 'elsewhere';

export interface CardState {
  phase: CardPhase;
  /** The laptop's words for the last answer it refused, shown on an `open` card, or null. */
  refusal: string | null;
  /** The summary of this phone's answer while it is `sending` and once it is `answered`, or null. */
  summary: string | null;
  /** Who answered an `elsewhere` card's prompt: the laptop, another phone, or null when the laptop did not say. */
  elsewhereBy: 'laptop' | 'phone' | null;
  /** The session the prompt is open in. */
  session: PhoneSessionRef;
  /** The prompt, as its session's set last sent it. */
  prompt: PhonePrompt;
  /** The token of the answer on its way while `sending`, so only its own reply settles the card; null otherwise. */
  answerID: string | null;
  /** A `phone` or `unknown` resolution that came while `sending`, held until the reply settles; null otherwise. */
  held: PhonePromptResolution | null;
}

/**
 * This phone's answer to a prompt that may have landed: its summary, and whether the laptop took
 * it (`delivered` or `unknown`) rather than failing in a way that may mean it landed all the same.
 */
export interface AnsweredHere {
  summary: string;
  taken: boolean;
}

export interface PromptsState {
  /** The open prompts, by `refKey` of their session, in the laptop's order. Only the open session's set is held. */
  bySession: Readonly<Record<string, readonly PhonePrompt[]>>;
  /** Each card, by `cardKey` of its session and prompt. */
  cards: Readonly<Record<string, CardState>>;
  /** This phone's answers that may have landed, by `cardKey`. */
  answeredHere: Readonly<Record<string, AnsweredHere>>;
  /** The sessions whose `message.send` from this phone is on its way, by `refKey`. */
  sending: Readonly<Record<string, true>>;
}

/** The most entries `answeredHere` keeps. */
export const ANSWERED_HERE_LIMIT = 64;

/**
 * The key of `promptID` in `ref`'s session, for `cards` and `answeredHere`. It encodes the pair as
 * JSON, so no session's key and prompt ID run together into another pair's.
 */
export function cardKey(ref: PhoneSessionRef, promptID: string): string {
  return JSON.stringify([refKey(ref), promptID]);
}

/** The slice with no prompts. */
export function emptyPrompts(): PromptsState {
  return { bySession: emptyRecord(), cards: emptyRecord(), answeredHere: emptyRecord(), sending: emptyRecord() };
}

/**
 * `s` with one `prompt.changed` folded in, and one receipt for each resolution whose receipt is
 * due now, in order, `id` being the prompt ID: `applyEvent` passes each to `addReceipt`. The
 * resolutions are applied first, then `d.prompts` replaces the session's set, and every other
 * session's set is dropped. When nothing changed it returns `s` itself and no receipts. A
 * resolution for a prompt that has no card still gives its receipt, with `s` itself when nothing
 * else changed.
 */
export function applyPromptChanged(
  s: PromptsState,
  d: PromptChangedData,
): { prompts: PromptsState; receipts: ReadonlyArray<{ id: string; text: string }> } {
  const key = refKey(d.session);
  const cards = editable(s.cards);
  const here = editable(s.answeredHere);
  const sets = editable(s.bySession);
  const receipts: { id: string; text: string }[] = [];

  for (const r of d.resolved ?? []) {
    const id = r.promptID;
    const k = cardKey(d.session, id);
    const card = own(cards.value, k);
    if (card?.phase === 'sending') {
      if (r.answeredBy === 'laptop') {
        cards.set(k, { ...card, phase: 'elsewhere', elsewhereBy: 'laptop', refusal: null, answerID: null, held: null });
        receipts.push({ id, text: receiptText('laptop', null) });
        here.delete(k);
      } else {
        cards.set(k, { ...card, held: r });
      }
      continue;
    }
    const entry = own(here.value, k);
    const source = receiptSource(r, entry !== undefined || card?.phase === 'answered');
    receipts.push({ id, text: receiptText(source, entry?.summary ?? card?.summary ?? null) });
    here.delete(k);
    if (card === undefined) continue;
    const by = elsewhereBy(r);
    if (card.phase === 'answered') {
      cards.delete(k);
    } else if (card.phase === 'open') {
      if (source === 'thisPhone') cards.delete(k);
      else cards.set(k, { ...card, phase: 'elsewhere', elsewhereBy: by, refusal: null });
    } else if (by !== null && by !== card.elsewhereBy && source !== 'thisPhone') {
      cards.set(k, { ...card, elsewhereBy: by });
    }
  }

  const before = own(s.bySession, key) ?? [];
  const kept = samePrompts(before, d.prompts) ? before : d.prompts;
  for (const p of kept) {
    const k = cardKey(d.session, p.id);
    const card = own(cards.value, k);
    if (card !== undefined) {
      if (card.prompt !== p && !samePrompt(card.prompt, p)) cards.set(k, { ...card, prompt: p });
    } else if (!before.some((b) => b.id === p.id)) {
      cards.set(k, newCard(d.session, p, own(here.value, k)));
    }
  }
  for (const other of Object.keys(s.bySession)) if (other !== key) sets.delete(other);
  if (kept.length === 0) sets.delete(key);
  else if (kept !== before) sets.set(key, kept);

  for (const k of Object.keys(cards.value)) {
    const card = cards.value[k]!;
    if (!needsItsSet(card)) continue;
    const set = own(sets.value, refKey(card.session)) ?? [];
    if (!set.some((p) => p.id === card.prompt.id)) cards.delete(k);
  }

  if (!cards.changed && !here.changed && !sets.changed) return { prompts: s, receipts };
  return { prompts: { ...s, bySession: sets.value, cards: cards.value, answeredHere: here.value }, receipts };
}

/**
 * The card the dock shows for `ref`'s session, and the prompt it shows, or null when it shows
 * none. An `elsewhere` card comes first, so the user reads that their prompt was answered before
 * another prompt takes its place, then a `sending` card, then an `answered` one, then an `open`
 * one, so a second tap meant for the prompt just answered never lands on the next. Cards of one
 * phase go in the order of the session's set. An `answered` or `open` card shows only while its
 * prompt is in the set: it says the prompt waits, or that it took this phone's answer and has not
 * closed yet, which a prompt the set no longer holds does not.
 */
export function cardFor(s: PromptsState, ref: PhoneSessionRef): { prompt: PhonePrompt; card: CardState } | null {
  const set = own(s.bySession, refKey(ref)) ?? [];
  const candidates: CardState[] = [];
  for (const p of set) {
    const card = own(s.cards, cardKey(ref, p.id));
    if (card !== undefined) candidates.push(card);
  }
  for (const k of Object.keys(s.cards)) candidates.push(s.cards[k]!);
  let best: CardState | null = null;
  for (const card of candidates) {
    if (!sameRef(card.session, ref)) continue;
    if (needsItsSet(card) && !set.some((p) => p.id === card.prompt.id)) continue;
    if (best === null || PHASE_RANK[card.phase] < PHASE_RANK[best.phase]) best = card;
  }
  return best === null ? null : { prompt: best.prompt, card: best };
}

/** Whether `card` stands only while its prompt is in its session's set: an `open` or an `answered` one. */
function needsItsSet(card: CardState): boolean {
  return card.phase === 'open' || card.phase === 'answered';
}

const PHASE_RANK: Readonly<Record<CardPhase, number>> = { elsewhere: 0, sending: 1, answered: 2, open: 3 };

/**
 * The prompt `promptID` when `ref`'s set holds it and its card is `open`, or null: the one prompt
 * an answer may go to now.
 */
export function openPrompt(s: PromptsState, ref: PhoneSessionRef, promptID: string): PhonePrompt | null {
  const prompt = (own(s.bySession, refKey(ref)) ?? []).find((p) => p.id === promptID);
  const card = own(s.cards, cardKey(ref, promptID));
  if (prompt === undefined || card === undefined || card.phase !== 'open') return null;
  return prompt;
}

/**
 * Whether `answer` fits `prompt` (the checks of 4b's `PromptAnswer.validate`), so a stale card
 * never sends an answer of the wrong shape:
 * - its kind is the prompt's;
 * - a question answer has a value, not blank once trimmed, under exactly the prompt's question
 *   texts, and the prompt has at least one question;
 * - a permission answer's decision is one of the three, `allow_always` only when the prompt
 *   offers it (`allowAlways`), and only a deny carries a message, never a blank one.
 */
export function answerFits(prompt: PhonePrompt, answer: PromptAnswer): boolean {
  if (answer.kind !== prompt.kind) return false;
  if (answer.kind === 'permission') {
    if (!Object.hasOwn(PERMISSION_SUMMARIES, answer.decision)) return false;
    if (answer.decision === 'allow_always' && !prompt.allowAlways) return false;
    return answer.message === undefined || (answer.decision === 'deny' && trimLikeLaptop(answer.message) !== '');
  }
  const texts = new Set((prompt.questions ?? []).map((q) => q.text));
  const keys = Object.keys(answer.answers);
  if (texts.size === 0 || keys.length !== texts.size) return false;
  return keys.every((k) => texts.has(k) && trimLikeLaptop(answer.answers[k]!) !== '');
}

/**
 * `s` with the card of `promptID` in `ref`'s session turned `sending`, for this phone's answer,
 * whose summary is `summary` and whose token is `answerID`. Only an `open` card turns; otherwise
 * it returns `s`.
 */
export function beginAnswer(s: PromptsState, ref: PhoneSessionRef, promptID: string, summary: string, answerID: string): PromptsState {
  const k = cardKey(ref, promptID);
  const card = own(s.cards, k);
  if (card === undefined || card.phase !== 'open') return s;
  return withCard(s, k, { ...card, phase: 'sending', refusal: null, summary, answerID, held: null });
}

/**
 * How a `prompt.answer` ended: the laptop's outcome, or the error it failed with, `mayHaveLanded`
 * saying whether the answer may have reached the prompt all the same (`mayHaveLanded`).
 */
export type AnswerSettlement = { outcome: PromptAnswerOutcome } | { error: string; message: string; mayHaveLanded: boolean };

/**
 * Whether an answer that failed with `code` may have reached the prompt all the same
 * (`ACTING_METHODS` in `client/client.ts`):
 * - `not_confirmed`: the channel dropped before the laptop answered;
 * - `bad_reply`: the laptop answered, in a reply this app cannot read;
 * - `internal`: the laptop failed after it may have acted, such as on a result that does not
 *   decode;
 * - `too_large` when `fitsOneFrame`: the loader refused a body all the same, and the client
 *   fails the largest one posted, which need not be the one it refused. A body that does not fit
 *   one frame is refused before it is posted, with the same code, and never lands.
 *
 * Every other code is a refusal: the laptop did not act on it.
 */
export function mayHaveLanded(code: string, fitsOneFrame: boolean): boolean {
  return code === 'not_confirmed' || code === 'bad_reply' || code === 'internal' || (code === 'too_large' && fitsOneFrame);
}

/**
 * `s` with the reply to the answer whose token is `answerID` folded into the card of `promptID`
 * in `ref`'s session, and the receipt due now, if any, for that session's transcript. Only a card
 * still `sending` that answer changes, so a reply that comes after a laptop resolution changes
 * nothing. A sending card leaves the slice only through its reply, or through a laptop resolution,
 * so a reply never finds its card gone otherwise. With no resolution held, a card whose prompt the
 * session's set no longer holds goes as the reply settles it, unless it turns `elsewhere`
 * (`withSettledCard`): its prompt left with no resolution, so nothing waits on it. What the reply
 * records in `answeredHere` it records all the same, so the prompt, should it enter the set again,
 * gets its card back `answered` or `open` (`newCard`); a refusal on it goes with the card.
 */
export function settleAnswer(
  s: PromptsState,
  ref: PhoneSessionRef,
  promptID: string,
  answerID: string,
  settled: AnswerSettlement,
): { prompts: PromptsState; receipt: { session: PhoneSessionRef; id: string; text: string } | null } {
  const k = cardKey(ref, promptID);
  const card = own(s.cards, k);
  if (card === undefined || card.phase !== 'sending' || card.answerID !== answerID) return { prompts: s, receipt: null };
  const outcome = 'outcome' in settled ? settled.outcome : null;
  const taken = outcome === 'delivered' || outcome === 'unknown';
  const landed = taken || ('error' in settled && settled.mayHaveLanded);
  /** An earlier answer of this phone's to the prompt, which may have landed. */
  const earlier = own(s.answeredHere, k);
  const summary = card.summary ?? '';
  if (card.held !== null) {
    const held = card.held;
    const source = landed ? 'thisPhone' : receiptSource(held, earlier !== undefined);
    const receipt = { session: card.session, id: promptID, text: receiptText(source, landed ? summary : (earlier?.summary ?? null)) };
    const after = source === 'thisPhone'
      ? withoutCard(s, k)
      : withCard(s, k, { ...card, phase: 'elsewhere', elsewhereBy: elsewhereBy(held), refusal: null, answerID: null, held: null });
    return { prompts: forget(after, k), receipt };
  }
  if (taken) {
    const answered = withSettledCard(s, k, { ...card, phase: 'answered', answerID: null });
    return { prompts: { ...answered, answeredHere: remember(answered.answeredHere, k, { summary, taken: true }) }, receipt: null };
  }
  if (outcome === 'already_resolved') {
    const after: CardState = earlier === undefined
      ? { ...card, phase: 'elsewhere', elsewhereBy: null, summary: null, answerID: null }
      : { ...card, phase: 'answered', summary: earlier.summary, answerID: null };
    return { prompts: withSettledCard(s, k, after), receipt: null };
  }
  const refusal = 'error' in settled && settled.error !== 'superseded' ? settled.message : null;
  const reopened = withSettledCard(s, k, { ...card, phase: 'open', refusal, summary: null, answerID: null });
  if (!landed) return { prompts: reopened, receipt: null };
  return { prompts: { ...reopened, answeredHere: remember(reopened.answeredHere, k, { summary, taken: false }) }, receipt: null };
}

/** `s` with the `open` card of `promptID` in `ref`'s session showing `refusal`, or `s` itself when it has no such card. */
export function refuseAnswer(s: PromptsState, ref: PhoneSessionRef, promptID: string, refusal: string): PromptsState {
  const k = cardKey(ref, promptID);
  const card = own(s.cards, k);
  if (card === undefined || card.phase !== 'open' || card.refusal === refusal) return s;
  return withCard(s, k, { ...card, refusal });
}

/**
 * `s` without the card of `promptID` in `ref`'s session. A `sending` card stays, since its reply
 * still has to say who answered; so does `s` when there is no such card.
 */
export function dismissCard(s: PromptsState, ref: PhoneSessionRef, promptID: string): PromptsState {
  const k = cardKey(ref, promptID);
  const card = own(s.cards, k);
  if (card === undefined || card.phase === 'sending') return s;
  return withoutCard(s, k);
}

/** Whether a `message.send` from this phone to `ref`'s session is on its way. */
export function isSending(s: PromptsState, ref: PhoneSessionRef): boolean {
  return Object.hasOwn(s.sending, refKey(ref));
}

/** `s` with `ref`'s session marked as sending a message, or `s` itself when it already is. */
export function beginSend(s: PromptsState, ref: PhoneSessionRef): PromptsState {
  const k = refKey(ref);
  return Object.hasOwn(s.sending, k) ? s : { ...s, sending: withKey(s.sending, k, true) };
}

/** `s` with `ref`'s session no longer marked as sending a message, or `s` itself when it was not. */
export function endSend(s: PromptsState, ref: PhoneSessionRef): PromptsState {
  const sending = withoutKey(s.sending, refKey(ref));
  return sending === s.sending ? s : { ...s, sending };
}

/** The card a prompt entering `session`'s set gets: `answered` when `entry` is this phone's answer the laptop took, `open` otherwise. */
function newCard(session: PhoneSessionRef, prompt: PhonePrompt, entry: AnsweredHere | undefined): CardState {
  const card: CardState = {
    phase: 'open', refusal: null, summary: null, elsewhereBy: null, session, prompt, answerID: null, held: null,
  };
  return entry?.taken === true ? { ...card, phase: 'answered', summary: entry.summary } : card;
}

function elsewhereBy(r: PhonePromptResolution): 'laptop' | 'phone' | null {
  return r.answeredBy === 'unknown' ? null : r.answeredBy;
}

function withCard(s: PromptsState, k: string, card: CardState): PromptsState {
  return { ...s, cards: withKey(s.cards, k, card) };
}

function withoutCard(s: PromptsState, k: string): PromptsState {
  const cards = withoutKey(s.cards, k);
  return cards === s.cards ? s : { ...s, cards };
}

/**
 * `s` with `card`, which a reply just settled, under `k`; or without it when it is `open` or
 * `answered` and its session's set no longer holds its prompt (`needsItsSet`), as
 * `applyPromptChanged` takes such a card down.
 */
function withSettledCard(s: PromptsState, k: string, card: CardState): PromptsState {
  const listed = (own(s.bySession, refKey(card.session)) ?? []).some((p) => p.id === card.prompt.id);
  return needsItsSet(card) && !listed ? withoutCard(s, k) : withCard(s, k, card);
}

/** `s` without the `answeredHere` entry under `k`. */
function forget(s: PromptsState, k: string): PromptsState {
  const answeredHere = withoutKey(s.answeredHere, k);
  return answeredHere === s.answeredHere ? s : { ...s, answeredHere };
}

/** `r` with `entry` recorded last under `k`, and only the newest `ANSWERED_HERE_LIMIT` entries kept. */
function remember(r: Readonly<Record<string, AnsweredHere>>, k: string, entry: AnsweredHere): Record<string, AnsweredHere> {
  const next = copy(r);
  delete next[k];
  next[k] = entry;
  const keys = Object.keys(next);
  for (let i = 0; i < keys.length - ANSWERED_HERE_LIMIT; i++) delete next[keys[i]!];
  return next;
}

/** Two prompt sets that hold the same prompts, field for field, in the same order. */
function samePrompts(a: readonly PhonePrompt[], b: readonly PhonePrompt[]): boolean {
  return a.length === b.length && a.every((p, i) => samePrompt(p, b[i]!));
}

/**
 * Two prompts with the same fields. Both are decoded from the laptop's JSON, which writes a
 * prompt's fields in one order, so their encodings match when their fields do.
 */
function samePrompt(a: PhonePrompt, b: PhonePrompt): boolean {
  return a === b || JSON.stringify(a) === JSON.stringify(b);
}

/**
 * A record copied the first time it is changed, so the one it started from stays as it was and
 * `changed` says whether it was.
 */
function editable<V>(base: Readonly<Record<string, V>>) {
  let value: Record<string, V> = base as Record<string, V>;
  let changed = false;
  const writable = (): Record<string, V> => {
    if (!changed) {
      value = copy(base);
      changed = true;
    }
    return value;
  };
  return {
    get value(): Readonly<Record<string, V>> { return value; },
    get changed(): boolean { return changed; },
    set(key: string, v: V): void { writable()[key] = v; },
    delete(key: string): void { if (Object.hasOwn(value, key)) delete writable()[key]; },
  };
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

/** The text typed into the "Other" of `q` in `d`, trimmed as the laptop trims it: `''` when there is none. */
export function otherText(d: QuestionDraft, q: PhoneQuestion): string {
  return trimLikeLaptop(own(d.other, q.text) ?? '');
}

/**
 * Whether the "Other" of `q` gives `d` a value: it is chosen (the laptop's `Draft.isOtherChosen`)
 * and its text is not blank.
 */
export function otherCounts(d: QuestionDraft, q: PhoneQuestion): boolean {
  return own(d.otherChosen, q.text) === true && otherText(d, q) !== '';
}

/**
 * How many values a multi-select question `q` has in `d`: its picked options, and its "Other"
 * when it counts (`otherCounts`). The count "Send N selected" shows.
 */
export function selectedCount(q: PhoneQuestion, d: QuestionDraft): number {
  const chosen = own(d.picks, q.text) ?? [];
  return q.options.filter((o) => chosen.includes(o.label)).length + (otherCounts(d, q) ? 1 : 0);
}

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
  const other = otherCounts(d, q) ? otherText(d, q) : null;
  const labels = q.options.map((o) => o.label);
  if (q.multiSelect) {
    const parts = labels.filter((l) => chosen.includes(l));
    if (other !== null) parts.push(other);
    return parts.length === 0 ? null : parts.join(', ');
  }
  if (other !== null) return other;
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

// MARK: - Messages

/**
 * A scalar that types nothing a person could see: whitespace (`\p{White_Space}` is the set
 * Swift's `.whitespacesAndNewlines` holds), a format character (`Cf`), or a default-ignorable
 * code point.
 */
const INVISIBLE = /^[\p{White_Space}\p{Cf}\p{Default_Ignorable_Code_Point}]*$/u;

/**
 * Whether `text` is a message the laptop refuses as blank, "Write a message first."
 * (`PhoneMessageText.isBlank` in `Sources/TBDDaemon/Base/PhoneMessageText.swift`): empty, or
 * every scalar whitespace, a format character such as U+200B ZERO WIDTH SPACE, or a
 * default-ignorable code point such as U+3164 HANGUL FILLER. One visible scalar makes it not
 * blank.
 */
export function isBlankMessage(text: string): boolean {
  return INVISIBLE.test(text);
}

/** The text under `key` in `r` (a session's draft or refusal, by `refKey`), or null when there is none. */
export function textAt(r: Readonly<Record<string, string>>, key: string): string | null {
  return own(r, key) ?? null;
}

/**
 * `r` with `text` under `key`, or without `key` when `text` is null or empty; `r` itself when
 * that changes nothing. The copy is on a null prototype.
 */
export function withText(r: Readonly<Record<string, string>>, key: string, text: string | null): Readonly<Record<string, string>> {
  return text === null || text === '' ? withoutKey(r, key) : withValue(r, key, text);
}

// MARK: - Helpers
//
// `trimLikeLaptop` and the record helpers are shared with the sheet slice (`sheets.ts`).

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
export function own<V>(r: Readonly<Record<string, V>>, key: string): V | undefined {
  return Object.hasOwn(r, key) ? r[key] : undefined;
}

/** A copy of `r` on a null prototype with `key` set to `value`. */
export function withKey<V>(r: Readonly<Record<string, V>>, key: string, value: V): Record<string, V> {
  const next = copy(r);
  next[key] = value;
  return next;
}

/** A copy of `r` on a null prototype with `key` set to `value`, or `r` itself when it holds that already. */
export function withValue<V>(r: Readonly<Record<string, V>>, key: string, value: V): Readonly<Record<string, V>> {
  return own(r, key) === value ? r : withKey(r, key, value);
}

/** A copy of `r` on a null prototype without `key`, or `r` itself when it has no such key. */
export function withoutKey<V>(r: Readonly<Record<string, V>>, key: string): Readonly<Record<string, V>> {
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
