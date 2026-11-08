// Tests store.ts: the initial state, and a store that notifies only when the state changed.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { emptyPrompts } from './prompts.ts';
import { emptySheets } from './sheets.ts';
import { createStore, initialState, nextToast, SESSIONS_ROUTE } from './store.ts';
import { emptyTranscript } from './transcript.ts';

test('the initial state', () => {
  const s = initialState();
  assert.deepEqual(s.conn, { up: false, subscribed: false, error: null });
  assert.equal(s.env, null);
  assert.equal(s.ui.route, SESSIONS_ROUTE);
  assert.deepEqual(s.ui.route, { screen: 'sessions' });
  assert.equal(s.ui.sheet, null);
  assert.equal(s.ui.menu, null);
  assert.equal(s.ui.showDetails, false);
  assert.equal(s.ui.toast, null);
  assert.equal(s.ui.pendingOpen, null);
  assert.equal(s.ui.nav, 0);
  assert.equal(s.ui.lastRowID, null);
  assert.deepEqual(s.sessions.layout, []);
  for (const record of [s.sessions.rows, s.ui.collapsed, s.ui.refusal, s.ui.drafts]) {
    assert.deepEqual(Object.keys(record), []);
    assert.equal(Object.getPrototypeOf(record), null);
  }
  // The slices parts 6c and 6d fill start as their own modules say.
  assert.deepEqual(s.transcript, emptyTranscript());
  assert.deepEqual(s.prompts, emptyPrompts());
  assert.deepEqual(s.sheets, emptySheets());
  // Each call makes its own state.
  assert.notEqual(initialState().ui, initialState().ui);
});

test('update notifies only when the state is a new object', () => {
  const store = createStore();
  let calls = 0;
  store.subscribe(() => { calls++; });
  store.update((s) => s);
  assert.equal(calls, 0);
  const before = store.get();
  store.update((s) => ({ ...s, env: null }));
  assert.equal(calls, 1);
  assert.notEqual(store.get(), before);
});

test('every listener hears each change, until it unsubscribes', () => {
  const store = createStore();
  const heard: string[] = [];
  const offA = store.subscribe(() => { heard.push('a'); });
  store.subscribe(() => { heard.push('b'); });
  store.update((s) => ({ ...s }));
  offA();
  store.update((s) => ({ ...s }));
  assert.deepEqual(heard, ['a', 'b', 'b']);
});

test('a listener reads the new state', () => {
  const store = createStore();
  let seen: unknown = null;
  store.subscribe(() => { seen = store.get().conn.up; });
  store.update((s) => ({ ...s, conn: { ...s.conn, up: true } }));
  assert.equal(seen, true);
});

test('createStore starts from the state it is given', () => {
  const s = initialState();
  assert.equal(createStore(s).get(), s);
});

test('each toast has an ID one past the one showing', () => {
  const ui = initialState().ui;
  assert.deepEqual(nextToast(ui, 'a'), { id: 1, text: 'a' });
  assert.deepEqual(nextToast({ ...ui, toast: { id: 4, text: 'a' } }, 'a'), { id: 5, text: 'a' });
});
