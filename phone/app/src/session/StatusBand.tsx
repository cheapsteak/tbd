/**
 * The band under the header that says why a session is stopped (spec section 8.3; mock
 * `sessionHTML`): the reason for an error or a rate limit, and a line each for an unreadable
 * status and an exited session (`bandText`). Any other status has no band. The band sits in a
 * live region (`role="status"`) that is always rendered, so it stays mounted while the session
 * screen is open: a band that appears or changes on the open session (or on a tab switch) is
 * announced, while one present when the screen first opens is read with the screen. The region
 * is a real box that does not grow (`flex: none`), 0 px tall while there is no band, because
 * older Safari leaves a `display: contents` element out of the accessibility tree. Contract: `StatusBand({ session })`.
 *
 * A rate limit's line names the day it lifts unless that is today, so the band reads the time
 * again on the 30 s beat (`useNow`), and the weekday goes once that day comes.
 */

import type { JSX } from 'react';
import type { PhoneSession } from '../protocol/types.ts';
import { STATUS } from '../state/status.ts';
import { useNow } from '../ui/now.ts';
import { bandText } from './bandText.ts';
import { AGE_REFRESH_MS, StatusGlyph } from './StatusGlyph.tsx';

export function StatusBand({ session }: { session: PhoneSession }): JSX.Element {
  const now = useNow(AGE_REFRESH_MS);
  const text = bandText(session.status, now);
  const { chip } = session.status;
  const { cls } = STATUS[chip];
  return (
    <div role="status" style={{ flex: 'none' }}>
      {text !== null && (
        <div className={`banner st-${cls}`}>
          <StatusGlyph chip={chip} />
          <span>{text}</span>
        </div>
      )}
    </div>
  );
}
