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
 * **Fields an older laptop does not send** (`rowWords.ts`). Each row draws what the mock draws
 * from the field when the laptop sent it, and what it drew before the field existed when not:
 * - a failed tool's mark reads "exit 2" with the exit code, and "failed" without one;
 * - a file edit names the file's path, relative to the worktree when the file is inside it,
 *   and the file's name without one;
 * - a slash command shows its output under the command, as plain text, and nothing without one;
 * - a system note's label is its kind's, such as "Hook", and "System" without one;
 * - Claude's text that is an API error (`apiError`) draws as the mock's error row, its text
 *   plain rather than markdown, in the rate-limit tone for a rate limit and the error tone for
 *   the rest; without the field it is Claude's text, as before.
 *
 * **Details** (`DetailPane`, and `state/detail.ts` for the chunk rules). A row whose detail is
 * open (it has a record) reads `aria-expanded="true"` and turns its triangle down.
 * - A tool row draws its box under the button: Input and Result, or the loading line. A tap
 *   collapses it, a failed one too, and the next tap starts over.
 * - "Show more" ends every message the laptop cut (`truncated`): Claude's, yours, a peer's, a
 *   slash command, thinking and a system note, since the laptop cuts each of their texts at
 *   4 KB (4b `TranscriptShaper.message`). It puts the message's whole text in place of the cut
 *   text once all of it arrived, drawn as the cut text is (through `Markdown` for Claude, you
 *   and a peer, as plain text otherwise), and the button goes, as in the mock. It draws at most
 *   `MAX_DETAIL_LINES` lines of it (`firstLines`), as a tool's parts do. Its box, under the
 *   message, shows the loading line, the too-large line, after a text too large or cut at those
 *   lines, or the laptop's message. While the text loads, the button stays, marked busy
 *   (`aria-busy`), and a tap on it cancels the load (spec section 7, "Large details"): the
 *   detail goes, and the row shows its cut text and "Show more" again. Until the whole text has
 *   arrived the row keeps its cut text, so a load that fails partway shows the cut text, "Show
 *   more" and the laptop's message, never part of the text, and a tap starts over. So does a
 *   text that arrived no longer than the cut one: the row keeps the cut text and "Show more",
 *   with no box. The mock draws the button only after Claude's blocks, where it starts a line
 *   of its own; after the inline text of the other kinds it is a block, styled inline, since
 *   app.css is not this file's, so it starts a line there too.
 * - A subagent row draws its items in `.nest`, each through this component as a nested row,
 *   under one budget for the whole nest (`nest.ts`): items past it are not drawn, and the row
 *   shows "Too large for the phone. Open on the laptop." under the nest. While the rest load,
 *   the items that arrived show, and the loading line under them, as a tool row's box keeps its
 *   Input while its Result loads. It collapses as a tool row does.
 *
 * **Nested rows draw, and never open.** A nested row has no row key, so it has no record in
 * `details`, and the laptop could not serve one anyway: it finds a detail by looking the item ID
 * up in the session's own transcript (`TranscriptDetailReader.text`), while a subagent's items
 * come from the subagent's own transcript file. So a nested tool or subagent is a plain
 * `div.tool` with the spacer in place of the triangle, as a file edit is, and a nested message
 * has no "Show more". That also bounds the nesting at one level: a nested subagent draws as its
 * row alone.
 */

import { memo, useMemo, useRef, type CSSProperties, type JSX, type ReactNode } from 'react';
import type { MdNode } from '../markdown/mdTree.ts';
import type { PhoneItem } from '../protocol/types.ts';
import { firstLines } from '../state/detail.ts';
import type { DetailState } from '../state/detail.ts';
import type { TranscriptRow } from '../state/transcript.ts';
import { toolGlyph } from '../state/status.ts';
import { Markdown } from '../markdown/Markdown.tsx';
import { Dots, Icon } from '../ui/Icon.tsx';
import { DetailPane } from './DetailPane.tsx';
import { planNest, type NestPlan } from './nest.ts';
import { editTarget, errorTone, failMark, noteLabel } from './rowWords.ts';

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
  // A message's whole text once "Show more" brought all of it, cut to its first lines, read again only when it changes.
  const wholeText = detail !== null && (detail.phase === 'open' || detail.phase === 'tooLarge') ? detail.text.text : undefined;
  const whole = useMemo(() => (wholeText === undefined ? null : firstLines(wholeText)), [wholeText]);
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
  // The whole text takes the cut text's place only when it says more than the cut text does.
  const full = wholeText !== undefined && wholeText.length > text.length ? whole : null;
  // The text a message draws, and its markdown read ahead, which is of the cut text only.
  const shown = full?.text ?? text;
  const tree = full === null ? p.tree : null;
  /**
   * A message's row (this file's header): its box `cls`, holding `head`, then `body`, its text,
   * then "Show more" while it offers it, on a line of its own after inline text; then the
   * detail's box.
   */
  const message = (cls: string, head: ReactNode, body: ReactNode, inline: boolean): JSX.Element => {
    const loading = detail?.phase === 'loading';
    return (
      <>
        <div className={cls}>
          {head}
          {body}
          {it.truncated && toggle !== null && full === null && (
            <button
              className="morebtn"
              type="button"
              style={inline ? OWN_LINE : undefined}
              aria-busy={loading || undefined}
              onClick={() => toggle('text')}
            >
              Show more
            </button>
          )}
        </div>
        {detail !== null && (full !== null || loading || detail.phase === 'failed') && (
          <DetailPane detail={detail} parts={false} cut={full?.cut === true} />
        )}
      </>
    );
  };
  switch (it.kind) {
    case 'user':
      return message('me', <span className="who">You</span>, <Markdown inline text={shown} nodes={tree} />, true);
    case 'assistant':
      if (it.apiError !== undefined) {
        return message(`errrow ${errorTone(it.apiError)}`, <Icon name="octa" />, <span>{shown}</span>, true);
      }
      return message('say', null, <Markdown text={shown} nodes={tree} />, false);
    case 'tool': {
      const label = (
        <>
          <Icon name={toolGlyph(name)} cls="ti" />
          <b>{name}</b>
          <code>{it.target ?? ''}</code>
          {toolMark(it.toolStatus, name, it.exitCode)}
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
          <code>{editTarget(it)}</code>
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
          {detail !== null && <Nest detail={detail} />}
        </>
      );
    }
    case 'slash': {
      const body = (
        <>
          <code>{shown}</code>
          {it.output !== undefined && <span>{it.output}</span>}
        </>
      );
      return message('slash', null, body, true);
    }
    case 'peer': {
      const head = (
        <span className="who">
          <Icon name="msg" />
          From {it.sender ?? ''}
        </span>
      );
      return message('peer', head, <Markdown inline text={shown} nodes={tree} />, true);
    }
    case 'thinking':
      return message('extra', <span className="dl">Thinking</span>, shown, true);
    case 'systemNote':
      return message('extra', <span className="dl">{noteLabel(it.noteKind)}</span>, shown, true);
  }
});

/**
 * "Show more" after inline text, or in `.slash`'s column: a block, so it starts a line of its
 * own, as after Claude's blocks, and only as wide as its words, so the tap goes to it alone.
 */
const OWN_LINE: CSSProperties = { display: 'block', alignSelf: 'flex-start' };

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

/**
 * A tool row's mark: the dots while it runs, the exit code or "failed" after an error
 * (`failMark`), and a check after a Bash call that did not fail.
 */
function toolMark(status: string | undefined, name: string, exitCode: number | undefined): JSX.Element | null {
  if (status === 'running') return <Dots />;
  if (status === 'error') return <span className="fail">{failMark(exitCode)}</span>;
  if (name !== 'Bash') return null;
  return (
    <span className="okm">
      <Icon name="check" />
    </span>
  );
}

/**
 * A subagent's items in `.nest`, as `planNest` plans them, then the detail's box: the loading
 * line while more items load, the too-large line when the laptop's detail or the nest's budget
 * left items out, or the laptop's message. Each nested row is an `ItemRow` with no `toggle`, so
 * it never opens and never nests. The plan is read again only when the items change, and goes
 * on from the last one as more items arrive, so the rows already drawn are not drawn again.
 */
const Nest = memo(function Nest(p: { detail: DetailState }): JSX.Element {
  const { items } = p.detail;
  const last = useRef<NestPlan | null>(null);
  const plan = useMemo(() => (last.current = planNest(items, last.current)), [items]);
  return (
    <>
      {plan.rows.length > 0 && (
        <div className="nest">
          {plan.rows.map((r, i) => (
            <ItemRow key={i} row={r.row} detail={undefined} toggle={null} tree={r.tree} />
          ))}
        </div>
      )}
      <DetailPane detail={p.detail} parts={false} cut={plan.cut} />
    </>
  );
});
