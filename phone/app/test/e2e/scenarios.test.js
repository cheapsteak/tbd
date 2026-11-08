// The shared mock scenario (scenarios/mock.json), checked in Node. It is the mocks' sample data
// in wire form, written by hand, and every part's end-to-end tests read it, so a slip in it
// fails here in seconds rather than as a puzzling screen in Playwright:
// - every detail the transcripts point to comes back from `transcript.detail` and decodes with
//   the app's own decoders (fake-laptop-app.test.js already decodes the replies to subscribe,
//   `transcript.open`, `profiles.list` and `remote.providers` for every scenario);
// - every ID it holds names something that is there: layout rows, profiles, open prompts,
//   transcripts and details.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import { decodeEnvelope, decodeResult } from '../../src/protocol/wire.ts';
import { createFakeLaptop, refKey } from './fake-laptop-app.js';

const MOCK = JSON.parse(readFileSync(new URL('scenarios/mock.json', import.meta.url), 'utf8'));

/** Every session of the scenario, with its row. */
function sessionsOf(scenario) {
  return scenario.rows.flatMap((/** @type {any} */ row) => row.sessions.map((/** @type {any} */ session) => ({ row, session })));
}

test('mock.json: every detail comes back from transcript.detail and decodes', () => {
  /** @type {any[]} */
  const sent = [];
  const laptop = createFakeLaptop({ scenario: MOCK, emit: (body) => sent.push(body), defer: (fn) => fn() });
  laptop.connect();
  let n = 0;
  const ask = (/** @type {string} */ method, /** @type {object} */ params) => {
    const requestID = `req-${++n}`;
    laptop.handle({ kind: 'request', requestID, method, params });
    const reply = sent.find((body) => body.kind === 'reply' && body.requestID === requestID);
    assert.ok(reply, `a reply to ${method}`);
    assert.equal(reply.error, undefined, `${method} ${JSON.stringify(params)} was refused: ${JSON.stringify(reply.error)}`);
    const wire = JSON.parse(JSON.stringify(reply));
    decodeEnvelope(wire);
    assert.deepEqual(decodeResult(/** @type {any} */ (method), wire.result), wire.result, `the ${method} result keeps every field`);
    return wire.result;
  };
  ask('sessions.subscribe', {});

  let checked = 0;
  for (const { session } of sessionsOf(MOCK)) {
    const key = refKey(session.ref);
    const items = MOCK.transcripts[key] ?? [];
    if (!session.capabilities.transcript.available) continue;
    ask('transcript.open', { session: session.ref, showDetails: true, resume: false });
    const nested = items.flatMap((/** @type {any} */ item) => MOCK.details[item.id]?.subagent ?? []);
    for (const item of [...items, ...nested]) {
      for (const part of Object.keys(MOCK.details[item.id] ?? {})) {
        const result = ask('transcript.detail', { session: session.ref, itemID: item.id, part, chunk: 0 });
        assert.equal(result.tooLarge, false);
        if (part === 'subagent') assert.deepEqual(result.items, MOCK.details[item.id].subagent);
        else assert.equal(result.text, MOCK.details[item.id][part]);
        checked += 1;
      }
    }
  }
  assert.equal(checked, Object.values(MOCK.details).reduce((sum, parts) => sum + Object.keys(parts).length, 0), 'every detail was asked for');
});

test('mock.json: every ID names something the scenario holds', () => {
  const rowIDs = MOCK.rows.map((/** @type {any} */ row) => row.id);
  const placed = MOCK.layout.flatMap((/** @type {any} */ group) => group.rows.map((/** @type {any} */ p) => p.id));
  assert.deepEqual([...placed].sort(), [...rowIDs].sort(), 'each row is placed exactly once');
  assert.equal(new Set(rowIDs).size, rowIDs.length, 'row IDs are unique');

  const profiles = new Map(MOCK.profiles.map((/** @type {any} */ p) => [p.id, p]));
  const keys = new Set();
  for (const { row, session } of sessionsOf(MOCK)) {
    const key = refKey(session.ref);
    assert.ok(!keys.has(key), `${key} is one session`);
    keys.add(key);
    if (row.kind === 'remoteSession') assert.equal(row.id, key, 'a remote row is named by its session');
    if (session.profileID !== undefined) assert.equal(profiles.get(session.profileID)?.name, session.profileName, `${key}'s profile`);
    const open = MOCK.prompts[key] ?? [];
    assert.equal(session.openPromptID, open[0]?.id, `${key}'s open prompt`);
    assert.equal(MOCK.transcripts[key] === undefined, !session.capabilities.transcript.available, `${key} has a transcript when it offers one`);
  }
  for (const key of [...Object.keys(MOCK.transcripts), ...Object.keys(MOCK.prompts)]) assert.ok(keys.has(key), `${key} names a session`);

  const itemIDs = new Set();
  const collect = (/** @type {any[]} */ items) => {
    for (const item of items) {
      assert.ok(!itemIDs.has(item.id), `${item.id} is one item`);
      itemIDs.add(item.id);
      if (MOCK.details[item.id]?.subagent) collect(MOCK.details[item.id].subagent);
    }
  };
  for (const items of Object.values(MOCK.transcripts)) collect(/** @type {any[]} */ (items));
  for (const id of Object.keys(MOCK.details)) assert.ok(itemIDs.has(id), `the detail ${id} names an item`);
});
