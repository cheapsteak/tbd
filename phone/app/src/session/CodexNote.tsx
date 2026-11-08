/**
 * The note a Codex session shows in place of its transcript and dock (mock `sessionHTML`):
 * Codex tabs show their status only. Contract: `CodexNote()`, with no props.
 */

import type { JSX } from 'react';
import { Icon } from '../ui/Icon.tsx';

export function CodexNote(): JSX.Element {
  return (
    <div className="tx-wrap">
      <div className="tx">
        <div className="codex-note">
          <Icon name="term" />
          <b>Codex transcripts arrive in a later TBD release.</b>
          <span>This tab shows its status only. Open it on the laptop to read or reply.</span>
        </div>
      </div>
    </div>
  );
}
