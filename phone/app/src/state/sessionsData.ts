/**
 * The sessions list: a `sessions.subscribe` snapshot, and each `sessions.changed` merged into
 * it. The rows' and groups' IDs are the daemon's (`PhoneSnapshotBuilder`):
 * - a worktree row's ID is its worktree's UUID, and a remote session's row is
 *   `remote:<provider>/<sessionID>`;
 * - a repo group is `repo:<UUID>`, and is kept when it has no rows;
 * - a provider group is `provider:<name>`, and the scratch group is `scratch`.
 */

import type { PhoneRow, SessionsChangedData, SessionsSubscribeResult } from '../protocol/types.ts';
import { emptyRecord } from './store.ts';
import type { SessionsData } from './store.ts';

/**
 * The list a snapshot gives: its layout and rows, as they came. The layout replaces the old
 * one, and the rows replace all the old rows. A snapshot with `more` set holds only some rows;
 * the rest follow as `sessions.changed` events, and the layout names them already.
 */
export function applySnapshot(r: SessionsSubscribeResult): SessionsData {
  const rows = emptyRecord<PhoneRow>();
  for (const row of r.rows ?? []) rows[row.id] = row;
  return { layout: r.layout ?? [], rows };
}

/**
 * `d` with one `sessions.changed` merged in: each row in `c.rows` replaces the row with its ID
 * or is added, each ID in `c.removedRowIDs` is removed, and `c.layout`, when present, replaces
 * the layout. Without one, the layout is `d.layout` itself. The daemon never lists a row in
 * both; if it did, the row would stay.
 */
export function applySessionsChanged(d: SessionsData, c: SessionsChangedData): SessionsData {
  const rows = emptyRecord<PhoneRow>();
  for (const id of Object.keys(d.rows)) rows[id] = d.rows[id]!;
  for (const id of c.removedRowIDs) delete rows[id];
  for (const row of c.rows) rows[row.id] = row;
  return { layout: c.layout ?? d.layout, rows };
}

/** The row with ID `id`, or null. Only the list's own rows count, never an inherited member. */
export function rowByID(d: SessionsData, id: string): PhoneRow | null {
  return Object.hasOwn(d.rows, id) ? d.rows[id]! : null;
}
