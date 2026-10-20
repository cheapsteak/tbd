// The usage feature: what session.start and session.measure write to
// usage.json. The test kit raises both events, so they go through
// register.ts the way the engine raises them.
import type { On, SessionMeasureInput, SessionUsage } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

const SESSION_ID = 'sess-1'
const INCARNATION = '5B0C2D9E-4F1A-4C55-9E2B-7A1D3C8F6E01'
const USAGE = `/sessions/${SESSION_ID}/usage.json`
const START = { cwd: '/work', surface: 'terminal', isInteractive: true } as const
const FEATURES_ON = {
  TBD_SESSIONS_DIR: '/sessions',
  TBD_MOD_FEATURES: 'usage',
  TBD_TERMINAL_INCARNATION_ID: INCARNATION,
}
// What a session answers before its first response: the window, no fill.
const BASELINE: SessionUsage = { startedAt: 500, context: { window: 200_000 }, rateLimits: [] }
const MEASURED: SessionMeasureInput = {
  context: { window: 1_000_000, tokens: 50_000, percent: 5 },
  rateLimits: [
    { kind: 'five_hour', percentUsed: 23.5, resetsAt: '2026-10-20T18:00:00Z' },
    { kind: 'seven_day', percentUsed: 7 },
  ],
  cost: { usd: 1.25 },
  changed: ['context', 'rateLimits', 'cost'],
}

type World = { writes: { path: string; text: string }[]; logs: string[] }

// Answers everything the mod calls beneath it and records each file written.
function world(on: On, env: Record<string, string>, failWrites = false): World {
  const writes: World['writes'] = []
  const logs: string[] = []
  mock.env(on, env)
  mock.clock(on, { now: 1_234.75 })
  on('session.id', () => ({ value: SESSION_ID }))
  on('session.usage', () => ({ value: BASELINE }))
  on('fs.write', ($, e) => {
    if (failWrites) {
      return { deny: 'disk full' }
    }
    writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('fs.exists', () => ({ value: false }))
  on('fs.read', ($, e) => ({ deny: `ENOENT: ${e.path}` }))
  on('prompt.read', () => ({ value: { text: '', cursor: 0 } }))
  on('ui.log', ($, e) => {
    logs.push(e.text)
    return { value: undefined }
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.measure', ($, e) => ({ changed: e.changed }))
  return { writes, logs }
}

function usageRecords(w: World): Record<string, unknown>[] {
  return w.writes.filter(write => write.path === USAGE).map(write => JSON.parse(write.text))
}

test('aMeasurementWritesEveryFigureItCarries', async ($, on) => {
  const w = world(on, FEATURES_ON)

  expect(await $.session.measure(MEASURED)).toEqual({ changed: MEASURED.changed })

  expect(usageRecords(w)).toEqual([
    {
      schemaVersion: 1,
      claudeSessionID: SESSION_ID,
      incarnationID: INCARNATION,
      measuredAt: 1_234,
      context: { window: 1_000_000, tokens: 50_000, percent: 5 },
      rateLimits: [
        { kind: 'five_hour', percentUsed: 23.5, resetsAt: '2026-10-20T18:00:00Z' },
        { kind: 'seven_day', percentUsed: 7 },
      ],
      cost: { usd: 1.25 },
    },
  ])
})

test('aFigureTheMeasurementLacksIsLeftOutNotZeroed', async ($, on) => {
  const w = world(on, FEATURES_ON)

  await $.session.measure({ context: { window: 200_000 }, rateLimits: [], changed: ['context'] })

  const [usage] = usageRecords(w)
  expect(usage?.context).toEqual({ window: 200_000 })
  expect(usage?.rateLimits).toEqual([])
  expect(usage !== undefined && 'cost' in usage).toBe(false)
})

test('sessionStartWritesABaselineWithTheWindow', async ($, on) => {
  const w = world(on, FEATURES_ON)

  expect(await $.session.start(START)).toEqual({ cwd: START.cwd })

  expect(usageRecords(w)).toEqual([
    {
      schemaVersion: 1,
      claudeSessionID: SESSION_ID,
      incarnationID: INCARNATION,
      measuredAt: 1_234,
      context: { window: 200_000 },
      rateLimits: [],
    },
  ])
})

test('aSpawnWithoutUsageWritesNoUsageFile', async ($, on) => {
  const w = world(on, { ...FEATURES_ON, TBD_MOD_FEATURES: 'composer-draft' })

  expect(await $.session.start(START)).toEqual({ cwd: START.cwd })
  expect(await $.session.measure(MEASURED)).toEqual({ changed: MEASURED.changed })

  expect(usageRecords(w)).toEqual([])
})

test('withoutTheFeatureListAMeasurementPassesThrough', async ($, on) => {
  const w = world(on, { TBD_SESSIONS_DIR: '/sessions', TBD_TERMINAL_INCARNATION_ID: INCARNATION })

  expect(await $.session.measure(MEASURED)).toEqual({ changed: MEASURED.changed })

  expect(w.writes).toEqual([])
})

test('aFailedWriteIsLoggedAndTheMeasurementPassesOn', async ($, on) => {
  const w = world(on, FEATURES_ON, true)

  expect(await $.session.measure(MEASURED)).toEqual({ changed: MEASURED.changed })

  expect(w.writes).toEqual([])
  expect(w.logs.some(text => text.startsWith('usage: could not record a measurement'))).toBe(true)
})
