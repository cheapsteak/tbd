/**
 * The box under a row whose detail is open, drawn element for element as the mock's `detailHTML`
 * draws it (mock 862-868). It only renders the `DetailState` it is given:
 * - **a tool's parts**: each text part that arrived, "Input" or "Result" (`.dl`) over its text in
 *   a `<pre>`. A `<pre>` holds its text as one text node, so even a 1 MB part is one node. It
 *   draws at most `MAX_DETAIL_LINES` lines of a part (`firstLines`), since a megabyte of short
 *   lines lays out far taller than a phone handles well;
 * - **loading**: the parts that arrived whole, then `.loading`, a spinner and "Loading from the
 *   laptop…", for the part on its way, as the mock shows a detail on its way. So a tool's Input
 *   stays while its result loads, as when a tool tapped while it ran stops running (`followItem`);
 * - **too large**: `.toobig`, the laptop glyph and "Too large for the phone. Open on the
 *   laptop.", under each part the laptop or the phone's caps cut, or the lines cap cut, so a
 *   too-large Input reads as such above a whole Result; and once at the end for a part the box
 *   does not draw, or when `cut` says the caller left something out, as a nest past its budget
 *   or a message's whole text past its first `MAX_DETAIL_LINES` lines;
 * - **failed**: the laptop's message, such as "That detail is not in the transcript.", after
 *   what arrived.
 *
 * `parts` says whether the box draws the text parts: a tool row's box does, while "Show more"
 * puts its text in the message itself and a subagent's items go in `.nest`, so their boxes show
 * only the loading line, the too-large line or the message. With nothing to show it draws
 * nothing.
 */

import { useMemo, type JSX } from 'react';
import { firstLines } from '../state/detail.ts';
import type { DetailState } from '../state/detail.ts';
import type { TranscriptDetailPart } from '../protocol/types.ts';
import { Icon } from '../ui/Icon.tsx';

/** The mock's label for each text part a tool row shows. */
const LABELS: Partial<Record<TranscriptDetailPart, string>> = { input: 'Input', result: 'Result' };

/** One part the box draws: its label, its lines as drawn, and whether any of it was left out. */
interface ShownPart {
  part: TranscriptDetailPart;
  label: string;
  text: string;
  large: boolean;
}

export function DetailPane(p: { detail: DetailState; parts: boolean; cut?: boolean }): JSX.Element | null {
  const { detail } = p;
  const shown = useMemo(() => (p.parts ? partsOf(detail) : []), [p.parts, detail]);
  const loading = detail.phase === 'loading';
  // A part too large that the box does not draw, or something the caller left out.
  const largeElsewhere = !loading && (p.cut === true || detail.largeParts.some((part) => !shown.some((s) => s.part === part)));
  const error = detail.phase === 'failed' ? detail.error : null;
  if (shown.length === 0 && !loading && !largeElsewhere && error === null) return null;
  return (
    <div className="detail">
      {shown.map((s) => [
        <span key={`${s.part}-label`} className="dl">{s.label}</span>,
        <pre key={s.part}>{s.text}</pre>,
        s.large && <TooLarge key={`${s.part}-large`} />,
      ])}
      {loading && (
        <div className="loading">
          <span className="spin" />
          Loading from the laptop…
        </div>
      )}
      {largeElsewhere && <TooLarge />}
      {error !== null && <span>{error}</span>}
    </div>
  );
}

/**
 * The text parts of `detail` the box draws, in order, each cut to its first lines: every part
 * that arrived whole, so not the one still loading.
 */
function partsOf(detail: DetailState): ShownPart[] {
  const out: ShownPart[] = [];
  const arrived = detail.phase === 'loading' ? detail.parts.slice(0, detail.partIndex) : detail.parts;
  for (const part of arrived) {
    const label = LABELS[part];
    const text = detail.text[part];
    if (label === undefined || text === undefined) continue;
    const lines = firstLines(text);
    out.push({ part, label, text: lines.text, large: lines.cut || detail.largeParts.includes(part) });
  }
  return out;
}

function TooLarge(): JSX.Element {
  return (
    <div className="toobig">
      <Icon name="laptop" />
      Too large for the phone. Open on the laptop.
    </div>
  );
}
