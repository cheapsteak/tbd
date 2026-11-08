/**
 * The status symbol the sessions list and the session header draw beside a status (mock
 * `sessionsHTML` and `sessionHTML`): the dots for working, nothing for idle, and the chip's
 * glyph for the rest. Contract: `StatusGlyph({ chip })`. Also the beat both screens read their
 * ages on (`AGE_REFRESH_MS`, for `useNow`).
 */

import type { JSX } from 'react';
import type { PhoneStatusChip } from '../protocol/types.ts';
import { STATUS } from '../state/status.ts';
import { Dots, Icon } from '../ui/Icon.tsx';

/** How often the ages on the sessions screens are read again, in milliseconds. */
export const AGE_REFRESH_MS = 30_000;

export function StatusGlyph({ chip }: { chip: PhoneStatusChip }): JSX.Element | null {
  const { glyph } = STATUS[chip];
  if (glyph === 'dots') return <Dots />;
  return glyph === null ? null : <Icon name={glyph} />;
}
