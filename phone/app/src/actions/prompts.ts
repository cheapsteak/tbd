// Filled by plan 6 part 6d
//
// The prompt and composer actions: answering an open prompt, hiding its card, and sending a
// message. Part 6d fills them. Until then each does nothing.
//
// Contract, once filled:
// - `answerPrompt(promptID, answer, summary): Promise<void>` – sends `prompt.answer` for the
//   open session, and records the answer and its `summary` for the receipt ("Answered on this
//   phone: <summary>"). It resolves once the laptop replied or the request failed.
// - `dismissPrompt(promptID): void` – takes `promptID`'s card down from the dock, such as once
//   it shows "Answered". It changes only the prompt slice and sends nothing.
// - `setDraft(text): void` – keeps the open session's unsent text in `ui.drafts`.
// - `sendMessage(): Promise<void>` – sends the open session's draft with `message.send`, never
//   a blank or whitespace-only one, and resolves once the laptop replied or the request failed.
//   A refusal goes in `ui.refusal`.
// Like every action, none rejects (`actions/index.ts`); `superseded` is silent.
//
// **Never retry an answer or a send automatically under a new request ID.** An answer or a
// send that failed with `not_confirmed`, `bad_reply`, `internal` or `too_large` may have
// happened all the same (`ACTING_METHODS` in `client/client.ts`), and a new ID is a new action
// to the laptop. Show the error, and leave the choice to the user.
//
// The stub: each does nothing, and the Promise ones resolve at once.

import type { PromptAnswer } from '../protocol/types.ts';
import type { ActionContext, Actions } from './index.ts';

export function promptActions(ctx: ActionContext, self: () => Actions) {
  return {
    async answerPrompt(promptID: string, answer: PromptAnswer, summary: string): Promise<void> {},
    dismissPrompt(promptID: string): void {},
    setDraft(text: string): void {},
    async sendMessage(): Promise<void> {},
  };
}
