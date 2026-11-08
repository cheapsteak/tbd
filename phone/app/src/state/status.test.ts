import { test } from 'node:test';
import assert from 'node:assert/strict';
import { STATUS, ago, dur, toolGlyph, PROFILE_KIND_WORDS } from './status.ts';

const T = 1_800_000_000_000;

test('words and ranks follow spec 8.2 and the mock', () => {
  const byRank = Object.values(STATUS).sort((a, b) => a.rank - b.rank);
  assert.deepEqual(byRank.map((s) => s.word), ['Waiting for you', 'Error', 'Rate limited', 'Working', 'Idle', 'Parked', 'Exited', 'Unknown']);
  assert.deepEqual(byRank.map((s) => s.rank), [0, 1, 2, 3, 4, 5, 6, 7]);
  assert.deepEqual(byRank.map((s) => s.short), ['Waiting', 'Error', 'Limited', 'Working', 'Idle', 'Parked', 'Exited', 'Unknown']);
  assert.deepEqual(byRank.map((s) => s.glyph), ['hand', 'octa', 'glass', 'dots', null, 'moon', 'power', 'unk']);
  assert.deepEqual(byRank.map((s) => s.cls), ['wait', 'err', 'rate', 'work', 'idle', 'park', 'gone', 'unk']);
  assert.equal(STATUS.rateLimited.short, 'Limited');
  assert.equal(STATUS.working.glyph, 'dots');
  assert.equal(STATUS.idle.glyph, null);
  assert.equal(STATUS.exited.glyph, 'power');
  assert.equal(STATUS.unknown.cls, 'unk');
});

test('ago', () => {
  assert.equal(ago(T, T - 59_999), 'now');
  assert.equal(ago(T, T - 60_000), '1m');
  assert.equal(ago(T, T - 3_599_999), '59m');
  assert.equal(ago(T, T - 3_600_000), '1h');
  assert.equal(ago(T, T - 86_400_000), '1d');
  assert.equal(ago(T, T + 5_000), 'now');
});

test('dur', () => {
  assert.equal(dur(72_000), '1m 12s');
  assert.equal(dur(9_000), '9s');
  assert.equal(dur(-1), '0s');
});

test('tool glyphs', () => {
  assert.equal(toolGlyph('Read'), 'eye');
  assert.equal(toolGlyph('Grep'), 'search');
  assert.equal(toolGlyph('Glob'), 'search');
  assert.equal(toolGlyph('Bash'), 'term');
  for (const t of ['Edit', 'Write', 'MultiEdit']) assert.equal(toolGlyph(t), 'pen');
  assert.equal(toolGlyph('WebFetch'), 'globe');
  assert.equal(toolGlyph('Task'), 'term');
  assert.equal(toolGlyph(undefined), 'term');
  assert.equal(toolGlyph('constructor'), 'term');
});

test('profile kind words', () => {
  assert.equal(PROFILE_KIND_WORDS['oauth'], 'Claude subscription');
  assert.equal(PROFILE_KIND_WORDS['oauthToken'], 'Claude subscription');
  assert.equal(PROFILE_KIND_WORDS['apiKey'], 'API key');
  assert.equal(PROFILE_KIND_WORDS['bedrock'], 'Amazon Bedrock');
});
