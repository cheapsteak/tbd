// Tests announce.ts: the transcript's live region says the rows that came in at the bottom, in
// their own words, a few of them at most, each cut short.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { PhoneItem } from '../protocol/types.ts';
import type { TranscriptRow } from '../state/transcript.ts';
import { ANNOUNCE_CHARS, ANNOUNCE_ROWS, ANNOUNCE_SOURCE_CHARS, announcement, spoken } from './announce.ts';

let nextKey = 1;

function row(item: Partial<PhoneItem> & Pick<PhoneItem, 'kind'>): TranscriptRow {
  return { key: nextKey++, kind: 'item', item: { id: `i${nextKey}`, truncated: false, ...item } };
}

function receipt(text: string): TranscriptRow {
  return { key: nextKey++, kind: 'receipt', id: 'p1', text };
}

test("each row that says something says its own words, and its markdown's marks go", () => {
  assert.equal(spoken(row({ kind: 'assistant', text: 'Fixed **both** cases.\n\n- `isLocalPath` checks [the link](https://acme.example).' })),
    'Fixed both cases. isLocalPath checks the link.');
  assert.equal(spoken(row({ kind: 'user', text: 'Run the *auth* tests\nagain' })), 'Run the auth tests again');
  assert.equal(spoken(row({ kind: 'peer', text: 'Keep the `saved-card` list.' })), 'Keep the saved-card list.');
  assert.equal(spoken(receipt('Answered on this phone: Yes')), 'Answered on this phone: Yes');
  assert.equal(spoken(row({ kind: 'tool', toolName: 'Bash', target: 'npm test -- auth', toolStatus: 'running' })), 'Bash npm test -- auth');
});

test('a file edit, a subagent, a slash command, thinking, a system note and an empty message say nothing', () => {
  for (const r of [
    row({ kind: 'fileEdit', toolName: 'Edit', target: 'CheckoutForm.tsx' }),
    row({ kind: 'subagent', toolName: 'Agent', target: 'Find the step wrapper' }),
    row({ kind: 'slash', text: '/compact' }),
    row({ kind: 'thinking', text: 'Check the lockfile first.' }),
    row({ kind: 'systemNote', text: 'PostToolUse: lint passed.' }),
    row({ kind: 'assistant', text: '  \n ' }),
    row({ kind: 'tool' }),
  ]) {
    assert.equal(spoken(r), null);
  }
});

test('a long row is cut to ANNOUNCE_CHARS, never inside a surrogate pair', () => {
  assert.equal(ANNOUNCE_CHARS, 500);
  assert.equal(spoken(row({ kind: 'assistant', text: 'a'.repeat(5_000) }))?.length, ANNOUNCE_CHARS);
  const emoji = spoken(row({ kind: 'user', text: `${'a'.repeat(ANNOUNCE_CHARS - 1)}😀 more` }))!;
  assert.equal(emoji, 'a'.repeat(ANNOUNCE_CHARS - 1));
  const whole = 'b'.repeat(ANNOUNCE_CHARS);
  assert.equal(spoken(row({ kind: 'user', text: whole })), whole);
});

test('a message’s words come from its first ANNOUNCE_SOURCE_CHARS characters only', () => {
  assert.equal(ANNOUNCE_SOURCE_CHARS, 1_000);
  // Forty links of 25 characters each fill the characters read; the ones after them are not read.
  const link = '[x](https://acme.ex/a/b) ';
  assert.equal(link.length * 40, ANNOUNCE_SOURCE_CHARS);
  const said = Array.from({ length: 40 }, () => 'x').join(' ');
  assert.equal(spoken(row({ kind: 'assistant', text: link.repeat(400) })), said);
  assert.equal(spoken(row({ kind: 'user', text: link.repeat(400) })), said);
  assert.equal(spoken(row({ kind: 'peer', text: link.repeat(400) })), said);
  // Ordinary text still says ANNOUNCE_CHARS, and a cut of what is read never parts a surrogate pair.
  assert.equal(spoken(row({ kind: 'assistant', text: 'Fixed **both** cases. '.repeat(300) }))?.length, ANNOUNCE_CHARS);
  const parted = `${link.repeat(39)}${'b'.repeat(24)}${'😀'.repeat(10)}`;
  assert.equal(spoken(row({ kind: 'user', text: parted })), `${Array.from({ length: 39 }, () => 'x').join(' ')} ${'b'.repeat(24)}`);
});

test('an announcement says the last ANNOUNCE_ROWS rows that say something, oldest first', () => {
  assert.equal(ANNOUNCE_ROWS, 3);
  const burst = Array.from({ length: 50 }, (_, i) => row({ kind: 'assistant', text: `Message ${i}.` }));
  assert.deepEqual(announcement(burst), ['Message 47.', 'Message 48.', 'Message 49.']);
  const mixed = [
    row({ kind: 'user', text: 'Go' }),
    row({ kind: 'tool', toolName: 'Read', target: 'auth.ts' }),
    row({ kind: 'thinking', text: 'Hmm.' }),
    receipt('Answered on the laptop'),
    row({ kind: 'fileEdit', toolName: 'Edit', target: 'auth.ts' }),
  ];
  assert.deepEqual(announcement(mixed), ['Go', 'Read auth.ts', 'Answered on the laptop']);
  assert.deepEqual(announcement([row({ kind: 'thinking', text: 'Hmm.' })]), []);
  assert.deepEqual(announcement([]), []);
});
