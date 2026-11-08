// Filled by plan 6 part 6c
//
// The open session's transcript: its items, read from the transcript slice, kept at the bottom
// while the reader is there, older pages loaded on scroll back, and each item's details.
// Contract: `TranscriptView({ session })`. The session screen keys it by the session, so a
// switch to another session mounts it afresh.
//
// The stub renders nothing.

import type { JSX } from 'react';
import type { PhoneSession } from '../protocol/types.ts';

export function TranscriptView(_props: { session: PhoneSession }): JSX.Element | null {
  return null;
}
