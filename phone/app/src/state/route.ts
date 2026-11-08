/**
 * Which session the app shows, kept to the sessions the list shows. The phone acts only on a
 * session its list shows; anything else the laptop refuses as `not_found`. So the session
 * screen closes when its session leaves every row of a complete list, and a session the laptop
 * made for this phone opens only once a row lists it.
 *
 * A row lists a session only where the layout places the row. The laptop can send a row that
 * the layout does not place: when a layout is too large for a frame, it drops groups from the
 * end but still sends their rows (`PhoneSnapshotBuilder.build`). Such a row shows nowhere in
 * the list, so nothing here finds a session in it.
 */

import { sameRef } from '../protocol/wire.ts';
import type { PhoneRow, PhoneSession, PhoneSessionRef } from '../protocol/types.ts';
import { isComplete, rowByID } from './sessionsData.ts';
import { SESSIONS_ROUTE } from './store.ts';
import type { PendingOpen, Route, SessionsData } from './store.ts';

/** The row that lists `ref`, and its session, or null when no row the layout places does. */
export function findSession(d: SessionsData, ref: PhoneSessionRef): { row: PhoneRow; session: PhoneSession } | null {
  for (const group of d.layout) {
    for (const placement of group.rows) {
      const row = rowByID(d, placement.id);
      if (row === null) continue;
      for (const session of row.sessions) {
        if (sameRef(session.ref, ref)) return { row, session };
      }
    }
  }
  return null;
}

/** The row with ID `id` when the layout places it and it has arrived, or null. */
function placedRow(d: SessionsData, id: string): PhoneRow | null {
  const placed = d.layout.some((group) => group.rows.some((placement) => placement.id === id));
  return placed ? rowByID(d, id) : null;
}

/**
 * `route`, or the sessions route when it shows a session that no row lists and the list is
 * complete (`isComplete`). While a row the layout places has not arrived, as after a snapshot
 * with `more` set, a session route stands, since that row may hold its session. A route that
 * stands is returned itself, so a `!==` check tells a change.
 */
export function resolveRoute(route: Route, d: SessionsData): Route {
  if (route.screen === 'sessions') return route;
  return findSession(d, route.ref) === null && isComplete(d) ? SESSIONS_ROUTE : route;
}

/** Whether `a` and `b` show the same screen: both the list, or both the same session. */
export function sameRoute(a: Route, b: Route): boolean {
  if (a.screen === 'sessions') return b.screen === 'sessions';
  return b.screen === 'session' && sameRef(a.ref, b.ref);
}

/**
 * The session route `p` opens, once the list shows its session; null while it does not.
 * A `{ worktreeID }` open waits for the layout to place that worktree's row and for the row to
 * list a session, and opens the first one: the row can arrive before its first session does.
 */
export function resolvePendingOpen(p: PendingOpen, d: SessionsData): Route | null {
  return pendingOpenTarget(p, d)?.route ?? null;
}

/**
 * `resolvePendingOpen`'s route, with the row that lists its session, so a caller that needs the
 * row does not look the session up again.
 */
export function pendingOpenTarget(p: PendingOpen, d: SessionsData): { route: Route; row: PhoneRow } | null {
  if ('ref' in p) {
    const found = findSession(d, p.ref);
    return found === null ? null : { route: { screen: 'session', ref: p.ref }, row: found.row };
  }
  const row = placedRow(d, p.worktreeID);
  const first = row?.sessions[0];
  return row === null || first === undefined ? null : { route: { screen: 'session', ref: first.ref }, row };
}
