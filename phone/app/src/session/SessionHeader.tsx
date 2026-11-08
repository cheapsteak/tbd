// Filled by plan 6 part 6b
//
// The session screen's header: back, the row's name, the session's account and model, and the
// buttons that open the header's menus. Contract: `SessionHeader({ row, session })`, where
// `row` lists `session`.
//
// The stub: the back button and the row's name.

import type { JSX } from 'react';
import type { PhoneRow, PhoneSession } from '../protocol/types.ts';
import { useActions } from '../state/context.tsx';
import { Icon } from '../ui/Icon.tsx';

export function SessionHeader({ row }: { row: PhoneRow; session: PhoneSession }): JSX.Element | null {
  const actions = useActions();
  return (
    <div className="s-head">
      <button className="ib" type="button" aria-label="Back to sessions" onClick={() => actions.back()}>
        <Icon name="chev-l" />
      </button>
      <span>{row.name}</span>
    </div>
  );
}
