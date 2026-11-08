/**
 * A transcript message's markdown, drawn as React elements from `mdTree` (or `mdInline`), so no
 * HTML string is made. A link is a `span.lnk` with the link role, as the mock draws it, and opens
 * only through the `openLink` action, behind the loader's sheet: the app never renders a raw
 * link element or a URL attribute.
 *
 * `inline` draws the text as one run with no blocks, the way the mock draws your messages and
 * messages from other sessions (its `inline`). Otherwise it draws blocks, the way the mock draws
 * assistant text (its `md`): app.css spaces paragraphs and lists only inside `.say`.
 *
 * `nodes`, when given, is the text's markdown read ahead, and is drawn in place of reading
 * `text` again: a subagent's nest reads all its items under one budget (`transcript/nest.ts`).
 */

import { useMemo, type CSSProperties, type JSX, type KeyboardEvent, type ReactNode } from 'react';
import { useActions } from '../state/context.tsx';
import { mdInline, mdTree, type MdNode } from './mdTree.ts';

export function Markdown(p: { text: string; inline?: boolean; nodes?: readonly MdNode[] | null }): JSX.Element {
  const inline = p.inline === true;
  const given = p.nodes ?? null;
  const nodes = useMemo(() => given ?? (inline ? mdInline(p.text) : mdTree(p.text)), [given, p.text, inline]);
  return <>{draw(nodes)}</>;
}

/**
 * Styles for the blocks the mock never shows, which app.css has no rule for: an ordered list
 * spaced like `.say ul`, a quote ruled like `.nest`, and a code block that wraps, so a long line
 * never widens the transcript past the screen.
 */
const OL_STYLE: CSSProperties = { margin: '0 0 6px', paddingLeft: 18 };
const QUOTE_STYLE: CSSProperties = { margin: '0 0 6px', paddingLeft: 10, borderLeft: '2px solid var(--sep)' };
const PRE_STYLE: CSSProperties = {
  margin: '0 0 6px', fontFamily: 'var(--mono)', fontSize: '.9em', whiteSpace: 'pre-wrap', overflowWrap: 'anywhere',
};
const HR_STYLE: CSSProperties = { margin: '6px 0', border: 0, borderTop: '1px solid var(--sep)' };

function draw(nodes: readonly MdNode[]): ReactNode[] {
  return nodes.map(drawNode);
}

function drawNode(node: MdNode, key: number): ReactNode {
  switch (node.t) {
    case 'text':
      return node.text;
    case 'code':
      return <code key={key}>{node.text}</code>;
    case 'pre':
      return <pre key={key} style={PRE_STYLE}>{node.text}</pre>;
    case 'br':
      return <br key={key} />;
    case 'hr':
      return <hr key={key} style={HR_STYLE} />;
    case 'p':
      return <p key={key}>{draw(node.children)}</p>;
    case 'h':
      return <p key={key}><strong>{draw(node.children)}</strong></p>;
    case 'ul':
      return <ul key={key}>{draw(node.children)}</ul>;
    case 'ol':
      return <ol key={key} start={node.start === 1 ? undefined : node.start} style={OL_STYLE}>{draw(node.children)}</ol>;
    case 'li':
      return <li key={key}>{draw(node.children)}</li>;
    case 'blockquote':
      return <blockquote key={key} style={QUOTE_STYLE}>{draw(node.children)}</blockquote>;
    case 'strong':
      return <strong key={key}>{draw(node.children)}</strong>;
    case 'em':
      return <em key={key}>{draw(node.children)}</em>;
    case 'del':
      return <del key={key}>{draw(node.children)}</del>;
    case 'link':
      return <Link key={key} url={node.url}>{draw(node.children)}</Link>;
  }
}

/**
 * A link, as the mock's `.lnk`. A click opens it, and so does Enter, as for any element with the
 * link role. Space does not: on a link it scrolls the page, and the role promises a link's keys.
 */
function Link(p: { url: string; children: ReactNode }): JSX.Element {
  const { openLink } = useActions();
  const onKeyDown = (e: KeyboardEvent<HTMLSpanElement>): void => {
    if (e.key !== 'Enter' || e.repeat) return;
    e.preventDefault();
    openLink(p.url);
  };
  return (
    <span className="lnk" role="link" tabIndex={0} onClick={() => openLink(p.url)} onKeyDown={onKeyDown}>
      {p.children}
    </span>
  );
}
