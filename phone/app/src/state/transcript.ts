// Filled by plan 6 part 6c
//
// The transcript slice of `AppState`: the open session's items, its paging cursor, open
// details and receipts. Part 6c fills it. Until then it holds only which session is open.
//
// Contract, once filled:
// - `emptyTranscript()`: the slice with no transcript open.
// - `applyTranscriptEvent(s, e)`: `transcript.append`, `transcript.update` and
//   `transcript.reset` for the open session, folded into the slice. Any other event, or one
//   for another session, returns `s` itself, so the store does not notify.
// - `addReceipt(s, ref, id, text)`: a receipt line ("Answered on this phone: …") added to the
//   open transcript when it is `ref`'s, keyed by `id` (a prompt ID) so a second receipt for the
//   same prompt replaces the first. For another session it returns `s` itself.
// Each returns a new object when it changes anything and `s` itself when it does not.
//
// The stub: an empty slice, and each function returns `s` unchanged.

import type { AppEvent, PhoneSessionRef } from '../protocol/types.ts';

export interface TranscriptState {
  ref: PhoneSessionRef | null;
}

export function emptyTranscript(): TranscriptState {
  return { ref: null };
}

export function applyTranscriptEvent(s: TranscriptState, e: AppEvent): TranscriptState {
  return s;
}

export function addReceipt(s: TranscriptState, ref: PhoneSessionRef, id: string, text: string): TranscriptState {
  return s;
}
