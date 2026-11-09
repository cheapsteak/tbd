// Filled by plan 6 part 6d
//
// The prompt and composer actions: answering an open prompt, taking its card down, and sending
// a message. The prompt slice they change is `state/prompts.ts`.
//
// Contract:
// - `answerPrompt(promptID, answer): Promise<void>` – sends `prompt.answer` for the open
//   session, once, and records the answer's summary (`answerSummary` of the prompt's questions)
//   for the receipt ("Answered on this phone: <summary>"). It resolves once the laptop replied or
//   the request failed. It sends nothing, and changes nothing, unless every one of these holds at
//   the moment of the gesture:
//   - the route shows a session, and the list shows that session (`findSession`);
//   - the transcript slice shows that session's transcript open (`phase` `open`, a resume
//     included). The laptop sends a session's prompts only while its transcript is open on this
//     phone and says nothing when it stops, so a set the slice holds for a session whose
//     transcript is opening, failed or closed may be stale;
//   - that session's prompt set holds `promptID`, and its card is `open`, so a second tap while
//     the first answer is on its way, or on a card that shows it was answered, sends nothing;
//   - `answer` fits the prompt (`answerFits`).
//   When the list shows the session's `answer` capability unavailable, it sends nothing and
//   shows the list's reason as the card's refusal, the words the laptop would refuse it with.
//   The reply is folded in with `settleAnswer`, whose receipt goes to the transcript through
//   `addReceipt`, as `applyEvent`'s do.
// - `dismissPrompt(promptID): void` – takes the card of `promptID` in the session the route
//   shows down from the dock, such as once it shows "Answered" or that someone else answered. It
//   leaves a `sending` card, whose reply still has to say who answered, changes only the prompt
//   slice, and sends nothing.
// - `setDraft(text): void` – keeps `text` as the unsent text of the session the route shows, in
//   `ui.drafts` by `refKey` of the session, and takes down that session's refusal in
//   `ui.refusal`, as the mock's composer does once the user types (mock 1489-1493).
// - `sendMessage(): Promise<void>` – sends the draft of the session the route shows with
//   `message.send`, as typed, and resolves once the laptop replied or the request failed. Every
//   part of it is read from the store at the moment of the gesture. It sends nothing, and
//   changes nothing, unless every one of these holds:
//   - the route shows a session, and the list shows that session (`findSession`) with its `send`
//     capability available;
//   - no `message.send` to that session is on its way (`isSending`), so a second tap while the
//     first message is on its way sends nothing;
//   - the draft is not blank (`isBlankMessage`), since the laptop refuses a blank message
//     `bad_request` ("Write a message first.", 4b `PhoneAppService+Send.swift`).
//   The session's status plays no part: the laptop takes a message while a session works and
//   answers for itself, and the app shows its reply. When the send goes out it marks the session
//   as sending (`beginSend`), takes down the session's refusal, and, when the list shows the
//   session `parked`, toasts "Waking the session, then sending…". It does not toast a message
//   whose body the client refuses before posting (too large for one frame, or params that make
//   no body), since nothing goes to the session; the client's refusal shows as any error does.
//   When the request settles the mark goes (`endSend`), and:
//   - a reply (`sent`, `woken` or any other outcome) clears the draft, but only when it still
//     holds the text sent: what the user typed meanwhile stays;
//   - an error keeps the draft and puts the error's message in `ui.refusal` as it came,
//     `not_confirmed` included; `superseded` leaves no refusal.
// Like every action, none rejects (`actions/index.ts`); `superseded` is silent.
//
// **Never retry an answer or a send automatically under a new request ID.** An answer or a
// send that failed with `not_confirmed`, `bad_reply`, `internal` or `too_large` may have
// happened all the same (`ACTING_METHODS` in `client/client.ts`), and a new ID is a new action
// to the laptop. Show the error, and leave the choice to the user: such a failure turns the card
// back `open` with the error's message, and only a new tap sends again. It also records the
// answer as this phone's (`mayHaveLanded` in `state/prompts.ts`), so that if it did land, its
// resolution reads "Answered on this phone". To tell the loader's `too_large`, which may come
// after the answer was posted, from the client's, refused before posting, the action checks the
// body against one frame itself, as the client does. A send that failed keeps the draft and
// shows the error, and only a new tap on Send sends again.

import { AppError, BAD_PARAMS_TEXT, newRequestID } from '../client/client.ts';
import { fitsFrame } from '../limits.ts';
import type { Method, ParamsOf, PhonePrompt, PhonePromptAnswerParams, PhoneSessionRef, PromptAnswer } from '../protocol/types.ts';
import { refKey, requestBody, sameRef } from '../protocol/wire.ts';
import {
  answerFits, answerSummary, beginAnswer, beginSend, dismissCard, endSend, isBlankMessage, isSending, mayHaveLanded, openPrompt,
  refuseAnswer, settleAnswer, textAt, withText,
} from '../state/prompts.ts';
import type { AnswerSettlement, PromptsState } from '../state/prompts.ts';
import { findSession } from '../state/route.ts';
import type { AppState, UIState } from '../state/store.ts';
import { addReceipt } from '../state/transcript.ts';
import type { ActionContext, Actions } from './index.ts';
import { errorText } from './sheets.ts';

/** The toast when a message goes to a parked session (mock `send()`). */
export const WAKING_TEXT = 'Waking the session, then sending…';

/**
 * Where an answer to `promptID` goes, read from `s` at the moment of the gesture: the session the
 * route shows, as the list shows it, with the prompt it answers and, when the list shows the
 * session's `answer` capability unavailable with a reason, that reason; or null when the answer
 * must not go out (see `answerPrompt`).
 */
function answerTarget(s: AppState, promptID: string, answer: PromptAnswer): { ref: PhoneSessionRef; prompt: PhonePrompt; refusal: string | null } | null {
  const { route } = s.ui;
  if (route.screen !== 'session') return null;
  const t = s.transcript;
  if (t.phase !== 'open' || t.ref === null || !sameRef(t.ref, route.ref)) return null;
  const prompt = openPrompt(s.prompts, route.ref, promptID);
  if (prompt === null || !answerFits(prompt, answer)) return null;
  const found = findSession(s.sessions, route.ref);
  if (found === null) return null;
  const capability = found.session.capabilities.answer;
  if (capability.available) return { ref: found.session.ref, prompt, refusal: null };
  return capability.reason === undefined ? null : { ref: found.session.ref, prompt, refusal: capability.reason };
}

/**
 * Whether `params` make a `method` body that fits one frame, measured as the client measures it
 * before posting (`request` in `client/client.ts`), with an ID of the length the client gives.
 * One that does not, or whose params do not make a body at all, is refused before it is posted.
 */
function fitsOneFrame<M extends Method>(method: M, params: ParamsOf<M>): boolean {
  try {
    return fitsFrame(requestBody(newRequestID(), method, params));
  } catch {
    return false;
  }
}

function withPrompts(s: AppState, prompts: PromptsState): AppState {
  return prompts === s.prompts ? s : { ...s, prompts };
}

/**
 * Where a message goes and what it says: the session, its `refKey`, the draft as typed, and
 * whether the message wakes the session: the list shows it parked, and the body fits one frame,
 * so the client will post it rather than refuse it at once.
 */
interface SendTarget {
  ref: PhoneSessionRef;
  key: string;
  text: string;
  wakes: boolean;
}

/**
 * Where a message goes, read from `s` at the moment of the gesture: the session the route shows,
 * as the list shows it, with its draft; or null when nothing must go out (see `sendMessage`).
 */
function sendTarget(s: AppState): SendTarget | null {
  const { route } = s.ui;
  if (route.screen !== 'session') return null;
  const found = findSession(s.sessions, route.ref);
  if (found === null || !found.session.capabilities.send.available) return null;
  const { ref } = found.session;
  if (isSending(s.prompts, ref)) return null;
  const key = refKey(ref);
  const text = textAt(s.ui.drafts, key) ?? '';
  if (isBlankMessage(text)) return null;
  const wakes = found.session.status.chip === 'parked' && fitsOneFrame('message.send', { session: ref, text });
  return { ref, key, text, wakes };
}

/** `ui` with `drafts` and `refusal` replaced, or `ui` itself when neither changed. */
function withTexts(ui: UIState, drafts: UIState['drafts'], refusal: UIState['refusal']): UIState {
  return drafts === ui.drafts && refusal === ui.refusal ? ui : { ...ui, drafts, refusal };
}

export function promptActions(ctx: ActionContext, self: () => Actions) {
  const { store, client } = ctx;

  return {
    async answerPrompt(promptID: string, answer: PromptAnswer): Promise<void> {
      const answerID = newRequestID();
      const sent: { ref: PhoneSessionRef | null } = { ref: null };
      store.update((s) => {
        const to = answerTarget(s, promptID, answer);
        if (to === null) return s;
        if (to.refusal !== null) return withPrompts(s, refuseAnswer(s.prompts, to.ref, promptID, to.refusal));
        const summary = answerSummary(answer, to.prompt.questions ?? []);
        const prompts = beginAnswer(s.prompts, to.ref, promptID, summary, answerID);
        if (prompts === s.prompts) return s;
        sent.ref = to.ref;
        return { ...s, prompts };
      });
      const ref = sent.ref;
      if (ref === null) return;
      const params: PhonePromptAnswerParams = { session: ref, promptID, answer };
      const fits = fitsOneFrame('prompt.answer', params);
      let settled: AnswerSettlement;
      try {
        const result = await client.request('prompt.answer', params);
        settled = { outcome: result.outcome };
      } catch (error) {
        // An error that is no `AppError` is a fault in the client's own setup, which posts
        // nothing. Its message is the client's own, for its log, so the card shows the client's
        // words for a request it could not send as made.
        settled = error instanceof AppError
          ? { error: error.code, message: error.message, mayHaveLanded: mayHaveLanded(error.code, fits) }
          : { error: 'internal', message: BAD_PARAMS_TEXT, mayHaveLanded: false };
      }
      store.update((s) => {
        const { prompts, receipt } = settleAnswer(s.prompts, ref, promptID, answerID, settled);
        const transcript = receipt === null ? s.transcript : addReceipt(s.transcript, receipt.session, receipt.id, receipt.text);
        if (prompts === s.prompts && transcript === s.transcript) return s;
        return { ...s, prompts, transcript };
      });
    },

    dismissPrompt(promptID: string): void {
      store.update((s) => {
        const { route } = s.ui;
        return route.screen === 'session' ? withPrompts(s, dismissCard(s.prompts, route.ref, promptID)) : s;
      });
    },

    setDraft(text: string): void {
      store.update((s) => {
        const { route } = s.ui;
        if (route.screen !== 'session') return s;
        const key = refKey(route.ref);
        const ui = withTexts(s.ui, withText(s.ui.drafts, key, text), withText(s.ui.refusal, key, null));
        return ui === s.ui ? s : { ...s, ui };
      });
    },

    async sendMessage(): Promise<void> {
      const sent: { to: SendTarget | null } = { to: null };
      store.update((s) => {
        const to = sendTarget(s);
        if (to === null) return s;
        sent.to = to;
        return { ...s, prompts: beginSend(s.prompts, to.ref), ui: withTexts(s.ui, s.ui.drafts, withText(s.ui.refusal, to.key, null)) };
      });
      const to = sent.to;
      if (to === null) return;
      if (to.wakes) self().toast(WAKING_TEXT);
      // How the request ended: taken, or failed with the words to show, null for none.
      let settled: { taken: true } | { taken: false; refusal: string | null };
      try {
        await client.request('message.send', { session: to.ref, text: to.text });
        settled = { taken: true };
      } catch (error) {
        settled = { taken: false, refusal: errorText(error) };
      }
      store.update((s) => {
        const prompts = endSend(s.prompts, to.ref);
        let ui = s.ui;
        if (settled.taken) {
          // The draft goes only when it still holds the text sent: what the user typed meanwhile stays.
          if (textAt(ui.drafts, to.key) === to.text) ui = withTexts(ui, withText(ui.drafts, to.key, null), ui.refusal);
        } else if (settled.refusal !== null) {
          ui = withTexts(ui, ui.drafts, withText(ui.refusal, to.key, settled.refusal));
        }
        if (prompts === s.prompts && ui === s.ui) return s;
        return { ...s, prompts, ui };
      });
    },
  };
}
