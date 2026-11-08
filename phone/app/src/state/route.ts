/**
 * Which session the app shows, kept to the sessions the list shows. The phone acts only on a
 * session its list shows; anything else the laptop refuses as `not_found`. So the session
 * screen closes when its session leaves every row, and a session the laptop made for this
 * phone opens only once a row lists it.
 */

import { sameRef } from '../protocol/wire.ts';
import type { PhoneRow, PhoneSession, PhoneSessionRef } from '../protocol/types.ts';
import { rowByID } from './sessionsData.ts';
import { SESSIONS_ROUTE } from './store.ts';
import type { PendingOpen, Route, SessionsData } from './store.ts';

/** The row that lists `ref`, and its session, or null when no row does. */
export function findSession(d: SessionsData, ref: PhoneSessionRef): { row: PhoneRow; session: PhoneSession } | null {
  for (const row of Object.values(d.rows)) {
    for (const session of row.sessions) {
      if (sameRef(session.ref, ref)) return { row, session };
    }
  }
  return null;
}

/**
 * `route`, or the sessions route when it shows a session that no row lists. A route that
 * stands is returned itself, so a `!==` check tells a change.
 */
export function resolveRoute(route: Route, d: SessionsData): Route {
  if (route.screen === 'sessions') return route;
  return findSession(d, route.ref) === null ? SESSIONS_ROUTE : route;
}

/** Whether `a` and `b` show the same screen: both the list, or both the same session. */
export function sameRoute(a: Route, b: Route): boolean {
  if (a.screen === 'sessions') return b.screen === 'sessions';
  return b.screen === 'session' && sameRef(a.ref, b.ref);
}

/**
 * The session route `p` opens, once the list shows its session; null while it does not.
 * A `{ worktreeID }` open waits for that worktree's row to list a session, and opens the first
 * one: the row can arrive before its first session does.
 */
export function resolvePendingOpen(p: PendingOpen, d: SessionsData): Route | null {
  if ('ref' in p) return findSession(d, p.ref) === null ? null : { screen: 'session', ref: p.ref };
  const first = rowByID(d, p.worktreeID)?.sessions[0];
  return first === undefined ? null : { screen: 'session', ref: first.ref };
}
