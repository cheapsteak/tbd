/**
 * The string the app keeps in a history entry for its route. The loader stores it in the entry
 * unread and hands it back in a `route` message (`phone/loader/history.js`), so how it encodes a
 * route is the app's own business. Coming back, it is untrusted: an entry may hold a string an
 * older or newer app wrote, or one the loader could not check against this app.
 */

import { MAX_ROUTE_STATE_LENGTH } from '../limits.ts';
import { obj, oneOf } from '../protocol/decode.ts';
import { decodePhoneSessionRef } from '../protocol/wire.ts';
import type { PhoneSessionRef } from '../protocol/types.ts';
import type { Route } from './store.ts';

type SessionRoute = Extract<Route, { screen: 'session' }>;

const decodeSessionRoute = obj<SessionRoute>({ screen: oneOf(['session']), ref: decodePhoneSessionRef }, {});

/**
 * `route` as an entry's string: null for the sessions list, and JSON of the session route for a
 * session. A session whose string would pass `MAX_ROUTE_STATE_LENGTH` is null too, so its entry
 * shows the list: the loader would refuse the longer string.
 */
export function encodeRoute(route: Route): string | null {
  if (route.screen === 'sessions') return null;
  const state = JSON.stringify({ screen: 'session', ref: refFields(route.ref) });
  return state.length <= MAX_ROUTE_STATE_LENGTH ? state : null;
}

/**
 * The session route an entry's string names, rebuilt from its known fields, or null for
 * anything else. It never throws: a string that is not JSON, or JSON of anything but a session
 * route, is null.
 */
export function decodeRoute(state: string): Route | null {
  try {
    return decodeSessionRoute(JSON.parse(state));
  } catch {
    return null;
  }
}

/** `ref` with only the fields its kind names, so nothing else a ref object holds is written. */
function refFields(ref: PhoneSessionRef): PhoneSessionRef {
  return ref.kind === 'local'
    ? { kind: 'local', terminalID: ref.terminalID }
    : { kind: 'remote', provider: ref.provider, sessionID: ref.sessionID };
}
