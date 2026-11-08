/**
 * The open session's transcript: its rows, read from the transcript slice. For now a plain
 * list, `.tx` as the scroll element with a wrapper per row; Task 6c-6 replaces the wrapper with
 * the virtual list's `.tx-row` and adds the bottom anchor and older pages.
 * Contract: `TranscriptView({ session })`. The session screen keys it by the session, so a
 * switch to another session mounts it afresh.
 *
 * - **No transcript.** When the session's transcript capability is unavailable, the laptop's
 *   reason is all it shows (`.codex-note`).
 * - **Opening.** The mock has no loading state for a transcript, so while an open is on its way
 *   with no rows, nothing is drawn.
 * - **Failed.** The slice's error, which is the laptop's own text, in the same note.
 * - **Row attributes.** Each row's wrapper carries `data-key` (the row key) and `data-tx-row`.
 *   (`data-row` is not used: the e2e fixtures' `rowButtons` matches `button[data-row]`.)
 */

import { useCallback, type JSX } from 'react';
import { useActions, useAppState } from '../state/context.tsx';
import type { PhoneSession } from '../protocol/types.ts';
import { sameRef } from '../protocol/wire.ts';
import { Icon } from '../ui/Icon.tsx';
import { ItemRow, type RowPart } from './ItemRow.tsx';

export function TranscriptView(p: { session: PhoneSession }): JSX.Element {
  const actions = useActions();
  const t = useAppState((s) => s.transcript);
  // One function for every row on every render, so a row draws again only when it changes.
  const toggle = useCallback((rowKey: number, part: RowPart) => void actions.toggleDetail(rowKey, part), [actions]);
  const { available, reason } = p.session.capabilities.transcript;
  if (!available) return <Note text={reason ?? ''} />;
  if (t.phase === 'failed') return <Note text={t.error ?? ''} />;
  const rows = t.ref !== null && sameRef(t.ref, p.session.ref) ? t.rows : [];
  return (
    <div className="tx-wrap">
      <div className="tx" id="tx" aria-live="polite">
        {rows.map((row) => (
          <div key={row.key} data-key={row.key} data-tx-row="" style={ROW_STYLE}>
            <ItemRow row={row} detail={t.details[row.key]} toggle={toggle} />
          </div>
        ))}
      </div>
    </div>
  );
}

/** Lays a row out as `.tx` does its children, so the row's own margins and gaps act the same. */
const ROW_STYLE = { display: 'flex', flexDirection: 'column', gap: 8 } as const;

function Note(p: { text: string }): JSX.Element {
  return (
    <div className="tx-wrap">
      <div className="tx">
        <div className="codex-note">
          <Icon name="term" />
          <b>{p.text}</b>
        </div>
      </div>
    </div>
  );
}
