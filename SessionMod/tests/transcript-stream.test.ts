// The transcript-stream feature. The test kit raises none of turn.step,
// session.append, turn.start or turn.complete with the shapes these tests
// need, so they call the feature's exported hooks with a stream of their own,
// whose writer records what it was told, and drive the writer with a clock of
// their own.
import type {
  SessionAppendResult,
  Timer,
  TurnStepChunk,
  TurnStepInput,
  TurnStepResult,
} from 'claude-code'
import { expect, test } from 'claude-code/testing'

import {
  MIN_WRITE_INTERVAL_MS,
  createRecorder,
  createSnapshotWriter,
  sessionAppend,
  snapshotRecord,
  turnComplete,
  turnStart,
  turnStep,
} from '../hooks/features/transcript-stream.ts'
import type { Change, TranscriptStream } from '../hooks/features/transcript-stream.ts'

const TURN = 'turn-1'
const STEP: TurnStepInput = { turnId: TURN, index: 0, model: 'claude-test', messageCount: 3 }
const ANSWERED: TurnStepResult = { turnId: TURN, index: 0, answer: '', toolUses: [], stopReason: 'end_turn', usage: null }

/** A stream whose writer records each change it is told of. */
function recordingStream(): { stream: TranscriptStream; changes: Change[] } {
  const changes: Change[] = []
  return {
    stream: {
      recorder: createRecorder(),
      writer: {
        changed: change => {
          changes.push(change)
        },
        idle: async () => {},
      },
    },
    changes,
  }
}

/** A `next` for turn.step that streams `chunks` and returns `result`. */
function streaming(chunks: TurnStepChunk[], result: TurnStepResult = ANSWERED) {
  return async function* (): AsyncGenerator<TurnStepChunk, TurnStepResult> {
    for (const chunk of chunks) {
      yield chunk
    }
    return result
  }
}

/** Runs one step through the hook, collecting what it yields and returns. */
async function runStep(
  stream: TranscriptStream,
  chunks: TurnStepChunk[],
  options: { input?: TurnStepInput; result?: TurnStepResult } = {},
): Promise<{ yielded: TurnStepChunk[]; returned: TurnStepResult }> {
  const generator = turnStep(stream, options.input ?? STEP, streaming(chunks, options.result))
  const yielded: TurnStepChunk[] = []
  while (true) {
    const item = await generator.next()
    if (item.done === true) {
      return { yielded, returned: item.value }
    }
    yielded.push(item.value)
  }
}

/** Raises session.append for an assistant row holding one block of `type`. */
async function append(stream: TranscriptStream, type: string, uuid: string, agentId?: string): Promise<void> {
  const row = {
    message: { type: 'assistant', role: 'assistant', content: [{ type }] },
    door: 'response',
    origin: { kind: 'model', model: 'claude-test' },
    uuid,
    ...(agentId === undefined ? {} : { agentId }),
  } as const
  const stored = { message: row.message, uuid } as unknown as SessionAppendResult
  await sessionAppend(stream, row as never, async () => stored)
}

function text(index: number, value: string): TurnStepChunk {
  return { kind: 'text', index, text: value }
}

function thinking(index: number, value: string): TurnStepChunk {
  return { kind: 'thinking', index, text: value }
}

function blocksOf(stream: TranscriptStream, step = 0): unknown[] {
  const steps = stream.recorder.view().steps as { blocks: unknown[] }[]
  return steps[step]?.blocks ?? []
}

test('aSubagentStepPassesThroughAndRecordsNothing', async () => {
  const { stream, changes } = recordingStream()
  const chunks = [text(0, 'hello')]

  const { yielded } = await runStep(stream, chunks, { input: { ...STEP, agentId: 'agent-1' } })
  await append(stream, 'text', 'row-sub', 'agent-1')

  expect(yielded).toEqual(chunks)
  expect(changes).toEqual([])
  expect(stream.recorder.view().steps).toEqual([])
})

test('everyChunkIsYieldedUnchangedAndInOrder', async () => {
  const { stream } = recordingStream()
  const chunks: TurnStepChunk[] = [
    { kind: 'engine', ref: 1 },
    thinking(0, 'Let me '),
    thinking(0, 'think.'),
    text(1, 'Hi '),
    { kind: 'tool', index: 2, id: 'toolu_1', name: 'Bash' },
    { kind: 'input', index: 2, json: '{"command":"ls"}' },
    { kind: 'stop', stopReason: 'tool_use', usage: null },
  ]
  const result = { ...ANSWERED, stopReason: 'tool_use' as const }

  const { yielded, returned } = await runStep(stream, chunks, { result })

  expect(yielded).toHaveLength(chunks.length)
  yielded.forEach((chunk, i) => expect(chunk).toBe(chunks[i]))
  expect(returned).toBe(result)
})

test('textAndThinkingAreRecordedInStepOrder', async () => {
  const { stream } = recordingStream()

  await runStep(stream, [thinking(0, 'Plan '), thinking(0, 'it.'), text(1, 'Done '), text(1, 'now.')])

  expect(blocksOf(stream)).toEqual([
    { kind: 'thinking', text: 'Plan it.', ended: true },
    { kind: 'text', text: 'Done now.', ended: true },
  ])
  expect(stream.recorder.view().steps).toMatchObject([{ index: 0, ended: true, stopReason: 'end_turn' }])
})

test('aThinkingBlockWithNoTextIsLeftOutButTakesItsUuid', async () => {
  const { stream } = recordingStream()
  stream.recorder.turnStarted(TURN)

  // The empty thinking block streams a chunk with no text; its row comes first.
  const generator = turnStep(stream, STEP, streaming([thinking(0, ''), text(1, 'Answer')]))
  await generator.next()
  await append(stream, 'thinking', 'row-thinking')
  await generator.next()
  await append(stream, 'text', 'row-text')
  await generator.next()

  expect(blocksOf(stream)).toEqual([{ kind: 'text', text: 'Answer', ended: true, uuid: 'row-text' }])
})

test('aThinkingBlockTheStreamNeverShowedStillTakesItsUuid', async () => {
  const { stream } = recordingStream()

  // No chunk at all for the thinking block: only its row says it was there.
  const generator = turnStep(stream, STEP, streaming([text(1, 'Answer')]))
  await append(stream, 'thinking', 'row-thinking')
  await generator.next()
  await append(stream, 'text', 'row-text')
  await generator.next()

  expect(blocksOf(stream)).toEqual([{ kind: 'text', text: 'Answer', ended: true, uuid: 'row-text' }])
})

test('uuidsAttachInOrderAcrossThinkingAndTextBlocks', async () => {
  const { stream } = recordingStream()
  const generator = turnStep(
    stream,
    STEP,
    streaming([thinking(0, 'First thought'), text(1, 'First answer'), thinking(2, 'Second thought'), text(3, 'Second answer')]),
  )

  await generator.next()
  await append(stream, 'thinking', 'row-1')
  await generator.next()
  await append(stream, 'text', 'row-2')
  await generator.next()
  await append(stream, 'thinking', 'row-3')
  await generator.next()
  await append(stream, 'text', 'row-4')
  await generator.next()

  expect(blocksOf(stream)).toEqual([
    { kind: 'thinking', text: 'First thought', ended: true, uuid: 'row-1' },
    { kind: 'text', text: 'First answer', ended: true, uuid: 'row-2' },
    { kind: 'thinking', text: 'Second thought', ended: true, uuid: 'row-3' },
    { kind: 'text', text: 'Second answer', ended: true, uuid: 'row-4' },
  ])
})

test('aStreamingBlockIsOpenUntilTheNextBlockStarts', async () => {
  const { stream, changes } = recordingStream()
  const generator = turnStep(stream, STEP, streaming([text(0, 'one '), text(0, 'two'), text(1, 'three')]))

  await generator.next()
  await generator.next()
  expect(blocksOf(stream)).toEqual([{ kind: 'text', text: 'one two', ended: false }])

  await generator.next()
  expect(blocksOf(stream)).toEqual([
    { kind: 'text', text: 'one two', ended: true },
    { kind: 'text', text: 'three', ended: false },
  ])
  // The step's start, two deltas, then the first block's end with the second's start.
  expect(changes).toEqual(['boundary', 'streaming', 'streaming', 'boundary'])
})

test('anInterruptedStepRecordsANullStopReason', async () => {
  const { stream } = recordingStream()

  await runStep(stream, [text(0, 'Partial')], { result: { ...ANSWERED, stopReason: null } })

  expect(stream.recorder.view().steps).toEqual([
    { index: 0, ended: true, stopReason: null, blocks: [{ kind: 'text', text: 'Partial', ended: true }] },
  ])
})

test('theFileHoldsTheCurrentStepAndTheOneBefore', async () => {
  const { stream } = recordingStream()

  for (const index of [0, 1, 2]) {
    await runStep(stream, [text(0, `step ${index}`)], { input: { ...STEP, index }, result: { ...ANSWERED, index } })
  }

  const steps = stream.recorder.view().steps as { index: number }[]
  expect(steps.map(step => step.index)).toEqual([1, 2])
})

test('aNewTurnClearsTheSteps', async () => {
  const { stream, changes } = recordingStream()
  await turnStart(stream, { text: 'hi', turnId: TURN }, async () => ({ turnId: TURN }))
  await runStep(stream, [text(0, 'Old answer')])
  await turnComplete(stream, { answer: 'Old answer', durationMs: 5, isAborted: false, turnId: TURN, reason: 'answer' }, async () => ({ text: '' }))
  expect(stream.recorder.view().turn).toEqual({ id: TURN, completion: 'answer' })

  changes.length = 0
  await turnStart(stream, { text: 'again', turnId: 'turn-2' }, async () => ({ turnId: 'turn-2' }))

  expect(stream.recorder.view()).toEqual({ turn: { id: 'turn-2' }, steps: [] })
  expect(changes).toEqual(['boundary'])
})

test('aSubagentTurnLeavesTheMainTurnAlone', async () => {
  const { stream, changes } = recordingStream()
  await turnStart(stream, { text: 'hi', turnId: TURN }, async () => ({ turnId: TURN }))
  changes.length = 0

  await turnStart(stream, { text: 'task', turnId: 'turn-sub', agentId: 'agent-1' }, async () => ({ turnId: 'turn-sub' }))
  await turnComplete(
    stream,
    { answer: '', durationMs: 5, isAborted: false, turnId: 'turn-sub', agentId: 'agent-1', reason: 'answer' },
    async () => ({ text: '' }),
  )

  expect(stream.recorder.view().turn).toEqual({ id: TURN })
  expect(changes).toEqual([])
})

test('theSnapshotRecordCarriesTheSchemaAndWholeMilliseconds', () => {
  const recorder = createRecorder()
  recorder.turnStarted(TURN)

  expect(snapshotRecord(recorder, 'sess-1', 1_234.75)).toEqual({
    schemaVersion: 1,
    sessionId: 'sess-1',
    updatedAtMs: 1_234,
    turn: { id: TURN },
    steps: [],
  })
})

// The writer, driven by a clock the test moves by hand. Each write holds until
// the test finishes it, so "one write in flight" is observable.
type ManualClock = {
  now: number
  timers: { at: number; run: () => void; live: boolean }[]
}

function manualClock(): { state: ManualClock; clock: { now(): Promise<number>; after(ms: number, run: () => void): Timer } } {
  const state: ManualClock = { now: 1_000, timers: [] }
  return {
    state,
    clock: {
      now: async () => state.now,
      after: (ms, run) => {
        const timer = { at: state.now + ms, run, live: true }
        state.timers.push(timer)
        return {
          cancel: () => {
            timer.live = false
          },
        }
      },
    },
  }
}

/** Moves the clock and fires the timers now due. */
async function advance(state: ManualClock, ms: number): Promise<void> {
  state.now += ms
  for (const timer of state.timers) {
    if (timer.live && timer.at <= state.now) {
      timer.live = false
      timer.run()
    }
  }
  await settle()
}

/** Lets every promise that can settle now settle. */
async function settle(): Promise<void> {
  for (let i = 0; i < 20; i += 1) {
    await Promise.resolve()
  }
}

function heldWrites(): { writes: { version: number; startedAt: number; finish: () => void }[]; write: (version: () => number, state: ManualClock) => () => Promise<void> } {
  const writes: { version: number; startedAt: number; finish: () => void }[] = []
  return {
    writes,
    write: (version, state) => () =>
      new Promise<void>(resolve => {
        writes.push({ version: version(), startedAt: state.now, finish: resolve })
      }),
  }
}

test('theWriterKeepsOneWriteInFlightAndWritesTheNewest', async () => {
  const { state, clock } = manualClock()
  const held = heldWrites()
  let version = 0
  const writer = createSnapshotWriter(clock, held.write(() => version, state))

  version = 1
  writer.changed('streaming')
  await settle()
  version = 2
  writer.changed('streaming')
  version = 3
  writer.changed('streaming')
  await settle()
  expect(held.writes.map(write => write.version)).toEqual([1])

  await advance(state, MIN_WRITE_INTERVAL_MS)
  expect(held.writes).toHaveLength(1)

  held.writes[0]?.finish()
  await settle()
  expect(held.writes.map(write => write.version)).toEqual([1, 3])
})

test('theWriterSpacesStreamingWritesByTheInterval', async () => {
  const { state, clock } = manualClock()
  const held = heldWrites()
  let version = 0
  const writer = createSnapshotWriter(clock, held.write(() => version, state))

  version = 1
  writer.changed('streaming')
  await settle()
  held.writes[0]?.finish()
  await settle()

  version = 2
  writer.changed('streaming')
  await settle()
  await advance(state, MIN_WRITE_INTERVAL_MS - 1)
  expect(held.writes).toHaveLength(1)

  await advance(state, 1)
  expect(held.writes.map(write => [write.version, write.startedAt])).toEqual([
    [1, 1_000],
    [2, 1_000 + MIN_WRITE_INTERVAL_MS],
  ])
})

test('aBoundaryWritesWithoutWaitingForTheInterval', async () => {
  const { state, clock } = manualClock()
  const held = heldWrites()
  let version = 0
  const writer = createSnapshotWriter(clock, held.write(() => version, state))

  version = 1
  writer.changed('streaming')
  await settle()
  held.writes[0]?.finish()
  await settle()

  version = 2
  writer.changed('streaming')
  await settle()
  version = 3
  writer.changed('boundary')
  await settle()

  expect(held.writes.map(write => [write.version, write.startedAt])).toEqual([
    [1, 1_000],
    [3, 1_000],
  ])
})

test('aBoundaryDuringAWriteIsWrittenAsSoonAsItEnds', async () => {
  const { state, clock } = manualClock()
  const held = heldWrites()
  let version = 0
  const writer = createSnapshotWriter(clock, held.write(() => version, state))

  version = 1
  writer.changed('streaming')
  await settle()
  version = 2
  writer.changed('boundary')
  await settle()
  expect(held.writes).toHaveLength(1)

  held.writes[0]?.finish()
  await settle()
  expect(held.writes.map(write => [write.version, write.startedAt])).toEqual([
    [1, 1_000],
    [2, 1_000],
  ])
})

test('aFailedWriteIsDroppedAndTheNextOneStillRuns', async () => {
  const { state, clock } = manualClock()
  const attempts: number[] = []
  let version = 0
  const writer = createSnapshotWriter(clock, async () => {
    attempts.push(version)
    if (version === 1) {
      throw new Error('disk full')
    }
  })

  version = 1
  writer.changed('boundary')
  await settle()
  version = 2
  writer.changed('boundary')
  await settle()
  await writer.idle()

  expect(attempts).toEqual([1, 2])
  expect(state.timers).toEqual([])
})
