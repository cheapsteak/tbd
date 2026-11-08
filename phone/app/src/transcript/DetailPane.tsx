/**
 * The box under a row whose detail is open, drawn element for element as the mock's `detailHTML`
 * draws it (mock 862-868). It only renders the `DetailState` it is given:
 * - **loading**: `.loading`, a spinner and "Loading from the laptop…", and nothing else, as the
 *   mock shows a detail on its way;
 * - **a tool's parts**: each text part that arrived, "Input" or "Result" (`.dl`) over its text in
 *   a `<pre>`. A `<pre>` holds its text as one text node, so even a 1 MB part is one node;
 * - **too large**: `.toobig`, the laptop glyph and "Too large for the phone. Open on the
 *   laptop.", after what arrived;
 * - **failed**: the laptop's message, such as "That detail is not in the transcript.", after
 *   what arrived.
 *
 * `parts` says whether the box draws the text parts: a tool row's box does, while "Show more"
 * puts its text in the message itself and a subagent's items go in `.nest`, so their boxes show
 * only the loading line, the too-large line or the message. With nothing to show it draws
 * nothing.
 */

import type { JSX } from 'react';
import type { DetailState } from '../state/detail.ts';
import type { TranscriptDetailPart } from '../protocol/types.ts';
import { Icon } from '../ui/Icon.tsx';

/** The mock's label for each text part a tool row shows. */
const LABELS: Partial<Record<TranscriptDetailPart, string>> = { input: 'Input', result: 'Result' };

export function DetailPane(p: { detail: DetailState; parts: boolean }): JSX.Element | null {
  const { detail } = p;
  if (detail.phase === 'loading') {
    return (
      <div className="detail">
        <div className="loading">
          <span className="spin" />
          Loading from the laptop…
        </div>
      </div>
    );
  }
  const shown = p.parts ? detail.parts.filter((part) => LABELS[part] !== undefined && detail.text[part] !== undefined) : [];
  const tooLarge = detail.phase === 'tooLarge';
  const error = detail.phase === 'failed' ? detail.error : null;
  if (shown.length === 0 && !tooLarge && error === null) return null;
  return (
    <div className="detail">
      {shown.map((part) => [
        <span key={`${part}-label`} className="dl">{LABELS[part]}</span>,
        <pre key={part}>{detail.text[part]}</pre>,
      ])}
      {tooLarge && (
        <div className="toobig">
          <Icon name="laptop" />
          Too large for the phone. Open on the laptop.
        </div>
      )}
      {error !== null && <span>{error}</span>}
    </div>
  );
}
