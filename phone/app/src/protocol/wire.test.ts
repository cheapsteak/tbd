// Tests the protocol decoders' rules (absent stays absent, unknown fields drop, enums and
// integers are checked, paths are dotted), the envelope, request bodies and session-reference
// keys, and checks the name lists against the Swift enums they mirror.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { obj, record, str } from './decode.ts';
import {
  decodeEnvelope, decodeEventData, decodeParams, decodePhoneGroupLayout, decodePhonePrompt, decodePhoneRow,
  decodePhoneSessionRef, decodePhoneStatus, decodePhoneStatusChip, decodePromptAnswer, decodePromptAnswerResult,
  decodeResult, DecodeError, ERROR_CODES, EVENTS, METHODS, PENDING_PROMPT_KINDS, PERMISSION_DECISIONS,
  PHONE_AGENTS, PHONE_ANSWERED_BY, PHONE_ITEM_KINDS, PHONE_STATUS_CHIPS, PROMPT_ANSWER_OUTCOMES, refKey,
  requestBody, sameRef, TRANSCRIPT_DETAIL_PARTS,
} from './wire.ts';
import type { Method, ParamsOf, PhoneSessionRef } from './types.ts';

const SOURCES = new URL('../../../../Sources/', import.meta.url);
const PROTOCOL_DIR = new URL('../../../protocol/', import.meta.url);

const LOCAL: PhoneSessionRef = { kind: 'local', terminalID: '9CE4DD2A-2C1B-5EE0-8D72-D53584AC9D48' };
const REMOTE: PhoneSessionRef = { kind: 'remote', provider: 'acme-cloud', sessionID: 'rs-1042' };
const ROW = {
  id: 'row-1', kind: 'worktree', name: 'fix-login', remote: false, statusChangedAt: 1_762_500_000_000, sessions: [],
};

function fixture(name: string): Record<string, any> {
  return JSON.parse(readFileSync(new URL(name, PROTOCOL_DIR), 'utf8'));
}

/** A `DecodeError` at exactly `path`. */
function at(path: string): (err: unknown) => boolean {
  return (err) => {
    assert.ok(err instanceof DecodeError, `a DecodeError, not ${String(err)}`);
    assert.equal(err.path, path, err.message);
    return true;
  };
}

/**
 * The raw values of Swift enum `name` in `file`, in order: a case's explicit raw value, or its
 * own name when it has none. Only the enum's own `case` lines count, not those in a nested body.
 */
function swiftRawValues(file: string, name: string): string[] {
  const source = readFileSync(new URL(file, SOURCES), 'utf8');
  const head = new RegExp(`\\benum ${name}\\b[^{]*\\{`).exec(source);
  if (head === null) throw new Error(`${file} declares no enum ${name}`);
  let depth = 1;
  let body = '';
  for (let i = head.index + head[0].length; depth > 0; i++) {
    const c = source[i];
    if (c === undefined) throw new Error(`enum ${name} in ${file} never closes`);
    if (c === '{') depth++;
    else if (c === '}') depth--;
    else if (depth === 1) body += c;
  }
  const values: string[] = [];
  for (const line of body.split('\n')) {
    const match = /^\s*case\s+(.+?)\s*$/.exec(line);
    if (match === null) continue;
    for (const piece of (match[1] ?? '').split(',')) {
      const parts = /^\s*(\w+)\s*(?:=\s*"([^"]*)")?\s*$/.exec(piece);
      if (parts === null) throw new Error(`cannot read the case ${JSON.stringify(piece)} of ${name}`);
      values.push(parts[2] ?? parts[1] ?? '');
    }
  }
  return values;
}

// The plan's tests.

test('a missing required field names its path', () => {
  assert.throws(() => decodeResult('sessions.subscribe', { seq: 1, replayed: false, omittedRows: 0, more: false }), /stream/);
  assert.throws(() => decodeResult('sessions.subscribe', { seq: 1, replayed: false, omittedRows: 0, more: false }), at('stream'));
});

test('an absent optional field stays absent', () => {
  const data = decodeEventData('sessions.changed', { rows: [], removedRowIDs: [] });
  assert.equal('layout' in data, false);
  assert.deepEqual(Object.keys(decodePhoneStatus({ chip: 'idle', changedAt: 1 })), ['chip', 'changedAt']);
  const page = decodeResult('transcript.page', { items: [{ id: 'i1', kind: 'user', truncated: false }], reachedStart: true, omittedItems: 0 });
  assert.equal('cursor' in page, false);
  assert.deepEqual(Object.keys(page.items[0] ?? {}), ['id', 'kind', 'truncated']);
});

test('an unknown status chip is refused', () => {
  assert.throws(() => decodePhoneStatusChip('sleeping', 'chip'), /chip/);
  assert.throws(() => decodePhoneStatus({ chip: 'sleeping', changedAt: 1 }), at('chip'));
});

test('refKey', () => {
  assert.equal(refKey({ kind: 'local', terminalID: 'T1' }), 'local:T1');
  assert.equal(refKey({ kind: 'remote', provider: 'acme-cloud', sessionID: 's-1' }), 'remote:acme-cloud/s-1');
});

test('an envelope that is neither a reply nor an event is refused', () => {
  assert.throws(() => decodeEnvelope({ kind: 'request', requestID: 'x', method: 'm', params: {} }), at('kind'));
});

// Names.

test("the method, event and error code lists are PhoneAppProtocol.swift's", () => {
  const file = 'TBDDaemon/PhoneBridge/App/PhoneAppProtocol.swift';
  assert.deepEqual([...METHODS], swiftRawValues(file, 'PhoneAppMethod'));
  assert.deepEqual([...EVENTS], swiftRawValues(file, 'PhoneAppEventName'));
  assert.deepEqual([...ERROR_CODES], swiftRawValues(file, 'PhoneAppErrorCode'));
  assert.equal(METHODS.length, 14);
  assert.equal(EVENTS.length, 5);
  assert.equal(ERROR_CODES.length, 10);
});

test('the enum value lists are the Swift enums they mirror', () => {
  const messages = 'TBDDaemon/PhoneBridge/App/PhoneAppMessages.swift';
  assert.deepEqual([...PHONE_STATUS_CHIPS], swiftRawValues(messages, 'PhoneStatusChip'));
  assert.deepEqual([...PHONE_AGENTS], swiftRawValues(messages, 'PhoneAgent'));
  assert.deepEqual([...PHONE_ITEM_KINDS], swiftRawValues(messages, 'PhoneItemKind'));
  assert.deepEqual([...TRANSCRIPT_DETAIL_PARTS], swiftRawValues(messages, 'TranscriptDetailPart'));
  assert.deepEqual([...PHONE_ANSWERED_BY], swiftRawValues(messages, 'PhoneAnsweredBy'));
  assert.deepEqual([...PERMISSION_DECISIONS], swiftRawValues('TBDShared/PromptAnswer.swift', 'PermissionDecision'));
  assert.deepEqual([...PROMPT_ANSWER_OUTCOMES], swiftRawValues('TBDShared/PromptAnswer.swift', 'PromptAnswerOutcome'));
  assert.deepEqual([...PENDING_PROMPT_KINDS], swiftRawValues('TBDShared/PendingPrompt.swift', 'PendingPromptKind'));
});

test('the Swift enum reader takes raw values, bare names and nothing from nested bodies', () => {
  // `PromptAnswerOutcome` has an `init(from:)` body; `PhoneAppErrorCode` mixes both case forms.
  assert.deepEqual(swiftRawValues('TBDShared/PromptAnswer.swift', 'PromptAnswerOutcome'), ['delivered', 'already_resolved', 'unknown']);
  assert.deepEqual(swiftRawValues('TBDDaemon/PhoneBridge/App/PhoneAppProtocol.swift', 'PhoneAppErrorCode').slice(3, 6),
    ['not_found', 'unsupported', 'refused']);
});

test('the name lists cannot be changed', () => {
  assert.ok(Object.isFrozen(METHODS) && Object.isFrozen(EVENTS) && Object.isFrozen(ERROR_CODES));
});

// Paths and enums.

test('an enum value outside its list names its dotted path', () => {
  const json = fixture('sessions.subscribe.reply.json');
  json.result.rows[2].sessions[0].status.chip = 'sleeping';
  assert.throws(() => decodeResult('sessions.subscribe', json.result), at('rows[2].sessions[0].status.chip'));
  assert.throws(() => decodeResult('sessions.subscribe', json.result), /rows\[2\]\.sessions\[0\]\.status\.chip: the string "sleeping" is not one of waitingForYou/);
});

test('the string-typed kinds are checked against their lists', () => {
  assert.throws(() => decodePhoneRow({ ...ROW, kind: 'folder' }), at('kind'));
  assert.throws(() => decodePhoneGroupLayout({ id: 'g', kind: 'folder', name: 'g', rows: [] }), at('kind'));
  assert.throws(() => decodePhonePrompt({ id: 'p', kind: 'plan', targetTruncated: false, allowAlways: false }), at('kind'));
  assert.equal(decodePhoneRow({ ...ROW, kind: 'remoteSession' }).kind, 'remoteSession');
});

test('a session ref of another kind is refused, and each kind keeps only its own fields', () => {
  assert.throws(() => decodePhoneSessionRef({ kind: 'cloud', terminalID: 'T1' }, 'session'), at('session.kind'));
  assert.throws(() => decodePhoneSessionRef({ kind: 'remote', provider: 'acme-cloud' }), at('sessionID'));
  assert.deepEqual(decodePhoneSessionRef({ kind: 'local', terminalID: 'T1', provider: 'acme-cloud' }), { kind: 'local', terminalID: 'T1' });
  assert.deepEqual(decodePhoneSessionRef({ ...REMOTE, terminalID: 'T1' }), REMOTE);
});

test('a prompt answer decodes by its kind', () => {
  const answers = Object.create(null);
  answers['Which?'] = 'Unit';
  assert.deepEqual(decodePromptAnswer({ kind: 'question', answers: { 'Which?': 'Unit' } }), { kind: 'question', answers });
  assert.deepEqual(decodePromptAnswer({ kind: 'permission', decision: 'allow_always' }), { kind: 'permission', decision: 'allow_always' });
  assert.deepEqual(decodePromptAnswer({ kind: 'permission', decision: 'deny', message: 'No.', answers: {} }),
    { kind: 'permission', decision: 'deny', message: 'No.' });
  assert.throws(() => decodePromptAnswer({ kind: 'permission', decision: 'maybe' }), at('decision'));
  assert.throws(() => decodePromptAnswer({ kind: 'question', answers: { 'Which?': 1 } }, 'answer'), at('answer.answers["Which?"]'));
  assert.throws(() => decodePromptAnswer({ kind: 'plan' }), at('kind'));
});

test("an answer outcome this build does not know reads as unknown, as Swift's does", () => {
  assert.deepEqual(decodePromptAnswerResult({ outcome: 'delivered' }), { outcome: 'delivered' });
  assert.deepEqual(decodePromptAnswerResult({ outcome: 'already_resolved' }), { outcome: 'already_resolved' });
  assert.deepEqual(decodePromptAnswerResult({ outcome: 'queued' }), { outcome: 'unknown' });
  assert.throws(() => decodePromptAnswerResult({ outcome: 1 }), at('outcome'));
});

// Values.

test('a null is refused, optional field or not', () => {
  assert.throws(() => decodePhoneStatus({ chip: 'idle', changedAt: 1, reason: null }), at('reason'));
  assert.throws(() => decodePhoneStatus({ chip: 'idle', changedAt: null }), at('changedAt'));
  assert.throws(() => decodeEventData('sessions.changed', { rows: [], removedRowIDs: [], layout: null }), at('layout'));
  assert.throws(() => decodeResult('transcript.open', { resumed: false, seq: 0, page: null }), /is null/);
});

test('integers must be safe integers', () => {
  for (const changedAt of [1.5, 2 ** 53, -(2 ** 53), Number.NaN, Number.POSITIVE_INFINITY, '1', true]) {
    assert.throws(() => decodePhoneStatus({ chip: 'idle', changedAt }), at('changedAt'), String(changedAt));
  }
  assert.equal(decodePhoneStatus({ chip: 'idle', changedAt: Number.MAX_SAFE_INTEGER }).changedAt, Number.MAX_SAFE_INTEGER);
});

test('strings, booleans, arrays and objects are checked', () => {
  assert.throws(() => decodePhoneRow({ ...ROW, name: 7 }), at('name'));
  assert.throws(() => decodePhoneRow({ ...ROW, remote: 'false' }), at('remote'));
  assert.throws(() => decodePhoneRow({ ...ROW, sessions: {} }), at('sessions'));
  assert.throws(() => decodePhoneRow([ROW]), at(''));
  assert.throws(() => decodeEventData('sessions.changed', { rows: [ROW, 'row'], removedRowIDs: [] }), at('rows[1]'));
});

test('unknown fields are dropped, at every depth', () => {
  const data = decodeEventData('sessions.changed', {
    rows: [{ ...ROW, colour: 'red', sessions: [] }], removedRowIDs: [], extra: { a: 1 },
  });
  assert.deepEqual(data, { rows: [ROW], removedRowIDs: [] });
  assert.equal('colour' in (data.rows[0] ?? {}), false);
});

test('a field is never read from a prototype', () => {
  const inherited = Object.create({ chip: 'idle', changedAt: 1 });
  assert.throws(() => decodePhoneStatus(inherited), at('chip'));
  const parsed = JSON.parse('{"__proto__": {"chip": "idle", "changedAt": 1}}');
  assert.throws(() => decodePhoneStatus(parsed), at('chip'));
});

test("a map keeps a parsed __proto__ key as an entry, on a null prototype, and Object.prototype stays clean", () => {
  const params = JSON.parse(`{
    "provider": "acme-cloud", "repoID": "16E7737E-5C20-548E-81FC-5DD3F9A51D36", "message": "Go.",
    "strings": {"__proto__": "x", "constructor": "y", "prototype": "z"},
    "bools": {"__proto__": true}
  }`);
  assert.ok(Object.hasOwn(params.strings, '__proto__'), 'JSON.parse keeps __proto__ as an own key');
  const decoded = decodeParams('remote.create', params);
  for (const map of [decoded.strings, decoded.bools]) assert.equal(Object.getPrototypeOf(map), null);
  assert.deepEqual(Object.keys(decoded.strings), ['__proto__', 'constructor', 'prototype']);
  assert.equal(Object.getOwnPropertyDescriptor(decoded.strings, '__proto__')?.value, 'x');
  assert.equal(decoded.strings['constructor'], 'y');
  assert.equal(Object.getOwnPropertyDescriptor(decoded.bools, '__proto__')?.value, true);
  assert.equal(({} as Record<string, unknown>)['x'], undefined);
  assert.equal(Object.getPrototypeOf({}), Object.prototype);
  // The map encodes as a plain object, its keys intact.
  const sent = JSON.parse(JSON.stringify(requestBody('r1', 'remote.create', decoded)));
  assert.equal(Object.getOwnPropertyDescriptor(sent.params.strings, '__proto__')?.value, 'x');
  assert.equal(sent.params.strings.constructor, 'y');
});

test('a map refuses a value of the wrong type, naming its key', () => {
  const decodeAnswers = obj<{ answers: Record<string, string> }>({ answers: record(str) }, {});
  assert.throws(() => decodeAnswers({ answers: { 'Where should the session cookie be set?': true } }),
    at('answers["Where should the session cookie be set?"]'));
  assert.throws(() => decodeAnswers({ answers: ['a'] }), at('answers'));
});

// Envelope.

test('a reply carries exactly one of result and error', () => {
  assert.deepEqual(decodeEnvelope({ kind: 'reply', requestID: 'r1', result: {} }), { kind: 'reply', requestID: 'r1', result: {} });
  assert.throws(() => decodeEnvelope({ kind: 'reply', requestID: 'r1' }), /neither/);
  assert.throws(() => decodeEnvelope({ kind: 'reply', requestID: 'r1', result: {}, error: { code: 'internal', message: 'x' } }), /both/);
  assert.throws(() => decodeEnvelope({ kind: 'reply', requestID: 'r1', result: null }), at('result'));
  assert.throws(() => decodeEnvelope({ kind: 'reply', result: {} }), at('requestID'));
  assert.throws(() => decodeEnvelope({ kind: 'reply', requestID: 'r1', error: { code: 'internal' } }), at('error.message'));
});

test("the daemon's fallback error reply, with no request ID, decodes", () => {
  const body = JSON.parse('{"error":{"code":"internal","message":"The reply could not be encoded."},"kind":"reply","requestID":""}');
  assert.deepEqual(decodeEnvelope(body), {
    kind: 'reply', requestID: '', error: { code: 'internal', message: 'The reply could not be encoded.' },
  });
});

test('an error reply keeps a code outside the closed list, and drops other fields', () => {
  assert.deepEqual(decodeEnvelope({ kind: 'reply', requestID: 'r1', error: { code: 'new_code', message: 'm', detail: 'd' } }),
    { kind: 'reply', requestID: 'r1', error: { code: 'new_code', message: 'm' } });
});

test('an event needs a known name, an integer seq and data', () => {
  const event = { kind: 'event', event: 'sessions.changed', seq: 3, data: { rows: [], removedRowIDs: [] } };
  assert.deepEqual(decodeEnvelope({ ...event, extra: 1 }), event);
  assert.throws(() => decodeEnvelope({ ...event, event: 'sessions.moved' }), at('event'));
  assert.throws(() => decodeEnvelope({ ...event, seq: 3.5 }), at('seq'));
  assert.throws(() => decodeEnvelope({ kind: 'event', event: 'sessions.changed', seq: 3 }), at('data'));
  assert.throws(() => decodeEnvelope('{"kind":"event"}'), at(''));
});

// Tables and request bodies.

test('a method or event name outside the tables is refused', () => {
  for (const name of ['sessions.unsubscribe', 'constructor', '__proto__', 'toString']) {
    assert.throws(() => decodeParams(name as Method, {}), DecodeError, name);
    assert.throws(() => decodeResult(name as Method, {}), DecodeError, name);
    assert.throws(() => decodeEventData(name as 'sessions.changed', {}), DecodeError, name);
  }
});

test('a request body holds exactly the wire fields', () => {
  const params = { session: { ...LOCAL, colour: 'red' }, profileID: undefined, note: 'x' } as unknown as ParamsOf<'session.fork'>;
  const body = requestBody('r1', 'session.fork', params);
  assert.deepEqual(body, { kind: 'request', requestID: 'r1', method: 'session.fork', params: { session: LOCAL } });
  assert.equal('profileID' in (body.params as object), false);
});

test('a request body refuses params of the wrong shape before anything is sent', () => {
  const bad = { session: LOCAL, text: 42 } as unknown as ParamsOf<'message.send'>;
  assert.throws(() => requestBody('r1', 'message.send', bad), at('text'));
  assert.deepEqual(requestBody('r2', 'transcript.close', {}), { kind: 'request', requestID: 'r2', method: 'transcript.close', params: {} });
});

test('sameRef compares kinds and every field', () => {
  assert.equal(sameRef(LOCAL, { kind: 'local', terminalID: LOCAL.kind === 'local' ? LOCAL.terminalID : '' }), true);
  assert.equal(sameRef(LOCAL, { kind: 'local', terminalID: 'other' }), false);
  assert.equal(sameRef(REMOTE, { kind: 'remote', provider: 'acme-cloud', sessionID: 'rs-1042' }), true);
  assert.equal(sameRef(REMOTE, { kind: 'remote', provider: 'acme-batch', sessionID: 'rs-1042' }), false);
  assert.equal(sameRef(LOCAL, REMOTE), false);
  assert.equal(sameRef(REMOTE, LOCAL), false);
  const a: PhoneSessionRef = { kind: 'remote', provider: 'acme/x', sessionID: 'y' };
  const b: PhoneSessionRef = { kind: 'remote', provider: 'acme', sessionID: 'x/y' };
  assert.equal(sameRef(a, b), false);
});

test('no two session refs share a refKey', () => {
  // Each pair would share a key if the provider were written as it is.
  const pairs: Array<[PhoneSessionRef, PhoneSessionRef]> = [
    [{ kind: 'remote', provider: 'acme/x', sessionID: 'y' }, { kind: 'remote', provider: 'acme', sessionID: 'x/y' }],
    [{ kind: 'remote', provider: 'acme%2Fx', sessionID: 'y' }, { kind: 'remote', provider: 'acme/x', sessionID: 'y' }],
    [{ kind: 'remote', provider: 'a%25', sessionID: 'b' }, { kind: 'remote', provider: 'a%', sessionID: 'b' }],
  ];
  for (const [a, b] of pairs) assert.notEqual(refKey(a), refKey(b), `${refKey(a)} and ${refKey(b)}`);
  assert.equal(refKey({ kind: 'remote', provider: 'acme/x', sessionID: 'y' }), 'remote:acme%2Fx/y');
  assert.equal(refKey({ kind: 'remote', provider: 'a%', sessionID: 'b' }), 'remote:a%25/b');
  assert.equal(refKey({ kind: 'remote', provider: 'acme cloud', sessionID: 's/1' }), 'remote:acme cloud/s/1');
  // A lone surrogate, which encodeURIComponent refuses, still makes a key.
  assert.equal(refKey({ kind: 'remote', provider: 'acme\ud800', sessionID: 's' }), 'remote:acme\ud800/s');

  // Every key a sample makes is its own: refs from providers and session IDs built of the
  // characters that matter, each pair of distinct refs checked.
  const parts = ['', 'a', '/', '%', '%2F', '%25', 'a/b', '2F'];
  const refs: PhoneSessionRef[] = [];
  for (const provider of parts) for (const sessionID of parts) refs.push({ kind: 'remote', provider, sessionID });
  for (const terminalID of parts) refs.push({ kind: 'local', terminalID });
  const seen = new Map<string, PhoneSessionRef>();
  for (const ref of refs) {
    const key = refKey(ref);
    const other = seen.get(key);
    assert.equal(other, undefined, `${JSON.stringify(ref)} and ${JSON.stringify(other)} share ${key}`);
    seen.set(key, ref);
  }
});

test("a remote session's refKey is its row ID in the session list", () => {
  const json = fixture('sessions.subscribe.reply.json');
  const remoteRow = decodeResult('sessions.subscribe', json.result).rows?.find((row) => row.remote);
  assert.ok(remoteRow !== undefined && remoteRow.sessions[0] !== undefined);
  assert.equal(refKey(remoteRow.sessions[0].ref), remoteRow.id);
});
