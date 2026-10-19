import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import type { MockClock } from 'claude-code/testing'

const SESSION_ID = 'sess-1'
const INCARNATION = '5B0C2D9E-4F1A-4C55-9E2B-7A1D3C8F6E01'
const ALIVE = `/sessions/${SESSION_ID}/alive.json`
const START = { cwd: '/work', surface: 'terminal', isInteractive: true } as const
const END = { reason: 'other', sessionId: SESSION_ID, resume: { id: SESSION_ID } } as const
const FEATURES_ON = {
  TBD_SESSIONS_DIR: '/sessions',
  TBD_MOD_FEATURES: 'composer-draft',
  TBD_TERMINAL_INCARNATION_ID: INCARNATION,
}

type World = { writes: { path: string; text: string }[]; clock: MockClock }

// Answers everything the mod calls beneath it and records each file written.
// No composer-draft.json exists and the box is empty.
function world(on: On, env: Record<string, string>, sessionId = SESSION_ID): World {
  const writes: World['writes'] = []
  mock.env(on, env)
  const clock = mock.clock(on, { now: 1_000 })
  on('session.id', () => ({ value: sessionId }))
  on('fs.write', ($, e) => {
    writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('fs.read', ($, e) => ({ deny: `ENOENT: ${e.path}` }))
  on('prompt.read', () => ({ value: { text: '', cursor: 0 } }))
  on('ui.log', () => ({ value: undefined }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.end', ($, e) => ({ sessionId: e.sessionId }))
  return { writes, clock }
}

function aliveRecords(w: World): Record<string, unknown>[] {
  return w.writes.filter(write => write.path === ALIVE).map(write => JSON.parse(write.text))
}

test('heartbeatWritesAliveAtStartAndEveryThirtySeconds', async ($, on) => {
  const w = world(on, FEATURES_ON)

  await $.session.start(START)
  await w.clock.settle()
  await w.clock.advance(30_000)

  expect(aliveRecords(w)).toEqual([
    {
      schemaVersion: 1,
      sessionId: SESSION_ID,
      incarnationId: INCARNATION,
      modVersion: 1,
      features: ['composer-draft'],
      heartbeatAtMs: 1_000,
    },
    {
      schemaVersion: 1,
      sessionId: SESSION_ID,
      incarnationId: INCARNATION,
      modVersion: 1,
      features: ['composer-draft'],
      heartbeatAtMs: 31_000,
    },
  ])
})

test('withoutTheFeatureListNothingIsWritten', async ($, on) => {
  const w = world(on, { TBD_SESSIONS_DIR: '/sessions', TBD_TERMINAL_INCARNATION_ID: INCARNATION })

  expect(await $.session.start(START)).toEqual({ cwd: START.cwd })
  await w.clock.settle()
  await w.clock.advance(30_000)
  expect(await $.session.end(END)).toEqual({ sessionId: SESSION_ID })
  await w.clock.settle()

  expect(w.writes).toEqual([])
})

test('anUnknownFeatureIsNotListedAsRunning', async ($, on) => {
  const w = world(on, { ...FEATURES_ON, TBD_MOD_FEATURES: 'composer-draft,later-feature' })

  await $.session.start(START)
  await w.clock.settle()

  const alive = aliveRecords(w)
  expect(alive).toHaveLength(1)
  expect(alive[0]).toMatchObject({ features: ['composer-draft'] })
})

test('anUnsafeSessionIdHasNoDirectory', async ($, on) => {
  const w = world(on, FEATURES_ON, '../escape')

  expect(await $.session.start(START)).toEqual({ cwd: START.cwd })
  await w.clock.settle()
  await w.clock.advance(30_000)
  expect(await $.session.end({ ...END, sessionId: '../escape' })).toEqual({ sessionId: '../escape' })
  await w.clock.settle()

  expect(w.writes).toEqual([])
})
