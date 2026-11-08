/**
 * One row of the transcript, drawn element for element and class for class as the mock's
 * `itemHTML` draws it (mock 870-897), with its open detail. It only renders: a tap on a tool, a
 * subagent or "Show more" calls `toggle` with the row's key, which the list wires to
 * `toggleDetail`, and `detail` is that row's record in the slice's `details`.
 *
 * **It renders again only when its own props change** (`memo`). The list passes each row the
 * same row object, detail record and `toggle` until that row changes, so an append, an update of
 * another row or a tick of another part of the state draws no row again, an open nest included.
 *
 * Where the wire holds less than the mock shows, the row shows less, and says what it can:
 * - a failed tool's mark reads "failed", since the wire has no exit code;
 * - a slash row has its command only, since the wire has no output;
 * - a system note's label is always "System", since the wire has no label.
 *
 * **Details** (`DetailPane`, and `state/detail.ts` for the chunk rules). A row whose detail is
 * open (it has a record) reads `aria-expanded="true"` and turns its triangle down.
 * - A tool row draws its box under the button: Input and Result, or the loading line. A tap
 *   collapses it, a failed one too, and the next tap starts over.
 * - "Show more" puts the message's whole text in place of the cut text, through `Markdown`,
 *   once it arrived, and the button goes, as in the mock. Its box shows the loading line, the
 *   too-large line or the laptop's message. After a failure the button comes back, and a tap
 *   starts over.
 * - A subagent row draws its items in `.nest`, each through this component as a nested row,
 *   under one budget for the whole nest (`nest.ts`): items past it are not drawn, and the row
 *   shows "Too large for the phone. Open on the laptop." under the nest. It collapses as a tool
 *   row does.
 *
 * **Nested rows draw, and never open.** A nested row has no row key, so it has no record in
 * `details`, and the laptop could not serve one anyway: it finds a detail by looking the item ID
 * up in the session's own transcript (`TranscriptDetailReader.text`), while a subagent's items
 * come from the subagent's own transcript file. So a nested tool or subagent is a plain
 * `div.tool` with the spacer in place of the triangle, as a file edit is, and a nested message
 * has no "Show more". That also bounds the nesting at one level: a nested subagent draws as its
 * row alone.
 */

import { memo, useMemo, type JSX } from 'react';
import type { MdNode } from '../markdown/mdTree.ts';
import type { PhoneItem } from '../protocol/types.ts';
import type { DetailState } from '../state/detail.ts';
import type { TranscriptRow } from '../state/transcript.ts';
import { toolGlyph } from '../state/status.ts';
import { Markdown } from '../markdown/Markdown.tsx';
import { Dots, Icon } from '../ui/Icon.tsx';
import { DetailPane } from './DetailPane.tsx';
import { planNest } from './nest.ts';

/** The part each kind of row opens with a tap: a tool's input (then its result), the rest of a message, or a subagent's items. */
export type RowPart = 'input' | 'text' | 'subagent';

/**
 * - `toggle`: what a tap calls, with the row's key, or null for a nested row, which never opens.
 *   Pass the same function on every render, or `memo` gains nothing.
 * - `tree`: a nested message's markdown, read ahead under its nest's budget.
 */
export interface ItemRowProps {
  row: TranscriptRow;
  detail: DetailState | undefined;
  toggle: ((rowKey: number, part: RowPart) => void) | null;
  tree?: readonly MdNode[] | null;
}

export const ItemRow = memo(function ItemRow(p: ItemRowProps): JSX.Element | null {
  const { row, toggle: onToggle } = p;
  const toggle = onToggle === null ? null : (part: RowPart): void => onToggle(row.key, part);
  const detail = toggle !== null ? (p.detail ?? null) : null;
  const expanded = detail !== null;
  if (row.kind === 'receipt') {
    return (
      <div className="receipt">
        <Icon name="check" />
        {row.text}
      </div>
    );
  }
  const it: PhoneItem = row.item;
  const text = it.text ?? '';
  const name = it.toolName ?? '';
  switch (it.kind) {
    case 'user':
      return (
        <div className="me">
          <span className="who">You</span>
          <Markdown inline text={text} nodes={p.tree} />
        </div>
      );
    case 'assistant': {
      const full = detail?.phase !== 'loading' ? detail?.text.text : undefined;
      return (
        <>
          <div className="say">
            <Markdown text={full ?? text} nodes={full === undefined ? p.tree : null} />
            {it.truncated && toggle !== null && (detail === null || detail.phase === 'failed') && (
              <button className="morebtn" type="button" onClick={() => toggle('text')}>
                Show more
              </button>
            )}
          </div>
          {detail !== null && <DetailPane detail={detail} parts={false} />}
        </>
      );
    }
    case 'tool': {
      const label = (
        <>
          <Icon name={toolGlyph(name)} cls="ti" />
          <b>{name}</b>
          <code>{it.target ?? ''}</code>
          {toolMark(it.toolStatus, name)}
        </>
      );
      return (
        <>
          {toolLine(label, expanded, toggle === null ? null : () => toggle('input'))}
          {detail !== null && <DetailPane detail={detail} parts />}
        </>
      );
    }
    case 'fileEdit': {
      const label = (
        <>
          <Icon name="pen" cls="ti" />
          <b>{name}</b>
          <code>{it.target ?? ''}</code>
          <span className="plus">+{it.added ?? 0}</span>
          <span className="minus">{`−${it.removed ?? 0}`}</span>
        </>
      );
      return toolLine(label, false, null);
    }
    case 'subagent': {
      const label = (
        <>
          <Icon name="bot" cls="ti" />
          <b>{it.agentType ?? ''} agent</b>
          <code>{it.target ?? ''}</code>
          <span className="cnt">{it.itemCount ?? 0} items</span>
        </>
      );
      return (
        <>
          {toolLine(label, expanded, toggle === null ? null : () => toggle('subagent'))}
          {detail !== null && (detail.phase === 'loading' ? <DetailPane detail={detail} parts={false} /> : <Nest detail={detail} />)}
        </>
      );
    }
    case 'slash':
      return (
        <div className="slash">
          <code>{text}</code>
        </div>
      );
    case 'peer':
      return (
        <div className="peer">
          <span className="who">
            <Icon name="msg" />
            From {it.sender ?? ''}
          </span>
          <Markdown inline text={text} nodes={p.tree} />
        </div>
      );
    case 'thinking':
      return (
        <div className="extra">
          <span className="dl">Thinking</span>
          {text}
        </div>
      );
    case 'systemNote':
      return (
        <div className="extra">
          <span className="dl">System</span>
          {text}
        </div>
      );
  }
});

/**
 * A tool, file edit or subagent row's line, `label` after the triangle: a button that opens the
 * row's detail with `onTap`, or, with no `onTap`, a plain `div.tool` with the spacer in the
 * triangle's place, as a file edit and every nested row draw.
 */
function toolLine(label: JSX.Element, expanded: boolean, onTap: (() => void) | null): JSX.Element {
  if (onTap === null) {
    return (
      <div className="tool">
        <span className="sp" />
        {label}
      </div>
    );
  }
  return (
    <button className="tool" type="button" aria-expanded={expanded} onClick={onTap}>
      <Icon name={expanded ? 'tri-d' : 'tri-r'} cls="tri" />
      {label}
    </button>
  );
}

/** A tool row's mark: the dots while it runs, "failed" after an error, and a check after a Bash call that did not fail. */
function toolMark(status: string | undefined, name: string): JSX.Element | null {
  if (status === 'running') return <Dots />;
  if (status === 'error') return <span className="fail">failed</span>;
  if (name !== 'Bash') return null;
  return (
    <span className="okm">
      <Icon name="check" />
    </span>
  );
}

/**
 * A subagent's items in `.nest`, as `planNest` plans them, then the detail's box: the
 * too-large line when the laptop's detail or the nest's budget left items out, or the laptop's
 * message. Each nested row is an `ItemRow` with no `toggle`, so it never opens and never nests.
 * The plan is read again only when the items change.
 */
const Nest = memo(function Nest(p: { detail: DetailState }): JSX.Element {
  const { items } = p.detail;
  const plan = useMemo(() => planNest(items), [items]);
  return (
    <>
      {plan.rows.length > 0 && (
        <div className="nest">
          {plan.rows.map((r, i) => (
            <ItemRow key={i} row={{ key: i, kind: 'item', item: r.item }} detail={undefined} toggle={null} tree={r.tree} />
          ))}
        </div>
      )}
      <DetailPane detail={p.detail} parts={false} cut={plan.cut} />
    </>
  );
});
