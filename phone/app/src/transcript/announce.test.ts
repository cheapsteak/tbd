// Tests announce.ts: the transcript's live region says the rows that came in at the bottom, in
// their own words, a few of them at most, each cut short.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { PhoneItem } from '../protocol/types.ts';
import type { TranscriptRow } from '../state/transcript.ts';
import { ANNOUNCE_CHARS, ANNOUNCE_ROWS, ANNOUNCE_SOURCE_CHARS, announcement, lastRows, spoken } from './announce.ts';

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

test('a message says the text its author meant: its characters as typed and its character references decoded', () => {
  assert.equal(spoken(row({ kind: 'assistant', text: "it&#39;s a & b, &lt;tag&gt; &amp; `a &amp; b`" })), "it's a & b, <tag> & a &amp; b");
  assert.equal(spoken(row({ kind: 'user', text: "it&#39;s a & b &quot;q&quot;" })), 'it\'s a & b "q"');
  assert.equal(spoken(row({ kind: 'peer', text: 'a &#38; b &copy; &nope;' })), 'a & b © &nope;');
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
  assert.deepEqual(announcement(burst, burst.length, []), ['Message 47.', 'Message 48.', 'Message 49.']);
  const mixed = [
    row({ kind: 'user', text: 'Go' }),
    row({ kind: 'tool', toolName: 'Read', target: 'auth.ts' }),
    row({ kind: 'thinking', text: 'Hmm.' }),
    receipt('Answered on the laptop'),
    row({ kind: 'fileEdit', toolName: 'Edit', target: 'auth.ts' }),
  ];
  assert.deepEqual(announcement(mixed, mixed.length, []), ['Go', 'Read auth.ts', 'Answered on the laptop']);
  assert.deepEqual(announcement([row({ kind: 'thinking', text: 'Hmm.' })], 1, []), []);
  assert.deepEqual(announcement([], 0, []), []);
  // Only the rows that came in, the last `arrived` of them.
  assert.deepEqual(announcement(mixed, 2, lastRows(mixed.slice(0, 3))), ['Answered on the laptop']);
});

/** `r` with its item's fields replaced by `over`, in place: the same key. */
function changed(r: TranscriptRow, over: Partial<PhoneItem>): TranscriptRow {
  if (r.kind !== 'item') throw new Error('not an item');
  return { ...r, item: { ...r.item, ...over } };
}

test('a message among the last ANNOUNCE_ROWS rows whose text changed in place says its new words, once', () => {
  const rows = [row({ kind: 'user', text: 'Go' }), row({ kind: 'assistant', text: '' }), row({ kind: 'peer', text: 'Hold on.' })];
  const before = lastRows(rows);
  // An empty message whose text arrives, and a message whose text changes.
  const now = [rows[0]!, changed(rows[1]!, { text: 'Both **pass**.' }), changed(rows[2]!, { text: 'Keep the `saved-card` list.' })];
  assert.deepEqual(announcement(now, 0, before), ['Both pass.', 'Keep the saved-card list.']);
  // Seen again, nothing changed since.
  assert.deepEqual(announcement(now, 0, lastRows(now)), []);
  // The user's own message, changed in place: it says the words added.
  const mine = [changed(now[0]!, { text: 'Go on' }), ...now.slice(1)];
  assert.deepEqual(announcement(mine, 0, lastRows(now)), ['on']);
});

test('a message whose text grows says only the words added, however long it is', () => {
  const long = 'Checking each file in turn. '.repeat(60);
  assert.ok(long.length > ANNOUNCE_SOURCE_CHARS);
  const said = row({ kind: 'assistant', text: long });
  const rows = [row({ kind: 'user', text: 'Go' }), said];
  // Past the characters read for a message's words, an addition is still said, and only it.
  const grown = [rows[0]!, changed(said, { text: `${long}All **pass** now.` })];
  assert.deepEqual(announcement(grown, 0, lastRows(rows)), ['All pass now.']);
  // A short message as it streams.
  const short = row({ kind: 'peer', text: 'Working on' });
  assert.deepEqual(announcement([changed(short, { text: 'Working on it.' })], 0, [short]), ['it.']);
  // An addition is cut as any row is, and white space alone says nothing.
  const many = announcement([changed(short, { text: `Working on${' it'.repeat(1_000)}` })], 0, [short]);
  assert.deepEqual(many.map((line) => line.length), [ANNOUNCE_CHARS]);
  assert.deepEqual(announcement([changed(short, { text: 'Working on \n ' })], 0, [short]), []);
  // An addition never starts inside a surrogate pair.
  const emoji = row({ kind: 'user', text: 'a\ud83d' });
  assert.deepEqual(announcement([changed(emoji, { text: 'a😀 b' })], 0, [emoji]), ['😀 b']);
});

test('a message whose text changes other than by growing says its new text from the start', () => {
  const said = row({ kind: 'assistant', text: 'Both **pass**.' });
  assert.deepEqual(announcement([changed(said, { text: 'All pass.' })], 0, [said]), ['All pass.']);
  const long = row({ kind: 'assistant', text: 'x '.repeat(1_000) });
  const rewritten = announcement([changed(long, { text: `y ${'x '.repeat(1_000)}` })], 0, [long]);
  assert.deepEqual(rewritten.map((line) => [line.length, line.slice(0, 4)]), [[ANNOUNCE_CHARS, 'y x ']]);
});

test('a change in place that says nothing new, a tool, a receipt and a row further up say nothing', () => {
  const tool = row({ kind: 'tool', toolName: 'Bash', target: 'npm test', toolStatus: 'running' });
  const far = row({ kind: 'assistant', text: 'Far up.' });
  const said = row({ kind: 'assistant', text: 'Both **pass**.' });
  const answered = receipt('Answered on this phone: Yes');
  const rows = [far, row({ kind: 'user', text: 'Go' }), tool, said, answered];
  const before = lastRows(rows);
  const now = [
    changed(far, { text: 'Changed far up.' }), rows[1]!, changed(tool, { toolStatus: 'ok' }),
    // The same words: only the marks changed, or text emptied.
    changed(said, { text: 'Both *pass*.' }), { ...answered, text: 'Answered on the laptop' },
  ];
  assert.deepEqual(announcement(now, 0, before), []);
  assert.deepEqual(announcement([...now.slice(0, 3), changed(said, { text: '' }), now[4]!], 0, before), []);
  // A row the list never saw at the bottom is not taken for a change.
  assert.deepEqual(announcement(now, 0, []), []);
});

test('rows that arrive and a message changed in place above them share the ANNOUNCE_ROWS lines', () => {
  const said = row({ kind: 'assistant', text: 'Working on it.' });
  const rows = [row({ kind: 'user', text: 'Go' }), said];
  const before = lastRows(rows);
  const one = [rows[0]!, changed(said, { text: 'Done.' }), row({ kind: 'assistant', text: 'Next.' })];
  assert.deepEqual(announcement(one, 1, before), ['Done.', 'Next.']);
  // Three rows that arrive fill the lines, and the changed row is no longer among the last three.
  const three = [rows[0]!, changed(said, { text: 'Done.' }), ...['A.', 'B.', 'C.'].map((text) => row({ kind: 'assistant', text }))];
  assert.deepEqual(announcement(three, 3, before), ['A.', 'B.', 'C.']);
});
