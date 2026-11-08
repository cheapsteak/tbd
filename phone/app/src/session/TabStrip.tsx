/**
 * The tabs of a row with more than one session (mock `sessionHTML`), in the row's order, each
 * with a dot in its status colour and the status word for screen readers. A tap, Enter or Space opens that
 * session; Arrow keys, Home and End move focus between tabs without opening one. The session screen shows it only when `row.sessions.length > 1`. Contract:
 * `TabStrip({ row, session })`, where `session` is the open one of `row`'s sessions.
 */

import type { JSX, KeyboardEvent } from 'react';
import type { PhoneRow, PhoneSession } from '../protocol/types.ts';
import { refKey } from '../protocol/wire.ts';
import { useActions } from '../state/context.tsx';
import { STATUS } from '../state/status.ts';

/** Moves focus (not selection) along the tabs: Arrow keys wrap, Home and End jump to the ends. */
function moveFocus(e: KeyboardEvent<HTMLDivElement>): void {
  const tabs = Array.from(e.currentTarget.querySelectorAll<HTMLElement>('[role="tab"]'));
  const at = tabs.indexOf(document.activeElement as HTMLElement);
  if (at < 0) return;
  const target =
    e.key === 'ArrowRight' ? (at + 1) % tabs.length
    : e.key === 'ArrowLeft' ? (at - 1 + tabs.length) % tabs.length
    : e.key === 'Home' ? 0
    : e.key === 'End' ? tabs.length - 1
    : -1;
  if (target < 0) return;
  e.preventDefault();
  tabs[target]?.focus();
}

export function TabStrip({ row, session }: { row: PhoneRow; session: PhoneSession }): JSX.Element {
  const actions = useActions();
  const open = refKey(session.ref);
  return (
    <div className="tabs" role="tablist" aria-label={row.name} onKeyDown={moveFocus}>
      {row.sessions.map((s) => {
        const st = STATUS[s.status.chip];
        const key = refKey(s.ref);
        return (
          <button key={key} className="tab" type="button" role="tab" aria-selected={key === open} tabIndex={key === open ? 0 : -1} onClick={() => actions.openSession(s.ref)}>
            <span className={`tdot st-${st.cls}`} />
            {s.tabName}
            <span className="sr">{st.word}</span>
          </button>
        );
      })}
    </div>
  );
}
