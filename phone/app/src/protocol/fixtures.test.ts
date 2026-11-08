// Spec 4.4: every app-protocol message has a fixture under `phone/protocol/`, and the TypeScript
// side decodes and re-encodes each one, as the Swift tests do, so the two sides cannot drift.
// A field the decoders dropped, or one they added, fails the round trip.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  decodeEnvelope, decodeEventData, decodeParams, decodeResult, ERROR_CODES, EVENTS, isErrorCode, METHODS, requestBody,
} from './wire.ts';
import type { EventName, Method } from './types.ts';

const PROTOCOL_DIR = fileURLToPath(new URL('../../../protocol/', import.meta.url));

/** What the loader sends or receives: the value as JSON encodes it. */
function roundTrip(value: unknown): unknown {
  return JSON.parse(JSON.stringify(value));
}

function asMethod(name: string): Method {
  assert.ok((METHODS as readonly string[]).includes(name), `${name} is a method`);
  return name as Method;
}

function asEvent(name: string): EventName {
  assert.ok((EVENTS as readonly string[]).includes(name), `${name} is an event`);
  return name as EventName;
}

test('every method and event has its fixtures, and no fixture is unaccounted for', () => {
  const want = new Set([
    'error.reply.json',
    ...METHODS.flatMap((m) => [`${m}.request.json`, `${m}.reply.json`]),
    ...EVENTS.map((e) => `${e}.event.json`),
  ]);
  assert.equal(want.size, 1 + METHODS.length * 2 + EVENTS.length);
  assert.deepEqual(new Set(readdirSync(PROTOCOL_DIR)), want);
});

for (const file of readdirSync(PROTOCOL_DIR).sort()) {
  test(`${file} decodes and encodes back to itself`, () => {
    const json = JSON.parse(readFileSync(join(PROTOCOL_DIR, file), 'utf8'));

    if (file === 'error.reply.json') {
      const env = decodeEnvelope(json);
      if (env.kind !== 'reply') assert.fail('an error reply decodes as a reply');
      assert.equal('result' in env, false);
      assert.deepEqual(env.error, json.error);
      assert.ok(env.error !== undefined && isErrorCode(env.error.code), `${env.error?.code} is in ERROR_CODES`);
      assert.ok(ERROR_CODES.includes(json.error.code));
      assert.deepEqual(roundTrip({ kind: env.kind, requestID: env.requestID, error: env.error }), json);
      return;
    }

    if (file.endsWith('.request.json')) {
      const method = asMethod(file.slice(0, -'.request.json'.length));
      assert.equal(json.kind, 'request');
      assert.equal(json.method, method);
      // The body as the loader sends it, JSON-encoded.
      assert.deepEqual(roundTrip(requestBody(json.requestID, method, decodeParams(method, json.params))), json);
      return;
    }

    if (file.endsWith('.reply.json')) {
      const method = asMethod(file.slice(0, -'.reply.json'.length));
      const env = decodeEnvelope(json);
      if (env.kind !== 'reply') assert.fail('a reply decodes as a reply');
      assert.equal('error' in env, false);
      assert.deepEqual(roundTrip({ kind: env.kind, requestID: env.requestID, result: decodeResult(method, env.result) }), json);
      return;
    }

    if (file.endsWith('.event.json')) {
      const event = asEvent(file.slice(0, -'.event.json'.length));
      const env = decodeEnvelope(json);
      if (env.kind !== 'event') assert.fail('an event decodes as an event');
      assert.equal(env.event, event);
      assert.deepEqual(roundTrip({ kind: env.kind, event: env.event, seq: env.seq, data: decodeEventData(env.event, env.data) }), json);
      return;
    }

    assert.fail(`${file} is neither a request, a reply nor an event`);
  });
}

test('the decoders build new values and leave the fixture untouched', () => {
  const file = join(PROTOCOL_DIR, 'sessions.subscribe.reply.json');
  const json = JSON.parse(readFileSync(file, 'utf8'));
  const before = JSON.stringify(json);
  const env = decodeEnvelope(json);
  if (env.kind !== 'reply') assert.fail('a reply decodes as a reply');
  const result = decodeResult('sessions.subscribe', env.result);
  assert.notEqual(result, json.result);
  assert.notEqual(result.rows, json.result.rows);
  assert.notEqual(result.rows?.[0], json.result.rows[0]);
  assert.notEqual(result.rows?.[0]?.sessions[0]?.ref, json.result.rows[0].sessions[0].ref);
  assert.equal(JSON.stringify(json), before);
});
