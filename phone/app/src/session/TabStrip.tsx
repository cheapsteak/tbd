// Filled by plan 6 part 6b
//
// The tabs of a row with more than one session, each with its status, opening that session on a
// tap. The session screen shows it only when `row.sessions.length > 1`. Contract:
// `TabStrip({ row, session })`, where `session` is the open one of `row`'s sessions.
//
// The stub renders nothing.

import type { JSX } from 'react';
import type { PhoneRow, PhoneSession } from '../protocol/types.ts';

export function TabStrip(_props: { row: PhoneRow; session: PhoneSession }): JSX.Element | null {
  return null;
}
