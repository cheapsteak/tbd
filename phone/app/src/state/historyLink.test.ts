// Tests historyLink.ts: each history request carries the route's string and the move count of
// the last route message the loader sent, so the loader can drop a request the browser's own
// move has overtaken.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { HistoryRequest } from '../host.ts';
import type { PhoneSessionRef } from '../protocol/types.ts';
import { HistoryLink } from './historyLink.ts';
import { encodeRoute } from './routeState.ts';
import { SESSIONS_ROUTE } from './store.ts';

const R: PhoneSessionRef = { kind: 'local', terminalID: 'T-R' };

function linked() {
  const posted: HistoryRequest[] = [];
  return { posted, link: new HistoryLink((request) => { posted.push(request); }) };
}

test('before any route message, each request carries move 0', () => {
  const { posted, link } = linked();
  link.push({ screen: 'session', ref: R });
  link.replace(SESSIONS_ROUTE);
  link.back();
  assert.deepEqual(posted, [
    { op: 'push', state: encodeRoute({ screen: 'session', ref: R }), move: 0 },
    { op: 'replace', state: null, move: 0 },
    { op: 'back', move: 0 },
  ]);
});

test('each request carries the move of the last route message seen', () => {
  const { posted, link } = linked();
  link.seen(3);
  link.push(SESSIONS_ROUTE);
  link.seen(5);
  link.replace({ screen: 'session', ref: R });
  link.back();
  link.seen(2);
  link.back();
  assert.deepEqual(posted, [
    { op: 'push', state: null, move: 3 },
    { op: 'replace', state: encodeRoute({ screen: 'session', ref: R }), move: 5 },
    { op: 'back', move: 5 },
    { op: 'back', move: 2 },
  ]);
});

test('a session route too long for an entry is sent as the list', () => {
  const { posted, link } = linked();
  link.push({ screen: 'session', ref: { kind: 'remote', provider: 'acme-cloud', sessionID: 's'.repeat(1_024) } });
  assert.deepEqual(posted, [{ op: 'push', state: null, move: 0 }]);
});
