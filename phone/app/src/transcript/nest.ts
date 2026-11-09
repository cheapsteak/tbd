/**
 * What a subagent's nest draws: its items in order, each message's markdown read ahead, under
 * one budget for the whole nest (spec section 7, "Large details").
 *
 * A nest can hold up to `MAX_SUBAGENT_ITEMS` items (`state/detail.ts`), and each message among
 * them would otherwise read its own markdown and draw its own nodes, each up to a message's caps
 * (`MAX_MARKDOWN_LENGTH` characters read, `MAX_NODES` nodes, `markdown/mdTree.ts`). Measured
 * through the real bundle in desktop Chrome, a laptop that sent 144 messages of hostile markdown
 * froze the page for 9 s, and 171 honest 4 KB previews of short lines made 700,000 nodes. So the
 * nest shares one message's caps among all its items (`MdBudget`):
 * - **Markdown:** the items read `NEST_MARKDOWN_LENGTH` characters as markdown between them, in
 *   order. Past it, a message shows as plain lines.
 * - **Nodes:** the items draw about `NEST_NODES` nodes between them, each row counting
 *   `ROW_NODES` for its own elements beside its text. A message that reaches the limit shows the
 *   rest of its text as one text node, and the items after it are not drawn: the nest is `cut`,
 *   and the row shows "Too large for the phone. Open on the laptop." under it.
 *
 * So a nest costs about what one message does.
 *
 * **Items arrive a chunk at a time** (`state/detail.ts`), and the row shows those that arrived
 * while the rest load. So a plan goes on from the last one when the items begin with the items
 * it planned (`planNest`): its rows stand as the same objects, which the nested rows draw from,
 * so they draw nothing again, and only the items after them are read. A nest of a hundred
 * chunks then costs about what it costs drawn once.
 *
 * Pure, with no React, so `node --test` loads it.
 */

import { MAX_MARKDOWN_LENGTH, MAX_NODES, mdInline, mdTree } from '../markdown/mdTree.ts';
import type { MdBudget, MdNode } from '../markdown/mdTree.ts';
import type { PhoneItem } from '../protocol/types.ts';
import type { TranscriptRow } from '../state/transcript.ts';

/** The characters a whole nest reads as markdown: one message's, 6,144. */
export const NEST_MARKDOWN_LENGTH = MAX_MARKDOWN_LENGTH;

/** About the most nodes a whole nest draws: one message's, 50,000. */
export const NEST_NODES = MAX_NODES;

/**
 * The nodes each nested row counts for its own elements beside its text: at least what any row
 * draws, such as a tool row's box, spacer, glyph, name, target and mark, so the count is never
 * low.
 */
export const ROW_NODES = 16;

/**
 * One nested row: its item, its text's markdown when it draws through `Markdown`, and the row it
 * draws as, keyed by its place in the nest.
 */
export interface NestRow {
  item: PhoneItem;
  tree: readonly MdNode[] | null;
  row: TranscriptRow;
}

export interface NestPlan {
  rows: readonly NestRow[];
  /** True when items were left out for the budget. */
  cut: boolean;
  /** The items planned, which a plan of more items begins with to go on from this one. */
  items: readonly PhoneItem[];
  /** What the rows left of the nest's budget. */
  left: Readonly<MdBudget>;
}

/**
 * The rows `items` draw in a nest, under the nest's budget (this file's header). Given `from`, a
 * plan of items that `items` begins with, the same objects in the same places, it goes on from
 * there, and returns `from` itself when `from` left items out already. Either way the plan is the
 * one `items` would get afresh.
 */
export function planNest(items: readonly PhoneItem[], from: NestPlan | null = null): NestPlan {
  const goOn = from !== null && beginsWith(items, from.items);
  if (goOn && from.cut) return from;
  const budget: MdBudget = goOn ? { ...from.left } : { markdown: NEST_MARKDOWN_LENGTH, nodes: NEST_NODES };
  const rows: NestRow[] = goOn ? [...from.rows] : [];
  for (let i = rows.length; i < items.length; i++) {
    if (budget.nodes < ROW_NODES) return { rows, cut: true, items, left: budget };
    budget.nodes -= ROW_NODES;
    const item = items[i]!;
    rows.push({ item, tree: treeOf(item, budget), row: { key: i, kind: 'item', item } });
  }
  return { rows, cut: false, items, left: budget };
}

/** Whether `items` begins with `head`'s items, the same objects in the same places. */
function beginsWith(items: readonly PhoneItem[], head: readonly PhoneItem[]): boolean {
  return head.length <= items.length && head.every((item, i) => items[i] === item);
}

/**
 * The markdown of `item`'s text, spent from `budget`, for the rows `ItemRow` draws through
 * `Markdown`; null for the rest, an API error among them, whose text draws plain.
 */
function treeOf(item: PhoneItem, budget: MdBudget): readonly MdNode[] | null {
  const text = item.text ?? '';
  switch (item.kind) {
    case 'assistant':
      return item.apiError === undefined ? mdTree(text, budget) : null;
    case 'user':
    case 'peer':
      return mdInline(text, budget);
    default:
      return null;
  }
}
