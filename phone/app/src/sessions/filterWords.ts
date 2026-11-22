/**
 * The words on a repo header's filter chip and in its accessible label (spec
 * `docs/specs/2026-11-22-phone-remote-session-filter-design.md`, "States"). A chip names its one
 * registry provider by the provider's registry key; with two or more, it says "remote", and its
 * label says "remote sessions except cloud". As on the laptop sidebar, a count of 1 reads in the
 * singular.
 */

import type { RemoteFilterChip } from '../state/sessionsView.ts';

/** What a chip says: `text` on it, `label` to a screen reader. */
export interface FilterChipWords {
  text: string;
  label: string;
}

export function filterChipWords(chip: RemoteFilterChip): FilterChipWords {
  const [only, ...others] = chip.providers;
  const name = only !== undefined && others.length === 0 ? only : null;
  if (!chip.on) {
    return name === null
      ? { text: 'Hide remote', label: 'Hide remote sessions except cloud' }
      : { text: `Hide ${name}`, label: `Hide ${name} sessions` };
  }
  const one = chip.count === 1;
  const what = name === null
    ? (one ? 'remote session except cloud' : 'remote sessions except cloud')
    : (one ? `${name} session` : `${name} sessions`);
  return { text: `${chip.count} hidden`, label: `${chip.count} ${what} hidden. Tap to show ${one ? 'it' : 'them'}.` };
}
