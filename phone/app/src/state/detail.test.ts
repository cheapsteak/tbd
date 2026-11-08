// Tests detail.ts, the chunk rules of a transcript row's detail, and `toggleDetail`, which sends
// the requests and folds each reply in. The laptop's numbers are untrusted, so most of these
// feed `addChunk` replies an honest laptop never sends, and check that the phone neither asks
// without end nor holds without bound. The action tests use a fake client that records each
// request and hands back a promise the test settles; the store and the actions are real.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { chunkText } from '../../test/e2e/fake-laptop-app.js';
import { AppError, BAD_REPLY_TEXT, SUPERSEDED_TEXT } from '../client/client.ts';
import { createActions } from '../actions/index.ts';
import type { Method, ParamsOf, PhoneItem, PhoneSessionRef, ResultOf, TranscriptDetailPart, TranscriptDetailResult } from '../protocol/types.ts';
import { utf8Length } from '../limits.ts';
import {
  addChunk, askOf, cancelDetail, DETAIL_CHUNK_BYTES, DETAIL_LIMIT_BYTES, detailParts, failDetail, MAX_DETAIL_CHUNKS,
  MAX_SUBAGENT_ITEMS, startDetail,
} from './detail.ts';
import type { DetailAsk, DetailState } from './detail.ts';
import { createStore, initialState } from './store.ts';
import { applyPage, applyTranscriptEvent, beginOpen, beginResume, emptyTranscript } from './transcript.ts';
import type { TranscriptState } from './transcript.ts';

const SWIFT_CONSTANTS = new URL('../../../../Sources/TBDDaemon/PhoneBridge/App/PhoneAppConstants.swift', import.meta.url);
const NOT_FOUND_TEXT = 'That detail is not in the transcript.';
const R: PhoneSessionRef = { kind: 'local', terminalID: 'T-R' };
const OTHER: PhoneSessionRef = { kind: 'local', terminalID: 'T-other' };

/** A reply to `ask`, as an honest laptop sends it, with `over` changing any field. */
function reply(ask: DetailAsk, chunkCount: number, over: Partial<TranscriptDetailResult> = {}): TranscriptDetailResult {
  const r: TranscriptDetailResult = { itemID: 'i1', part: ask.part, chunk: ask.chunk, chunkCount, totalBytes: 0, tooLarge: false, ...over };
  if (r.text === undefined && r.items === undefined) {
    if (ask.part === 'subagent') r.items = [];
    else r.text = `${ask.part}${ask.chunk}`;
  }
  return r;
}

/**
 * Feeds `d` the reply `answer` gives for each request, until it asks for nothing or `limit`
 * requests went out. Returns the detail and every request it made, the first included.
 */
function run(d: DetailState, answer: (ask: DetailAsk) => TranscriptDetailResult, limit = 10_000) {
  const asks: DetailAsk[] = [askOf(d)];
  let ask: DetailAsk | null = askOf(d);
  while (ask !== null) {
    if (asks.length > limit) assert.fail(`more than ${limit} requests`);
    const step = addChunk(d, answer(ask));
    d = step.next;
    ask = step.ask;
    if (ask !== null) asks.push(ask);
  }
  return { d, asks };
}

function tool(id: string, toolStatus = 'ok'): PhoneItem {
  return { id, kind: 'tool', truncated: false, toolName: 'Bash', target: 'npm test', toolStatus };
}

function nested(i: number, text = ''): PhoneItem {
  return { id: `n${i}`, kind: 'assistant', text, truncated: false };
}

// MARK: - The chunk rules

test('chunks join in order and stop at chunkCount', () => {
  const { d, asks } = run(startDetail(['text']), (ask) => reply(ask, 3));
  assert.deepEqual(asks, [{ part: 'text', chunk: 0 }, { part: 'text', chunk: 1 }, { part: 'text', chunk: 2 }]);
  assert.equal(d.text.text, 'text0text1text2');
  assert.equal(d.phase, 'open');
  assert.equal(d.chunkCount, 3);
});

test('a tool row fetches its input, then its result', () => {
  const parts = detailParts('input', tool('t1'));
  assert.deepEqual(parts, ['input', 'result']);
  const { d, asks } = run(startDetail(parts), (ask) => reply(ask, ask.part === 'input' ? 2 : 1));
  assert.deepEqual(asks, [{ part: 'input', chunk: 0 }, { part: 'input', chunk: 1 }, { part: 'result', chunk: 0 }]);
  assert.deepEqual(d.text, { input: 'input0input1', result: 'result0' });
  assert.equal(d.phase, 'open');
});

test('each other part loads itself, and a running tool loads its input alone', () => {
  assert.deepEqual(detailParts('text', nested(1)), ['text']);
  assert.deepEqual(detailParts('subagent', nested(1)), ['subagent']);
  assert.deepEqual(detailParts('input', tool('t1', 'running')), ['input']);
  assert.deepEqual(detailParts('input', tool('t1', 'error')), ['input', 'result']);
});

test('tooLarge keeps the first chunk and asks for nothing more', () => {
  const step = addChunk(startDetail(['input', 'result']), reply({ part: 'input', chunk: 0 }, 1, { text: 'first', tooLarge: true }));
  assert.equal(step.ask, null);
  assert.equal(step.next.phase, 'tooLarge');
  assert.deepEqual(step.next.text, { input: 'first' });
  // Not of that part, and not of a later one: the result is never asked for.
  const later = addChunk(startDetail(['input']), reply({ part: 'input', chunk: 0 }, 3, { tooLarge: true }));
  assert.equal(later.ask, null);
  assert.equal(later.next.phase, 'tooLarge');
});

test('a collapsed detail drops later replies and asks for nothing', () => {
  const d = cancelDetail(addChunk(startDetail(['text']), reply({ part: 'text', chunk: 0 }, 3)).next);
  assert.equal(d.cancelled, true);
  assert.deepEqual(d.text, {});
  const step = addChunk(d, reply({ part: 'text', chunk: 1 }, 3));
  assert.equal(step.next, d);
  assert.equal(step.ask, null);
  assert.equal(failDetail(d, 'x'), d);
});

test('a detail that ended takes no more replies', () => {
  for (const ended of [run(startDetail(['text']), (ask) => reply(ask, 1)).d, failDetail(startDetail(['text']), 'x')]) {
    const step = addChunk(ended, reply({ part: 'text', chunk: 0 }, 1));
    assert.equal(step.next, ended);
    assert.equal(step.ask, null);
  }
});

// MARK: - The laptop's numbers

test('a reply for another part or chunk is not added, and fails as a reply the app cannot read', () => {
  const asked = addChunk(startDetail(['input', 'result']), reply({ part: 'input', chunk: 0 }, 2)).next;
  for (const wrong of [{ part: 'result' as TranscriptDetailPart }, { chunk: 0 }, { chunk: 2 }, { chunk: -1 }, { chunk: 1.5 }]) {
    const step = addChunk(asked, reply(askOf(asked), 2, wrong));
    assert.equal(step.ask, null, JSON.stringify(wrong));
    assert.equal(step.next.phase, 'failed');
    assert.equal(step.next.error, BAD_REPLY_TEXT);
    assert.deepEqual(step.next.text, { input: 'input0' }, 'what arrived before stays, and the bad reply is not added');
  }
});

test('a reply with no text for a text part, or no items for a subagent, fails', () => {
  const text = addChunk(startDetail(['text']), { itemID: 'i1', part: 'text', chunk: 0, chunkCount: 1, totalBytes: 0, tooLarge: false, items: [] });
  assert.equal(text.next.error, BAD_REPLY_TEXT);
  const agent = addChunk(startDetail(['subagent']), { itemID: 'i1', part: 'subagent', chunk: 0, chunkCount: 1, totalBytes: 0, tooLarge: false, text: 'x' });
  assert.equal(agent.next.error, BAD_REPLY_TEXT);
});

test('a chunkCount that is not a positive integer fails the detail and never throws', () => {
  for (const chunkCount of [0, -1, -1e9, 1.5, Number.NaN, Infinity, -Infinity, 2 ** 53]) {
    const step = addChunk(startDetail(['text']), reply({ part: 'text', chunk: 0 }, chunkCount));
    assert.equal(step.ask, null, String(chunkCount));
    assert.equal(step.next.phase, 'failed', String(chunkCount));
    assert.equal(step.next.error, BAD_REPLY_TEXT);
  }
});

test('an absurd chunkCount keeps the first chunk as too large and asks for nothing more', () => {
  for (const chunkCount of [MAX_DETAIL_CHUNKS + 1, 1e9, Number.MAX_SAFE_INTEGER]) {
    const step = addChunk(startDetail(['input', 'result']), reply({ part: 'input', chunk: 0 }, chunkCount));
    assert.equal(step.ask, null, String(chunkCount));
    assert.equal(step.next.phase, 'tooLarge');
    assert.deepEqual(step.next.text, { input: 'input0' });
  }
});

test('the phone asks for at most MAX_DETAIL_CHUNKS chunks of a part, whatever the laptop says', () => {
  // Empty chunks never reach the byte limit, so only the count stops them.
  const { d, asks } = run(startDetail(['text']), (ask) => reply(ask, MAX_DETAIL_CHUNKS, { text: '' }));
  assert.equal(asks.length, MAX_DETAIL_CHUNKS);
  assert.equal(d.phase, 'open');
  // A later reply cannot raise the count its part's first reply set.
  const raised = run(startDetail(['text', 'result']), (ask) => reply(ask, ask.part === 'result' ? 1 : ask.chunk === 0 ? 2 : 1e9));
  assert.deepEqual(raised.asks, [{ part: 'text', chunk: 0 }, { part: 'text', chunk: 1 }, { part: 'result', chunk: 0 }]);
  assert.equal(raised.d.phase, 'open');
});

test('a text part over 1 MB in UTF-8 is too large, whatever tooLarge and chunkCount say', () => {
  // 30,000 é take 60,000 bytes, so the 18th chunk passes 1,048,576 bytes while the text holds
  // only 540,000 UTF-16 units.
  const chunk = 'é'.repeat(30_000);
  const { d, asks } = run(startDetail(['input', 'result']), (ask) => reply(ask, 100, { text: chunk }));
  assert.equal(asks.length, 18);
  assert.ok(asks.every((a) => a.part === 'input'));
  assert.equal(d.phase, 'tooLarge');
  assert.equal(d.text.input?.length, 18 * 30_000);
  assert.equal(d.bytes, 18 * 60_000);
  assert.ok(d.bytes <= DETAIL_LIMIT_BYTES + 65_519, 'a part holds at most the limit and one frame');
});

test('the 1 MB limit counts each part on its own', () => {
  const full = 'x'.repeat(DETAIL_CHUNK_BYTES);
  // Each part holds 16 chunks of 60,000 bytes, 960,000 bytes, so 1,920,000 in all.
  const { d, asks } = run(startDetail(['input', 'result']), (ask) => reply(ask, 16, { text: full }));
  assert.equal(asks.length, 32);
  assert.equal(d.phase, 'open');
  assert.equal(utf8Length(d.text.input ?? '') + utf8Length(d.text.result ?? ''), 32 * DETAIL_CHUNK_BYTES);
});

test('a text exactly at the limit is not too large', () => {
  const { d } = run(startDetail(['text']), (ask) => reply(ask, 2, { text: 'x'.repeat(DETAIL_LIMIT_BYTES / 2) }));
  assert.equal(d.phase, 'open');
  assert.equal(d.bytes, DETAIL_LIMIT_BYTES);
});

test('subagent items join across chunks and are capped in number', () => {
  const items = (ask: DetailAsk) => Array.from({ length: 400 }, (_, i) => nested(ask.chunk * 400 + i));
  const { d, asks } = run(startDetail(['subagent']), (ask) => reply(ask, 5, { items: items(ask) }));
  assert.equal(asks.length, 3);
  assert.equal(d.phase, 'tooLarge');
  assert.equal(d.items.length, MAX_SUBAGENT_ITEMS);
  assert.deepEqual(d.items.slice(398, 402).map((it) => it.id), ['n398', 'n399', 'n400', 'n401']);
  assert.equal(d.items.at(-1)?.id, `n${MAX_SUBAGENT_ITEMS - 1}`);
});

test('subagent items are capped in size', () => {
  // 50 items of 10,000 bytes each are about 500 KB a chunk, so the third chunk passes 1 MB.
  const items = (ask: DetailAsk) => Array.from({ length: 50 }, (_, i) => nested(ask.chunk * 50 + i, 'é'.repeat(5_000)));
  const { d, asks } = run(startDetail(['subagent']), (ask) => reply(ask, 40, { items: items(ask) }));
  assert.equal(asks.length, 3);
  assert.equal(d.phase, 'tooLarge');
  assert.equal(d.items.length, 150);
  assert.ok(d.bytes > DETAIL_LIMIT_BYTES);
});

test('a subagent within the caps opens with every item, in order', () => {
  const { d } = run(startDetail(['subagent']), (ask) => reply(ask, 2, { items: [nested(ask.chunk * 2), nested(ask.chunk * 2 + 1)] }));
  assert.equal(d.phase, 'open');
  assert.deepEqual(d.items.map((it) => it.id), ['n0', 'n1', 'n2', 'n3']);
});

test("the limits mirror the daemon's", () => {
  const swift = readFileSync(SWIFT_CONSTANTS, 'utf8');
  const value = (pattern: RegExp): number => {
    const digits = pattern.exec(swift)?.[1];
    if (digits === undefined) throw new Error(`PhoneAppConstants.swift has no match for ${pattern}`);
    return Number(digits.replaceAll('_', ''));
  };
  assert.equal(DETAIL_LIMIT_BYTES, value(/static let detailLimitBytes = ([\d_]+)/));
  assert.equal(DETAIL_CHUNK_BYTES, value(/static let detailChunkBytes = ([\d_]+)/));
  assert.equal(MAX_DETAIL_CHUNKS, 105);
});

test('MAX_DETAIL_CHUNKS takes every chunk of the most finely cut text within the limit', () => {
  // A control character escapes to 6 bytes from 1, the most any scalar grows, so a text of
  // them cuts into the most chunks. The fake laptop cuts as the daemon does.
  for (const text of ['\u0001'.repeat(DETAIL_LIMIT_BYTES), `x${'\u0001'.repeat(DETAIL_LIMIT_BYTES - 1)}`]) {
    const chunks: string[] = chunkText(text, DETAIL_CHUNK_BYTES, Infinity);
    assert.ok(chunks.length <= MAX_DETAIL_CHUNKS, `${chunks.length} chunks`);
    const { d, asks } = run(startDetail(['result']), (ask) => reply(ask, chunks.length, { text: chunks[ask.chunk]! }));
    assert.equal(asks.length, chunks.length);
    assert.equal(d.phase, 'open');
    assert.equal(d.text.result, text);
  }
});

// MARK: - toggleDetail

interface Sent {
  method: Method;
  params: any;
  resolve(result: unknown): void;
  reject(error: unknown): void;
}

/** A store showing `R`'s transcript with `items`, and the actions over a fake client. */
function harness(items: PhoneItem[] = [tool('t1'), nested(9)]) {
  const sent: Sent[] = [];
  const client = {
    stream: null as string | null,
    lastSeq: null as number | null,
    request<M extends Method>(method: M, params: ParamsOf<M>): Promise<ResultOf<M>> {
      return new Promise<ResultOf<M>>((resolve, reject) => {
        sent.push({ method, params, resolve: resolve as (result: unknown) => void, reject });
      });
    },
  };
  const opened = applyPage(beginOpen(emptyTranscript(), R, false, 'open-1'), { items, reachedStart: true, omittedItems: 0 });
  const store = createStore({ ...initialState(), transcript: { ...opened, phase: 'open' } });
  const actions = createActions({ store, client, link: { openLink: () => {} }, now: () => 0 });
  const t = (): TranscriptState => store.get().transcript;
  const key = (i: number): number => t().rows[i]!.key;
  return {
    sent, store, actions, t, key,
    /** The `transcript.detail` requests, as `[part, chunk]`. */
    asked: (): Array<[string, number]> => sent.filter((s) => s.method === 'transcript.detail').map((s) => [s.params.part, s.params.chunk]),
    last: (): Sent => sent.at(-1)!,
    setTranscript: (fn: (t: TranscriptState) => TranscriptState) => store.update((s) => ({ ...s, transcript: fn(s.transcript) })),
  };
}

/** Lets the promise handlers run. */
function flush(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

/** An honest reply to request `s`. */
function answer(s: Sent, chunkCount: number, over: Partial<TranscriptDetailResult> = {}): void {
  s.resolve(reply({ part: s.params.part, chunk: s.params.chunk }, chunkCount, { itemID: s.params.itemID, ...over }));
}

test('toggleDetail asks for one chunk at a time, for the row it was tapped on', async () => {
  const h = harness();
  const done = h.actions.toggleDetail(h.key(0), 'input');
  assert.deepEqual(h.sent.map((s) => s.params), [{ session: R, itemID: 't1', part: 'input', chunk: 0 }]);
  assert.equal(h.t().details[h.key(0)]?.phase, 'loading');
  answer(h.last(), 2);
  await flush();
  assert.deepEqual(h.asked(), [['input', 0], ['input', 1]]);
  answer(h.last(), 2);
  await flush();
  assert.deepEqual(h.asked(), [['input', 0], ['input', 1], ['result', 0]]);
  answer(h.last(), 1);
  await done;
  const d = h.t().details[h.key(0)]!;
  assert.equal(d.phase, 'open');
  assert.deepEqual(d.text, { input: 'input0input1', result: 'result0' });
});

test("not_found ends the detail with the daemon's message", async () => {
  const h = harness();
  const done = h.actions.toggleDetail(h.key(0), 'input');
  h.last().reject(new AppError('not_found', NOT_FOUND_TEXT));
  await done;
  const d = h.t().details[h.key(0)]!;
  assert.equal(d.phase, 'failed');
  assert.equal(d.error, NOT_FOUND_TEXT);
  assert.equal(h.sent.length, 1);
});

test('an error on a later part keeps what arrived', async () => {
  const h = harness();
  const done = h.actions.toggleDetail(h.key(0), 'input');
  answer(h.last(), 1);
  await flush();
  h.last().reject(new AppError('not_found', NOT_FOUND_TEXT));
  await done;
  const d = h.t().details[h.key(0)]!;
  assert.equal(d.phase, 'failed');
  assert.deepEqual(d.text, { input: 'input0' });
});

test('a tap after a failure starts over', async () => {
  const h = harness();
  const first = h.actions.toggleDetail(h.key(0), 'input');
  h.last().reject(new AppError('not_found', NOT_FOUND_TEXT));
  await first;
  const again = h.actions.toggleDetail(h.key(0), 'input');
  assert.deepEqual(h.asked(), [['input', 0], ['input', 0]]);
  assert.equal(h.t().details[h.key(0)]?.phase, 'loading');
  answer(h.last(), 1);
  await flush();
  answer(h.last(), 1);
  await again;
  assert.equal(h.t().details[h.key(0)]?.phase, 'open');
});

test('collapsing stops the next chunk request', async () => {
  const h = harness();
  const done = h.actions.toggleDetail(h.key(0), 'input');
  await h.actions.toggleDetail(h.key(0), 'input');
  const collapsed = h.t().details[h.key(0)]!;
  assert.equal(collapsed.cancelled, true);
  answer(h.last(), 3);
  await done;
  assert.deepEqual(h.asked(), [['input', 0]]);
  assert.equal(h.t().details[h.key(0)], collapsed, 'the late reply changed nothing');
});

test('a tap on an open detail collapses it, and the next tap loads it afresh', async () => {
  const h = harness();
  const done = h.actions.toggleDetail(h.key(0), 'input');
  answer(h.last(), 1);
  await flush();
  answer(h.last(), 1);
  await done;
  await h.actions.toggleDetail(h.key(0), 'input');
  assert.equal(h.t().details[h.key(0)]?.cancelled, true);
  assert.equal(h.sent.length, 2);
  void h.actions.toggleDetail(h.key(0), 'input');
  assert.deepEqual(h.asked(), [['input', 0], ['result', 0], ['input', 0]]);
  assert.equal(h.t().details[h.key(0)]?.cancelled, false);
});

test('a too-large detail collapses with a tap', async () => {
  const h = harness();
  const done = h.actions.toggleDetail(h.key(0), 'input');
  answer(h.last(), 1, { tooLarge: true });
  await done;
  assert.equal(h.t().details[h.key(0)]?.phase, 'tooLarge');
  await h.actions.toggleDetail(h.key(0), 'input');
  assert.equal(h.t().details[h.key(0)]?.cancelled, true);
  assert.equal(h.sent.length, 1);
});

test('a reply for another item fails the detail as a reply the app cannot read', async () => {
  const h = harness();
  const done = h.actions.toggleDetail(h.key(0), 'input');
  answer(h.last(), 3, { itemID: 'someone-else' });
  await done;
  const d = h.t().details[h.key(0)]!;
  assert.equal(d.phase, 'failed');
  assert.equal(d.error, BAD_REPLY_TEXT);
  assert.deepEqual(d.text, {});
  assert.equal(h.sent.length, 1);
});

test('two rows load their details side by side, each one chunk at a time', async () => {
  const h = harness([tool('t1'), tool('t2')]);
  const one = h.actions.toggleDetail(h.key(0), 'input');
  const two = h.actions.toggleDetail(h.key(1), 'input');
  assert.deepEqual(h.sent.map((s) => s.params.itemID), ['t1', 't2']);
  answer(h.sent[1]!, 1);
  await flush();
  assert.deepEqual(h.sent.map((s) => [s.params.itemID, s.params.part]), [['t1', 'input'], ['t2', 'input'], ['t2', 'result']]);
  answer(h.sent[0]!, 1);
  answer(h.sent[2]!, 1);
  await flush();
  answer(h.sent[3]!, 1);
  await Promise.all([one, two]);
  assert.equal(h.t().details[h.key(0)]?.phase, 'open');
  assert.equal(h.t().details[h.key(1)]?.phase, 'open');
});

test('a reply that lands after a reset, a reopen, a close or a switch does not touch the new slice', async () => {
  const replace: Array<[string, (t: TranscriptState) => TranscriptState]> = [
    ['reset', (t) => applyTranscriptEvent(t, {
      event: 'transcript.reset', seq: 30, data: { session: R, reason: 'rewrite', page: { items: [tool('t1')], reachedStart: true, omittedItems: 0 } },
    })],
    ['reopen, still opening', (t) => beginOpen(t, R, true, 'open-2')],
    ['close', (t) => ({ ...emptyTranscript(), nextKey: t.nextKey, pendingClose: true })],
    ['switch', (t) => beginOpen(t, OTHER, false, 'open-2')],
  ];
  for (const [what, fn] of replace) {
    const h = harness();
    const done = h.actions.toggleDetail(h.key(0), 'input');
    h.setTranscript(fn);
    const after = h.t();
    answer(h.last(), 3);
    await done;
    assert.equal(h.t(), after, what);
    assert.deepEqual(h.asked(), [['input', 0]], what);
  }
});

test('a resume keeps the rows, so a detail on its way carries on', async () => {
  const h = harness();
  const done = h.actions.toggleDetail(h.key(0), 'input');
  h.setTranscript((t) => beginResume(t, 'resume-1'));
  answer(h.last(), 1);
  await flush();
  assert.deepEqual(h.asked(), [['input', 0], ['result', 0]]);
  answer(h.last(), 1);
  await done;
  assert.equal(h.t().details[h.key(0)]?.phase, 'open');
});

test('a superseded detail request closes the row silently', async () => {
  const h = harness();
  const done = h.actions.toggleDetail(h.key(0), 'input');
  h.last().reject(new AppError('superseded', SUPERSEDED_TEXT));
  await done;
  assert.equal(h.t().details[h.key(0)], undefined);
});

test('toggleDetail does nothing for a receipt, a row that is gone, or a transcript not open', async () => {
  const h = harness();
  h.setTranscript((t) => ({ ...t, rows: [...t.rows, { key: 99, kind: 'receipt', id: 'p1', text: 'Answered on this phone' }] }));
  await h.actions.toggleDetail(99, 'input');
  await h.actions.toggleDetail(12_345, 'input');
  h.setTranscript((t) => beginOpen(t, R, false, 'open-2'));
  await h.actions.toggleDetail(h.key(0), 'input');
  assert.deepEqual(h.sent, []);
  assert.deepEqual(h.t().details, {});
});

test('toggleDetail resolves on a bad reply and never rejects', async () => {
  const h = harness();
  const done = h.actions.toggleDetail(h.key(0), 'input');
  answer(h.last(), Number.NaN);
  await done;
  assert.equal(h.t().details[h.key(0)]?.error, BAD_REPLY_TEXT);
});
