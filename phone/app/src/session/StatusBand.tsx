/**
 * The band under the header that says why a session is stopped (spec section 8.3; mock
 * `sessionHTML`): the reason for an error or a rate limit, and a line each for an unreadable
 * status and an exited session (`bandText`). Any other status has no band. It is a live region
 * (`role="status"`), so a screen reader announces it as it appears and changes. Contract:
 * `StatusBand({ session })`.
 *
 * A rate limit's line names the day it lifts unless that is today, so the band reads the time
 * again on the 30 s beat (`useNow`), and the weekday goes once that day comes.
 */

import type { JSX } from 'react';
import type { PhoneSession, PhoneStatusChip } from '../protocol/types.ts';
import { Icon } from '../ui/Icon.tsx';
import { useNow } from '../ui/now.ts';
import { bandText } from './bandText.ts';
import { AGE_REFRESH_MS } from './StatusGlyph.tsx';

type BandGlyph = 'octa' | 'glass' | 'unk' | 'power';

const BANDS: Partial<Record<PhoneStatusChip, { cls: string; glyph: BandGlyph }>> = {
  error: { cls: 'err', glyph: 'octa' },
  rateLimited: { cls: 'rate', glyph: 'glass' },
  unknown: { cls: 'unk', glyph: 'unk' },
  exited: { cls: 'gone', glyph: 'power' },
};

export function StatusBand({ session }: { session: PhoneSession }): JSX.Element | null {
  const now = useNow(AGE_REFRESH_MS);
  const band = BANDS[session.status.chip];
  const text = bandText(session.status, now);
  if (band === undefined || text === null) return null;
  return (
    <div className={`banner st-${band.cls}`} role="status">
      <Icon name={band.glyph} />
      <span>{text}</span>
    </div>
  );
}
