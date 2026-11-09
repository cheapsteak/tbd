// Filled by plan 6 part 6d
//
// The composer at the bottom of the dock: the open session's unsent text and Send (mock
// `composerHTML`). Contract: `Composer({ session })`, the open session. The dock renders it
// below the prompt card. It reads the draft from `ui.drafts` and the laptop's last refusal from
// `ui.refusal`, both by `refKey` of the session, and acts through `setDraft` and `sendMessage`
// (`actions/prompts.ts`).
//
// The stub renders nothing.

import type { JSX } from 'react';
import type { PhoneSession } from '../protocol/types.ts';

export function Composer(_props: { session: PhoneSession }): JSX.Element | null {
  return null;
}
