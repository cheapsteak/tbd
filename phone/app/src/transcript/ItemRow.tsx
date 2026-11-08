/**
 * One row of the transcript, drawn element for element and class for class as the mock's
 * `itemHTML` draws it (mock 870-897), with its open detail. It only renders: a tap on a tool, a
 * subagent or "Show more" calls `toggle`, which the list wires to `toggleDetail` with the row's
 * key, and `detail` is that row's record in the slice's `details`.
 *
 * Where the wire holds less than the mock shows, the row shows less, and says what it can:
 * - a failed tool's mark reads "failed", since the wire has no exit code;
 * - a slash row has its command only, since the wire has no output;
 * - a system note's label is always "System", since the wire has no label.
 *
 * **Details** (`DetailPane`, and `state/detail.ts` for the chunk rules). A row whose detail is
 * open (a record, not cancelled) reads `aria-expanded="true"` and turns its triangle down.
 * - A tool row draws its box under the button: Input and Result, or the loading line.
 * - "Show more" puts the message's whole text in place of the cut text, through `Markdown`,
 *   once it arrived, and the button goes, as in the mock. Its box shows the loading line, the
 *   too-large line or the laptop's message. After a failure the button comes back, and a tap
 *   starts over.
 * - A subagent row draws its items in `.nest`, each through this component as a nested row.
 *
 * **Nested rows draw, and never open.** A nested row has no row key, so it has no record in
 * `details`, and the laptop could not serve one anyway: it finds a detail by looking the item ID
 * up in the session's own transcript (`TranscriptDetailReader.text`), while a subagent's items
 * come from the subagent's own transcript file. So a nested tool or subagent is a plain
 * `div.tool` with the spacer in place of the triangle, as a file edit is, and a nested message
 * has no "Show more". That also bounds the nesting at one level: a nested subagent draws as its
 * row alone.
 */

import type { JSX } from 'react';
import type { PhoneItem } from '../protocol/types.ts';
import { isOpen } from '../state/detail.ts';
import type { DetailState } from '../state/detail.ts';
import type { TranscriptRow } from '../state/transcript.ts';
import { toolGlyph } from '../state/status.ts';
import { Markdown } from '../markdown/Markdown.tsx';
import { Dots, Icon } from '../ui/Icon.tsx';
import { DetailPane } from './DetailPane.tsx';

/** The part each kind of row opens with a tap: a tool's input (then its result), the rest of a message, or a subagent's items. */
export type RowPart = 'input' | 'text' | 'subagent';

export function ItemRow(p: { row: TranscriptRow; detail: DetailState | undefined; toggle: ((part: RowPart) => void) | null }): JSX.Element | null {
  const { row, toggle } = p;
  const detail = toggle !== null && isOpen(p.detail) ? p.detail : null;
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
          <Markdown inline text={text} />
        </div>
      );
    case 'assistant': {
      const full = detail?.phase !== 'loading' ? detail?.text.text : undefined;
      return (
        <>
          <div className="say">
            <Markdown text={full ?? text} />
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
      const mark = it.toolStatus === 'running' ? (
        <Dots />
      ) : it.toolStatus === 'error' ? (
        <span className="fail">failed</span>
      ) : name === 'Bash' ? (
        <span className="okm">
          <Icon name="check" />
        </span>
      ) : null;
      if (toggle === null) {
        return (
          <div className="tool">
            <span className="sp" />
            <Icon name={toolGlyph(name)} cls="ti" />
            <b>{name}</b>
            <code>{it.target ?? ''}</code>
            {mark}
          </div>
        );
      }
      return (
        <>
          <button className="tool" type="button" aria-expanded={expanded} onClick={() => toggle('input')}>
            <Icon name={expanded ? 'tri-d' : 'tri-r'} cls="tri" />
            <Icon name={toolGlyph(name)} cls="ti" />
            <b>{name}</b>
            <code>{it.target ?? ''}</code>
            {mark}
          </button>
          {detail !== null && <DetailPane detail={detail} parts />}
        </>
      );
    }
    case 'fileEdit':
      return (
        <div className="tool">
          <span className="sp" />
          <Icon name="pen" cls="ti" />
          <b>{name}</b>
          <code>{it.target ?? ''}</code>
          <span className="plus">+{it.added ?? 0}</span>
          <span className="minus">{`−${it.removed ?? 0}`}</span>
        </div>
      );
    case 'subagent': {
      const label = (
        <>
          <Icon name="bot" cls="ti" />
          <b>{it.agentType ?? ''} agent</b>
          <code>{it.target ?? ''}</code>
          <span className="cnt">{it.itemCount ?? 0} items</span>
        </>
      );
      if (toggle === null) {
        return (
          <div className="tool">
            <span className="sp" />
            {label}
          </div>
        );
      }
      return (
        <>
          <button className="tool" type="button" aria-expanded={expanded} onClick={() => toggle('subagent')}>
            <Icon name={expanded ? 'tri-d' : 'tri-r'} cls="tri" />
            {label}
          </button>
          {detail !== null && detail.phase !== 'loading' && detail.items.length > 0 && (
            <div className="nest">
              {detail.items.map((item, i) => (
                <ItemRow key={i} row={{ key: i, kind: 'item', item }} detail={undefined} toggle={null} />
              ))}
            </div>
          )}
          {detail !== null && <DetailPane detail={detail} parts={false} />}
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
          <Markdown inline text={text} />
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
}
