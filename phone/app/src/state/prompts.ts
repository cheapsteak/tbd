// Filled by plan 6 part 6d
//
// The prompt slice of `AppState`: each session's open prompts, the answers this phone sent,
// and the card's own state. Part 6d fills it. Until then it is empty.
//
// Contract, once filled:
// - `emptyPrompts()`: the slice with no prompts.
// - `applyPromptChanged(s, d)`: one `prompt.changed` folded into the slice. It returns the new
//   slice, and one receipt for each prompt in `d.resolved` that should leave a line in the
//   transcript, `id` being the prompt ID and `text` the line ("Answered on this phone: …",
//   "Answered on the laptop", …). `applyEvent` passes each receipt to `addReceipt` in
//   `state/transcript.ts`, in order. When nothing changed it returns `s` itself and no receipts.
//
// The stub: an empty slice, and `applyPromptChanged` returns `{ prompts: s, receipts: [] }`.

import type { PromptChangedData } from '../protocol/types.ts';

// Empty until part 6d gives it fields.
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
