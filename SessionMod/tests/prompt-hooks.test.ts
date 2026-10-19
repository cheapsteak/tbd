// The hooks that run on every change of the prompt box. The test kit raises
// neither prompt.edit nor prompt.change (its `$` carries the engine's
// EventCalls, whose prompt noun has neither), so these tests call the hooks'
// bodies, which register.ts hands each event to, with a stand-in `$`.
//
// This file's module state (the environment read, the draft writer, the
// restorable mark, a pending restore) lasts as long as the file, so every
// test shares one stand-in, starts from an empty box, and resets what it
// records. A test that starts a restore lets it land before it ends.
import type { EngineInterface, PromptChangeOrigin, PromptChangeResult, PromptEditResult } from 'claude-code'
import { expect, test } from 'claude-code/testing'

import { sessionEnd, sessionStart } from '../hooks/features/composer-draft.tsx'
import { promptChange, promptEdit } from '../hooks/register.ts'
import type { SessionContext, SessionEnv } from '../hooks/shared/session.ts'

const SESSION_ID = 'sess-1'
const INCARNATION = '5B0C2D9E-4F1A-4C55-9E2B-7A1D3C8F6E01'
const DIR = `/sessions/${SESSION_ID}`
const DRAFT = `${DIR}/composer-draft.json`
const RESTORE_RECORD = `${DIR}/composer-draft.restore.json`
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
// What a large paste leaves in the box: Claude Code's placeholder, never the
// pasted lines.
const PASTED = 'x[Pasted text #2 +50 lines]'
const SAVED = 'half-written prompt'
const EMPTY = { text: '', cursor: 0 }

const recorded = {
  writes: [] as { path: string; text: string }[],
  logs: [] as string[],
  failWrites: false,
  /** What `$.prompt.read()` answers; a fill that lands replaces it. */
  box: EMPTY as { text: string; cursor: number },
  /** `$.state`, by key. */
  state: {} as Record<string, unknown>,
  /** composer-draft.json's text; undefined for no file. */
  file: undefined as string | undefined,
  /** Answers for successive fills; `true` once they run out. */
  fillAnswers: [] as boolean[],
  fills: [] as string[],
  /** Callbacks `$.clock.after` was handed, which a test runs by hand. */
  timers: [] as (() => void)[],
}

// The `$` calls the hooks reach, answered from memory; the clock stands at a
// fractional millisecond.
const engine = {
  env: { get: async (name: string) => ENV[name] },
  session: { id: async () => SESSION_ID },
  clock: {
    now: async () => 1_234.75,
    after: (ms: number, run: () => void) => {
      recorded.timers.push(run)
      return { cancel: () => {} }
    },
  },
  prompt: {
    read: async () => recorded.box,
    fill: async ({ text }: { text: string }) => {
      const isFilled = recorded.fillAnswers.shift() ?? true
      recorded.fills.push(text)
      if (isFilled) {
        recorded.box = { text, cursor: text.length }
      }
      return { isFilled }
    },
  },
  fs: {
    write: async (path: string, text: string) => {
      if (recorded.failWrites) {
        throw new Error('disk full')
      }
      recorded.writes.push({ path, text })
    },
    exists: async (path: string) => path === DRAFT && recorded.file !== undefined,
    read: async (path: string) => {
      if (path === DRAFT && recorded.file !== undefined) {
        return recorded.file
      }
      throw new Error(`ENOENT: ${path}`)
    },
  },
  state: {
    get: async (ref: { key: string }) => ({ value: recorded.state[ref.key], version: 0 }),
    set: async (ref: { key: string }, value: unknown) => {
      recorded.state[ref.key] = value
      return { isSet: true, version: 1 }
    },
  },
  ui: {
    log: (text: string) => {
      recorded.logs.push(text)
    },
  },
} as unknown as EngineInterface

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

/** Raises prompt.change with the box `text` left by `origin`. */
async function change(text: string, origin: PromptChangeOrigin): Promise<void> {
  await promptChange(engine, FEATURES_ON, { text, cursor: text.length, origin }, nextAnswering<PromptChangeResult>({ text }).next)
}

/** Raises prompt.edit whose box after the edit is `text`. */
async function edit(text: string): Promise<void> {
  await promptEdit(engine, FEATURES_ON, EDIT, nextAnswering<PromptEditResult>({ text, cursor: text.length }).next)
}

/**
 * Waits for every queued draft write. session.end over an empty box only
 * flushes, so the box reads empty while it runs.
 */
async function settled(): Promise<void> {
  const box = recorded.box
  recorded.box = EMPTY
  await sessionEnd(engine, CTX)
  recorded.box = box
}

/** An empty box, a clean record, and the mark restorable, as a session starts. */
async function fresh(): Promise<void> {
  recorded.failWrites = false
  recorded.box = EMPTY
  await change('', { kind: 'clear' })
  await settled()
  recorded.writes = []
  recorded.logs = []
  recorded.state = {}
  recorded.file = undefined
  recorded.fillAnswers = []
  recorded.fills = []
  recorded.timers = []
}

/** Lets the restore session.start set off run to `isDone`; it runs on the stand-in's promises. */
async function until(isDone: () => boolean): Promise<void> {
  for (let turn = 0; turn < 1_000 && !isDone(); turn += 1) {
    await Promise.resolve()
  }
  expect(isDone()).toBe(true)
}

function draftRecords(): Record<string, unknown>[] {
  return recorded.writes.filter(write => write.path === DRAFT).map(write => JSON.parse(write.text))
}

function lastDraftRecord(): Record<string, unknown> | undefined {
  return draftRecords().at(-1)
}

function wroteRestoreRecord(): boolean {
  return recorded.writes.some(write => write.path === RESTORE_RECORD)
}

/** composer-draft.json as the feature writes it for a draft. */
function draftFile(text: string, restorable: boolean): string {
  return JSON.stringify({ schemaVersion: 1, sessionId: SESSION_ID, hasDraft: true, text, cursor: text.length, restorable, savedAtMs: 500 })
}

test('anEditSavesTheBoxNextResolved', async () => {
  await fresh()
  const below = nextAnswering(EDITED)

  const box = await promptEdit(engine, FEATURES_ON, EDIT, below.next)
  await settled()

  expect(box).toBe(EDITED)
  expect(below.calls()).toBe(1)
  expect(draftRecords()).toEqual([
    { schemaVersion: 1, sessionId: SESSION_ID, hasDraft: true, text: 'half', cursor: 4, restorable: true, savedAtMs: 1_234 },
  ])
})

test('anEditWhoseWriteFailsStillReturnsTheBox', async () => {
  await fresh()
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
  await fresh()
  const below = nextAnswering<PromptChangeResult>({ text: '' })

  const result = await promptChange(engine, FEATURES_ON, { text: '', cursor: 0, origin: { kind: 'clear' } }, below.next)
  await settled()

  expect(result).toEqual({ text: '' })
  expect(below.calls()).toBe(1)
  expect(draftRecords()).toEqual([{ schemaVersion: 1, sessionId: SESSION_ID, hasDraft: false, savedAtMs: 1_234 }])
})

test('aChangeSavesTheBoxAsItStands', async () => {
  await fresh()

  await promptChange(
    engine,
    FEATURES_ON,
    { text: 'recalled prompt', cursor: 8, origin: { kind: 'history' } },
    nextAnswering<PromptChangeResult>({ text: 'recalled prompt' }).next,
  )
  await settled()

  expect(draftRecords()).toEqual([
    {
      schemaVersion: 1,
      sessionId: SESSION_ID,
      hasDraft: true,
      text: 'recalled prompt',
      cursor: 8,
      restorable: false,
      savedAtMs: 1_234,
    },
  ])
})

// readSessionEnv answers null for a spawn with no TBD_MOD_FEATURES.
test('withoutTheFeatureListEditsAndChangesPassThroughAndWriteNothing', async () => {
  await fresh()
  const edited = nextAnswering(EDITED)
  const changed = nextAnswering<PromptChangeResult>({ text: '' })

  expect(await promptEdit(engine, null, EDIT, edited.next)).toBe(EDITED)
  expect(await promptChange(engine, null, { text: '', cursor: 0, origin: { kind: 'clear' } }, changed.next)).toEqual({
    text: '',
  })
  await settled()

  expect(edited.calls()).toBe(1)
  expect(changed.calls()).toBe(1)
  expect(recorded.writes).toEqual([])
})

// A large paste raises no prompt.edit: it reaches the box as an engine change
// whose text holds only the placeholder.
test('anEngineChangeMarksTheDraftNotRestorable', async () => {
  await fresh()

  await change(PASTED, { kind: 'engine' })
  await settled()

  expect(lastDraftRecord()).toMatchObject({ hasDraft: true, text: PASTED, restorable: false })
  // Kept where a reload of the module finds it.
  expect(recorded.state.composerDraftRestorable).toBe(false)
})

test('everyOriginButAClearOrAFillMarksTheDraft', async () => {
  const origins = [
    { kind: 'engine' },
    { kind: 'history' },
    { kind: 'undo' },
    { kind: 'app' },
    // A kind this build does not know reads as `engine`.
    { kind: 'dictation' } as unknown as PromptChangeOrigin,
  ] as PromptChangeOrigin[]
  for (const origin of origins) {
    await fresh()

    await change('recalled [Image #1]', origin)
    await settled()

    expect(lastDraftRecord()).toMatchObject({ hasDraft: true, restorable: false })
  }
})

test('anEditAfterAPasteKeepsTheMark', async () => {
  await fresh()

  await change(PASTED, { kind: 'engine' })
  await edit(`${PASTED} and more`)
  await settled()

  expect(lastDraftRecord()).toMatchObject({ text: `${PASTED} and more`, restorable: false })
})

test('aClearMakesTheNextDraftRestorable', async () => {
  await fresh()
  await change(PASTED, { kind: 'engine' })
  await settled()

  await change('', { kind: 'clear' })
  await edit('h')
  await settled()

  expect(lastDraftRecord()).toMatchObject({ text: 'h', restorable: true })
  expect(recorded.state.composerDraftRestorable).toBe(true)
})

test('anEditThatEmptiesTheBoxMakesTheNextDraftRestorable', async () => {
  await fresh()
  await change(PASTED, { kind: 'engine' })
  await settled()

  await edit('')
  await settled()
  await edit('a')
  await settled()

  expect(draftRecords().slice(-2)).toEqual([
    { schemaVersion: 1, sessionId: SESSION_ID, hasDraft: false, savedAtMs: 1_234 },
    { schemaVersion: 1, sessionId: SESSION_ID, hasDraft: true, text: 'a', cursor: 1, restorable: true, savedAtMs: 1_234 },
  ])
})

test('anotherPluginsFillKeepsTheMark', async () => {
  await fresh()

  await change('filled by another plugin', { kind: 'plugin', name: 'other' })
  await settled()
  expect(lastDraftRecord()).toMatchObject({ restorable: true })

  await change(PASTED, { kind: 'engine' })
  await change(`${PASTED} filled`, { kind: 'plugin', name: 'other' })
  await settled()
  expect(lastDraftRecord()).toMatchObject({ text: `${PASTED} filled`, restorable: false })
})

// The restore's fill raises a `plugin` change named after this plugin, and
// that change carries the mark the saved draft was written with: a draft the
// person was warned about stays one to warn about.
for (const restorable of [true, false]) {
  test(`theRestoreFillCarriesTheSavedMark (${restorable})`, async () => {
    await fresh()
    recorded.file = draftFile(SAVED, restorable)

    await sessionStart(engine, CTX)
    await until(wroteRestoreRecord)
    expect(recorded.fills).toEqual([SAVED])
    await change(SAVED, { kind: 'plugin', name: 'tbd' })
    await settled()

    expect(draftRecords()).toEqual([
      { schemaVersion: 1, sessionId: SESSION_ID, hasDraft: true, text: SAVED, cursor: SAVED.length, restorable, savedAtMs: 1_234 },
    ])
  })
}

// The engine collapses an over-long fill as it does a paste, and the box then
// holds a placeholder in place of the saved text.
test('aRestoreFillTheEngineCollapsedIsNotRestorable', async () => {
  await fresh()
  recorded.file = draftFile(SAVED, true)

  await sessionStart(engine, CTX)
  await until(wroteRestoreRecord)
  await change('[Pasted text #1 +50 lines]', { kind: 'plugin', name: 'tbd' })
  await settled()

  expect(lastDraftRecord()).toMatchObject({ text: '[Pasted text #1 +50 lines]', restorable: false })
})

// Until the fill lands, composer-draft.json holds the only copy of the draft,
// and an empty box saved then would overwrite it.
test('anEmptyBoxIsNotSavedWhileARestoreIsPending', async () => {
  await fresh()
  recorded.file = draftFile(SAVED, true)
  recorded.fillAnswers = [false]

  await sessionStart(engine, CTX)
  await until(() => recorded.timers.length === 1)
  await edit('')
  await change('', { kind: 'clear' })
  await settled()
  expect(draftRecords()).toEqual([])

  // The retry lands the fill, and the box saves as before.
  recorded.timers[0]?.()
  await until(wroteRestoreRecord)
  await change(SAVED, { kind: 'plugin', name: 'tbd' })
  await change('', { kind: 'clear' })
  await settled()

  expect(draftRecords().at(-1)).toEqual({ schemaVersion: 1, sessionId: SESSION_ID, hasDraft: false, savedAtMs: 1_234 })
})
