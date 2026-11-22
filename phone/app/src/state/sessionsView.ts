/**
 * The sessions list as the phone shows it (spec section 8.2, "Sessions"): the laptop's groups
 * and rows, sorted newest first at both levels, each row with the session it opens.
 *
 * The laptop sends its sidebar's stable order; the phone sorts by time instead, so whatever just
 * changed is at the top of the screen. Placement `depth` is ignored, because a sort by time
 * breaks the sidebar's tree.
 *
 * A repo group whose filter for registry-provider sessions is on leaves out its registry rows
 * (`isRegistryRow`), all but the selected one, and its header carries the chip that turns the
 * filter on and off (`RemoteFilterChip`). The design:
 * `docs/specs/2026-11-22-phone-remote-session-filter-design.md`. The filter is this view's
 * alone: the store keeps every row, and everything else reads the full list, so a hidden
 * session can still be opened and acted on.
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
 * A repo header's filter chip:
 * - `on` – whether the filter is on, as the phone shows it: its own value while a tap waits for
 *   the laptop, else the laptop's.
 * - `count` – how many registry rows the filter hides while on: every one but the selected row.
 * - `providers` – the registry providers of the repo's registry rows, distinct and sorted. One
 *   names the chip; two or more make it read "remote".
 */
export interface RemoteFilterChip {
  on: boolean;
  count: number;
  providers: string[];
}

/**
 * One group on screen. `repoID` is set for a repo group alone, whose header has the "+".
 * `newestAt` is its newest row's `statusChangedAt`, or 0 when it shows no rows. `filter` is its
 * header's chip, set on a repo group with at least one registry row, the selected one included,
 * whether the filter is on or off; null on every other group.
 */
export interface GroupView {
  group: PhoneGroupLayout;
  repoID: string | null;
  rows: RowView[];
  newestAt: number;
  filter: RemoteFilterChip | null;
}

/** What `sessionsView` reads besides the list. */
export interface SessionsViewOptions {
  /** The selected row (`UIState.lastRowID`), which the filter never hides. */
  lastRowID?: string | null;
  /** The phone's own filter value by repo ID, for a repo whose tap waits for the laptop. It wins over the layout's. */
  pending?: Readonly<Record<string, boolean>>;
}

/** The compiled cloud provider's name (`ClaudeCloudProvider.name`). Every other provider is a registry provider. */
export const CLOUD_PROVIDER = 'claude-cloud';

const REPO_PREFIX = 'repo:';

/**
 * Whether `row` is a registry row: it has a session, and every session it has is a remote
 * session of a registry provider, any provider but `CLOUD_PROVIDER`. That is a remote lane's
 * worktree row or a loose remote session's row; a local worktree row never is one.
 */
export function isRegistryRow(row: PhoneRow): boolean {
  return row.sessions.length > 0 && row.sessions.every((s) => s.ref.kind === 'remote' && s.ref.provider !== CLOUD_PROVIDER);
}

/** The registry providers of `rows`' sessions, distinct and sorted. */
function providersOf(rows: readonly PhoneRow[]): string[] {
  const names = new Set<string>();
  for (const row of rows) for (const s of row.sessions) if (s.ref.kind === 'remote') names.add(s.ref.provider);
  return [...names].sort();
}

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
  const [first, ...rest] = row.sessions;
  if (first === undefined) throw new RangeError(`bestSession: row ${row.id} has no sessions`);
  let best = first;
  for (const s of rest) {
    const rank = STATUS[s.status.chip].rank;
    const bestRank = STATUS[best.status.chip].rank;
    if (rank < bestRank || (rank === bestRank && s.status.changedAt > best.status.changedAt)) best = s;
  }
  return best;
}

/**
 * The groups and rows to show, in order:
 * - In a group, rows by `statusChangedAt`, newest first.
 * - Groups that show rows by their newest row, then the repo groups that show none, header
 *   only, so their "+" and their chip stay reachable. Scratch and provider groups that show
 *   none are dropped.
 * - Ties keep the laptop's order.
 *
 * A placement is skipped while its row has not arrived (after a snapshot with `more` set), and
 * so is a row with no sessions, such as a worktree with only shell tabs: there is nothing to open.
 *
 * In a repo group whose filter is on, by `opts.pending` for its repo when that holds it, else by
 * the layout's `remoteFilterOn`, each registry row is skipped too, except the selected row
 * (`opts.lastRowID`). Scratch and provider groups are never filtered: they hold the sessions
 * that match no repo.
 */
export function sessionsView(d: SessionsData, opts: SessionsViewOptions = {}): GroupView[] {
  const lastRowID = opts.lastRowID ?? null;
  const pending = opts.pending;
  const shown: GroupView[] = [];
  const emptyRepos: GroupView[] = [];
  for (const group of d.layout) {
    const repoID = repoIDOf(group);
    const listed: PhoneRow[] = [];
    for (const placement of group.rows) {
      const row = rowByID(d, placement.id);
      if (row === null || row.sessions.length === 0) continue;
      listed.push(row);
    }
    let filter: RemoteFilterChip | null = null;
    let visible = listed;
    const registry = repoID === null ? [] : listed.filter(isRegistryRow);
    if (repoID !== null && registry.length > 0) {
      const on = pending !== undefined && Object.hasOwn(pending, repoID) ? pending[repoID] === true : group.remoteFilterOn === true;
      const hidden = new Set(registry.filter((row) => row.id !== lastRowID));
      filter = { on, count: hidden.size, providers: providersOf(registry) };
      if (on) visible = listed.filter((row) => !hidden.has(row));
    }
    const rows: RowView[] = visible.map((row) => ({ row, best: bestSession(row), count: row.sessions.length }));
    // Array sort is stable, so equal times keep the layout's order.
    rows.sort((a, b) => b.row.statusChangedAt - a.row.statusChangedAt);
    const view: GroupView = { group, repoID, rows, newestAt: rows[0]?.row.statusChangedAt ?? 0, filter };
    if (rows.length > 0) shown.push(view);
    else if (group.kind === 'repo') emptyRepos.push(view);
  }
  shown.sort((a, b) => b.newestAt - a.newestAt);
  return [...shown, ...emptyRepos];
}
