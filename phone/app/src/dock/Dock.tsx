// Filled by plan 6 part 6d
//
// The dock at the bottom of the session screen: the open prompt's card, or the composer.
// Contract: `Dock({ session })`. The session screen keys it by the session, so a switch to
// another session mounts it afresh.
//
// The stub renders nothing.

import type { JSX } from 'react';
import type { PhoneSession } from '../protocol/types.ts';

export function Dock(_props: { session: PhoneSession }): JSX.Element | null {
  return null;
}
