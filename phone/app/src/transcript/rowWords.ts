/**
 * The words and tones a transcript row draws from its optional fields, as the mock's `itemHTML`
 * draws them (mock 870-897). Each falls back to what a row drew before the laptop sent the
 * field, so a row from an older laptop, which sends none of them, draws as it always did.
 *
 * Pure, with no React, so `node --test` loads it.
 */

import type { PhoneItem } from '../protocol/types.ts';

/**
 * The label of a system note of kind `noteKind`, a `SystemKind` raw value, in the mock's words
 * where it has them ("Hook"). A kind this build does not know, or none, reads "System", the
 * mock's fallback.
 */
export function noteLabel(noteKind: string | undefined): string {
  if (noteKind === undefined || !Object.hasOwn(NOTE_LABELS, noteKind)) return 'System';
  return NOTE_LABELS[noteKind]!;
}

/**
 * `SystemKind`'s raw values, the kinds the laptop's transcript sorts system text into, and the
 * label of each, in plain words.
 */
const NOTE_LABELS: Readonly<Record<string, string>> = Object.freeze({
  toolReminder: 'Reminder',
  hookOutput: 'Hook',
  environmentDetails: 'Environment',
  slashEnvelope: 'Command',
  skillBody: 'Skill',
  taskNotification: 'Background',
  nestedMemory: 'File',
  compactSummary: 'Compacted',
  other: 'Info',
});

/**
 * A failed tool's mark: "exit 2" when the laptop sent the exit code, as the mock draws it, and
 * "failed" when it sent none, rather than a number the result never named.
 */
export function failMark(exitCode: number | undefined): string {
  return exitCode === undefined ? 'failed' : `exit ${exitCode}`;
}

/**
 * The status tone of an API error row with class `apiError`: the rate-limit tone for
 * `rate_limit`, which a wait clears, and the error tone for every other class.
 */
export function errorTone(apiError: string): 'st-rate' | 'st-err' {
  return apiError === 'rate_limit' ? 'st-rate' : 'st-err';
}

/**
 * What a file edit's row names: the file's path, relative to the worktree when the file is inside
 * it, as the mock draws it; else, from a laptop that sends no path or a path too long to send,
 * the file's name.
 */
export function editTarget(item: PhoneItem): string {
  return item.path ?? item.target ?? '';
}
