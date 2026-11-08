/**
 * The status words, copied from the mock's status vocabulary (spec section 8.2): the long
 * and short word for each chip, its glyph, its rank in the sessions list and the colour class.
 * Also the small time and name helpers the mock shares with them.
 */

import type { PhoneStatusChip } from '../protocol/types.ts';
import type { GlyphName } from '../ui/glyphs.ts';

export interface StatusWords {
  word: string;
  short: string;
  glyph: GlyphName | 'dots' | null;
  rank: number;
  cls: 'wait' | 'err' | 'rate' | 'work' | 'idle' | 'park' | 'gone' | 'unk';
}

export const STATUS: Readonly<Record<PhoneStatusChip, StatusWords>> = {
  waitingForYou: { word: 'Waiting for you', short: 'Waiting', glyph: 'hand', rank: 0, cls: 'wait' },
  error: { word: 'Error', short: 'Error', glyph: 'octa', rank: 1, cls: 'err' },
  rateLimited: { word: 'Rate limited', short: 'Limited', glyph: 'glass', rank: 2, cls: 'rate' },
  working: { word: 'Working', short: 'Working', glyph: 'dots', rank: 3, cls: 'work' },
  idle: { word: 'Idle', short: 'Idle', glyph: null, rank: 4, cls: 'idle' },
  parked: { word: 'Parked', short: 'Parked', glyph: 'moon', rank: 5, cls: 'park' },
  exited: { word: 'Exited', short: 'Exited', glyph: 'power', rank: 6, cls: 'gone' },
  unknown: { word: 'Unknown', short: 'Unknown', glyph: 'unk', rank: 7, cls: 'unk' },
};

const MINUTE = 60_000;

/** How long ago `at` was, in the mock's short form: now, 5m, 3h, 2d. A future `at` reads as now. */
export function ago(now: number, at: number): string {
  const m = (now - at) / MINUTE;
  if (m < 1) return 'now';
  if (m < 60) return `${Math.floor(m)}m`;
  if (m < 1440) return `${Math.floor(m / 60)}h`;
  return `${Math.floor(m / 1440)}d`;
}

/** A length of time as `1m 12s` or `9s`. A negative length reads as `0s`. */
export function dur(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000));
  const m = Math.floor(s / 60);
  return m ? `${m}m ${s % 60}s` : `${s}s`;
}

/** What the profile kinds the daemon sends are called on screen. */
export const PROFILE_KIND_WORDS: Readonly<Record<string, string>> = {
  oauth: 'Claude subscription',
  oauthToken: 'Claude subscription',
  apiKey: 'API key',
  bedrock: 'Amazon Bedrock',
};

const TOOL_GLYPHS: Readonly<Record<string, GlyphName>> = {
  Read: 'eye',
  Grep: 'search',
  Glob: 'search',
  Bash: 'term',
  Edit: 'pen',
  Write: 'pen',
  MultiEdit: 'pen',
  WebFetch: 'globe',
};

/** The glyph for a tool's name. An unknown or missing tool gets the terminal. */
export function toolGlyph(toolName: string | undefined): GlyphName {
  if (toolName === undefined) return 'term';
  return Object.hasOwn(TOOL_GLYPHS, toolName) ? TOOL_GLYPHS[toolName] ?? 'term' : 'term';
}
