// Tests routeState.ts: the string the app keeps in a history entry for each route, and reading
// one back from the loader, which hands it on unread, so it is untrusted.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { MAX_ROUTE_STATE_LENGTH } from '../limits.ts';
import type { PhoneSessionRef } from '../protocol/types.ts';
import { decodeRoute, encodeRoute } from './routeState.ts';
import { SESSIONS_ROUTE } from './store.ts';
import type { Route } from './store.ts';

const LOCAL: PhoneSessionRef = { kind: 'local', terminalID: 'T-R' };
const REMOTE: PhoneSessionRef = { kind: 'remote', provider: 'acme-cloud', sessionID: 'rs-1' };

function shows(ref: PhoneSessionRef): Route {
  return { screen: 'session', ref };
}

test('the list is null', () => {
  assert.equal(encodeRoute(SESSIONS_ROUTE), null);
  assert.equal(encodeRoute({ screen: 'sessions' }), null);
});

test('a session route comes back as the route it was', () => {
  for (const ref of [LOCAL, REMOTE, { kind: 'remote', provider: 'a/b%c', sessionID: '' } as const,
    { kind: 'local', terminalID: '\u{1F600} "quoted" \\ \ud800' } as const]) {
    const state = encodeRoute(shows(ref));
    assert.equal(typeof state, 'string');
    assert.deepEqual(decodeRoute(state as string), shows(ref), JSON.stringify(ref));
  }
});

test('the string holds only the route: fields a ref carries beyond its kind are not written', () => {
  const ref = { kind: 'local', terminalID: 'T-R', extra: 'x'.repeat(2_000) } as PhoneSessionRef;
  const state = encodeRoute(shows(ref));
  assert.ok(state !== null && !state.includes('extra'));
  assert.deepEqual(decodeRoute(state), shows(LOCAL));
});

test('a session route whose string would pass the cap is null, so its entry shows the list', () => {
  const fits = (n: number) => encodeRoute(shows({ kind: 'remote', provider: 'acme-cloud', sessionID: 's'.repeat(n) }));
  const overhead = (fits(0) as string).length;
  const longest = fits(MAX_ROUTE_STATE_LENGTH - overhead);
  assert.equal(longest?.length, MAX_ROUTE_STATE_LENGTH);
  assert.equal(fits(MAX_ROUTE_STATE_LENGTH - overhead + 1), null);
  // Escapes count: a quote takes two code units in the string.
  assert.equal(encodeRoute(shows({ kind: 'local', terminalID: '"'.repeat(MAX_ROUTE_STATE_LENGTH / 2) })), null);
});

test('a string that is not a session route decodes to null, and never throws', () => {
  for (const state of [
    '', '{', 'null', '[]', '1', '"session"', 'true', '{}',
    '{"screen":"sessions"}',
    '{"screen":"session"}',
    '{"screen":"session","ref":null}',
    '{"screen":"session","ref":{"kind":"local"}}',
    '{"screen":"session","ref":{"kind":"local","terminalID":3}}',
    '{"screen":"session","ref":{"kind":"remote","provider":"acme-cloud"}}',
    '{"screen":"session","ref":{"kind":"cloud","terminalID":"T"}}',
    '{"screen":"session","ref":["local","T"]}',
    '{"screen":["session"],"ref":{"kind":"local","terminalID":"T"}}',
    '{"__proto__":{"screen":"session","ref":{"kind":"local","terminalID":"T"}}}',
    '{"screen":"session","ref":{"__proto__":{"kind":"local","terminalID":"T"}}}',
    '{"screen":"session","ref":{"kind":"local","__proto__":{"terminalID":"T"}}}',
  ]) {
    assert.equal(decodeRoute(state), null, state);
  }
});

test('a decoded route is rebuilt from its known fields', () => {
  const route = decodeRoute('{"screen":"session","ref":{"kind":"remote","provider":"acme-cloud","sessionID":"rs-1","x":1},"y":2}');
  assert.deepEqual(route, shows(REMOTE));
  assert.equal(Object.getPrototypeOf(route), Object.prototype);
});
