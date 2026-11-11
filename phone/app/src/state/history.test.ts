// Tests history.ts: the state each of the app's entries holds, reading it back from untrusted
// state, adding and rewriting entries, going back only from an entry the app added, and the
// browser's History API calls, none of which passes a URL. A fake port records each call; the
// actions' use of the history is in `actions/shell.test.ts`.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { PhoneSessionRef } from '../protocol/types.ts';
import { readEntry, RouteHistory, windowHistory } from './history.ts';
import type { HistoryPort } from './history.ts';
import { SESSIONS_ROUTE } from './store.ts';
import type { Route } from './store.ts';

const R: PhoneSessionRef = { kind: 'local', terminalID: 'T-R' };
const REMOTE: PhoneSessionRef = { kind: 'remote', provider: 'acme-cloud', sessionID: 'rs-1' };

function shows(ref: PhoneSessionRef): Route {
  return { screen: 'session', ref };
}

/** A port whose current entry holds `state`, recording each call; `pop` fires a `popstate`. */
function fakePort(state: unknown = null) {
  const calls: unknown[][] = [];
  const listeners = new Set<(state: unknown) => void>();
  const port: HistoryPort = {
    get state() {
      return state;
    },
    pushState(data) {
      calls.push(['push', data]);
      state = structuredClone(data);
    },
    replaceState(data) {
      calls.push(['replace', data]);
      state = structuredClone(data);
    },
    back() {
      calls.push(['back']);
    },
    onPopState(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  };
  return {
    port,
    calls,
    pop(next: unknown): void {
      state = next;
      for (const listener of [...listeners]) listener(next);
    },
  };
}

test("starting takes the current entry as the app's first, showing the route", () => {
  const fake = fakePort({ tbd: { route: shows(R), index: 4 } });
  new RouteHistory(fake.port, SESSIONS_ROUTE);
  assert.deepEqual(fake.calls, [['replace', { tbd: { route: SESSIONS_ROUTE, index: 0 } }]]);
});

test('push counts up from the current entry, and replace keeps its index', () => {
  const fake = fakePort();
  const routes = new RouteHistory(fake.port, SESSIONS_ROUTE);
  routes.push(shows(R));
  routes.push(shows(REMOTE));
  routes.replace(SESSIONS_ROUTE);
  assert.deepEqual(fake.calls.slice(1), [
    ['push', { tbd: { route: shows(R), index: 1 } }],
    ['push', { tbd: { route: shows(REMOTE), index: 2 } }],
    ['replace', { tbd: { route: SESSIONS_ROUTE, index: 2 } }],
  ]);
});

test('the index follows the entry the browser shows', () => {
  const fake = fakePort();
  const routes = new RouteHistory(fake.port, SESSIONS_ROUTE);
  routes.push(shows(R));
  // The browser went back to the first entry: the next push replaces the one forward of it.
  fake.pop({ tbd: { route: SESSIONS_ROUTE, index: 0 } });
  routes.push(shows(REMOTE));
  assert.deepEqual(fake.calls.at(-1), ['push', { tbd: { route: shows(REMOTE), index: 1 } }]);
});

test("an entry that is not the app's counts as a first entry", () => {
  const fake = fakePort();
  const routes = new RouteHistory(fake.port, SESSIONS_ROUTE);
  fake.pop(null);
  routes.push(shows(R));
  assert.deepEqual(fake.calls.at(-1), ['push', { tbd: { route: shows(R), index: 0 } }]);
  fake.pop({ other: true });
  routes.replace(SESSIONS_ROUTE);
  assert.deepEqual(fake.calls.at(-1), ['replace', { tbd: { route: SESSIONS_ROUTE, index: 0 } }]);
});

test('stepBack goes back only from an entry the app added', () => {
  const fake = fakePort();
  const routes = new RouteHistory(fake.port, SESSIONS_ROUTE);
  assert.equal(routes.stepBack(), false);
  routes.push(shows(R));
  assert.equal(routes.stepBack(), true);
  assert.deepEqual(fake.calls.at(-1), ['back']);
  // Not from the first entry, nor from one that is not the app's.
  for (const state of [{ tbd: { route: shows(R), index: 0 } }, null, { tbd: { route: shows(R), index: '1' } }]) {
    fake.pop(state);
    const made = fake.calls.length;
    assert.equal(routes.stepBack(), false, JSON.stringify(state));
    assert.equal(fake.calls.length, made);
  }
});

test("onPop reports the route of each of the app's entries the browser moves to", () => {
  const fake = fakePort();
  const routes = new RouteHistory(fake.port, SESSIONS_ROUTE);
  const seen: Route[] = [];
  const stop = routes.onPop((route) => seen.push(route));
  fake.pop({ tbd: { route: shows(R), index: 1 } });
  fake.pop({ tbd: { route: shows(REMOTE), index: 2 } });
  fake.pop({ tbd: { route: { screen: 'sessions' }, index: 0 } });
  assert.deepEqual(seen, [shows(R), shows(REMOTE), SESSIONS_ROUTE]);
  assert.equal(seen[2], SESSIONS_ROUTE);
  stop();
  fake.pop({ tbd: { route: shows(R), index: 1 } });
  assert.equal(seen.length, 3);
});

test("onPop ignores a popstate whose state is not the app's entry", () => {
  const fake = fakePort();
  const routes = new RouteHistory(fake.port, SESSIONS_ROUTE);
  const seen: Route[] = [];
  routes.onPop((route) => seen.push(route));
  for (const state of [null, undefined, 0, 'tbd', [], {}, { tbd: null }, { tbd: 'x' }, { route: SESSIONS_ROUTE, index: 0 }]) {
    fake.pop(state);
  }
  assert.deepEqual(seen, []);
});

test('readEntry refuses an entry whose route or index is not one the app writes', () => {
  const route = shows(R);
  const refused: unknown[] = [
    { tbd: { route } },
    { tbd: { index: 1 } },
    { tbd: { route, index: -1 } },
    { tbd: { route, index: 1.5 } },
    { tbd: { route, index: Number.MAX_SAFE_INTEGER + 1 } },
    { tbd: { route, index: '1' } },
    { tbd: { route: { screen: 'settings' }, index: 1 } },
    { tbd: { route: { screen: 'session' }, index: 1 } },
    { tbd: { route: { screen: 'session', ref: { kind: 'local' } }, index: 1 } },
    { tbd: { route: { screen: 'session', ref: { kind: 'remote', provider: 'acme-cloud' } }, index: 1 } },
    { tbd: { route: { screen: 'session', ref: { kind: 'ssh', terminalID: 'T-R' } }, index: 1 } },
    // Inherited fields are never read.
    Object.create({ tbd: { route, index: 1 } }),
    { tbd: Object.create({ route, index: 1 }) },
  ];
  for (const state of refused) assert.equal(readEntry(state), null, JSON.stringify(state));
  assert.deepEqual(readEntry({ tbd: { route, index: 3 }, other: 1 }), { route, index: 3 });
});

test('readEntry keeps only the fields of a ref it knows', () => {
  const read = readEntry({ tbd: { route: { screen: 'session', ref: { ...R, extra: 'x' }, also: 1 }, index: 1 } });
  assert.deepEqual(read, { route: shows(R), index: 1 });
});

test("windowHistory calls the window's History API with no URL, and listens for popstate", () => {
  const calls: unknown[][] = [];
  const listeners: Array<[string, unknown]> = [];
  const fakeWindow = {
    history: {
      state: { tbd: { route: SESSIONS_ROUTE, index: 0 } },
      pushState: (...args: unknown[]) => calls.push(['pushState', ...args]),
      replaceState: (...args: unknown[]) => calls.push(['replaceState', ...args]),
      back: (...args: unknown[]) => calls.push(['back', ...args]),
    },
    addEventListener: (type: string, listener: unknown) => listeners.push([type, listener]),
    removeEventListener: (type: string, listener: unknown) => calls.push(['removeEventListener', type, listener]),
  };
  const port = windowHistory(fakeWindow as unknown as Window);
  assert.deepEqual(port.state, { tbd: { route: SESSIONS_ROUTE, index: 0 } });
  port.pushState({ a: 1 });
  port.replaceState({ b: 2 });
  port.back();
  // Each call passes the data and an empty title, and never a third argument, the URL.
  assert.deepEqual(calls, [['pushState', { a: 1 }, ''], ['replaceState', { b: 2 }, ''], ['back']]);

  const seen: unknown[] = [];
  const stop = port.onPopState((state) => seen.push(state));
  assert.equal(listeners.length, 1);
  const [type, handle] = listeners[0]!;
  assert.equal(type, 'popstate');
  (handle as (event: { state: unknown }) => void)({ state: { tbd: 1 } });
  assert.deepEqual(seen, [{ tbd: 1 }]);
  stop();
  assert.deepEqual(calls.at(-1), ['removeEventListener', 'popstate', handle]);
});
