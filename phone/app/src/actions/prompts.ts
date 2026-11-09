// Filled by plan 6 part 6d (`setDraft` and `sendMessage` come in task 6d-6)
//
// The prompt and composer actions: answering an open prompt, taking its card down, and sending
// a message. The prompt slice they change is `state/prompts.ts`.
//
// Contract:
// - `answerPrompt(promptID, answer, summary): Promise<void>` – sends `prompt.answer` for the
//   open session, once, and records the answer and its `summary` for the receipt ("Answered on
//   this phone: <summary>"). It resolves once the laptop replied or the request failed. It
//   sends nothing, and changes nothing, unless every one of these holds at the moment of the
//   gesture:
//   - the route shows a session, and the list shows that session (`findSession`);
//   - that session's prompt set holds `promptID`, and its card is `open`, so a second tap while
//     the first answer is on its way, or on a card that shows it was answered, sends nothing;
//   - `answer` fits the prompt (`answerFits`).
//   When the list shows the session's `answer` capability unavailable, it sends nothing and
//   shows the list's reason as the card's refusal, the words the laptop would refuse it with.
//   The reply is folded in with `settleAnswer`, whose receipt goes to the transcript through
//   `addReceipt`, as `applyEvent`'s do.
// - `dismissPrompt(promptID): void` – takes `promptID`'s card down from the dock, such as once
//   it shows "Answered" or that someone else answered. It leaves a `sending` card, whose reply
//   still has to say who answered, changes only the prompt slice, and sends nothing.
// - `setDraft(text): void` – keeps the open session's unsent text in `ui.drafts`.
// - `sendMessage(): Promise<void>` – sends the open session's draft with `message.send`, never
//   a blank or whitespace-only one, and resolves once the laptop replied or the request failed.
//   A refusal goes in `ui.refusal`.
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
// body against one frame itself, as the client does.
//
// The stubs until task 6d-6: `setDraft` does nothing, and `sendMessage` resolves at once.

import { AppError, newRequestID } from '../client/client.ts';
import { fitsFrame } from '../limits.ts';
import type { PhonePromptAnswerParams, PhoneSessionRef, PromptAnswer } from '../protocol/types.ts';
import { requestBody } from '../protocol/wire.ts';
import { answerFits, beginAnswer, dismissCard, mayHaveLanded, openPrompt, refuseAnswer, settleAnswer } from '../state/prompts.ts';
import type { AnswerSettlement, PromptsState } from '../state/prompts.ts';
import { findSession } from '../state/route.ts';
import type { AppState } from '../state/store.ts';
import { addReceipt } from '../state/transcript.ts';
import type { ActionContext, Actions } from './index.ts';

/**
 * Where an answer to `promptID` goes, read from `s` at the moment of the gesture: the session the
 * route shows, as the list shows it; a refusal when the list shows its `answer` capability
 * unavailable with a reason; or null when the answer must not go out (see `answerPrompt`).
 */
function answerTarget(s: AppState, promptID: string, answer: PromptAnswer): { ref: PhoneSessionRef } | { refusal: string } | null {
  const { route } = s.ui;
  if (route.screen !== 'session') return null;
  const prompt = openPrompt(s.prompts, route.ref, promptID);
  if (prompt === null || !answerFits(prompt, answer)) return null;
  const found = findSession(s.sessions, route.ref);
  if (found === null) return null;
  const capability = found.session.capabilities.answer;
  if (!capability.available) return capability.reason === undefined ? null : { refusal: capability.reason };
  return { ref: found.session.ref };
}

/**
 * Whether `params` make a `prompt.answer` body that fits one frame, measured as the client
 * measures it before posting (`request` in `client/client.ts`), with an ID of the length the
 * client gives. One that does not is refused `too_large` before it is posted.
 */
function fitsOneFrame(params: PhonePromptAnswerParams): boolean {
  try {
    return fitsFrame(requestBody(newRequestID(), 'prompt.answer', params));
  } catch {
    return false;
  }
}

function withPrompts(s: AppState, prompts: PromptsState): AppState {
  return prompts === s.prompts ? s : { ...s, prompts };
}

export function promptActions(ctx: ActionContext, self: () => Actions) {
  const { store, client } = ctx;

  return {
    async answerPrompt(promptID: string, answer: PromptAnswer, summary: string): Promise<void> {
      const answerID = newRequestID();
      const target: { ref: PhoneSessionRef | null } = { ref: null };
      store.update((s) => {
        const to = answerTarget(s, promptID, answer);
        if (to === null) return s;
        if ('refusal' in to) return withPrompts(s, refuseAnswer(s.prompts, promptID, to.refusal));
        target.ref = to.ref;
        return withPrompts(s, beginAnswer(s.prompts, promptID, summary, answerID));
      });
      if (target.ref === null) return;
      const params: PhonePromptAnswerParams = { session: target.ref, promptID, answer };
      const fits = fitsOneFrame(params);
      let settled: AnswerSettlement;
      try {
        const result = await client.request('prompt.answer', params);
        settled = { outcome: result.outcome };
      } catch (error) {
        // An error that is no `AppError` is a fault in the client's own setup, which posts nothing.
        settled = error instanceof AppError
          ? { error: error.code, message: error.message, mayHaveLanded: mayHaveLanded(error.code, fits) }
          : { error: 'internal', message: error instanceof Error ? error.message : String(error), mayHaveLanded: false };
      }
      store.update((s) => {
        const { prompts, receipt } = settleAnswer(s.prompts, promptID, answerID, settled);
        const transcript = receipt === null ? s.transcript : addReceipt(s.transcript, receipt.session, receipt.id, receipt.text);
        if (prompts === s.prompts && transcript === s.transcript) return s;
        return { ...s, prompts, transcript };
      });
    },

    dismissPrompt(promptID: string): void {
      store.update((s) => withPrompts(s, dismissCard(s.prompts, promptID)));
    },

    setDraft(text: string): void {},

    async sendMessage(): Promise<void> {},
  };
}
