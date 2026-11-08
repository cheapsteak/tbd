// Filled by plan 6 part 6c
//
// The transcript actions: opening and closing the one transcript the laptop sends this phone,
// its older pages, and its details. Part 6c fills them. Until then each does nothing.
//
// Contract, once filled:
// - `openTranscript(ref): void` – sends `transcript.open` for `ref` with the `showDetails`
//   setting, and puts the first page in the transcript slice. The laptop keeps one transcript
//   open per phone, so opening another closes the first. `openSession` calls it, and so does
//   `onEvent` when a pending open becomes the route.
// - `closeTranscript(): void` – sends `transcript.close` and empties the slice. `back` calls
//   it, and so does `onEvent` when the open session leaves every row.
// - `resumeTranscriptOnUp(): void` – `onChannelUp` calls it inside the client's `onUp`, right
//   after its `sessions.subscribe` and without waiting for it (spec section 7, "Fewer round
//   trips"). It must make its request before its first `await`, so the request goes out in
//   `onUp`'s turn, ahead of the client's resends. The client rejects a `transcript.open` or
//   `transcript.close` in flight at a drop as `superseded` and never sends it again. So:
//   - when a transcript is open, it sends `transcript.open` for it with `resume: true`;
//   - when none is open but one may still be open on the laptop, because a
//     `transcript.close` was superseded, it sends a fresh `transcript.close`;
//   - otherwise it sends nothing.
// - `onShowDetailsChanged(): void` – `setShowDetails` calls it after the setting changed; it
//   opens the open transcript again with the new setting.
// - `loadOlder(): Promise<void>` – asks for the page before the slice's cursor, one at a time,
//   and resolves once it landed or failed.
// - `toggleDetail(rowKey, part): Promise<void>` – opens or closes one part of the row with key
//   `rowKey`, loading its chunks, and resolves once they landed or failed.
// Like every action, none rejects (`actions/index.ts`); `superseded` is silent.
//
// The stub: each does nothing, and the Promise ones resolve at once.

import type { PhoneSessionRef, TranscriptDetailPart } from '../protocol/types.ts';
import type { ActionContext, Actions } from './index.ts';

export function transcriptActions(ctx: ActionContext, self: () => Actions) {
  return {
    openTranscript(ref: PhoneSessionRef): void {},
    closeTranscript(): void {},
    resumeTranscriptOnUp(): void {},
    onShowDetailsChanged(): void {},
    async loadOlder(): Promise<void> {},
    async toggleDetail(rowKey: number, part: TranscriptDetailPart): Promise<void> {},
  };
}
