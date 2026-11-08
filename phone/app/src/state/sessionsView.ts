/**
 * The sessions list as the phone shows it (spec section 8.2, "Sessions"): the laptop's groups
 * and rows, sorted newest first at both levels, each row with the session it opens.
 *
 * The laptop sends its sidebar's stable order; the phone sorts by time instead, so whatever just
 * changed is at the top of the screen. Placement `depth` is ignored, because a sort by time
 * breaks the sidebar's tree.
 */

import type { PhoneGroupLayout, PhoneRow, PhoneSession } from '../protocol/types.ts';
import { rowByID } from './sessionsData.ts';
import { STATUS } from './status.ts';
import type { SessionsData } from './store.ts';

/** One row on screen: the row, the session its status and tap come from, and its session count. */
export interface RowView {
  row: PhoneRow;
  best: PhoneSession;
  count: number;
}

/**
 * One group on screen. `repoID` is set for a repo group alone, whose header has the "+".
 * `newestAt` is its newest row's `statusChangedAt`, or 0 when it shows no rows.
 */
export interface GroupView {
  group: PhoneGroupLayout;
  repoID: string | null;
  rows: RowView[];
  newestAt: number;
}

const REPO_PREFIX = 'repo:';

/** The repo ID of a repo group, whose ID is `repo:<UUID>` (`PhoneSnapshotBuilder`), or null for any other group. */
export function repoIDOf(group: PhoneGroupLayout): string | null {
  if (group.kind !== 'repo' || !group.id.startsWith(REPO_PREFIX)) return null;
  const id = group.id.slice(REPO_PREFIX.length);
  return id === '' ? null : id;
}

/**
 * The session a row shows and opens: the most urgent by `STATUS` rank, then the one whose status
 * changed last, then the first. A row with no sessions has none, and throws: `sessionsView`
 * never shows such a row.
 */
export function bestSession(row: PhoneRow): PhoneSession {
  let best: PhoneSession | undefined;
  for (const s of row.sessions) {
    if (best === undefined) {
      best = s;
      continue;
    }
    const rank = STATUS[s.status.chip].rank;
    const bestRank = STATUS[best.status.chip].rank;
    if (rank < bestRank || (rank === bestRank && s.status.changedAt > best.status.changedAt)) best = s;
  }
  if (best === undefined) throw new RangeError(`bestSession: row ${row.id} has no sessions`);
  return best;
}

/**
 * The groups and rows to show, in order:
 * - In a group, rows by `statusChangedAt`, newest first.
 * - Groups that show rows by their newest row, then the repo groups that show none, header
 *   only, so their "+" stays reachable. Scratch and provider groups that show none are dropped.
 * - Ties keep the laptop's order.
 *
 * A placement is skipped while its row has not arrived (after a snapshot with `more` set), and
 * so is a row with no sessions, such as a worktree with only shell tabs: there is nothing to open.
 */
export function sessionsView(d: SessionsData): GroupView[] {
  const shown: GroupView[] = [];
  const emptyRepos: GroupView[] = [];
  for (const group of d.layout) {
    const rows: RowView[] = [];
    for (const placement of group.rows) {
      const row = rowByID(d, placement.id);
      if (row === null || row.sessions.length === 0) continue;
      rows.push({ row, best: bestSession(row), count: row.sessions.length });
    }
    // Array sort is stable, so equal times keep the layout's order.
    rows.sort((a, b) => b.row.statusChangedAt - a.row.statusChangedAt);
    const view: GroupView = { group, repoID: repoIDOf(group), rows, newestAt: rows[0]?.row.statusChangedAt ?? 0 };
    if (rows.length > 0) shown.push(view);
    else if (group.kind === 'repo') emptyRepos.push(view);
  }
  shown.sort((a, b) => b.newestAt - a.newestAt);
  return [...shown, ...emptyRepos];
}
