// Tests rowWords.ts: the words and tones a row draws from the fields a newer laptop sends, and
// what it draws from an older laptop that sends none of them.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { PhoneItem } from '../protocol/types.ts';
import { editTarget, errorTone, failMark, noteLabel } from './rowWords.ts';

function edit(fields: Partial<PhoneItem>): PhoneItem {
  return { id: 'e1', kind: 'fileEdit', truncated: false, toolName: 'Edit', ...fields };
}

test("a system note's label is its kind's, and an unknown kind or none reads System", () => {
  const labels = {
    toolReminder: 'Reminder', hookOutput: 'Hook', environmentDetails: 'Environment', slashEnvelope: 'Command',
    skillBody: 'Skill', taskNotification: 'Background', nestedMemory: 'File', compactSummary: 'Compacted', other: 'Info',
  };
  for (const [kind, label] of Object.entries(labels)) assert.equal(noteLabel(kind), label, kind);
  assert.equal(noteLabel(undefined), 'System', 'an older laptop sends no kind');
  assert.equal(noteLabel('someNewKind'), 'System');
  for (const key of ['__proto__', 'constructor', 'toString', 'hasOwnProperty', '']) assert.equal(noteLabel(key), 'System', key);
});

test("a failed tool's mark names its exit code, and says failed without one", () => {
  assert.equal(failMark(2), 'exit 2');
  assert.equal(failMark(137), 'exit 137');
  assert.equal(failMark(-1), 'exit -1');
  assert.equal(failMark(0), 'exit 0');
  assert.equal(failMark(undefined), 'failed', 'an older laptop sends no exit code');
});

test('an API error row takes the rate-limit tone for a rate limit, and the error tone otherwise', () => {
  assert.equal(errorTone('rate_limit'), 'st-rate');
  for (const kind of ['server_error', 'unknown', 'authentication_failed', '']) assert.equal(errorTone(kind), 'st-err', kind);
});

test("a file edit names its path, and from an older laptop its file's name", () => {
  assert.equal(editTarget(edit({ path: 'src/auth/redirect.ts', target: 'redirect.ts' })), 'src/auth/redirect.ts');
  assert.equal(editTarget(edit({ path: '/Users/acme/notes/plan.md', target: 'plan.md' })), '/Users/acme/notes/plan.md');
  assert.equal(editTarget(edit({ target: 'redirect.ts' })), 'redirect.ts', 'an older laptop, or a path too long to send');
  assert.equal(editTarget(edit({})), '');
});
