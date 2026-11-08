/**
 * The tabs of a row with more than one session (mock `sessionHTML`), in the row's order, each
 * with a dot in its status colour and the status word for screen readers. A tap opens that
 * session. The session screen shows it only when `row.sessions.length > 1`. Contract:
 * `TabStrip({ row, session })`, where `session` is the open one of `row`'s sessions.
 */

import type { JSX } from 'react';
import type { PhoneRow, PhoneSession } from '../protocol/types.ts';
import { refKey } from '../protocol/wire.ts';
import { useActions } from '../state/context.tsx';
import { STATUS } from '../state/status.ts';

export function TabStrip({ row, session }: { row: PhoneRow; session: PhoneSession }): JSX.Element {
  const actions = useActions();
  const open = refKey(session.ref);
  return (
    <div className="tabs" role="tablist">
      {row.sessions.map((s) => {
        const st = STATUS[s.status.chip];
        const key = refKey(s.ref);
        return (
          <button key={key} className="tab" type="button" role="tab" aria-selected={key === open} onClick={() => actions.openSession(s.ref)}>
            <span className={`tdot st-${st.cls}`} />
            {s.tabName}
            <span className="sr">{st.word}</span>
          </button>
        );
      })}
    </div>
  );
}
