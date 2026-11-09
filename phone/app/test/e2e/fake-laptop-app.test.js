// The fake laptop the end-to-end tests run against (fake-laptop-app.js), checked in Node: its
// times, its transcript pages, its replay, its holds and its size check. Every body it sends
// must decode with the app's own decoders and keep every field it carries, so a fake reply the
// real app would refuse fails here in seconds rather than as an app error in Playwright.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { MAX_PLAINTEXT_LENGTH as LOADER_MAX_PLAINTEXT } from '../../../loader/channel/noise.js';
import { decodeEnvelope, decodeEventData, decodeResult, refKey as appRefKey } from '../../src/protocol/wire.ts';
import {
  AGO_SLACK_MS, MAX_PLAINTEXT_LENGTH, STREAM, TEXT, createFakeLaptop, frameBytes, refKey,
} from './fake-laptop-app.js';

const NOW = 1_762_500_000_000;
const SCENARIOS_DIR = fileURLToPath(new URL('scenarios/', import.meta.url));

const CAPS = {
  transcript: { available: true }, send: { available: true }, answer: { available: true },
  switchProfile: { available: true }, fork: { available: true }, model: { available: true },
};
const REF = { kind: 'local', terminalID: 'AAAAAAAA-0000-4000-8000-000000000001' };
const REPO_ID = 'AAAAAAAA-0000-4000-8000-0000000000A1';
const PROFILES = [
  { id: 'AAAAAAAA-0000-4000-8000-0000000000F1', name: 'Personal', kind: 'oauth', isDefault: true },
  { id: 'AAAAAAAA-0000-4000-8000-0000000000F2', name: 'acme-work', kind: 'oauth', isDefault: false },
];

/**
 * A scenario with one repo, one row and one session, whose transcript is `items`.
 * @param {any[]} [items]
 * @param {object} [more] more scenario keys
 */
function scenarioWith(items = [], more = {}) {
  return {
    layout: [{ id: `repo:${REPO_ID}`, kind: 'repo', name: 'acme-web', rows: [{ id: 'row-1', depth: 0 }] }],
    rows: [{
      id: 'row-1', kind: 'worktree', name: 'main', remote: false,
      sessions: [{
        ref: REF, agent: 'claude', tabName: 'Claude', status: { chip: 'idle', agoMinutes: 4 },
        profileID: PROFILES[0].id, profileName: 'Personal', model: 'opus', capabilities: CAPS,
      }],
    }],
    transcripts: { [refKey(REF)]: items },
    profiles: PROFILES,
    ...more,
  };
}

/** `kinds` as items, `i<n>` by index; a user or assistant item says its index. */
function itemsOf(kinds) {
  return kinds.map((kind, i) => {
    if (kind === 'tool') return { id: `i${i}`, kind, toolName: 'Bash', target: `step ${i}`, toolStatus: 'ok', truncated: false };
    return { id: `i${i}`, kind, text: `item ${i}`, truncated: false };
  });
}

/**
 * A fake laptop on a fixed clock that records what it sends and runs deferred work only on
 * `flush()`.
 * @param {object} [scenario]
 */
function makeLaptop(scenario = scenarioWith()) {
  /** @type {any[]} */
  const sent = [];
  /** @type {Array<() => void>} */
  const deferred = [];
  const laptop = createFakeLaptop({ scenario, emit: (body) => sent.push(body), now: () => NOW, defer: (fn) => deferred.push(fn) });
  let n = 0;
  /** @type {Map<string, string>} */
  const methods = new Map();
  return {
    laptop,
    sent,
    methods,
    /** Sends one request and returns its ID. */
    ask(method, params = {}, requestID = `req-${++n}`) {
      methods.set(requestID, method);
      laptop.handle({ kind: 'request', requestID, method, params });
      return requestID;
    },
    /** The reply to `requestID`, or undefined. */
    replyTo(requestID) {
      return sent.find((body) => body.kind === 'reply' && body.requestID === requestID);
    },
    /** Every reply to `requestID`, in order. */
    repliesTo(requestID) {
      return sent.filter((body) => body.kind === 'reply' && body.requestID === requestID);
    },
    events() {
      return sent.filter((body) => body.kind === 'event');
    },
    flush() {
      for (const fn of deferred.splice(0)) fn();
    },
    /** Connects and subscribes afresh. */
    subscribe(params = {}) {
      laptop.connect();
      return this.ask('sessions.subscribe', params);
    },
  };
}

/** Decodes every body as the app would, and checks the decoders kept every field. */
function assertDecodes(sent, methods) {
  for (const body of sent) {
    const wire = JSON.parse(JSON.stringify(body));
    const envelope = decodeEnvelope(wire);
    if (envelope.kind === 'event') {
      assert.deepEqual(decodeEventData(envelope.event, wire.data), wire.data, `${envelope.event} keeps every field`);
    } else if (envelope.result !== undefined) {
      const method = methods.get(envelope.requestID);
      assert.ok(method, `a reply to ${envelope.requestID}, which was asked`);
      assert.deepEqual(decodeResult(method, wire.result), wire.result, `the ${method} result keeps every field`);
    }
    assert.ok(frameBytes(body) <= MAX_PLAINTEXT_LENGTH);
  }
}

test('agoMinutes becomes milliseconds before now, with 20 s of slack', () => {
  const items = [{ id: 'i0', kind: 'user', text: 'hello', truncated: false, agoMinutes: 2 }];
  const { laptop } = makeLaptop(scenarioWith(items));
  const session = laptop.state.rows[0].sessions[0];
  assert.deepEqual(session.status, { chip: 'idle', changedAt: NOW - 4 * 60_000 - 20_000 });
  assert.equal(AGO_SLACK_MS, 20_000);
  // A row without statusChangedAt takes its newest session's.
  assert.equal(laptop.state.rows[0].statusChangedAt, NOW - 4 * 60_000 - 20_000);
  assert.deepEqual(laptop.state.transcripts[refKey(REF)][0], { id: 'i0', kind: 'user', text: 'hello', truncated: false, at: NOW - 2 * 60_000 - 20_000 });
});

test('the first page starts at the 4th-last message', () => {
  // Messages at 0, 2, 4, 5, 7 and 9: the 4th from the end is at 4.
  const kinds = ['user', 'tool', 'assistant', 'tool', 'user', 'assistant', 'tool', 'user', 'thinking', 'assistant'];
  const t = makeLaptop(scenarioWith(itemsOf(kinds)));
  t.subscribe();
  const id = t.ask('transcript.open', { session: REF, showDetails: false, resume: false });
  const { page } = t.replyTo(id).result;
  assert.deepEqual(page.items.map((/** @type {any} */ item) => item.id), ['i4', 'i5', 'i6', 'i7', 'i9']);
  assert.equal(page.cursor, '4');
  assert.equal(page.reachedStart, false);

  // Show details keeps the thinking item.
  const shown = t.ask('transcript.open', { session: REF, showDetails: true, resume: false });
  assert.deepEqual(t.replyTo(shown).result.page.items.map((/** @type {any} */ item) => item.id), ['i4', 'i5', 'i6', 'i7', 'i8', 'i9']);

  // Fewer than four messages: the whole transcript, with no cursor.
  const short = makeLaptop(scenarioWith(itemsOf(['user', 'tool', 'assistant'])));
  short.subscribe();
  const all = short.ask('transcript.open', { session: REF, showDetails: false, resume: false });
  assert.deepEqual(short.replyTo(all).result.page, {
    items: itemsOf(['user', 'tool', 'assistant']), reachedStart: true, omittedItems: 0,
  });
});

test('an older page holds the 20 messages before the cursor', () => {
  // 40 messages, with a tool after each assistant: 60 items. The first page takes 4 messages
  // and the next 20, so the one after that reaches the start with 16.
  const kinds = [];
  for (let i = 0; i < 40; i++) kinds.push(i % 2 === 0 ? 'user' : 'assistant', ...(i % 2 === 1 ? ['tool'] : []));
  const items = itemsOf(kinds);
  const t = makeLaptop(scenarioWith(items));
  t.subscribe();
  const open = t.ask('transcript.open', { session: REF, showDetails: false, resume: false });
  const cursor = t.replyTo(open).result.page.cursor;

  const older = t.ask('transcript.page', { session: REF, cursor });
  const page = t.replyTo(older).result;
  const messages = page.items.filter((/** @type {any} */ item) => item.kind !== 'tool');
  assert.equal(messages.length, 20);
  assert.equal(page.items[0].kind === 'tool', false, 'the page starts at a message');
  assert.equal(page.items.at(-1).id, items[Number(cursor) - 1].id, 'the page ends right before the cursor');
  assert.equal(page.cursor, String(items.findIndex((item) => item.id === page.items[0].id)));

  // The next page reaches the start: what is left, with no cursor.
  const last = t.ask('transcript.page', { session: REF, cursor: page.cursor });
  const start = t.replyTo(last).result;
  assert.equal(start.reachedStart, true);
  assert.equal(start.cursor, undefined);
  assert.equal(start.items[0].id, 'i0');
  assert.equal(start.items.filter((/** @type {any} */ item) => item.kind !== 'tool').length, 16);

  // A page needs its transcript open, and a cursor the laptop made.
  const stale = t.ask('transcript.page', { session: REF, cursor: '9999' });
  assert.equal(t.replyTo(stale).error.code, 'stale_cursor');
  t.ask('transcript.close');
  const closed = t.ask('transcript.page', { session: REF, cursor });
  assert.deepEqual(t.replyTo(closed).error, { code: 'not_open', message: TEXT.notOpen });
});

test('a subscribe with a known sinceSeq replays only later events', () => {
  const t = makeLaptop();
  const first = t.subscribe();
  assert.equal(t.replyTo(first).result.replayed, false);
  assert.equal(t.replyTo(first).result.seq, 0);
  const row = t.laptop.state.rows[0];
  t.laptop.emitEvent('sessions.changed', { rows: [row], removedRowIDs: [] });
  t.laptop.emitEvent('sessions.changed', { rows: [row], removedRowIDs: [] });
  assert.deepEqual(t.events().map((body) => body.seq), [1, 2]);

  // Away: the third event is numbered and kept, not sent.
  t.laptop.disconnect();
  t.laptop.emitEvent('sessions.changed', { rows: [row], removedRowIDs: [] });
  assert.deepEqual(t.events().map((body) => body.seq), [1, 2]);

  t.sent.length = 0;
  const again = t.subscribe({ stream: STREAM, sinceSeq: 2 });
  assert.deepEqual(t.sent.map((body) => body.kind === 'reply' ? 'reply' : body.seq), ['reply', 3]);
  assert.deepEqual(t.replyTo(again).result, { stream: STREAM, seq: 3, replayed: true, omittedRows: 0, more: false });

  // A sinceSeq the laptop never reached gets a snapshot, and nothing replays.
  t.sent.length = 0;
  t.laptop.disconnect();
  const unknown = t.subscribe({ stream: STREAM, sinceSeq: 99 });
  assert.equal(t.replyTo(unknown).result.replayed, false);
  assert.deepEqual(t.events(), []);
});

test('a reply that would not fit a frame throws', () => {
  const big = [{ id: 'i0', kind: 'assistant', text: 'x'.repeat(70_000), truncated: false }];
  const t = makeLaptop(scenarioWith(big));
  t.subscribe();
  assert.throws(() => t.ask('transcript.open', { session: REF, showDetails: false, resume: false }), /frame/);
  assert.equal(t.sent.filter((body) => body.kind === 'reply').length, 1, 'only the subscribe reply went out');

  t.laptop.setReply('profiles.list', { result: { profiles: [{ id: 'p', name: 'é'.repeat(40_000), kind: 'oauth', isDefault: true }] } });
  assert.throws(() => t.ask('profiles.list'), /frame/);
  assert.throws(() => t.laptop.emitEvent('transcript.append', { session: REF, items: big }), /frame/);
});

test('its frame budget is the loader\'s, and its ref keys are the app\'s', () => {
  assert.equal(MAX_PLAINTEXT_LENGTH, LOADER_MAX_PLAINTEXT);
  const refs = [REF, { kind: 'remote', provider: 'acme/cloud%1', sessionID: 'rs-1' }];
  for (const ref of refs) assert.equal(refKey(ref), appRefKey(/** @type {any} */ (ref)));
});

test('no event goes out on a connection before its subscribe reply', () => {
  const t = makeLaptop(scenarioWith(itemsOf(['user', 'assistant']), {
    prompts: { [refKey(REF)]: [{ id: 'p1', kind: 'permission', toolName: 'Bash', targetTruncated: false, allowAlways: false }] },
  }));
  t.laptop.connect();
  t.laptop.emitEvent('sessions.changed', { rows: [], removedRowIDs: [] });
  // A fresh open before the subscribe: its reply goes out, its prompts wait.
  const open = t.ask('transcript.open', { session: REF, showDetails: false, resume: false });
  assert.ok(t.replyTo(open));
  assert.deepEqual(t.events(), []);
  const sub = t.ask('sessions.subscribe', {});
  assert.equal(t.replyTo(sub).result.seq, 1, 'the snapshot covers the event made meanwhile');
  assert.deepEqual(t.events().map((body) => [body.event, body.seq]), [['prompt.changed', 2]]);
  assert.equal(t.events()[0].data.prompts[0].id, 'p1');
});

test('a resumed open waits for a replaying subscribe, and keeps the feed', () => {
  const t = makeLaptop(scenarioWith(itemsOf(['user', 'assistant'])));
  t.subscribe();
  t.ask('transcript.open', { session: REF, showDetails: false, resume: false });
  t.laptop.disconnect();
  t.laptop.connect();
  t.sent.length = 0;
  const sub = t.ask('sessions.subscribe', { stream: STREAM, sinceSeq: t.laptop.state.seq });
  const resume = t.ask('transcript.open', { session: REF, showDetails: false, resume: true });
  assert.deepEqual(t.replyTo(resume).result, { resumed: true, seq: t.laptop.state.seq });
  assert.ok(t.sent.indexOf(t.replyTo(sub)) < t.sent.indexOf(t.replyTo(resume)));

  // After a snapshot, a resume opens afresh.
  t.laptop.disconnect();
  const fresh = t.subscribe();
  assert.equal(t.replyTo(fresh).result.replayed, false);
  const reopen = t.ask('transcript.open', { session: REF, showDetails: false, resume: true });
  assert.equal(t.replyTo(reopen).result.resumed, false);
});

test('a held reply or event goes out on release, and a held event is numbered then', () => {
  const t = makeLaptop();
  t.laptop.hold('sessions.subscribe');
  t.laptop.connect();
  const sub = t.ask('sessions.subscribe', {});
  t.laptop.emitEvent('sessions.changed', { rows: [], removedRowIDs: [] });
  assert.deepEqual(t.sent, [], 'nothing before the subscribe reply');
  t.laptop.release('sessions.subscribe');
  assert.equal(t.replyTo(sub).result.seq, 1, 'the snapshot is made at its release');

  t.laptop.hold('sessions.changed');
  const fork = t.ask('session.fork', { session: REF, profileID: PROFILES[1].id });
  const ref = t.replyTo(fork).result.session;
  t.flush();
  assert.deepEqual(t.events(), []);
  t.laptop.emitEvent('transcript.append', { session: REF, items: itemsOf(['user']) });
  t.laptop.release('sessions.changed');
  assert.deepEqual(t.events().map((body) => [body.event, body.seq]), [['transcript.append', 2], ['sessions.changed', 3]]);
  const tabs = t.events()[1].data.rows[0].sessions;
  assert.deepEqual(tabs.map((/** @type {any} */ s) => s.tabName), ['Claude', 'Claude 2']);
  assert.deepEqual(tabs[1].ref, ref);
  assert.equal(tabs[1].profileName, 'acme-work');
  assert.throws(() => t.laptop.hold('sessions.typo'), RangeError);
});

test('a switch moves the session to the profile: a running one restarts idle, a parked one stays parked, and the reply says which', () => {
  for (const [chip, after, parked] of [['working', 'idle', false], ['parked', 'parked', true]]) {
    const scenario = scenarioWith();
    scenario.rows[0].sessions[0].status = { chip, agoMinutes: 4 };
    const t = makeLaptop(scenario);
    t.subscribe();
    const switched = t.ask('session.switchProfile', { session: REF, profileID: PROFILES[1].id });
    assert.deepEqual(t.replyTo(switched).result, { session: REF, parked }, chip);
    t.flush();
    const session = t.laptop.state.rows[0].sessions[0];
    assert.equal(session.status.chip, after, chip);
    assert.equal(session.profileName, 'acme-work', chip);
  }
});

test('setReply replaces a handler, and null brings it back', () => {
  const t = makeLaptop();
  t.subscribe();
  const error = { error: { code: 'phone_control_off', message: 'Phone control is off on this laptop.' } };
  t.laptop.setReply('profiles.list', error);
  assert.deepEqual(t.replyTo(t.ask('profiles.list')).error, error.error);
  t.laptop.setReply('profiles.list', (params, state) => ({ result: { profiles: state.profiles.slice(1) } }));
  assert.deepEqual(t.replyTo(t.ask('profiles.list')).result.profiles, [PROFILES[1]]);
  t.laptop.setReply('profiles.list', null);
  assert.deepEqual(t.replyTo(t.ask('profiles.list')).result.profiles, PROFILES);
  assert.throws(() => t.laptop.setReply('profiles.list', { profiles: [] }), TypeError);

  // A refused subscribe leaves the connection waiting: no event goes out.
  const fresh = makeLaptop();
  fresh.laptop.setReply('sessions.subscribe', error);
  fresh.subscribe();
  fresh.laptop.emitEvent('sessions.changed', { rows: [], removedRowIDs: [] });
  assert.deepEqual(fresh.events(), []);
});

test('a resent action gets its first reply and acts once', () => {
  const t = makeLaptop(scenarioWith(itemsOf(['user', 'assistant'])));
  t.subscribe();
  t.ask('transcript.open', { session: REF, showDetails: false, resume: false });
  t.sent.length = 0;
  t.ask('message.send', { session: REF, text: 'Ship it.' }, 'send-1');
  t.ask('message.send', { session: REF, text: 'Ship it.' }, 'send-1');
  const replies = t.sent.filter((body) => body.kind === 'reply');
  assert.deepEqual(replies.map((body) => body.result), [{ outcome: 'sent' }, { outcome: 'sent' }]);
  assert.deepEqual(t.events().map((body) => body.event), ['transcript.append', 'sessions.changed']);
  assert.equal(t.events()[1].data.rows[0].sessions[0].status.chip, 'working');
  t.ask('prompt.answer', { session: REF, promptID: 'p1', answer: { kind: 'permission', decision: 'allow' } }, 'send-1');
  assert.deepEqual(t.sent.at(-1).error, { code: 'bad_request', message: TEXT.idInUse });
  t.ask('message.send', { session: REF, text: '  ' });
  assert.deepEqual(t.sent.at(-1).error, { code: 'bad_request', message: TEXT.emptyMessage });
});

test('a resend of an action still running gets no reply of its own, across a blip too', () => {
  const t = makeLaptop(scenarioWith(itemsOf(['user', 'assistant'])));
  t.subscribe();
  t.ask('transcript.open', { session: REF, showDetails: false, resume: false });
  t.laptop.hold('message.send');
  t.sent.length = 0;
  t.ask('message.send', { session: REF, text: 'Ship it.' }, 'send-1');
  t.ask('message.send', { session: REF, text: 'Ship it.' }, 'send-1');
  // Another method under a running ID is refused at once, past the hold.
  t.ask('session.setModel', { session: REF, model: 'sonnet' }, 'send-1');
  assert.deepEqual(t.repliesTo('send-1').map((body) => body.error), [{ code: 'bad_request', message: TEXT.idInUse }]);

  // The phone reconnects and resends: the run is still going, so still nothing.
  t.laptop.disconnect();
  t.subscribe({ stream: STREAM, sinceSeq: t.laptop.state.seq });
  t.ask('message.send', { session: REF, text: 'Ship it.' }, 'send-1');
  t.laptop.release('message.send');
  const replies = t.repliesTo('send-1').filter((body) => body.result !== undefined);
  assert.deepEqual(replies.map((body) => body.result), [{ outcome: 'sent' }], 'one reply, on the connection the phone has now');
  assert.equal(t.events().filter((body) => body.event === 'transcript.append').length, 1, 'it acted once');

  // Once the reply is out, a resend gets it from the memory.
  t.ask('message.send', { session: REF, text: 'Ship it.' }, 'send-1');
  assert.deepEqual(t.repliesTo('send-1').at(-1).result, { outcome: 'sent' });
  assert.equal(t.events().filter((body) => body.event === 'transcript.append').length, 1);
});

test('only an acting request is remembered, so another method may reuse a read\'s ID', () => {
  const t = makeLaptop(scenarioWith(itemsOf(['user', 'assistant'])));
  t.subscribe();
  t.ask('transcript.open', { session: REF, showDetails: false, resume: false });
  // A read is not remembered: its resend runs again, and an action may take its ID.
  t.ask('profiles.list', {}, 'r-1');
  t.laptop.setReply('profiles.list', (params, state) => ({ result: { profiles: state.profiles.slice(1) } }));
  t.ask('profiles.list', {}, 'r-1');
  assert.deepEqual(t.repliesTo('r-1').at(-1).result.profiles, [PROFILES[1]]);
  t.ask('message.send', { session: REF, text: 'Ship it.' }, 'r-1');
  assert.deepEqual(t.repliesTo('r-1').at(-1).result, { outcome: 'sent' });
  // A read that reuses an action's ID runs as well: it never reaches the memory.
  t.laptop.setReply('profiles.list', null);
  t.ask('profiles.list', {}, 'r-1');
  assert.deepEqual(t.repliesTo('r-1').at(-1).result.profiles, PROFILES);
});

test('a reply that says the action certainly did not happen is not remembered; a refusal is', () => {
  const t = makeLaptop(scenarioWith(itemsOf(['user', 'assistant'])));
  t.subscribe();
  t.ask('transcript.open', { session: REF, showDetails: false, resume: false });
  const forgotten = [
    { code: 'phone_control_off', message: TEXT.phoneControlOff },
    { code: 'refused', message: TEXT.tooManyRequests },
    { code: 'internal', message: TEXT.settingUnreadable },
    { code: 'internal', message: TEXT.pairingUnreadable },
    { code: 'internal', message: TEXT.stopped },
  ];
  for (const [i, error] of forgotten.entries()) {
    const id = `send-${i}`;
    t.laptop.setReply('message.send', { error });
    t.ask('message.send', { session: REF, text: 'Ship it.' }, id);
    assert.deepEqual(t.repliesTo(id).at(-1).error, error);
    t.laptop.setReply('message.send', null);
    t.ask('message.send', { session: REF, text: 'Ship it.' }, id);
    assert.deepEqual(t.repliesTo(id).at(-1).result, { outcome: 'sent' }, `${error.code}: ${error.message}`);
  }

  // The handler's own refusals are kept, as the daemon keeps them: a resend gets the refusal.
  t.ask('message.send', { session: REF, text: '  ' }, 'empty');
  t.ask('message.send', { session: REF, text: 'Ship it.' }, 'empty');
  assert.deepEqual(t.repliesTo('empty').at(-1).error, { code: 'bad_request', message: TEXT.emptyMessage });
  t.laptop.setReply('message.send', { error: { code: 'internal', message: 'Something went wrong on the laptop.' } });
  t.ask('message.send', { session: REF, text: 'Ship it.' }, 'broke');
  t.laptop.setReply('message.send', null);
  t.ask('message.send', { session: REF, text: 'Ship it.' }, 'broke');
  assert.deepEqual(t.repliesTo('broke').map((body) => body.error?.code), ['internal', 'internal']);
});

test('a request sent on a connection that has ended is dropped, and its resend is taken afresh', () => {
  const t = makeLaptop();
  t.laptop.connect();
  const first = t.laptop.state.connection;
  // The channel blips while the phone's subscribe is on its way.
  t.laptop.disconnect();
  t.laptop.connect();
  const subscribe = { kind: 'request', requestID: 'sub-1', method: 'sessions.subscribe', params: {} };
  assert.equal(t.laptop.handle(subscribe, first), false);
  t.laptop.emitEvent('sessions.changed', { rows: [], removedRowIDs: [] });
  assert.deepEqual(t.sent, [], 'no reply, and the new connection is not live');
  assert.equal(t.laptop.handle(subscribe), true);
  assert.equal(t.replyTo('sub-1').result.seq, 1);

  // A subscribe held when its connection ends never replies, so its resend is not taken for it.
  t.sent.length = 0;
  t.laptop.hold('sessions.subscribe');
  t.laptop.disconnect();
  t.laptop.connect();
  t.ask('sessions.subscribe', {}, 'sub-2');
  t.laptop.disconnect();
  t.laptop.connect();
  t.ask('sessions.subscribe', {}, 'sub-2');
  t.laptop.release('sessions.subscribe');
  assert.deepEqual(t.sent.map((body) => [body.kind, body.requestID]), [['reply', 'sub-2']]);
  assert.equal(t.laptop.state.connection?.live, true);

  // With no connection at all, nothing is taken.
  t.laptop.disconnect();
  assert.equal(t.laptop.handle({ kind: 'request', requestID: 'r-1', method: 'profiles.list', params: {} }), false);
});

test('every body its default handlers send decodes with the app\'s decoders', () => {
  const scenario = scenarioWith(itemsOf(['user', 'tool', 'assistant', 'thinking', 'systemNote', 'subagent']), {
    details: {
      i1: { input: 'command: ls', result: 'a\n'.repeat(40_000) },
      i5: { subagent: [{ id: 's0', kind: 'assistant', text: 'found it', truncated: false, agoMinutes: 1 }] },
    },
    prompts: {
      [refKey(REF)]: [{
        id: 'p1', kind: 'question', targetTruncated: false, allowAlways: false,
        questions: [{ text: 'Add a test?', multiSelect: false, options: [{ label: 'Yes' }, { label: 'No' }] }],
      }],
    },
    providers: [{ name: 'acme-cloud', available: true, acceptsPrompt: true, fields: [] }],
  });
  scenario.rows[0].sessions[0].openPromptID = 'p1';
  scenario.transcripts[refKey(REF)][5] = {
    id: 'i5', kind: 'subagent', toolName: 'Agent', agentType: 'Explore', target: 'Find it', itemCount: 1, toolStatus: 'ok', truncated: false,
  };
  const t = makeLaptop(scenario);
  t.subscribe();
  t.ask('transcript.open', { session: REF, showDetails: true, resume: false });
  t.ask('transcript.detail', { session: REF, itemID: 'i1', part: 'result', chunk: 0 });
  t.ask('transcript.detail', { session: REF, itemID: 'i1', part: 'result', chunk: 1 });
  t.ask('transcript.detail', { session: REF, itemID: 'i5', part: 'subagent', chunk: 0 });
  t.ask('profiles.list');
  t.ask('remote.providers', { repoID: REPO_ID });
  t.ask('prompt.answer', { session: REF, promptID: 'p1', answer: { kind: 'question', answers: { 'Add a test?': 'Yes' } } });
  t.ask('message.send', { session: REF, text: 'y'.repeat(5_000) });
  t.ask('session.setModel', { session: REF, model: 'sonnet' });
  t.ask('session.switchProfile', { session: REF, profileID: PROFILES[1].id });
  t.ask('session.fork', { session: REF });
  t.ask('worktree.create', { repoID: REPO_ID, message: 'Add a search box.' });
  t.ask('remote.create', { provider: 'acme-cloud', repoID: REPO_ID, message: 'Triage it.', strings: {}, bools: {} });
  t.flush();
  t.ask('transcript.close');
  assertDecodes(t.sent, t.methods);

  const detail = t.sent.filter((body) => body.kind === 'reply' && body.result?.part === 'result');
  assert.equal(detail.length, 2);
  assert.equal(detail[0].result.chunkCount, 2);
  assert.equal(detail.map((body) => body.result.text).join(''), 'a\n'.repeat(40_000));
  const created = t.events().filter((body) => body.event === 'sessions.changed' && body.data.layout !== undefined);
  assert.deepEqual(created.map((body) => body.data.rows[0].name), ['new-worktree-1', 'new-remote-1']);
  assert.deepEqual(t.laptop.state.layout[0].rows.map((/** @type {any} */ r) => r.id).slice(1), created.map((body) => body.data.rows[0].id));
});

for (const name of readdirSync(SCENARIOS_DIR).filter((file) => file.endsWith('.json'))) {
  test(`scenarios/${name}: every reply the app asks for decodes`, () => {
    const scenario = JSON.parse(readFileSync(path.join(SCENARIOS_DIR, name), 'utf8'));
    const t = makeLaptop(scenario);
    t.subscribe();
    for (const row of t.laptop.state.rows) {
      for (const session of row.sessions) {
        if (session.capabilities.transcript.available) {
          t.ask('transcript.open', { session: session.ref, showDetails: false, resume: false });
          t.ask('transcript.open', { session: session.ref, showDetails: true, resume: false });
        }
      }
    }
    t.ask('profiles.list');
    t.ask('remote.providers', {});
    assert.equal(t.sent.filter((body) => body.error !== undefined).length, 0, 'no request was refused');
    assertDecodes(t.sent, t.methods);
  });
}
