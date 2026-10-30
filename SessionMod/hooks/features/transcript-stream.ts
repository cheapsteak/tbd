// transcript-stream: keeps transcript-stream.json, a live view of the main
// loop's answer as the model writes it, so TBD's transcript pane can show the
// answer before Claude Code writes it to the session's JSONL. The pane drops
// each block once the JSONL holds a row with the block's uuid.
//
// The turn.step hook only records chunks in memory and yields each one on at
// once; a separate writer puts the snapshot on disk, at most one write at a
// time and the newest snapshot each time.
import type {
  EngineInterface,
  Frozen,
  SessionAppendInput,
  SessionAppendResult,
  Timer,
  TurnCompleteInput,
  TurnCompleteResult,
  TurnStartInput,
  TurnStartResult,
  TurnStepChunk,
  TurnStepInput,
  TurnStepResult,
} from 'claude-code'

import { describe, resolveContext, writeJSON } from '../shared/session.ts'

export const FEATURE = 'transcript-stream'
export const FILE_NAME = 'transcript-stream.json'
export const SCHEMA_VERSION = 1
/** The least time between the starts of two writes while text streams. */
export const MIN_WRITE_INTERVAL_MS = 100
/** How many main-loop steps the file holds: the current one and the one before. */
export const STEPS_KEPT = 2

export type BlockKind = 'text' | 'thinking'

/** One content block of a step, as the mod knows it. */
export type StreamBlock = {
  kind: BlockKind
  /** The block's index in the response; -1 for a block known only from its row. */
  index: number
  text: string
  ended: boolean
  /** The id of the transcript row that holds the block, once session.append named it. */
  uuid?: string
}

export type StreamStep = {
  index: number
  ended: boolean
  /** Why the model stopped; null until the step ends, and on an interrupted step. */
  stopReason: string | null
  blocks: StreamBlock[]
}

export type StreamTurn = {
  id: string
  /** How the turn completed (`answer`, `aborted`, ...), once it has. */
  completion?: string
}

/**
 * What a change to the snapshot asks of the writer: `streaming` waits out the
 * write interval, `boundary` (a block, step or turn ended, or a turn started)
 * writes as soon as no write is in flight.
 */
export type Change = 'none' | 'streaming' | 'boundary'

/**
 * The in-memory view of the main loop's current turn. Pure: no `$`, no clock.
 * Each method answers what its event changed.
 */
export type StreamRecorder = {
  turnStarted(turnId: string): Change
  stepStarted(turnId: string, index: number): Change
  chunk(chunk: Frozen<TurnStepChunk>): Change
  stepEnded(stopReason: string | null): Change
  appended(kind: BlockKind, uuid: string): Change
  turnCompleted(turnId: string, reason: string): Change
  /** The file's body, less the fields the writer stamps. */
  view(): { turn: StreamTurn | null; steps: object[] }
}

export function createRecorder(): StreamRecorder {
  let turn: StreamTurn | null = null
  let steps: StreamStep[] = []

  function current(): StreamStep | undefined {
    return steps[steps.length - 1]
  }

  /** Ends every open block of the current step but the one at `index`. */
  function endOpenBlocks(exceptIndex?: number): boolean {
    let ended = false
    for (const block of current()?.blocks ?? []) {
      if (!block.ended && block.index !== exceptIndex) {
        block.ended = true
        ended = true
      }
    }
    return ended
  }

  function startTurn(turnId: string): void {
    turn = { id: turnId }
    steps = []
  }

  return {
    turnStarted(turnId) {
      startTurn(turnId)
      return 'boundary'
    },

    stepStarted(turnId, index) {
      if (turn?.id !== turnId) {
        // A step of a turn whose start this load never heard: it is the turn now.
        startTurn(turnId)
      }
      steps.push({ index, ended: false, stopReason: null, blocks: [] })
      steps = steps.slice(-STEPS_KEPT)
      return 'boundary'
    },

    chunk(chunk) {
      const step = current()
      if (step === undefined || step.ended) {
        return 'none'
      }
      switch (chunk.kind) {
        case 'text':
        case 'thinking': {
          let change: Change = endOpenBlocks(chunk.index) ? 'boundary' : 'none'
          let block = step.blocks.find(candidate => candidate.index === chunk.index && !candidate.ended)
          if (block === undefined) {
            block = { kind: chunk.kind, index: chunk.index, text: '', ended: false }
            step.blocks.push(block)
          }
          if (chunk.text !== '') {
            block.text += chunk.text
            if (change === 'none') {
              change = 'streaming'
            }
          }
          return change
        }
        case 'tool':
        case 'input':
          // A tool call's block starts: the blocks before it have ended.
          return endOpenBlocks(chunk.index) ? 'boundary' : 'none'
        case 'stop':
          return endOpenBlocks() ? 'boundary' : 'none'
        default:
          return 'none'
      }
    },

    stepEnded(stopReason) {
      const step = current()
      if (step === undefined) {
        return 'none'
      }
      endOpenBlocks()
      step.ended = true
      step.stopReason = stopReason
      return 'boundary'
    },

    appended(kind, uuid) {
      const step = current()
      if (step === undefined) {
        return 'none'
      }
      // session.append fires at the block's end, so the earliest block of the
      // kind still waiting for its row is the one this row holds. A block the
      // stream carried no chunk for (a thinking block with no readable text)
      // is taken in here, so the blocks after it still meet their own rows.
      const block = step.blocks.find(candidate => candidate.kind === kind && candidate.uuid === undefined)
      if (block === undefined) {
        step.blocks.push({ kind, index: -1, text: '', ended: true, uuid })
        return 'none'
      }
      block.uuid = uuid
      block.ended = true
      return 'boundary'
    },

    turnCompleted(turnId, reason) {
      if (turn?.id !== turnId) {
        return 'none'
      }
      turn.completion = reason
      return 'boundary'
    },

    view() {
      return {
        turn: turn === null ? null : { ...turn },
        steps: steps.map(step => ({
          index: step.index,
          ended: step.ended,
          stopReason: step.stopReason,
          // A thinking block with no readable text has nothing to show.
          blocks: step.blocks
            .filter(block => !(block.kind === 'thinking' && block.text === ''))
            .map(block => ({
              kind: block.kind,
              text: block.text,
              ended: block.ended,
              ...(block.uuid === undefined ? {} : { uuid: block.uuid }),
            })),
        })),
      }
    },
  }
}

/** The clock the writer reads: `$.clock`'s now and after, or a test's. */
export type WriterClock = {
  now(): Promise<number>
  after(ms: number, run: () => void): Timer
}

export type SnapshotWriter = {
  /** Marks the snapshot changed; a `boundary` change skips the write interval. */
  changed(change: Change): void
  /** Resolves once no write is in flight; a write waiting on the clock stays waiting. */
  idle(): Promise<void>
}

/**
 * Writes the newest snapshot, one write at a time. A change made while a write
 * runs is written once it ends; changes made meanwhile collapse into that one
 * write, because `write` renders the snapshot as it stands when it starts.
 * While text streams, a write starts at least MIN_WRITE_INTERVAL_MS after the
 * previous one started; a boundary change does not wait. A write that rejects
 * is dropped, and the next one replaces the whole file.
 */
export function createSnapshotWriter(clock: WriterClock, write: () => Promise<void>): SnapshotWriter {
  let pending = false
  let urgent = false
  let lastStartMs: number | undefined
  let running: Promise<void> | undefined
  let timer: Timer | undefined

  function kick(): void {
    if (!pending || running !== undefined || timer !== undefined) {
      return
    }
    running = writeOnce().finally(() => {
      running = undefined
      kick()
    })
  }

  async function writeOnce(): Promise<void> {
    if (!urgent && lastStartMs !== undefined) {
      const wait = lastStartMs + MIN_WRITE_INTERVAL_MS - (await clock.now())
      if (wait > 0 && !urgent) {
        timer = clock.after(wait, () => {
          timer = undefined
          kick()
        })
        return
      }
    }
    pending = false
    urgent = false
    lastStartMs = await clock.now()
    try {
      await write()
    } catch {
      // Dropped: `write` reports its own failures.
    }
  }

  return {
    changed(change) {
      if (change === 'none') {
        return
      }
      pending = true
      if (change === 'boundary') {
        urgent = true
        timer?.cancel()
        timer = undefined
      }
      kick()
    },
    async idle() {
      while (running !== undefined) {
        await running
      }
    },
  }
}

/** A recorder and the writer that puts its snapshot on disk. */
export type TranscriptStream = {
  recorder: StreamRecorder
  writer: SnapshotWriter
}

/** The snapshot as transcript-stream.json holds it. */
export function snapshotRecord(recorder: StreamRecorder, sessionId: string, now: number): object {
  return {
    schemaVersion: SCHEMA_VERSION,
    sessionId,
    // The app reads it as an integer.
    updatedAtMs: Math.trunc(now),
    ...recorder.view(),
  }
}

let stream: TranscriptStream | undefined

/** This load's stream, made at the first event that needs it. */
export function transcriptStream($: EngineInterface): TranscriptStream {
  if (stream === undefined) {
    const recorder = createRecorder()
    const writer = createSnapshotWriter(
      { now: () => $.clock.now(), after: (ms, run) => $.clock.after(ms, run) },
      () => saveSnapshot($, recorder),
    )
    stream = { recorder, writer }
  }
  return stream
}

async function saveSnapshot($: EngineInterface, recorder: StreamRecorder): Promise<void> {
  try {
    const ctx = await resolveContext($)
    if (ctx !== null) {
      await writeJSON($, `${ctx.dir}/${FILE_NAME}`, snapshotRecord(recorder, ctx.sessionId, await $.clock.now()))
    }
  } catch (error) {
    $.ui.log(`${FEATURE}: could not write the snapshot: ${describe(error)}`, { to: 'debug' })
  }
}

/** The kind of block an assistant row's content block is, or null for one the stream does not carry. */
function blockKind(type: string): BlockKind | null {
  switch (type) {
    case 'text':
      return 'text'
    case 'thinking':
    case 'redacted_thinking':
      return 'thinking'
    default:
      return null
  }
}

// The feature's hooks, which register.ts calls for a spawn that listed
// transcript-stream. Each takes the stream it records into, so a test hands
// in its own. Subagents' events pass straight through: only the main loop
// streams.

/**
 * turn.step: yields every chunk from beneath on, unchanged and at once, and
 * records the main loop's text and thinking. Nothing is awaited between
 * receiving a chunk and yielding it.
 */
export async function* turnStep(
  s: TranscriptStream,
  e: Frozen<TurnStepInput>,
  next: (e: Frozen<TurnStepInput>) => AsyncGenerator<TurnStepChunk, TurnStepResult>,
): AsyncGenerator<TurnStepChunk, TurnStepResult> {
  const chunks = next(e)
  if (e.agentId !== undefined) {
    return yield* chunks
  }
  record(s, () => s.recorder.stepStarted(e.turnId, e.index))
  while (true) {
    const item = await chunks.next()
    if (item.done === true) {
      const result = item.value
      // A null stop reason is an interrupted step, or one no response came for.
      record(s, () => s.recorder.stepEnded(result.stopReason))
      return result
    }
    const chunk = item.value
    record(s, () => s.recorder.chunk(chunk))
    yield chunk
  }
}

/** session.append: names the uuid of the main loop's assistant rows' blocks. Observe only. */
export async function sessionAppend(
  s: TranscriptStream,
  e: Frozen<SessionAppendInput>,
  next: (e: Frozen<SessionAppendInput>) => Promise<SessionAppendResult>,
): Promise<SessionAppendResult> {
  const result = await next(e)
  if (e.agentId === undefined && e.message.type === 'assistant' && result.deny === undefined) {
    for (const block of e.message.content) {
      const kind = blockKind(block.type)
      if (kind !== null) {
        record(s, () => s.recorder.appended(kind, result.uuid))
      }
    }
  }
  return result
}

/** turn.start: a main-loop turn clears the previous turn's steps. */
export async function turnStart(
  s: TranscriptStream,
  e: Frozen<TurnStartInput>,
  next: (e: Frozen<TurnStartInput>) => Promise<TurnStartResult>,
): Promise<TurnStartResult> {
  if (e.agentId === undefined) {
    record(s, () => s.recorder.turnStarted(e.turnId))
  }
  return next(e)
}

/** turn.complete: records how the main-loop turn ended. */
export async function turnComplete(
  s: TranscriptStream,
  e: Frozen<TurnCompleteInput>,
  next: (e: Frozen<TurnCompleteInput>) => Promise<TurnCompleteResult>,
): Promise<TurnCompleteResult> {
  if (e.agentId === undefined) {
    record(s, () => s.recorder.turnCompleted(e.turnId, e.reason))
  }
  return next(e)
}

/** Applies one event to the recorder and tells the writer. A failure here never reaches the session. */
function record(s: TranscriptStream, apply: () => Change): void {
  try {
    s.writer.changed(apply())
  } catch {
    // The recorder is pure; a throw would be a bug, and the answer must flow regardless.
  }
}
