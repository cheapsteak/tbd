/**
 * The band under the header that says why a session is stopped (spec section 8.3; mock
 * `sessionHTML`): the reason for an error or a rate limit, and a line each for an unreadable
 * status and an exited session. Any other status has no band. Contract: `StatusBand({ session })`.
 */

import type { JSX } from 'react';
import type { PhoneSession } from '../protocol/types.ts';
import { Icon } from '../ui/Icon.tsx';

export function StatusBand({ session }: { session: PhoneSession }): JSX.Element | null {
  const { chip, reason } = session.status;
  switch (chip) {
    case 'error':
      return <Band cls="err" glyph="octa" text={reason ?? ''} />;
    case 'rateLimited':
      return <Band cls="rate" glyph="glass" text={reason ?? ''} />;
    case 'unknown':
      return <Band cls="unk" glyph="unk" text="TBD cannot read this tab's status, so it shows as Unknown." />;
    case 'exited':
      return <Band cls="gone" glyph="power" text="This session has exited. Restart it on the laptop." />;
    default:
      return null;
  }
}

function Band({ cls, glyph, text }: { cls: string; glyph: 'octa' | 'glass' | 'unk' | 'power'; text: string }): JSX.Element {
  return (
    <div className={`banner st-${cls}`}>
      <Icon name={glyph} />
      <span>{text}</span>
    </div>
  );
}
