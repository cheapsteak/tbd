// Tests client.ts, the app protocol client: request bodies and IDs, the frame budget, the
// in-flight cap, replies, and what a dropped channel does to requests and event numbering. A
// fake `post` records each body the client sends, and replies and events reach it through
// `handle`, as the loader's messages do. The methods it treats as acting are checked against
// the daemon's request memory (`PhoneAppService.swift`).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { MAX_BODY_BYTES, MAX_IN_FLIGHT } from '../limits.ts';
import { METHODS, requestBody } from '../protocol/wire.ts';
import type { AppEvent, Method, PhoneSessionRef, SessionsSubscribeParams } from '../protocol/types.ts';
import {
  ACTING_METHODS, AppClient, AppError, BAD_PARAMS_TEXT, BAD_REPLY_TEXT, newRequestID, NOT_CONFIRMED_TEXT, STATE_METHODS,
  SUPERSEDED_TEXT, TOO_LONG_TEXT,
} from './client.ts';
import type { ClientOptions } from './client.ts';

const REF: PhoneSessionRef = { kind: 'local', terminalID: '08A7FA53-E9FD-5ACA-8D10-6F6F0E189F62' };
// Outside phone/: the classifier's `Sources/TBDDaemon/PhoneBridge/App/*` route
// (scripts/ci/phone-parts-needed.sh) runs these tests when either file changes.
const SERVICE = new URL('../../../../Sources/TBDDaemon/PhoneBridge/App/PhoneAppService.swift', import.meta.url);
const PROTOCOL = new URL('../../../../Sources/TBDDaemon/PhoneBridge/App/PhoneAppProtocol.swift', import.meta.url);

type Body = Record<string, any>;

interface Harness {
  c: AppClient;
  posted: Body[];
  events: AppEvent[];
  calls: string[];
  /** The client's clock, in milliseconds. */
  clock: { now: number };
  /** Feeds one app body to the client. */
  app(body: Body): void;
  /** Answers `request` with `result`. */
  reply(request: Body | undefined, result: Body): void;
  /** Answers `request` with an error. */
  fail(request: Body | undefined, code: string, message: string): void;
  up(): void;
  down(): void;
}

/**
 * A client with a recording `post`, request IDs `r1`, `r2`, … and its clock at 0. `whenUp` runs
 * inside `onUp`, as the app's own subscribe does.
 */
function harness(options: Partial<ClientOptions> & { whenUp?: (c: AppClient) => void } = {}): Harness {
  const posted: Body[] = [];
  const events: AppEvent[] = [];
  const calls: string[] = [];
  const clock = { now: 0 };
  let n = 0;
  const { whenUp, ...rest } = options;
  const c: AppClient = new AppClient({
    post: (body) => { posted.push(body); },
    onEvent: (event) => { events.push(event); },
    onUp: () => { calls.push('up'); whenUp?.(c); },
    onDown: () => { calls.push('down'); },
    now: () => clock.now,
    newID: () => `r${++n}`,
    ...rest,
  });
  const app = (body: Body): void => c.handle({ t: 'app', body });
  return {
    c, posted, events, calls, clock, app,
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

/** What the app's `onUp` sends first: a subscribe that carries on from where the client is. */
function subscribe(c: AppClient): void {
  const params: SessionsSubscribeParams = {};
  if (c.stream !== null) params.stream = c.stream;
  if (c.lastSeq !== null) params.sinceSeq = c.lastSeq;
  track(c.request('sessions.subscribe', params));
}

/** A subscribe reply with a fresh snapshot (no rows) at `seq`. */
function snapshot(stream: string, seq: number): Body {
  return { stream, seq, replayed: false, layout: [], rows: [], omittedRows: 0, more: false };
}

/** A subscribe reply that replays the missed events, naming the stream's current `seq`. */
function replay(stream: string, seq: number): Body {
  return { stream, seq, replayed: true, omittedRows: 0, more: false };
}

/** A `sessions.changed` event numbered `seq`. */
function event(h: Harness, seq: number): void {
  h.app({ kind: 'event', event: 'sessions.changed', seq, data: { rows: [], removedRowIDs: [] } });
}

/** The last body posted for `method`. */
function last(h: Harness, method: Method): Body | undefined {
  return h.posted.filter((b) => b.method === method).at(-1);
}

/** Brings the channel up and answers `onUp`'s subscribe with a snapshot of stream `s1`. */
function connect(h: Harness): void {
  h.up();
  h.reply(last(h, 'sessions.subscribe'), snapshot('s1', 0));
}

/** Answers the latest subscribe with a replay of the client's stream, which releases held actions. */
function confirm(h: Harness): void {
  h.reply(last(h, 'sessions.subscribe'), replay(h.c.stream ?? 's1', h.c.lastSeq ?? 0));
}

/** How many times a body with `requestID` was posted. */
function sends(h: Harness, requestID: string): number {
  return h.posted.filter((b) => b.requestID === requestID).length;
}

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

test('sendFailed tooLarge fails only the posted, unanswered request with the largest body', async () => {
  const h = harness();
  h.up();
  const short = track(h.c.request('message.send', { session: REF, text: 'hi' }));
  const long = track(h.c.request('message.send', { session: REF, text: 'x'.repeat(1_000) }));
  const longer = track(h.c.request('message.send', { session: REF, text: 'x'.repeat(2_000) }));
  const read = track(h.c.request('profiles.list', {}));
  h.reply(h.posted[2], { outcome: 'sent' });   // the longest is answered, so it is not a candidate
  h.c.handle({ t: 'sendFailed', reason: 'tooLarge' });
  await flush();
  assert.equal(longer.state, 'resolved');
  assert.deepEqual([short.state, long.state, read.state], ['pending', 'rejected', 'pending']);
  assert.ok(long.error instanceof AppError);
  assert.deepEqual([long.error.code, long.error.message], ['too_large', TOO_LONG_TEXT]);
  // Each sendFailed stands for one body: a second fails the next largest.
  h.c.handle({ t: 'sendFailed', reason: 'tooLarge' });
  await flush();
  assert.deepEqual([short.state, read.state], ['rejected', 'pending']);
  // A reply to a failed request, if one comes, is ignored; the rest still resolve.
  h.reply(h.posted[1], { outcome: 'sent' });
  h.reply(h.posted[3], PROFILES);
  await flush();
  assert.equal(long.state, 'rejected');
  assert.equal(read.state, 'resolved');
});

test('sendFailed tooLarge fails the one posted last of bodies the same size', async () => {
  const h = harness();
  h.up();
  const first = track(h.c.request('message.send', { session: REF, text: 'A' }));
  const second = track(h.c.request('message.send', { session: REF, text: 'B' }));
  h.c.handle({ t: 'sendFailed', reason: 'tooLarge' });
  await flush();
  assert.deepEqual([first.state, second.state], ['pending', 'rejected']);
});

test('sendFailed tooLarge leaves the subscribe alone when a larger body is posted', async () => {
  let subscribed: { state: string } | undefined;
  const h = harness({ whenUp: (c) => { subscribed = track(c.request('sessions.subscribe', {})); } });
  h.up();
  const send = track(h.c.request('message.send', { session: REF, text: 'Run the unit tests.' }));
  h.c.handle({ t: 'sendFailed', reason: 'tooLarge' });
  await flush();
  assert.equal(send.state, 'rejected');
  assert.equal(subscribed!.state, 'pending');
  h.reply(last(h, 'sessions.subscribe'), snapshot('s1', 0));
  await flush();
  assert.equal(subscribed!.state, 'resolved');
});

test('sendFailed tooLarge frees one slot, which a request never posted takes', async () => {
  const h = harness();
  h.up();
  const all = Array.from({ length: 34 }, () => track(h.c.request('profiles.list', {})));
  h.c.handle({ t: 'sendFailed', reason: 'tooLarge' });
  await flush();
  // r10 to r32 have the longest bodies, and r32 was posted last of them.
  assert.deepEqual(all.flatMap((p, i) => (p.state === 'rejected' ? [i + 1] : [])), [32]);
  assert.deepEqual(h.posted.slice(32).map((b) => b.requestID), ['r33']);
  assert.equal(all[33]!.state, 'pending');
  // With nothing posted, it fails nothing.
  const idle = harness();
  const queued = track(idle.c.request('profiles.list', {}));
  idle.c.handle({ t: 'sendFailed', reason: 'tooLarge' });
  await flush();
  assert.equal(queued.state, 'pending');
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
  const h = harness({ whenUp: subscribe });
  h.up();
  h.reply(last(h, 'sessions.subscribe'), snapshot('s1', 0));
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

test('an ID that is still in use is never sent twice, and the request rejects rather than throws', async () => {
  const h = harness({ newID: () => 'same' });
  h.up();
  track(h.c.request('profiles.list', {}));
  let reused: Promise<unknown> | undefined;
  assert.doesNotThrow(() => { reused = h.c.request('message.send', { session: REF, text: 'hi' }); });
  await assert.rejects(reused!, (error: unknown) => (
    error instanceof Error && !(error instanceof AppError) && /request ID same is already in use/.test(error.message)
  ));
  assert.equal(h.posted.length, 1);
});

test('a newID that throws rejects the request, and nothing is posted', async () => {
  const h = harness({ newID: () => { throw new Error('no random values'); } });
  h.up();
  let p: Promise<unknown> | undefined;
  assert.doesNotThrow(() => { p = h.c.request('profiles.list', {}); });
  await assert.rejects(p!, /no random values/);
  assert.equal(h.posted.length, 0);
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

// MARK: - Across a dropped channel

test('channel up posts what onUp asks for before any resend', () => {
  const h = harness({ whenUp: subscribe });
  connect(h);
  track(h.c.request('profiles.list', {}));
  track(h.c.request('message.send', { session: REF, text: 'hi' }));
  const readID = last(h, 'profiles.list')!.requestID;
  const firstSendID = last(h, 'message.send')!.requestID;
  h.down();
  h.up();
  assert.equal(h.posted.at(-2)!.method, 'sessions.subscribe');
  assert.deepEqual(h.posted.at(-2)!.params, { stream: 's1', sinceSeq: 0 });
  assert.equal(h.posted.at(-1)!.requestID, readID);
  confirm(h);
  assert.equal(h.posted.at(-1)!.requestID, firstSendID);
});

test("onUp's requests go out in the order it makes them, then reposts in first-send order, then the queue", () => {
  const h = harness({
    whenUp: (c) => {
      subscribe(c);
      if (c.lastSeq !== null) track(c.request('transcript.open', { session: REF, showDetails: false, resume: true }));
    },
  });
  h.up();
  h.reply(last(h, 'sessions.subscribe'), snapshot('s1', 0));
  track(h.c.request('profiles.list', {}));
  track(h.c.request('message.send', { session: REF, text: 'hi' }));
  const read = last(h, 'profiles.list')!;
  const act = last(h, 'message.send')!;
  h.down();
  track(h.c.request('remote.providers', {}));
  const mark = h.posted.length;
  h.up();
  assert.deepEqual(h.posted.slice(mark).map((b) => b.method),
    ['sessions.subscribe', 'transcript.open', 'profiles.list', 'remote.providers']);
  assert.equal(h.posted[mark + 2], read);
  // The action waits for the subscribe reply.
  confirm(h);
  assert.equal(h.posted.at(-1), act);
});

test('an acting request is resent with its own requestID', async () => {
  const h = harness({ whenUp: subscribe });
  connect(h);
  const p = track(h.c.request('message.send', { session: REF, text: 'hi' }));
  const first = last(h, 'message.send')!;
  h.down();
  h.clock.now = 300_000;
  h.up();
  assert.equal(sends(h, first.requestID), 1);
  confirm(h);
  const resent = last(h, 'message.send')!;
  assert.equal(resent.requestID, first.requestID);
  assert.equal(sends(h, first.requestID), 2);
  h.reply(resent, { outcome: 'sent' });
  await flush();
  assert.deepEqual(p, { state: 'resolved', value: { outcome: 'sent' } });
});

test('an acting request first sent over 540 s ago is not resent', async () => {
  const h = harness();
  h.up();
  h.clock.now = 0;
  const p = h.c.request('message.send', { session: REF, text: 'hi' });
  h.down();
  h.clock.now = 540_001;
  h.up();
  await assert.rejects(p, { code: 'not_confirmed', message: NOT_CONFIRMED_TEXT });
  assert.equal(h.posted.filter((b) => b.method === 'message.send').length, 1);
  // Its reply, should it come after all, is ignored.
  h.reply(h.posted[0], { outcome: 'sent' });
});

test('an acting request at exactly 540,000 ms is resent, and at 540,001 it is not', async () => {
  const h = harness({ whenUp: subscribe });
  connect(h);
  h.clock.now = 0;
  const older = track(h.c.request('prompt.answer', { session: REF, promptID: 'p1', answer: { kind: 'permission', decision: 'allow' } }));
  const olderID = last(h, 'prompt.answer')!.requestID;
  h.clock.now = 1;
  const newer = track(h.c.request('prompt.answer', { session: REF, promptID: 'p2', answer: { kind: 'permission', decision: 'deny' } }));
  const newerID = last(h, 'prompt.answer')!.requestID;
  h.down();
  h.clock.now = 540_001;
  h.up();
  confirm(h);
  await flush();
  assert.equal(older.state, 'rejected');
  assert.equal((older.error as AppError).code, 'not_confirmed');
  assert.equal(newer.state, 'pending');
  assert.equal(sends(h, olderID), 1);
  assert.equal(sends(h, newerID), 2);
});

test('the horizon counts from the first send, not from the latest resend', async () => {
  const h = harness({ whenUp: subscribe });
  connect(h);
  const p = track(h.c.request('session.setModel', { session: REF, model: 'opus' }));
  const id = last(h, 'session.setModel')!.requestID;
  h.down();
  h.clock.now = 300_000;
  h.up();
  confirm(h);
  assert.equal(sends(h, id), 2);
  h.down();
  h.clock.now = 540_001;
  h.up();
  confirm(h);
  await flush();
  assert.equal(p.state, 'rejected');
  assert.equal((p.error as AppError).code, 'not_confirmed');
  assert.equal(sends(h, id), 2);
});

test('every acting method is held to the horizon, and no read or queued request is', async () => {
  const acting: Array<() => Promise<unknown>> = [];
  const h = harness();
  h.up();
  acting.push(
    () => h.c.request('message.send', { session: REF, text: 'hi' }),
    () => h.c.request('prompt.answer', { session: REF, promptID: 'p1', answer: { kind: 'question', answers: { Which: 'A' } } }),
    () => h.c.request('session.switchProfile', { session: REF, profileID: 'P1' }),
    () => h.c.request('session.fork', { session: REF }),
    () => h.c.request('session.setModel', { session: REF, model: 'opus' }),
    () => h.c.request('worktree.create', { repoID: 'R1', message: 'Fix the login loop.' }),
    () => h.c.request('remote.create', { provider: 'acme-cloud', repoID: 'R1', message: 'hi', strings: {}, bools: {} }),
  );
  const outcomes = acting.map((make) => track(make()));
  const reads = [
    track(h.c.request('profiles.list', {})),
    track(h.c.request('remote.providers', {})),
    track(h.c.request('transcript.page', { session: REF, cursor: 'c1' })),
    track(h.c.request('transcript.detail', { session: REF, itemID: 'i1', part: 'text', chunk: 0 })),
  ];
  h.down();
  const queued = track(h.c.request('worktree.create', { repoID: 'R1', message: 'Queued while down.' }));
  h.clock.now = 36_000_000;
  const mark = h.posted.length;
  h.up();
  await flush();
  assert.deepEqual(outcomes.map((o) => o.state), Array(7).fill('rejected'));
  assert.deepEqual(reads.map((o) => o.state), Array(4).fill('pending'));
  assert.equal(queued.state, 'pending');
  assert.deepEqual(h.posted.slice(mark).map((b) => b.method),
    ['profiles.list', 'remote.providers', 'transcript.page', 'transcript.detail', 'worktree.create']);
  assert.equal(h.posted.at(-1)!.params.message, 'Queued while down.');
});

test('a read is resent after any delay', () => {
  const h = harness();
  h.up();
  track(h.c.request('profiles.list', {}));
  h.down();
  h.clock.now = 7 * 24 * 3_600_000;
  h.up();
  assert.equal(sends(h, 'r1'), 2);
});

test('a queued request that was never posted is posted on up whatever its age', async () => {
  const h = harness({ whenUp: subscribe });
  const p = track(h.c.request('message.send', { session: REF, text: 'hi' }));
  h.clock.now = 3_600_000;
  h.up();   // a request never sent waits for no subscribe reply
  assert.equal(sends(h, 'r1'), 1);
  h.reply(last(h, 'sessions.subscribe'), snapshot('s1', 0));
  h.down();
  h.clock.now += 540_000;   // 540 s after its first send, not after it was made
  h.up();
  confirm(h);
  assert.equal(sends(h, 'r1'), 2);
  h.reply(last(h, 'message.send'), { outcome: 'sent' });
  await flush();
  assert.equal(p.state, 'resolved');
});

test('a subscribe reply that comes after the horizon rejects the held action, even with no slot free', async () => {
  const h = harness({
    whenUp: (c) => {
      subscribe(c);
      if (c.lastSeq !== null) track(c.request('transcript.open', { session: REF, showDetails: false, resume: true }));
    },
  });
  h.up();
  h.reply(last(h, 'sessions.subscribe'), snapshot('s1', 0));
  for (let i = 0; i < 31; i++) track(h.c.request('profiles.list', {}));
  const act = track(h.c.request('message.send', { session: REF, text: 'hi' }));
  const id = last(h, 'message.send')!.requestID;
  h.down();
  h.clock.now = 500_000;
  h.up();   // the subscribe, the open and 29 reads; the held action holds the last slot
  assert.equal(sends(h, id), 1);
  h.clock.now = 540_001;
  // Its release frees two slots, which the two reads first sent before it take.
  h.reply(last(h, 'sessions.subscribe'), replay('s1', 0));
  await flush();
  assert.equal(act.state, 'rejected');
  assert.equal((act.error as AppError).code, 'not_confirmed');
  assert.equal(sends(h, id), 1);
});

test('an acting request too old at channel up is rejected at once, even with no slot free', async () => {
  const h = harness({ whenUp: subscribe });
  h.up();
  h.reply(last(h, 'sessions.subscribe'), snapshot('s1', 0));
  for (let i = 0; i < 31; i++) track(h.c.request('profiles.list', {}));
  const act = track(h.c.request('session.fork', { session: REF }));
  h.down();
  h.clock.now = 600_000;
  h.up();
  await flush();
  assert.equal(act.state, 'rejected');
  assert.equal((act.error as AppError).code, 'not_confirmed');
});

test('a replaying subscribe keeps events numbered at or below its seq', () => {
  const h = harness({ whenUp: subscribe });
  h.up();
  h.reply(last(h, 'sessions.subscribe'), snapshot('s1', 100));
  assert.equal(h.c.lastSeq, 100);
  h.down();
  h.up();
  assert.deepEqual(last(h, 'sessions.subscribe')!.params, { stream: 's1', sinceSeq: 100 });
  h.reply(last(h, 'sessions.subscribe'), replay('s1', 120));
  assert.equal(h.c.stream, 's1');
  assert.equal(h.c.lastSeq, 100);
  for (let s = 101; s <= 120; s++) event(h, s);
  event(h, 120);
  assert.equal(h.events.length, 20);
  assert.deepEqual(h.events.map((e) => e.seq), Array.from({ length: 20 }, (_, i) => 101 + i));
  assert.equal(h.c.lastSeq, 120);
});

test('a snapshot restarts the numbering', () => {
  const h = harness({ whenUp: subscribe });
  h.up();
  h.reply(last(h, 'sessions.subscribe'), snapshot('s1', 500));
  h.down();
  h.up();
  h.reply(last(h, 'sessions.subscribe'), snapshot('s2', 3));
  assert.equal(h.c.stream, 's2');
  assert.equal(h.c.lastSeq, 3);
  event(h, 4);
  event(h, 3);
  assert.deepEqual(h.events.map((e) => e.seq), [4]);
});

test('events are dropped until the first subscribe reply, then repeats are dropped', () => {
  const h = harness({ whenUp: subscribe });
  event(h, 1);
  h.up();
  event(h, 2);
  h.reply(last(h, 'sessions.subscribe'), snapshot('s1', 5));
  event(h, 5);
  event(h, 6);
  event(h, 6);
  event(h, 8);
  event(h, 7);
  assert.deepEqual(h.events.map((e) => e.seq), [6, 8]);
});

test('an event between channel up and the subscribe reply is dropped', () => {
  const h = harness({ whenUp: subscribe });
  h.up();
  h.reply(last(h, 'sessions.subscribe'), snapshot('s1', 10));
  h.down();
  h.up();
  h.app({ kind: 'event', event: 'sessions.changed', seq: 11, data: { rows: [], removedRowIDs: ['stale'] } });
  h.reply(last(h, 'sessions.subscribe'), replay('s1', 12));
  h.app({ kind: 'event', event: 'sessions.changed', seq: 11, data: { rows: [], removedRowIDs: ['replayed'] } });
  event(h, 12);
  assert.deepEqual(h.events.map((e) => e.seq), [11, 12]);
  // The 11 before the reply is not delivered; the replayed 11 is.
  assert.deepEqual(h.events[0], { event: 'sessions.changed', seq: 11, data: { rows: [], removedRowIDs: ['replayed'] } });
});

test('an event whose data does not decode takes its seq and is not handed on', () => {
  const h = harness({ whenUp: subscribe });
  h.up();
  h.reply(last(h, 'sessions.subscribe'), snapshot('s1', 0));
  h.app({ kind: 'event', event: 'sessions.changed', seq: 1, data: { rows: 'not a list', removedRowIDs: [] } });
  event(h, 1);
  event(h, 2);
  assert.deepEqual(h.events.map((e) => e.seq), [2]);
});

test('a subscribe that fails leaves the numbering as it was and events dropped', async () => {
  const h = harness({ whenUp: subscribe });
  h.up();
  h.reply(last(h, 'sessions.subscribe'), snapshot('s1', 10));
  h.down();
  h.up();
  h.fail(last(h, 'sessions.subscribe'), 'internal', 'The sessions list changed while it was read. Try again.');
  event(h, 11);
  const again = h.c.request('sessions.subscribe', { stream: 's1', sinceSeq: 10 });
  h.reply(last(h, 'sessions.subscribe'), { stream: 's9', seq: 'not a number', replayed: false, omittedRows: 0, more: false });
  await assert.rejects(again, { code: 'bad_reply' });
  event(h, 11);
  assert.equal(h.c.stream, 's1');
  assert.equal(h.c.lastSeq, 10);
  assert.deepEqual(h.events, []);
  track(h.c.request('sessions.subscribe', { stream: 's1', sinceSeq: 10 }));
  h.reply(last(h, 'sessions.subscribe'), replay('s1', 11));
  event(h, 11);
  assert.deepEqual(h.events.map((e) => e.seq), [11]);
});

test('state requests in flight at a drop are rejected superseded and never resent', async () => {
  const h = harness();
  h.up();
  const subscribed = h.c.request('sessions.subscribe', {});
  const opened = h.c.request('transcript.open', { session: REF, showDetails: false, resume: false });
  const closed = h.c.request('transcript.close', {});
  const read = track(h.c.request('profiles.list', {}));
  h.down();
  const queued = h.c.request('transcript.open', { session: REF, showDetails: true, resume: false });
  h.up();
  for (const p of [subscribed, opened, closed, queued]) {
    await assert.rejects(p, { code: 'superseded', message: SUPERSEDED_TEXT });
  }
  assert.deepEqual(['r1', 'r2', 'r3', 'r4', 'r5'].map((id) => sends(h, id)), [1, 1, 1, 2, 0]);
  assert.equal(read.state, 'pending');
});

test('a reply to a superseded subscribe that arrives after the new up changes nothing', async () => {
  const h = harness({ whenUp: subscribe });
  h.up();
  h.reply(last(h, 'sessions.subscribe'), snapshot('s1', 10));
  h.down();
  h.up();
  const stale = last(h, 'sessions.subscribe')!;
  h.down();
  h.up();
  const current = last(h, 'sessions.subscribe')!;
  assert.notEqual(current.requestID, stale.requestID);
  h.reply(stale, snapshot('s9', 999));
  h.reply(stale, replay('s1', 12));
  assert.equal(h.c.stream, 's1');
  assert.equal(h.c.lastSeq, 10);
  event(h, 11);
  assert.deepEqual(h.events, []);   // still waiting for the current subscribe's reply
  h.reply(current, replay('s1', 11));
  event(h, 11);
  assert.deepEqual(h.events.map((e) => e.seq), [11]);
});

test('after a drop with 32 unanswered requests, reposts and onUp share the 32 slots', () => {
  const h = harness({ whenUp: subscribe });
  h.up();
  h.reply(last(h, 'sessions.subscribe'), snapshot('s1', 0));
  for (let i = 0; i < 32; i++) track(h.c.request('profiles.list', {}));
  const reads = h.posted.filter((b) => b.method === 'profiles.list');
  assert.equal(reads.length, 32);
  h.down();
  track(h.c.request('remote.providers', {}));
  const mark = h.posted.length;
  h.up();
  const afterUp = h.posted.slice(mark);
  assert.equal(afterUp.length, 32);
  assert.equal(afterUp[0]!.method, 'sessions.subscribe');
  assert.deepEqual(afterUp.slice(1), reads.slice(0, 31));
  // Each reply frees one slot: first the last repost, then the queue.
  h.reply(afterUp[0], replay('s1', 0));
  assert.equal(h.posted.length, mark + 33);
  assert.equal(h.posted.at(-1), reads[31]);
  h.reply(afterUp[1], PROFILES);
  assert.equal(h.posted.length, mark + 34);
  assert.equal(h.posted.at(-1)!.method, 'remote.providers');
});

test('a reply that reaches a request before its repost settles it, and it is not reposted', async () => {
  const h = harness({ whenUp: subscribe });
  h.up();
  h.reply(last(h, 'sessions.subscribe'), snapshot('s1', 0));
  const all = Array.from({ length: 32 }, () => track(h.c.request('profiles.list', {})));
  const lastRead = h.posted.at(-1)!;
  h.down();
  h.up();   // the subscribe and 31 reposts; the 32nd read waits
  // The daemon sends a running request's reply to the connection the phone has now.
  h.reply(lastRead, PROFILES);
  await flush();
  assert.equal(all[31]!.state, 'resolved');
  h.reply(last(h, 'sessions.subscribe'), replay('s1', 0));
  assert.equal(sends(h, lastRead.requestID), 1);
});

test('channel up twice in a row resends nothing twice', () => {
  const h = harness({ whenUp: subscribe });
  h.up();
  h.reply(last(h, 'sessions.subscribe'), snapshot('s1', 0));
  track(h.c.request('message.send', { session: REF, text: 'hi' }));
  const id = last(h, 'message.send')!.requestID;
  h.down();
  h.down();
  h.up();
  h.up();
  confirm(h);
  assert.equal(sends(h, id), 2);
  assert.equal(h.posted.filter((b) => b.method === 'sessions.subscribe').length, 2);
  assert.deepEqual(h.calls, ['up', 'down', 'up']);
});

test('sendFailed offline resends on the next up', async () => {
  const h = harness({ whenUp: subscribe });
  connect(h);   // r1 is the subscribe
  const p = track(h.c.request('message.send', { session: REF, text: 'hi' }));
  h.c.handle({ t: 'sendFailed', reason: 'offline' });
  // Not on this channel, even when something else is posted.
  track(h.c.request('profiles.list', {}));
  assert.deepEqual(h.posted.map((b) => b.requestID), ['r1', 'r2', 'r3']);
  h.down();
  h.up();
  confirm(h);
  assert.deepEqual(h.posted.map((b) => b.requestID), ['r1', 'r2', 'r3', 'r4', 'r3', 'r2']);
  assert.equal(h.posted[5], h.posted[1]);
  h.reply(h.posted[5], { outcome: 'sent' });
  await flush();
  assert.equal(p.state, 'resolved');
});

test('a held request still takes the reply sent before the loader reported it unsent', async () => {
  const h = harness();
  h.up();
  const p = track(h.c.request('profiles.list', {}));
  h.c.handle({ t: 'sendFailed', reason: 'offline' });
  h.reply(h.posted[0], PROFILES);
  await flush();
  assert.equal(p.state, 'resolved');
  h.down();
  h.up();
  assert.equal(sends(h, 'r1'), 1);
});

test('a resend repeats the request ID, method and params exactly', () => {
  const h = harness({ whenUp: subscribe });
  h.up();
  h.reply(last(h, 'sessions.subscribe'), snapshot('s1', 0));
  track(h.c.request('prompt.answer', {
    session: REF, promptID: 'p1', answer: { kind: 'question', answers: { 'Which database?': 'Postgres' } },
  }));
  const first = h.posted.find((b) => b.method === 'prompt.answer')!;
  const json = JSON.stringify(first);
  h.down();
  h.up();
  confirm(h);
  h.down();
  h.up();
  confirm(h);
  const resent = h.posted.filter((b) => b.requestID === first.requestID);
  assert.deepEqual(resent, [first, first, first]);
  for (const body of resent) assert.equal(body, first);
  assert.equal(JSON.stringify(first), json);
});

test('an unanswered request survives any number of drops and takes its one reply', async () => {
  const h = harness({ whenUp: subscribe });
  connect(h);
  const p = track(h.c.request('worktree.create', { repoID: 'R1', message: 'Fix the login loop.' }));
  for (let i = 0; i < 5; i++) {
    h.clock.now += 60_000;
    h.down();
    h.up();
    confirm(h);
  }
  assert.equal(sends(h, last(h, 'worktree.create')!.requestID), 6);
  h.reply(last(h, 'worktree.create'), { worktreeID: 'W1', session: REF });
  h.reply(last(h, 'worktree.create'), { worktreeID: 'W2' });
  await flush();
  assert.deepEqual(p, { state: 'resolved', value: { worktreeID: 'W1', session: REF } });
});

test('reposts still go out when onUp throws', () => {
  let fail = false;
  const h = harness({ whenUp: () => { if (fail) throw new Error('onUp failed'); } });
  h.up();
  track(h.c.request('profiles.list', {}));
  h.down();
  fail = true;
  assert.throws(() => h.up(), /onUp failed/);
  assert.equal(sends(h, 'r1'), 2);
});

// MARK: - Actions wait until the laptop shows it still remembers them

test('a daemon restart (a snapshot of a new stream) rejects a held action, which is posted only once', async () => {
  const h = harness({ whenUp: subscribe });
  connect(h);
  const p = track(h.c.request('message.send', { session: REF, text: 'hi' }));
  const id = last(h, 'message.send')!.requestID;
  h.down();
  h.up();
  assert.equal(sends(h, id), 1);
  h.reply(last(h, 'sessions.subscribe'), snapshot('s2', 0));
  await flush();
  assert.equal(p.state, 'rejected');
  assert.equal((p.error as AppError).code, 'not_confirmed');
  assert.equal((p.error as AppError).message, NOT_CONFIRMED_TEXT);
  assert.equal(h.c.stream, 's2');
  h.down();
  h.up();
  confirm(h);
  assert.equal(sends(h, id), 1);
});

test('a replaying subscribe releases a held action', async () => {
  const h = harness({ whenUp: subscribe });
  connect(h);
  const p = track(h.c.request('worktree.create', { repoID: 'R1', message: 'Fix the login loop.' }));
  const id = last(h, 'worktree.create')!.requestID;
  h.down();
  h.up();
  h.reply(last(h, 'sessions.subscribe'), replay('s1', 4));
  assert.equal(sends(h, id), 2);
  h.reply(last(h, 'worktree.create'), { worktreeID: 'W1' });
  await flush();
  assert.equal(p.state, 'resolved');
});

test('a snapshot of the same stream releases a held action', () => {
  const h = harness({ whenUp: subscribe });
  connect(h);
  track(h.c.request('session.fork', { session: REF }));
  const id = last(h, 'session.fork')!.requestID;
  h.down();
  h.up();
  h.reply(last(h, 'sessions.subscribe'), snapshot('s1', 9));
  assert.equal(sends(h, id), 2);
});

test('with no stream known before, a snapshot rejects a held action', async () => {
  const h = harness({ whenUp: subscribe });
  h.up();   // the first subscribe is never answered
  const p = track(h.c.request('message.send', { session: REF, text: 'hi' }));
  const id = last(h, 'message.send')!.requestID;
  h.down();
  h.up();
  assert.equal(h.c.stream, null);
  h.reply(last(h, 'sessions.subscribe'), snapshot('s1', 0));
  await flush();
  assert.equal(p.state, 'rejected');
  assert.equal((p.error as AppError).code, 'not_confirmed');
  assert.equal(sends(h, id), 1);
});

test('an error reply to the subscribe rejects a held action, never resent, and the action behind it goes', async () => {
  const h = harness({ whenUp: subscribe });
  connect(h);
  const held = track(h.c.request('message.send', { session: REF, text: 'A' }));
  const id = last(h, 'message.send')!.requestID;
  h.down();
  const queued = track(h.c.request('message.send', { session: REF, text: 'B' }));
  h.up();
  assert.equal(h.posted.at(-1)!.method, 'sessions.subscribe');
  h.fail(last(h, 'sessions.subscribe'), 'phone_control_off', 'Phone control is off on this laptop.');
  await flush();
  assert.equal(held.state, 'rejected');
  assert.deepEqual([(held.error as AppError).code, (held.error as AppError).message], ['not_confirmed', NOT_CONFIRMED_TEXT]);
  assert.equal(sends(h, id), 1);
  // B was never sent, so it goes now, and the laptop answers it.
  assert.equal(h.posted.at(-1)!.params.text, 'B');
  h.fail(h.posted.at(-1), 'phone_control_off', 'Phone control is off on this laptop.');
  await flush();
  assert.equal((queued.error as AppError | undefined)?.code, 'phone_control_off');
  // A later good reply has nothing left to release.
  track(h.c.request('sessions.subscribe', { stream: 's1', sinceSeq: 0 }));
  confirm(h);
  assert.equal(sends(h, id), 1);
});

test('a subscribe reply whose result or envelope does not decode rejects a held action too', async () => {
  const unreadable: Array<(h: Harness, subscribeBody: Body) => void> = [
    (h, s) => h.reply(s, { stream: 's1', seq: -0.5, replayed: true, omittedRows: 0, more: false }),
    (h, s) => h.app({ kind: 'reply', requestID: s.requestID, result: replay('s1', 0), error: { code: 'internal', message: 'x' } }),
  ];
  for (const send of unreadable) {
    const h = harness({ whenUp: subscribe });
    connect(h);
    const held = track(h.c.request('session.fork', { session: REF }));
    const id = last(h, 'session.fork')!.requestID;
    h.down();
    h.up();
    send(h, last(h, 'sessions.subscribe')!);
    await flush();
    assert.equal((held.error as AppError | undefined)?.code, 'not_confirmed');
    assert.equal(sends(h, id), 1);
    // Events stay dropped until a subscribe reply decodes.
    event(h, 1);
    assert.deepEqual(h.events, []);
  }
});

test('a failed subscribe rejects only acting reposts: reads and never-sent actions stay', async () => {
  const h = harness({ whenUp: subscribe });
  connect(h);
  const read = track(h.c.request('profiles.list', {}));
  h.down();
  const fresh = track(h.c.request('session.fork', { session: REF }));
  h.up();
  h.fail(last(h, 'sessions.subscribe'), 'internal', 'Something went wrong on the laptop.');
  await flush();
  assert.deepEqual([read.state, fresh.state], ['pending', 'pending']);
  assert.equal(sends(h, 'r2'), 2);
  assert.equal(sends(h, 'r3'), 1);
});

test('reads go out at once, a new action waits behind a held one, and a new stream leaves reads alone', async () => {
  const h = harness({ whenUp: subscribe });
  connect(h);
  const read = track(h.c.request('profiles.list', {}));
  const act = track(h.c.request('message.send', { session: REF, text: 'hi' }));
  const readID = last(h, 'profiles.list')!.requestID;
  h.down();
  const fresh = track(h.c.request('message.send', { session: REF, text: 'Written while offline.' }));
  const freshRead = track(h.c.request('remote.providers', {}));
  const mark = h.posted.length;
  h.up();
  assert.deepEqual(h.posted.slice(mark).map((b) => b.method), ['sessions.subscribe', 'profiles.list', 'remote.providers']);
  assert.equal(h.posted[mark + 1]!.requestID, readID);
  h.reply(last(h, 'sessions.subscribe'), snapshot('s2', 0));
  await flush();
  // The held action is rejected, and only then does the new one go.
  assert.equal(act.state, 'rejected');
  assert.equal((act.error as AppError).code, 'not_confirmed');
  assert.equal(h.posted.at(-1)!.params.text, 'Written while offline.');
  assert.deepEqual([read.state, fresh.state, freshRead.state], ['pending', 'pending', 'pending']);
});

test('an action written while offline goes out after the held action, not before', () => {
  const h = harness({ whenUp: subscribe });
  connect(h);
  track(h.c.request('message.send', { session: REF, text: 'A' }));
  const a = last(h, 'message.send')!;
  h.down();
  track(h.c.request('message.send', { session: REF, text: 'B' }));
  const mark = h.posted.length;
  h.up();
  assert.deepEqual(h.posted.slice(mark).map((b) => b.method), ['sessions.subscribe']);
  confirm(h);
  assert.deepEqual(h.posted.slice(mark + 1).map((b) => b.params.text), ['A', 'B']);
  assert.equal(h.posted[mark + 1], a);
  assert.deepEqual(h.posted.filter((b) => b.method === 'message.send').map((b) => b.params.text), ['A', 'A', 'B']);
});

test('an action made between channel up and the subscribe reply waits behind the held one', () => {
  const h = harness({ whenUp: subscribe });
  connect(h);
  track(h.c.request('message.send', { session: REF, text: 'A' }));
  h.down();
  h.up();
  track(h.c.request('message.send', { session: REF, text: 'C' }));
  track(h.c.request('profiles.list', {}));
  assert.equal(h.posted.at(-1)!.method, 'profiles.list');
  const mark = h.posted.length;
  confirm(h);
  assert.deepEqual(h.posted.slice(mark).map((b) => b.params.text), ['A', 'C']);
});

test('an action made while an earlier one is held after sendFailed offline waits for it', () => {
  const h = harness({ whenUp: subscribe });
  connect(h);
  track(h.c.request('message.send', { session: REF, text: 'A' }));
  h.c.handle({ t: 'sendFailed', reason: 'offline' });
  track(h.c.request('message.send', { session: REF, text: 'B' }));
  track(h.c.request('profiles.list', {}));
  assert.deepEqual(h.posted.slice(1).map((b) => b.params.text ?? b.method), ['A', 'profiles.list']);
  h.down();
  h.up();
  const mark = h.posted.length;
  confirm(h);
  assert.deepEqual(h.posted.slice(mark).map((b) => b.params.text), ['A', 'B']);
});

test('an action released before the horizon that waits for a slot past it is not resent', async () => {
  const h = harness({
    whenUp: (c) => {
      subscribe(c);
      if (c.lastSeq !== null) track(c.request('transcript.open', { session: REF, showDetails: false, resume: true }));
    },
  });
  connect(h);
  h.clock.now = 0;
  for (let i = 0; i < 31; i++) track(h.c.request('profiles.list', {}));
  const act = track(h.c.request('worktree.create', { repoID: 'R1', message: 'Fix the login loop.' }));
  const id = last(h, 'worktree.create')!.requestID;
  const reads = h.posted.filter((b) => b.method === 'profiles.list');
  h.down();
  h.clock.now = 400_000;
  h.up();   // the subscribe, the open and 29 reads; the held action holds the last slot
  h.clock.now = 500_000;
  confirm(h);   // releases the action; the two reads sent before it take the two free slots
  assert.equal(h.posted.at(-1), reads[30]);
  assert.equal(sends(h, id), 1);
  h.clock.now = 540_001;
  h.reply(reads[0], PROFILES);   // a slot frees, past the horizon
  await flush();
  assert.equal(act.state, 'rejected');
  assert.equal((act.error as AppError).code, 'not_confirmed');
  assert.equal(sends(h, id), 1);
});

test('the horizon still applies when a held action is released', async () => {
  const h = harness({ whenUp: subscribe });
  connect(h);
  h.clock.now = 0;
  const p = track(h.c.request('remote.create', { provider: 'acme-cloud', repoID: 'R1', message: 'hi', strings: {}, bools: {} }));
  const id = last(h, 'remote.create')!.requestID;
  h.down();
  h.clock.now = 500_000;
  h.up();
  h.clock.now = 540_001;
  confirm(h);
  await flush();
  assert.equal(p.state, 'rejected');
  assert.equal((p.error as AppError).code, 'not_confirmed');
  assert.equal(sends(h, id), 1);
});

test('a reply that reaches a held action before the subscribe reply settles it', async () => {
  const h = harness({ whenUp: subscribe });
  connect(h);
  const p = track(h.c.request('message.send', { session: REF, text: 'hi' }));
  const first = last(h, 'message.send')!;
  h.down();
  h.up();
  h.reply(first, { outcome: 'sent' });   // the first run's reply, sent to the new connection
  confirm(h);
  await flush();
  assert.equal(p.state, 'resolved');
  assert.equal(sends(h, first.requestID), 1);
});

test('a released action still waiting for a slot at a drop waits for the next subscribe reply again', async () => {
  const h = harness({
    whenUp: (c) => {
      subscribe(c);
      if (c.lastSeq !== null) track(c.request('transcript.open', { session: REF, showDetails: false, resume: true }));
    },
  });
  connect(h);
  for (let i = 0; i < 30; i++) track(h.c.request('profiles.list', {}));
  const acts = [
    track(h.c.request('message.send', { session: REF, text: 'one' })),
    track(h.c.request('message.send', { session: REF, text: 'two' })),
  ];
  const ids = h.posted.filter((b) => b.method === 'message.send').map((b) => b.requestID);
  h.down();
  h.up();   // the subscribe, the open and 28 reads; the two held actions hold the last two slots
  // Three slots free: the two reads first sent before the actions, then the first action.
  confirm(h);
  assert.deepEqual(ids.map((id) => sends(h, id)), [2, 1]);
  h.down();
  h.up();
  assert.deepEqual(ids.map((id) => sends(h, id)), [2, 1]);
  h.reply(last(h, 'sessions.subscribe'), snapshot('s2', 0));
  await flush();
  assert.deepEqual(acts.map((a) => (a.error as AppError | undefined)?.code), ['not_confirmed', 'not_confirmed']);
  assert.deepEqual(ids.map((id) => sends(h, id)), [2, 1]);
});

test('reposts go out in first-send order across two drops with more than 32 unanswered', () => {
  const h = harness({
    whenUp: (c) => {
      subscribe(c);
      if (c.lastSeq !== null) track(c.request('transcript.open', { session: REF, showDetails: false, resume: true }));
    },
  });
  connect(h);
  track(h.c.request('message.send', { session: REF, text: 'first action' }));
  for (let i = 0; i < 31; i++) track(h.c.request('profiles.list', {}));
  track(h.c.request('remote.providers', {}));
  track(h.c.request('message.send', { session: REF, text: 'later action' }));
  const reads = h.posted.filter((b) => b.method === 'profiles.list');
  assert.equal(h.posted.length, 33);   // the first subscribe, then 32; a read and an action wait
  for (let drop = 0; drop < 2; drop++) {
    h.down();
    const mark = h.posted.length;
    h.up();   // the subscribe, the open and 29 reads; the held action holds the last slot
    assert.deepEqual(h.posted.slice(mark + 2), reads.slice(0, 29));
  }
  const mark = h.posted.length;
  // Two slots free. The action was first sent before the waiting reads, so it goes first.
  confirm(h);
  h.reply(reads[0], PROFILES);
  h.reply(reads[1], PROFILES);
  h.reply(reads[2], PROFILES);
  assert.deepEqual(h.posted.slice(mark).map((b) => b.params.text ?? b.method),
    ['first action', 'profiles.list', 'profiles.list', 'remote.providers', 'later action']);
  assert.deepEqual(h.posted.slice(mark + 1, mark + 3), reads.slice(29, 31));
});

test('acting reposts waiting for the subscribe reply hold slots, from all but onUp', () => {
  const h = harness({ whenUp: subscribe });
  connect(h);
  track(h.c.request('message.send', { session: REF, text: 'one' }));
  const one = last(h, 'message.send')!;
  track(h.c.request('message.send', { session: REF, text: 'two' }));
  h.down();
  const mark = h.posted.length;
  h.up();   // the subscribe goes; the two actions wait for its reply
  for (let i = 0; i < 31; i++) track(h.c.request('profiles.list', {}));
  // The subscribe and 29 reads: the two waiting actions hold the other two slots.
  assert.deepEqual(h.posted.slice(mark).map((b) => b.method), ['sessions.subscribe', ...Array<string>(29).fill('profiles.list')]);
  confirm(h);   // the actions go out in the slots they held, and the subscribe's slot takes a read
  assert.deepEqual(h.posted.slice(mark + 30).map((b) => b.params.text ?? b.method), ['one', 'two', 'profiles.list']);
  assert.equal(h.posted[mark + 30], one);
  assert.equal(h.posted.length, mark + 33);
});

// MARK: - The refused stopgap and the clock

test("a refused reply to a repost of an action reads as not_confirmed", async () => {
  const h = harness({ whenUp: subscribe });
  connect(h);
  const p = h.c.request('message.send', { session: REF, text: 'hi' });
  h.down();
  h.up();
  confirm(h);
  h.fail(last(h, 'message.send'), 'refused', 'Too many requests are in progress. Try again in a moment.');
  await assert.rejects(p, { code: 'not_confirmed', message: NOT_CONFIRMED_TEXT });
});

test("a refused reply to an action posted once, or to a reposted read, keeps the daemon's words", async () => {
  const h = harness({ whenUp: subscribe });
  connect(h);
  const act = h.c.request('message.send', { session: REF, text: 'hi' });
  h.fail(last(h, 'message.send'), 'refused', 'This session has exited.');
  await assert.rejects(act, { code: 'refused', message: 'This session has exited.' });
  const read = h.c.request('profiles.list', {});
  h.down();
  h.up();
  h.fail(last(h, 'profiles.list'), 'refused', 'Too many requests are in progress. Try again in a moment.');
  await assert.rejects(read, { code: 'refused', message: 'Too many requests are in progress. Try again in a moment.' });
});

test('the default clock counts wall time through a suspension, and monotonic time through a step back', async (t) => {
  let wall = 1_762_500_000_000;
  let mono = 5_000;
  t.mock.method(Date, 'now', () => wall);
  t.mock.method(performance, 'now', () => mono);
  /** Sends an action, drops the channel, moves the clocks, and reconnects. */
  const run = async (move: () => void) => {
    const h = harness({ now: undefined, whenUp: subscribe });
    connect(h);
    const p = track(h.c.request('message.send', { session: REF, text: 'hi' }));
    const id = last(h, 'message.send')!.requestID;
    h.down();
    move();
    h.up();
    confirm(h);
    await flush();
    return { state: p.state, sends: sends(h, id) };
  };
  // Suspended: the monotonic clock stopped while 540,001 ms of wall time passed.
  assert.deepEqual(await run(() => { wall += 540_001; }), { state: 'rejected', sends: 1 });
  // The wall clock stepped back an hour while 540,001 ms passed.
  assert.deepEqual(await run(() => { wall -= 3_600_000; mono += 540_001; }), { state: 'rejected', sends: 1 });
  // Both say 540,000 ms passed: still within the horizon.
  assert.deepEqual(await run(() => { wall += 540_000; mono += 540_000; }), { state: 'pending', sends: 2 });
});
