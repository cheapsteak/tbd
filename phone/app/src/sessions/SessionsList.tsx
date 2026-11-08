// Filled by plan 6 part 6b
//
// The sessions screen: the laptop's rows, grouped by repo and sorted newest first, with each
// row's status, and a "+" on each repo header for New. Contract: `SessionsList()` takes no
// props, and reads the list and acts through the store's context.
//
// The stub: one button per row, in layout order, that opens the row's first session. A layout
// placement whose row has not arrived yet is skipped, and a row with no sessions shows nothing.

import { useMemo } from 'react';
import type { JSX } from 'react';
import type { PhoneRow, PhoneSession } from '../protocol/types.ts';
import { useActions, useAppState } from '../state/context.tsx';
import { rowByID } from '../state/sessionsData.ts';

export function SessionsList(): JSX.Element {
  const sessions = useAppState((s) => s.sessions);
  const actions = useActions();
  const rows = useMemo(() => {
    const out: Array<{ key: string; row: PhoneRow; first: PhoneSession }> = [];
    for (const group of sessions.layout) {
      for (const placement of group.rows) {
        const row = rowByID(sessions, placement.id);
        const first = row?.sessions[0];
        if (row === null || first === undefined) continue;
        out.push({ key: JSON.stringify([group.id, row.id]), row, first });
      }
    }
    return out;
  }, [sessions]);
  return (
    <ul>
      {rows.map(({ key, row, first }) => (
        <li key={key}>
          <button type="button" data-row={row.id} onClick={() => actions.openSession(first.ref)}>{row.name}</button>
        </li>
      ))}
    </ul>
  );
}
