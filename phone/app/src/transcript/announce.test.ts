// Tests announce.ts: the transcript's live region says the rows that came in at the bottom, in
// their own words, a few of them at most, each cut short.

import { mock, test } from 'node:test';
import assert from 'node:assert/strict';
import { Lexer } from 'marked';
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

test('an API error says its text as typed, as its row draws it, and the same text without the field reads as markdown', () => {
  const text = 'API Error: 529 **Overloaded**. See `status` &amp; retry.\nThe turn stopped.';
  assert.equal(spoken(row({ kind: 'assistant', text, apiError: 'server_error' })), 'API Error: 529 **Overloaded**. See `status` &amp; retry. The turn stopped.');
  assert.equal(spoken(row({ kind: 'assistant', text })), 'API Error: 529 Overloaded. See status & retry. The turn stopped.');
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

test('an addition says the words its row draws, inside the code block, link or emphasis the old text left open', () => {
  // The fence the old text opened holds the addition, so its line is code, not a heading.
  const fenced = row({ kind: 'assistant', text: 'Run this:\n```\nconst a = 1' });
  assert.deepEqual(announcement([changed(fenced, { text: 'Run this:\n```\nconst a = 1\n# not a heading\n```' })], 0, [fenced]), [
    '# not a heading',
  ]);
  // An addition that closes emphasis or a link changes the words before it, so the new text is said from its start.
  const em = row({ kind: 'user', text: 'Use the *fast' });
  assert.deepEqual(announcement([changed(em, { text: 'Use the *fast* path' })], 0, [em]), ['Use the fast path']);
  const link = row({ kind: 'peer', text: 'See [the guide' });
  assert.deepEqual(announcement([changed(link, { text: 'See [the guide](https://acme.example/guide) first.' })], 0, [link]), [
    'See the guide first.',
  ]);
  // Emphasis still open after the addition says only the words added.
  const open = row({ kind: 'assistant', text: 'Use **both' });
  assert.deepEqual(announcement([changed(open, { text: 'Use **both files' })], 0, [open]), ['files']);
  // Old text of ANNOUNCE_SOURCE_CHARS characters is still read with its addition, and the
  // addition is read as far past it as an addition read on its own.
  const full = `\`\`\`\n${'x'.repeat(ANNOUNCE_SOURCE_CHARS - 4)}`;
  assert.equal(full.length, ANNOUNCE_SOURCE_CHARS);
  const fullRow = row({ kind: 'assistant', text: full });
  const tail = announcement([changed(fullRow, { text: `${full}\n# ${'y '.repeat(ANNOUNCE_CHARS)}` })], 0, [fullRow]);
  assert.deepEqual(tail.map((line) => [line.length, line.slice(0, 6)]), [[ANNOUNCE_CHARS, '# y y ']]);
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

test("a message's text is read as markdown once for announcing, however often its row changes after it comes in", () => {
  // Claude's messages are read as blocks (`Lexer.lex`), the reader's and a peer's as one run (`Lexer.inlineTokens`).
  const lex = mock.method(Lexer.prototype, 'lex');
  const inline = mock.method(Lexer.prototype, 'inlineTokens');
  try {
    for (const [kind, spy] of [['assistant', lex], ['user', inline], ['peer', inline]] as const) {
      /** How many times `fn` read a text as markdown. */
      const reads = (fn: () => void): number => {
        const was = spy.mock.callCount();
        fn();
        return spy.mock.callCount() - was;
      };
      let text = 'Working';
      let shown = row({ kind, text });
      assert.equal(reads(() => assert.deepEqual(announcement([shown], 1, []), ['Working'])), 1, kind);
      for (const more of [' on', ' it', ' now.']) {
        const before = lastRows([shown]);
        text += more;
        shown = changed(shown, { text });
        // Only the new text is read: the old text's words were kept when it came in or last changed.
        assert.equal(reads(() => assert.deepEqual(announcement([shown], 0, before), [more.trim()])), 1, `${kind}${more}`);
      }
      // A row whose words were read says them again without reading its text.
      assert.equal(reads(() => assert.deepEqual(announcement([shown], 1, []), ['Working on it now.'])), 0, kind);
      // A change other than growth reads only its new text, once.
      const before = lastRows([shown]);
      shown = changed(shown, { text: 'Done.' });
      assert.equal(reads(() => assert.deepEqual(announcement([shown], 0, before), ['Done.'])), 1, kind);
    }
  } finally {
    lex.mock.restore();
    inline.mock.restore();
  }
});
