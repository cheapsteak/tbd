// The hooks that run on every change of the prompt box. The test kit raises
// neither prompt.edit nor prompt.change (its `$` carries the engine's
// EventCalls, whose prompt noun has neither), so these tests call the hooks'
// bodies, which register.ts hands each event to, with a stand-in `$`.
//
// This file's module state (the environment read, the draft writer) lasts as
// long as the file, so every test shares one stand-in and resets what it
// records.
import type { EngineInterface, PromptChangeResult, PromptEditResult } from 'claude-code'
import { expect, test } from 'claude-code/testing'

import { sessionEnd } from '../hooks/features/composer-draft.tsx'
import { promptChange, promptEdit } from '../hooks/register.ts'
import type { SessionContext, SessionEnv } from '../hooks/shared/session.ts'

const SESSION_ID = 'sess-1'
const INCARNATION = '5B0C2D9E-4F1A-4C55-9E2B-7A1D3C8F6E01'
const DIR = `/sessions/${SESSION_ID}`
const DRAFT = `${DIR}/composer-draft.json`
const FEATURES_ON: SessionEnv = {
  sessionsDir: '/sessions',
  incarnationId: INCARNATION,
  features: new Set(['composer-draft']),
}
const CTX: SessionContext = { dir: DIR, sessionId: SESSION_ID, incarnationId: INCARNATION, features: FEATURES_ON.features }
const ENV: Record<string, string> = {
  TBD_SESSIONS_DIR: '/sessions',
  TBD_MOD_FEATURES: 'composer-draft',
  TBD_TERMINAL_INCARNATION_ID: INCARNATION,
}
// The person typed `f` after `hal`.
const EDIT = { origin: { kind: 'composer' }, text: 'hal', cursor: 3, start: 3, end: 3, inputText: 'f' } as const
const EDITED: PromptEditResult = { text: 'half', cursor: 4 }

const recorded = {
  writes: [] as { path: string; text: string }[],
  logs: [] as string[],
  failWrites: false,
}

// The `$` calls the hooks reach, answered from memory; the clock stands at a
// fractional millisecond.
const engine = {
  env: { get: async (name: string) => ENV[name] },
  session: { id: async () => SESSION_ID },
  clock: { now: async () => 1_234.75 },
  prompt: { read: async () => ({ text: '', cursor: 0 }) },
  fs: {
    write: async (path: string, text: string) => {
      if (recorded.failWrites) {
        throw new Error('disk full')
      }
      recorded.writes.push({ path, text })
    },
  },
  ui: {
    log: (text: string) => {
      recorded.logs.push(text)
    },
  },
} as unknown as EngineInterface

function fresh(): void {
  recorded.writes = []
  recorded.logs = []
  recorded.failWrites = false
}

/** Waits for every queued draft write: session.end over an empty box only flushes. */
async function settled(): Promise<void> {
  await sessionEnd(engine, CTX)
}

function draftRecords(): Record<string, unknown>[] {
  return recorded.writes.filter(write => write.path === DRAFT).map(write => JSON.parse(write.text))
}

/** A `next` that answers `result` and counts its calls. */
function nextAnswering<T>(result: T): { next: () => Promise<T>; calls: () => number } {
  let calls = 0
  return {
    next: async () => {
      calls += 1
      return result
    },
    calls: () => calls,
  }
}

test('anEditSavesTheBoxNextResolved', async () => {
  fresh()
  const below = nextAnswering(EDITED)

  const box = await promptEdit(engine, FEATURES_ON, EDIT, below.next)
  await settled()

  expect(box).toBe(EDITED)
  expect(below.calls()).toBe(1)
  expect(draftRecords()).toEqual([
    { schemaVersion: 1, sessionId: SESSION_ID, hasDraft: true, text: 'half', cursor: 4, savedAtMs: 1_234 },
  ])
})

test('anEditWhoseWriteFailsStillReturnsTheBox', async () => {
  fresh()
  recorded.failWrites = true
  const below = nextAnswering(EDITED)

  const box = await promptEdit(engine, FEATURES_ON, EDIT, below.next)
  await settled()

  expect(box).toBe(EDITED)
  expect(below.calls()).toBe(1)
  expect(recorded.logs).toContain('composer-draft: could not save the draft: disk full')

  // The writer is not wedged: the next edit is saved.
  recorded.failWrites = false
  await promptEdit(engine, FEATURES_ON, EDIT, nextAnswering(EDITED).next)
  await settled()
  expect(draftRecords()).toHaveLength(1)
})

test('aClearRecordsNoDraft', async () => {
  fresh()
  const below = nextAnswering<PromptChangeResult>({ text: '' })

  const result = await promptChange(engine, FEATURES_ON, { text: '', cursor: 0, origin: { kind: 'clear' } }, below.next)
  await settled()

  expect(result).toEqual({ text: '' })
  expect(below.calls()).toBe(1)
  expect(draftRecords()).toEqual([{ schemaVersion: 1, sessionId: SESSION_ID, hasDraft: false, savedAtMs: 1_234 }])
})

test('aChangeSavesTheBoxAsItStands', async () => {
  fresh()

  await promptChange(
    engine,
    FEATURES_ON,
    { text: 'recalled prompt', cursor: 8, origin: { kind: 'history' } },
    nextAnswering<PromptChangeResult>({ text: 'recalled prompt' }).next,
  )
  await settled()

  expect(draftRecords()).toEqual([
    { schemaVersion: 1, sessionId: SESSION_ID, hasDraft: true, text: 'recalled prompt', cursor: 8, savedAtMs: 1_234 },
  ])
})

// readSessionEnv answers null for a spawn with no TBD_MOD_FEATURES.
test('withoutTheFeatureListEditsAndChangesPassThroughAndWriteNothing', async () => {
  fresh()
  const edit = nextAnswering(EDITED)
  const change = nextAnswering<PromptChangeResult>({ text: '' })

  expect(await promptEdit(engine, null, EDIT, edit.next)).toBe(EDITED)
  expect(await promptChange(engine, null, { text: '', cursor: 0, origin: { kind: 'clear' } }, change.next)).toEqual({
    text: '',
  })
  await settled()

  expect(edit.calls()).toBe(1)
  expect(change.calls()).toBe(1)
  expect(recorded.writes).toEqual([])
})
