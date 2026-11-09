// Tests nest.ts: a subagent's nest shares one message's markdown and node caps among all its
// items, so a laptop that sends a thousand hostile messages draws about what one costs.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mdTree } from '../markdown/mdTree.ts';
import type { MdBudget, MdNode } from '../markdown/mdTree.ts';
import type { PhoneItem } from '../protocol/types.ts';
import { MAX_SUBAGENT_ITEMS } from '../state/detail.ts';
import { NEST_MARKDOWN_LENGTH, NEST_NODES, planNest, ROW_NODES } from './nest.ts';
import type { NestPlan } from './nest.ts';

/**
 * The most nodes a nest may pass its budget by. A text that reaches it still draws the rest of
 * its source as one text node, and the containers around that node close over it, so a nest can
 * pass by a few; 2 at most in these cases, measured.
 */
const SLACK = 32;

function countNodes(nodes: readonly MdNode[]): number {
  let n = 0;
  for (const node of nodes) n += 1 + ('children' in node ? countNodes(node.children) : 0);
  return n;
}

/** The nodes a plan draws: each tree, and each row's own elements. */
function drawn(plan: NestPlan): number {
  return plan.rows.reduce((n, r) => n + ROW_NODES + (r.tree === null ? 0 : countNodes(r.tree)), 0);
}

/** The `strong` nodes of a plan, each of which only markdown read as markdown draws. */
function strongs(nodes: readonly MdNode[]): number {
  let n = 0;
  for (const node of nodes) {
    if (node.t === 'strong') n += 1;
    if ('children' in node) n += strongs(node.children);
  }
  return n;
}

function items(kind: 'assistant' | 'user' | 'peer', text: string, count = MAX_SUBAGENT_ITEMS): PhoneItem[] {
  return Array.from({ length: count }, (_, i) => ({ id: `n${i}`, kind, text, truncated: false }));
}

/**
 * Texts that cost the most to lex or draw, each about a message's markdown long or longer, and
 * whether a thousand of them pass the nest's nodes. Those of one line draw as one text node each
 * past the nest's markdown, so all thousand fit.
 */
const HOSTILE: Array<[name: string, text: string, cut: boolean]> = [
  ['stars and dots', '*.'.repeat(3_072), false],
  ['underscore pairs', '_a'.repeat(3_072), false],
  ['unclosed link targets', '[a](b'.repeat(1_228), false],
  ['short lines, a preview long', 'a\n'.repeat(2_048), true],
  ['short lines, a frame long', 'a\n'.repeat(19_000), true],
  ['setext headings', 'a\n-\n'.repeat(1_536), true],
  ['a table of stars', `|a|\n|-|\n${'|*a|\n'.repeat(1_225)}`, true],
];

test('a hostile nest draws about one message of nodes, and says when it left items out', () => {
  for (const [name, text, cut] of HOSTILE) {
    for (const kind of ['assistant', 'user'] as const) {
      const plan = planNest(items(kind, text));
      const nodes = drawn(plan);
      assert.ok(nodes <= NEST_NODES + SLACK, `${name}, ${kind}: ${nodes} nodes`);
      assert.equal(plan.cut, cut, `${name}, ${kind}`);
      assert.equal(plan.rows.length < MAX_SUBAGENT_ITEMS, cut, `${name}, ${kind}: ${plan.rows.length} rows`);
    }
  }
});

test('a nest reads one message of markdown between all its items', () => {
  // Each text is 5 characters of markdown that draw one strong node, so a nest that read more
  // than its budget as markdown would draw more of them.
  const plan = planNest(items('assistant', '**a**\n'.repeat(100), 200));
  const total = plan.rows.reduce((n, r) => n + strongs(r.tree ?? []), 0);
  assert.ok(total > 0);
  assert.ok(total <= NEST_MARKDOWN_LENGTH / 6 + 1, `${total} strong nodes`);
  assert.equal(strongs(plan.rows.at(-1)?.tree ?? []), 0, 'the last items show as plain lines');
});

test('a shared budget pays for each text it reads', () => {
  const budget: MdBudget = { markdown: 100, nodes: 1_000 };
  const first = mdTree('**a** '.repeat(100), budget);
  // It reads up to 100 characters, cut back to the last space.
  assert.ok(budget.markdown >= 0 && budget.markdown < 6, `${budget.markdown} left`);
  assert.equal(budget.nodes, 1_000 - countNodes(first));
  assert.equal(strongs(first), 16);
  // Too little left to read as markdown: the next text is plain.
  assert.equal(strongs(mdTree('**a**', budget)), 0);
  assert.equal(strongs(mdTree('**a**', { markdown: 0, nodes: 1_000 })), 0);
  // No nodes left: the next text is one node.
  const spent: MdBudget = { markdown: 6_144, nodes: 0 };
  assert.ok(countNodes(mdTree('a\n'.repeat(1_000), spent)) <= 2);
});

test('an honest nest draws every item, with markdown for messages only', () => {
  const nest: PhoneItem[] = [
    { id: 'a', kind: 'assistant', text: 'I read **three** files.', truncated: false },
    { id: 'u', kind: 'user', text: 'Look at `src/`', truncated: false },
    { id: 'p', kind: 'peer', text: 'done', truncated: false, sender: 'acme-bot' },
    { id: 't', kind: 'tool', truncated: false, toolName: 'Read', target: 'src/app.ts', toolStatus: 'ok' },
    { id: 's', kind: 'subagent', truncated: false, agentType: 'Explore', target: 'auth', itemCount: 4 },
    { id: 'k', kind: 'thinking', text: 'hmm', truncated: false },
    { id: 'x', kind: 'assistant', text: 'cut', truncated: true },
  ];
  const plan = planNest(nest);
  assert.equal(plan.cut, false);
  assert.deepEqual(plan.rows.map((r) => r.item.id), ['a', 'u', 'p', 't', 's', 'k', 'x']);
  assert.deepEqual(plan.rows.map((r) => r.tree !== null), [true, true, true, false, false, false, true]);
  assert.equal(strongs(plan.rows[0]!.tree!), 1);
  // A thousand small rows fit.
  const many = planNest(Array.from({ length: MAX_SUBAGENT_ITEMS }, (_, i) => nest[i % nest.length]!));
  assert.equal(many.cut, false);
  assert.equal(many.rows.length, MAX_SUBAGENT_ITEMS);
});

test("an API error in a nest reads no markdown, and spends none of the nest's", () => {
  const error: PhoneItem = { id: 'e', kind: 'assistant', text: '**API Error**: overloaded', truncated: false, apiError: 'server_error' };
  const message: PhoneItem = { id: 'a', kind: 'assistant', text: 'I read **three** files.', truncated: false };
  const plan = planNest([error, message]);
  assert.deepEqual(plan.rows.map((r) => r.tree !== null), [false, true]);
  assert.equal(plan.left.markdown, planNest([message]).left.markdown);
  assert.ok(plan.left.markdown < NEST_MARKDOWN_LENGTH);
});

test('an empty nest draws nothing and leaves nothing out', () => {
  const plan = planNest([]);
  assert.deepEqual(plan.rows, []);
  assert.equal(plan.cut, false);
});

/** `all` in chunks of `size` as a detail adds them, each chunk's items a new array that begins with the last. */
function arrivals(all: readonly PhoneItem[], size: number): PhoneItem[][] {
  const out: PhoneItem[][] = [];
  for (let end = size; end < all.length + size; end += size) out.push(all.slice(0, end));
  return out;
}

/** A plan's rows as what they draw: each item, its tree and its row. */
function drawing(plan: NestPlan): unknown {
  return { cut: plan.cut, rows: plan.rows.map((r) => [r.item, r.tree, r.row]) };
}

test('a plan that goes on as items arrive is the plan made afresh, and keeps the rows it planned', () => {
  const honest: PhoneItem[] = Array.from({ length: 300 }, (_, i) => (i % 3 === 2
    ? { id: `t${i}`, kind: 'tool', truncated: false, toolName: 'Read', target: `src/${i}.ts`, toolStatus: 'ok' }
    : { id: `m${i}`, kind: i % 3 === 0 ? 'assistant' : 'user', text: `Item **${i}** reads [src](https://acme.example/${i}).`, truncated: false }));
  // Hostile texts that read past the nest's markdown, and that pass its nodes partway through a chunk.
  const hostile = HOSTILE.filter(([name]) => name === 'stars and dots' || name === 'short lines, a preview long');
  const cases: Array<[string, PhoneItem[]]> = [['honest', honest], ...hostile.map(([name, text]): [string, PhoneItem[]] => [name, items('user', text, 100)])];
  for (const [name, all] of cases) {
    let plan: NestPlan | null = null;
    for (const now of arrivals(all, 15)) {
      const before: NestPlan | null = plan;
      plan = planNest(now, before);
      assert.deepEqual(drawing(plan), drawing(planNest(now)), `${name}, ${now.length} items`);
      if (before === null) continue;
      // The rows planned before are the same objects, so the nested rows they draw draw nothing again.
      before.rows.forEach((r, i) => assert.equal(plan!.rows[i], r, `${name}, row ${i}`));
      if (before.cut) assert.equal(plan, before, `${name}: a plan that left items out stays as it is`);
    }
  }
  // Other items, or the same ones as other objects, are planned afresh.
  const first = planNest(honest.slice(0, 9));
  const other = planNest(honest.slice(0, 9).map((item) => ({ ...item })), first);
  assert.notEqual(other.rows[0], first.rows[0]);
  assert.deepEqual(drawing(other), drawing(first));
  const shorter = planNest(honest.slice(0, 3), first);
  assert.deepEqual(drawing(shorter), drawing(planNest(honest.slice(0, 3))));
});
