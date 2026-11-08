// Tests client.ts, the app protocol client: request bodies and IDs, the frame budget, the
// in-flight cap, and replies. A fake `post` records each body the client sends, and replies
// and events reach it through `handle`, as the loader's messages do. The methods it treats as
// acting are checked against the daemon's request memory (`PhoneAppService.swift`).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { MAX_BODY_BYTES, MAX_IN_FLIGHT } from '../limits.ts';
import { METHODS, requestBody } from '../protocol/wire.ts';
import type { AppEvent, Method, PhoneSessionRef } from '../protocol/types.ts';
import {
  ACTING_METHODS, AppClient, AppError, BAD_PARAMS_TEXT, BAD_REPLY_TEXT, newRequestID, STATE_METHODS, TOO_LONG_TEXT,
} from './client.ts';
import type { ClientOptions } from './client.ts';

const REF: PhoneSessionRef = { kind: 'local', terminalID: '08A7FA53-E9FD-5ACA-8D10-6F6F0E189F62' };
const SERVICE = new URL('../../../../Sources/TBDDaemon/PhoneBridge/App/PhoneAppService.swift', import.meta.url);
const PROTOCOL = new URL('../../../../Sources/TBDDaemon/PhoneBridge/App/PhoneAppProtocol.swift', import.meta.url);

type Body = Record<string, any>;

interface Harness {
  c: AppClient;
  posted: Body[];
  events: AppEvent[];
  calls: string[];
  /** Feeds one app body to the client. */
  app(body: Body): void;
  /** Answers `request` with `result`. */
  reply(request: Body | undefined, result: Body): void;
  /** Answers `request` with an error. */
  fail(request: Body | undefined, code: string, message: string): void;
  up(): void;
  down(): void;
}

/** A client with a recording `post`, request IDs `r1`, `r2`, … and its clock at 0. */
function harness(options: Partial<ClientOptions> = {}): Harness {
  const posted: Body[] = [];
  const events: AppEvent[] = [];
  const calls: string[] = [];
  let n = 0;
  const c = new AppClient({
    post: (body) => { posted.push(body); },
    onEvent: (event) => { events.push(event); },
    onUp: () => { calls.push('up'); },
    onDown: () => { calls.push('down'); },
    now: () => 0,
    newID: () => `r${++n}`,
    ...options,
  });
  const app = (body: Body): void => c.handle({ t: 'app', body });
  return {
    c, posted, events, calls, app,
    reply: (request, result) => app({ kind: 'reply', requestID: request?.requestID, result }),
    fail: (request, code, message) => app({ kind: 'reply', requestID: request?.requestID, error: { code, message } }),
    up: () => c.handle({ t: 'channel', up: true }),
    down: () => c.handle({ t: 'channel', up: false }),
  };
}

/** Records how a promise settles, so a rejection the test does not await is never unhandled. */
function track<T>(promise: Promise<T>): { state: 'pending' | 'resolved' | 'rejected'; value?: T; error?: unknown } {
  const out: { state: 'pending' | 'resolved' | 'rejected'; value?: T; error?: unknown } = { state: 'pending' };
  promise.then((value) => { out.state = 'resolved'; out.value = value; }, (error: unknown) => { out.state = 'rejected'; out.error = error; });
  return out;
}

/** Lets every settled promise run its callbacks. */
function flush(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

const PROFILES = { profiles: [{ id: 'P1', name: 'acme', kind: 'apiKey', isDefault: true }] };

test('nothing is posted before the first channel up', () => {
  const h = harness();
  track(h.c.request('profiles.list', {}));
  assert.equal(h.posted.length, 0);
  assert.equal(h.c.up, false);
  h.up();
  assert.equal(h.c.up, true);
  assert.equal(h.posted.length, 1);
  assert.equal(h.posted[0]!.method, 'profiles.list');
});

test('a request is posted as requestBody builds it, with a fresh ID each time', () => {
  const h = harness();
  h.up();
  track(h.c.request('message.send', { session: REF, text: 'hi' }));
  track(h.c.request('message.send', { session: REF, text: 'hi' }));
  assert.deepEqual(h.posted, [
    requestBody('r1', 'message.send', { session: REF, text: 'hi' }),
    requestBody('r2', 'message.send', { session: REF, text: 'hi' }),
  ]);
});

test('requests wait in the order they were made', () => {
  const h = harness();
  track(h.c.request('profiles.list', {}));
  track(h.c.request('remote.providers', {}));
  track(h.c.request('message.send', { session: REF, text: 'hi' }));
  h.up();
  assert.deepEqual(h.posted.map((b) => b.requestID), ['r1', 'r2', 'r3']);
});

test('a reply resolves its request by requestID, and an unknown ID is ignored', async () => {
  const h = harness();
  h.up();
  const first = track(h.c.request('profiles.list', {}));
  const second = track(h.c.request('message.send', { session: REF, text: 'hi' }));
  h.app({ kind: 'reply', requestID: 'r99', result: { outcome: 'sent' } });
  h.app({ kind: 'reply', requestID: '', error: { code: 'internal', message: 'Something went wrong on the laptop.' } });
  h.reply(h.posted[1], { outcome: 'sent' });
  await flush();
  assert.equal(first.state, 'pending');
  assert.deepEqual(second, { state: 'resolved', value: { outcome: 'sent' } });
  h.reply(h.posted[0], PROFILES);
  await flush();
  assert.deepEqual(first, { state: 'resolved', value: PROFILES });
  // A second reply to an answered request changes nothing.
  h.reply(h.posted[0], { profiles: [] });
  await flush();
  assert.deepEqual(first.value, PROFILES);
});

test('a result is decoded by the method of the request it answers, and unknown fields are dropped', async () => {
  const h = harness();
  h.up();
  const p = h.c.request('session.fork', { session: REF });
  h.reply(h.posted[0], { session: { ...REF, extra: 1 }, note: 'x' });
  assert.deepEqual(await p, { session: REF });
});

test("an error reply rejects with the daemon's code and message", async () => {
  const h = harness();
  h.up();
  const p = h.c.request('message.send', { session: REF, text: 'hi' });
  h.fail(h.posted[0], 'refused', 'Write a message first.');
  await assert.rejects(p, (err: unknown) => {
    assert.ok(err instanceof AppError);
    assert.equal(err.code, 'refused');
    assert.equal(err.message, 'Write a message first.');
    return true;
  });
});

test("an error code outside the daemon's list rejects with bad_reply and keeps the daemon's message", async () => {
  const h = harness();
  h.up();
  const p = h.c.request('profiles.list', {});
  h.fail(h.posted[0], 'some_new_code', 'Update TBD on the laptop.');
  await assert.rejects(p, { code: 'bad_reply', message: 'Update TBD on the laptop.' });
});

test('a body over 65,497 bytes is refused before posting', async () => {
  const h = harness();
  const whileDown = h.c.request('message.send', { session: REF, text: 'x'.repeat(66_000) });
  await assert.rejects(whileDown, { code: 'too_large', message: 'That message is too long to send from a phone.' });
  h.up();
  const whileUp = h.c.request('message.send', { session: REF, text: 'x'.repeat(66_000) });
  await assert.rejects(whileUp, { code: 'too_large', message: TOO_LONG_TEXT });
  assert.equal(h.posted.length, 0);
});

test('a body of exactly 65,497 bytes is posted, and one byte more is not', async () => {
  const h = harness({ newID: () => 'fixed-id' });
  h.up();
  const overhead = new TextEncoder().encode(JSON.stringify(requestBody('fixed-id', 'message.send', { session: REF, text: '' }))).length;
  const text = 'é'.repeat(Math.floor((MAX_BODY_BYTES - overhead) / 2)) + 'x'.repeat((MAX_BODY_BYTES - overhead) % 2);
  assert.equal(new TextEncoder().encode(JSON.stringify(requestBody('fixed-id', 'message.send', { session: REF, text }))).length, MAX_BODY_BYTES);
  const fits = track(h.c.request('message.send', { session: REF, text }));
  assert.equal(h.posted.length, 1);
  h.reply(h.posted[0], { outcome: 'sent' });
  await flush();
  assert.equal(fits.state, 'resolved');
  await assert.rejects(h.c.request('message.send', { session: REF, text: `${text}x` }), { code: 'too_large' });
  assert.equal(h.posted.length, 1);
});

test('params of the wrong shape reject with bad_request before anything is posted', async () => {
  const h = harness();
  h.up();
  await assert.rejects(h.c.request('transcript.detail', { session: REF, itemID: 'i1', part: 'text', chunk: 1.5 }),
    { code: 'bad_request', message: BAD_PARAMS_TEXT });
  assert.equal(h.posted.length, 0);
});

test('at most 32 requests are in flight; the 33rd waits for a reply', () => {
  const h = harness();
  h.up();
  for (let i = 0; i < 33; i++) track(h.c.request('profiles.list', {}));
  assert.equal(MAX_IN_FLIGHT, 32);
  assert.equal(h.posted.length, 32);
  h.reply(h.posted[0], PROFILES);
  assert.equal(h.posted.length, 33);
  assert.equal(h.posted[32]!.requestID, 'r33');
});

test('an error reply frees a slot too', () => {
  const h = harness();
  h.up();
  for (let i = 0; i < 33; i++) track(h.c.request('profiles.list', {}));
  h.fail(h.posted[5], 'refused', 'Too many requests are in progress. Try again in a moment.');
  assert.equal(h.posted.length, 33);
});

test('sendFailed tooLarge fails every unanswered request', async () => {
  const h = harness();
  h.up();
  const posted = Array.from({ length: 33 }, () => track(h.c.request('profiles.list', {})));
  const answered = posted[0]!;
  h.reply(h.posted[0], PROFILES);   // r33 is posted in r1's slot
  h.c.handle({ t: 'sendFailed', reason: 'tooLarge' });
  await flush();
  assert.equal(answered.state, 'resolved');
  for (const p of posted.slice(1)) {
    assert.equal(p.state, 'rejected');
    assert.ok(p.error instanceof AppError);
    assert.equal(p.error.code, 'too_large');
    assert.equal(p.error.message, TOO_LONG_TEXT);
  }
  // Their replies, if they come, are ignored, and new requests go out.
  h.reply(h.posted[1], PROFILES);
  track(h.c.request('profiles.list', {}));
  assert.equal(h.posted.at(-1)!.requestID, 'r34');
});

test('sendFailed tooLarge leaves a request that was never posted waiting', async () => {
  const h = harness();
  h.up();
  const all = Array.from({ length: 34 }, () => track(h.c.request('profiles.list', {})));
  h.c.handle({ t: 'sendFailed', reason: 'tooLarge' });
  await flush();
  assert.equal(all.filter((p) => p.state === 'rejected').length, 32);
  // The two queued requests take the freed slots.
  assert.deepEqual(h.posted.slice(32).map((b) => b.requestID), ['r33', 'r34']);
  assert.equal(all[32]!.state, 'pending');
});

test('a result that does not decode rejects with bad_reply', async () => {
  const h = harness();
  h.up();
  const p = h.c.request('profiles.list', {});
  h.reply(h.posted[0], { profiles: [{ id: 'P1' }] });
  await assert.rejects(p, { code: 'bad_reply', message: BAD_REPLY_TEXT });
});

test('a reply whose envelope does not decode fails the request it names with bad_reply', async () => {
  const h = harness();
  h.up();
  const both = h.c.request('profiles.list', {});
  const badError = h.c.request('profiles.list', {});
  h.app({ kind: 'reply', requestID: 'r1', result: PROFILES, error: { code: 'internal', message: 'x' } });
  h.app({ kind: 'reply', requestID: 'r2', error: { code: 'refused' } });
  await assert.rejects(both, { code: 'bad_reply', message: BAD_REPLY_TEXT });
  await assert.rejects(badError, { code: 'bad_reply', message: BAD_REPLY_TEXT });
});

test('a body that is neither a reply nor an event is ignored', async () => {
  const h = harness();
  h.up();
  const p = track(h.c.request('profiles.list', {}));
  h.app({ kind: 'request', requestID: 'r1', method: 'profiles.list', params: {} });
  h.app({ kind: 'reply' });
  h.app({ nothing: true });
  await flush();
  assert.equal(p.state, 'pending');
});

test('a reply naming a request still queued is ignored, because the laptop never saw that ID', async () => {
  const h = harness();
  const p = track(h.c.request('profiles.list', {}));
  h.reply({ requestID: 'r1' }, PROFILES);
  await flush();
  assert.equal(p.state, 'pending');
  h.up();
  h.reply(h.posted[0], PROFILES);
  await flush();
  assert.equal(p.state, 'resolved');
});

test('an event is decoded by its name and handed on', () => {
  const h = harness();
  h.up();
  h.app({ kind: 'event', event: 'sessions.changed', seq: 1, data: { rows: [], removedRowIDs: ['row-1'], extra: true } });
  h.app({ kind: 'event', event: 'sessions.changed', seq: 2, data: { rows: 'not a list', removedRowIDs: [] } });
  h.app({ kind: 'event', event: 'no.such.event', seq: 3, data: {} });
  assert.deepEqual(h.events, [{ event: 'sessions.changed', seq: 1, data: { rows: [], removedRowIDs: ['row-1'] } }]);
});

test('channel up and down call onUp and onDown on each change only', () => {
  const h = harness();
  h.down();
  h.up();
  h.up();
  h.down();
  h.down();
  assert.deepEqual(h.calls, ['up', 'down']);
});

test('env messages are ignored', () => {
  const h = harness();
  h.c.handle({
    t: 'env',
    env: {
      safeArea: { top: 0, right: 0, bottom: 0, left: 0 },
      viewport: { width: 390, height: 844, offsetTop: 0, offsetLeft: 0, scale: 1 },
      layout: { width: 390, height: 844 },
      colorScheme: 'dark',
    },
  });
  assert.deepEqual(h.calls, []);
  assert.equal(h.posted.length, 0);
});

test('an ID that is still in use is never sent twice', () => {
  const h = harness({ newID: () => 'same' });
  h.up();
  track(h.c.request('profiles.list', {}));
  assert.throws(() => h.c.request('message.send', { session: REF, text: 'hi' }), /already in use/);
  assert.equal(h.posted.length, 1);
});

test('the default request ID is a lowercase version 4 UUID, new each time', () => {
  const ids = new Set<string>();
  for (let i = 0; i < 1_000; i++) {
    const id = newRequestID();
    assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    ids.add(id);
  }
  assert.equal(ids.size, 1_000);
  const posted: Body[] = [];
  const c = new AppClient({ post: (b) => { posted.push(b); }, onEvent() {}, onUp() {}, onDown() {} });
  c.handle({ t: 'channel', up: true });
  track(c.request('profiles.list', {}));
  assert.match(posted[0]!.requestID, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});

/** Each `PhoneAppMethod` case's name mapped to its wire name. */
function swiftMethodNames(): Map<string, string> {
  const source = readFileSync(PROTOCOL, 'utf8');
  const body = /enum PhoneAppMethod\b[^{]*\{([^}]*)\}/.exec(source)?.[1];
  assert.ok(body !== undefined, 'PhoneAppMethod is in PhoneAppProtocol.swift');
  return new Map([...body.matchAll(/case (\w+) = "([^"]+)"/g)].map((m) => [m[1]!, m[2]!]));
}

/** The wire names of the methods in each arm of `remembersReplies(of:)`, keyed by what the arm returns. */
function rememberedMethods(): { remembered: Method[]; forgotten: Method[] } {
  const source = readFileSync(SERVICE, 'utf8');
  const body = /static func remembersReplies\(of method: PhoneAppMethod\) -> Bool \{([\s\S]*?)\n {4}\}/.exec(source)?.[1];
  assert.ok(body !== undefined, 'remembersReplies(of:) is in PhoneAppService.swift');
  const names = swiftMethodNames();
  const arm = (returns: string): Method[] => {
    const cases = new RegExp(`case ([^:]*):\\s*return ${returns}\\b`).exec(body)?.[1];
    assert.ok(cases !== undefined, `remembersReplies has an arm that returns ${returns}`);
    return [...cases.matchAll(/\.(\w+)/g)].map((m) => {
      const wire = names.get(m[1]!);
      assert.ok(wire !== undefined, `.${m[1]} is a PhoneAppMethod`);
      return wire as Method;
    });
  };
  return { remembered: arm('true'), forgotten: arm('false') };
}

test("the acting methods are the ones the daemon's request memory keeps", () => {
  const { remembered, forgotten } = rememberedMethods();
  assert.deepEqual([...ACTING_METHODS].sort(), [...remembered].sort());
  assert.deepEqual([...remembered, ...forgotten].sort(), [...METHODS].sort());
  for (const method of STATE_METHODS) assert.ok(forgotten.includes(method), method);
  assert.deepEqual([...STATE_METHODS].sort(), ['sessions.subscribe', 'transcript.close', 'transcript.open']);
});
