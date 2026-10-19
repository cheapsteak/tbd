import type { On, RenderPropsOf } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import type { MockClock } from 'claude-code/testing'

import { NOTICE_MS, RESTORE_RETRY_MS, createDraftWriter, draftRecord } from '../hooks/features/composer-draft.tsx'

const SESSION_ID = 'sess-1'
const INCARNATION = '5B0C2D9E-4F1A-4C55-9E2B-7A1D3C8F6E01'
const DIR = `/sessions/${SESSION_ID}`
const DRAFT = `${DIR}/composer-draft.json`
const UNRESTORED = `${DIR}/composer-draft.unrestored`
const SAVED = 'half-written prompt'
const SLOW_WRITE_MS = 100
const START = { cwd: '/work', surface: 'terminal', isInteractive: true } as const
const END = { reason: 'other', sessionId: SESSION_ID, resume: { id: SESSION_ID } } as const
const BAND: RenderPropsOf['AbovePrompt'] = {
  hasSurvey: false,
  isWorking: false,
  maxRows: 8,
  bodyColumns: 75,
  scroll: { offset: 0, bodyRows: 7 },
  view: {},
}
const NOTICE = { type: 'Text', text: 'Restored your unsent draft' }

type World = {
  /** composer-draft.json's text; undefined for no file. */
  file: string | undefined
  /** The file is there, but reading it fails. */
  readFails: boolean
  /** The prompt box's text; a fill that lands replaces it. */
  box: string
  /** Answers for successive fills; `true` once they run out. */
  fillAnswers: boolean[]
  writes: { path: string; text: string }[]
  fills: { text: string; mode: string; isFilled: boolean }[]
  logs: string[]
  clock: MockClock
}

type WorldOptions = {
  /** A draft composer-draft.json holds at the start. */
  draft?: string
  file?: string
  readFails?: boolean
  box?: string
  fillAnswers?: boolean[]
  slowDraftWrite?: boolean
  /** Spawned with no TBD_MOD_FEATURES. */
  withoutFeatures?: boolean
}

/** composer-draft.json as the feature writes it for a draft. */
function draftFile(text: string): string {
  return JSON.stringify({ schemaVersion: 1, sessionId: SESSION_ID, hasDraft: true, text, cursor: text.length, savedAtMs: 500 })
}

// Answers everything the mod calls beneath it, from the world's fields as
// they stand when each call lands, and records what the mod did.
function world(on: On, options: WorldOptions = {}): World {
  mock.env(on, {
    TBD_SESSIONS_DIR: '/sessions',
    TBD_TERMINAL_INCARNATION_ID: INCARNATION,
    ...(options.withoutFeatures ? {} : { TBD_MOD_FEATURES: 'composer-draft' }),
  })
  const w: World = {
    file: options.draft === undefined ? options.file : draftFile(options.draft),
    readFails: options.readFails ?? false,
    box: options.box ?? '',
    fillAnswers: [...(options.fillAnswers ?? [])],
    writes: [],
    fills: [],
    logs: [],
    clock: mock.clock(on, { now: 1_000 }),
  }
  on('session.id', () => ({ value: SESSION_ID }))
  on('fs.write', async ($, e) => {
    if (options.slowDraftWrite && e.path === DRAFT) {
      await w.clock.sleep(SLOW_WRITE_MS)
    }
    w.writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('fs.exists', ($, e) => ({ value: e.path === DRAFT && (w.file !== undefined || w.readFails) }))
  on('fs.read', ($, e) => {
    if (e.path === DRAFT && w.readFails) {
      return { deny: `EACCES: ${e.path}` }
    }
    return e.path === DRAFT && w.file !== undefined ? { value: w.file } : { deny: `ENOENT: ${e.path}` }
  })
  on('prompt.read', () => ({ value: { text: w.box, cursor: w.box.length } }))
  on('prompt.fill', ($, e) => {
    const isFilled = w.fillAnswers.shift() ?? true
    w.fills.push({ text: e.text, mode: e.mode, isFilled })
    if (isFilled) {
      w.box = e.text
    }
    return { isFilled }
  })
  on('ui.log', ($, e) => {
    w.logs.push(e.text)
    return { value: undefined }
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.end', ($, e) => ({ sessionId: e.sessionId }))
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine band</Text>
  })
  return w
}

function draftRecords(w: World): Record<string, unknown>[] {
  return w.writes.filter(write => write.path === DRAFT).map(write => JSON.parse(write.text))
}

function wroteUnrestored(w: World): boolean {
  return w.writes.some(write => write.path === UNRESTORED)
}

test('writerKeepsOnlyTheNewestQueuedBox', async () => {
  const written: string[] = []
  let release = () => {}
  const firstWriteHeld = new Promise<void>(resolve => {
    release = resolve
  })
  const writer = createDraftWriter(async box => {
    written.push(box.text)
    if (written.length === 1) {
      await firstWriteHeld
    }
  })

  writer.queue({ text: 'h', cursor: 1 })
  writer.queue({ text: 'ha', cursor: 2 })
  writer.queue({ text: 'hal', cursor: 3 })
  release()
  await writer.flush()

  expect(written).toEqual(['h', 'hal'])
})

test('anEmptyBoxRecordsNoDraft', () => {
  const record = draftRecord(SESSION_ID, { text: '', cursor: 0 }, 42)

  expect(record).toStrictEqual({ schemaVersion: 1, sessionId: SESSION_ID, hasDraft: false, savedAtMs: 42 })
  expect(record).not.toHaveProperty('text')
})

test('aDraftRecordsItsTextAndCursor', () => {
  expect(draftRecord(SESSION_ID, { text: SAVED, cursor: 4 }, 42)).toStrictEqual({
    schemaVersion: 1,
    sessionId: SESSION_ID,
    hasDraft: true,
    text: SAVED,
    cursor: 4,
    savedAtMs: 42,
  })
})

test('aDraftRecordsWholeMilliseconds', () => {
  expect(draftRecord(SESSION_ID, { text: SAVED, cursor: 4 }, 1_234.75)).toMatchObject({ savedAtMs: 1_234 })
  expect(draftRecord(SESSION_ID, { text: '', cursor: 0 }, 1_234.75)).toMatchObject({ savedAtMs: 1_234 })
})

test('aFailingWriteNeverLosesTheEdit', async () => {
  const written: string[] = []
  const writer = createDraftWriter(async box => {
    if (box.text === 'h') {
      throw new Error('disk full')
    }
    written.push(box.text)
  })

  expect(() => writer.queue({ text: 'h', cursor: 1 })).not.toThrow()
  await expect(writer.flush()).resolves.toBeUndefined()
  writer.queue({ text: 'ha', cursor: 2 })
  await writer.flush()

  expect(written).toEqual(['ha'])
})

test('aStartWithoutADraftSavesTheBox', async ($, on) => {
  const w = world(on)

  await $.session.start(START)
  await w.clock.settle()

  expect(w.fills).toEqual([])
  expect(draftRecords(w)).toEqual([{ schemaVersion: 1, sessionId: SESSION_ID, hasDraft: false, savedAtMs: 1_000 }])
})

// An unreadable file may hold a draft: the start neither overwrites it nor
// settles the process, so a later start that can read it still restores it.
for (const [name, options] of [
  ['aDraftFileThatDoesNotParseIsLeftAlone', { file: '{"hasDraft":tru' }],
  ['aDraftFileThatCannotBeReadIsLeftAlone', { readFails: true }],
] as const) {
  test(name, async ($, on) => {
    const w = world(on, options)

    await $.session.start(START)
    await w.clock.settle()

    expect(draftRecords(w)).toEqual([])
    expect(w.fills).toEqual([])
    expect(w.logs.some(line => line.startsWith('composer-draft: could not read composer-draft.json, left it alone'))).toBe(
      true,
    )

    w.readFails = false
    w.file = draftFile(SAVED)
    await $.session.start(START)
    await w.clock.settle()

    expect(w.fills).toEqual([{ text: SAVED, mode: 'replace', isFilled: true }])
  })
}

test('restoreFillsAnEmptyBox', async ($, on) => {
  const w = world(on, { draft: SAVED })

  await $.session.start(START)
  await w.clock.settle()

  expect(w.fills).toEqual([{ text: SAVED, mode: 'replace', isFilled: true }])
  expect(w.logs).toContain('composer-draft: restored')
  expect(wroteUnrestored(w)).toBe(false)
})

test('restoreRetriesWhileTheBoxRefuses', async ($, on) => {
  const w = world(on, { draft: SAVED, fillAnswers: [false, false] })

  await $.session.start(START)
  await w.clock.settle()
  expect(w.fills).toHaveLength(1)
  await w.clock.advance(RESTORE_RETRY_MS)
  expect(w.fills).toHaveLength(2)
  await w.clock.advance(RESTORE_RETRY_MS)
  await w.clock.advance(10 * RESTORE_RETRY_MS)

  expect(w.fills).toEqual([
    { text: SAVED, mode: 'replace', isFilled: false },
    { text: SAVED, mode: 'replace', isFilled: false },
    { text: SAVED, mode: 'replace', isFilled: true },
  ])
})

test('aNonEmptyBoxGetsUnrestoredInstead', async ($, on) => {
  const w = world(on, { draft: SAVED, box: 'typed meanwhile' })

  await $.session.start(START)
  await w.clock.settle()

  expect(w.fills).toEqual([])
  expect(w.box).toBe('typed meanwhile')
  expect(w.writes).toContainEqual({ path: UNRESTORED, text: SAVED })
  expect(w.logs).toContain('composer-draft: box was not empty, saved the draft to composer-draft.unrestored')
})

test('aSecondStartInTheSameIncarnationRestoresNothing', async ($, on) => {
  const w = world(on, { draft: SAVED })
  await $.session.start(START)
  await w.clock.settle()
  expect(w.fills).toHaveLength(1)

  // A reload: the draft file still holds the draft, and so does the box.
  await $.session.start(START)
  await w.clock.settle()
  await w.clock.advance(10 * RESTORE_RETRY_MS)

  expect(w.fills).toHaveLength(1)
  expect(wroteUnrestored(w)).toBe(false)
})

test('aReloadNeverTakesThePersonsOwnDraftForOneToRestore', async ($, on) => {
  const w = world(on)
  await $.session.start(START)
  await w.clock.settle()

  // The person typed a draft, which was saved; then the module reloads.
  w.box = 'typed since'
  w.file = draftFile('typed since')
  await $.session.start(START)
  await w.clock.settle()

  expect(w.fills).toEqual([])
  expect(wroteUnrestored(w)).toBe(false)
})

test('noticeShowsThenHidesAfterThreeSeconds', async ($, on) => {
  const w = world(on, { draft: SAVED })
  await $.session.start(START)
  await w.clock.settle()

  const bands = [
    await $.ui.mount({ plugin: 'tbd', surface: 'terminal', component: 'AbovePrompt', props: BAND }),
    await $.ui.mount({ plugin: 'tbd', surface: 'desktop', component: 'AbovePrompt', props: BAND }),
  ]
  for (const band of bands) {
    expect(await band.find(NOTICE)).toBeDefined()
    expect(await band.find({ type: 'Text', text: 'engine band' })).toBeDefined()
  }

  await w.clock.advance(NOTICE_MS - 1)
  for (const band of bands) {
    expect(await band.find(NOTICE)).toBeDefined()
  }

  await w.clock.advance(1)
  for (const band of bands) {
    expect(await band.find(NOTICE)).toBeUndefined()
    expect(await band.find({ type: 'Text', text: 'engine band' })).toBeDefined()
  }
})

test('theNoticeYieldsToASurvey', async ($, on) => {
  const w = world(on, { draft: SAVED })
  await $.session.start(START)
  await w.clock.settle()

  const band = await $.ui.mount({
    plugin: 'tbd',
    surface: 'terminal',
    component: 'AbovePrompt',
    props: { ...BAND, hasSurvey: true },
  })

  expect(await band.find(NOTICE)).toBeUndefined()
  expect(await band.find({ type: 'Text', text: 'engine band' })).toBeDefined()
})

test('withoutTheFeatureListTheBandPassesThroughAndNothingIsRestored', async ($, on) => {
  const w = world(on, { draft: SAVED, withoutFeatures: true })
  await $.session.start(START)
  await w.clock.settle()

  const band = await $.ui.mount({ plugin: 'tbd', surface: 'terminal', component: 'AbovePrompt', props: BAND })

  expect(await band.find(NOTICE)).toBeUndefined()
  expect(await band.find({ type: 'Text', text: 'engine band' })).toBeDefined()
  expect(w.fills).toEqual([])
  expect(w.writes).toEqual([])
})

test('aNoticeLeftByAnEarlierLoadIsTakenDownAtTheNextStart', async ($, on) => {
  const w = world(on, { draft: SAVED })
  await $.session.start(START)
  await w.clock.settle()

  // A reload before the notice's timer fires drops that timer.
  await w.clock.advance(NOTICE_MS / 3)
  await $.session.start(START)
  await w.clock.settle()

  const band = await $.ui.mount({ plugin: 'tbd', surface: 'terminal', component: 'AbovePrompt', props: BAND })
  expect(await band.find(NOTICE)).toBeUndefined()
})

test('sessionEndAwaitsTheFinalWrite', async ($, on) => {
  const w = world(on, { box: SAVED, slowDraftWrite: true })

  let isEnded = false
  const ended = $.session.end(END).then(() => {
    isEnded = true
  })
  await w.clock.settle()
  expect(isEnded).toBe(false)
  await w.clock.advance(SLOW_WRITE_MS)
  await ended

  expect(draftRecords(w)).toEqual([
    { schemaVersion: 1, sessionId: SESSION_ID, hasDraft: true, text: SAVED, cursor: SAVED.length, savedAtMs: 1_000 },
  ])
})

test('anEmptyBoxAtSessionEndKeepsTheSavedDraft', async ($, on) => {
  const w = world(on, { draft: SAVED, box: '' })

  await $.session.end(END)

  expect(draftRecords(w)).toEqual([])
})
