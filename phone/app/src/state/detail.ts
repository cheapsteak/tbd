/**
 * One open detail of a transcript row: a tool call's input and result, the whole of a message
 * whose preview was cut, or a subagent's items, loaded chunk by chunk through
 * `transcript.detail` (spec section 7, "Large details"). The transcript slice holds each open
 * detail by its row's key (`TranscriptState.details` in `transcript.ts`).
 *
 * Part 6c fills in the chunk rules (Task 6c-5). For now this module holds only the shape.
 */

import type { PhoneItem, TranscriptDetailPart } from '../protocol/types.ts';

export interface DetailState {
  /** The parts to load, in order, such as `input` then `result` for a tool row. */
  parts: readonly TranscriptDetailPart[];
  /** The part loading now, as an index into `parts`. */
  partIndex: number;
  /** The chunk of that part asked for last. */
  chunk: number;
  /** How many chunks that part has, as its first result said. */
  chunkCount: number;
  /** Each text part's text so far, by part name. */
  text: Readonly<Record<string, string>>;
  /** A subagent's items so far. */
  items: readonly PhoneItem[];
  phase: 'loading' | 'open' | 'tooLarge' | 'failed';
  /** True once the reader collapsed the row: later results are dropped. */
  cancelled: boolean;
  /** The laptop's message when `phase` is `failed`. */
  error: string | null;
}
