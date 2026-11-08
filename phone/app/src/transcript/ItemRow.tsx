/**
 * One row of the transcript, drawn element for element and class for class as the mock's
 * `itemHTML` draws it (mock 870-897). It only renders: a tap on a tool, subagent or "Show more"
 * calls `toggleDetail` with the row's key, and the detail itself (6c-5) is drawn beside the row
 * by the list, not here.
 *
 * Where the wire holds less than the mock shows, the row shows less, and says what it can:
 * - a failed tool's mark reads "failed", since the wire has no exit code;
 * - a slash row has its command only, since the wire has no output;
 * - a system note's label is always "System", since the wire has no label.
 *
 * A row whose detail is open (a record in the slice's `details`, not cancelled) reads
 * `aria-expanded="true"`.
 */

import type { JSX } from 'react';
import type { PhoneItem } from '../protocol/types.ts';
import type { TranscriptRow } from '../state/transcript.ts';
import { toolGlyph } from '../state/status.ts';
import { Markdown } from '../markdown/Markdown.tsx';
import { Dots, Icon } from '../ui/Icon.tsx';

export function ItemRow(p: { row: TranscriptRow; expanded: boolean; toggle: (part: 'input' | 'text' | 'subagent') => void }): JSX.Element | null {
  const { row, expanded, toggle } = p;
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
    case 'assistant':
      return (
        <div className="say">
          <Markdown text={text} />
          {it.truncated && !expanded && (
            <button className="morebtn" type="button" onClick={() => toggle('text')}>
              Show more
            </button>
          )}
        </div>
      );
    case 'tool':
      return (
        <button className="tool" type="button" aria-expanded={expanded} onClick={() => toggle('input')}>
          <Icon name={expanded ? 'tri-d' : 'tri-r'} cls="tri" />
          <Icon name={toolGlyph(name)} cls="ti" />
          <b>{name}</b>
          <code>{it.target ?? ''}</code>
          {it.toolStatus === 'running' ? (
            <Dots />
          ) : it.toolStatus === 'error' ? (
            <span className="fail">failed</span>
          ) : name === 'Bash' ? (
            <span className="okm">
              <Icon name="check" />
            </span>
          ) : null}
        </button>
      );
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
    case 'subagent':
      return (
        <button className="tool" type="button" aria-expanded={expanded} onClick={() => toggle('subagent')}>
          <Icon name={expanded ? 'tri-d' : 'tri-r'} cls="tri" />
          <Icon name="bot" cls="ti" />
          <b>{it.agentType ?? ''} agent</b>
          <code>{it.target ?? ''}</code>
          <span className="cnt">{it.itemCount ?? 0} items</span>
        </button>
      );
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
