// usage: records the session's context window, rate limits and cost to
// usage.json, so TBD reads the window this session resolved instead of
// guessing it from the model. A baseline is written at session.start, so the
// window is known before the first turn, and every session.measure rewrites
// the file with the figures it carries.
import type { EngineInterface, Frozen, SessionContextUsage, SessionCost, SessionRateLimit } from 'claude-code'

import { describe, writeJSON } from '../shared/session.ts'
import type { SessionContext } from '../shared/session.ts'

export const FEATURE = 'usage'
export const USAGE_FILE = 'usage.json'
export const SCHEMA_VERSION = 1

/** The figures both events carry: `$.session.usage()`'s, or a measurement's. */
export type UsageFigures = {
  context: Frozen<SessionContextUsage>
  rateLimits: readonly Frozen<SessionRateLimit>[]
  cost?: Frozen<SessionCost>
}

/**
 * usage.json's record. Only the fields named here are copied, and a figure
 * the engine does not have is left out, never zeroed: readers take a missing
 * `tokens` as "no reading yet", and a zero as an empty window.
 */
export function usageRecord(ctx: SessionContext, figures: UsageFigures, now: number): object {
  const { window, tokens, percent } = figures.context
  return {
    schemaVersion: SCHEMA_VERSION,
    claudeSessionID: ctx.sessionId,
    incarnationID: ctx.incarnationId,
    // The daemon reads it as an integer.
    measuredAt: Math.trunc(now),
    context: {
      window,
      ...(tokens === undefined ? {} : { tokens }),
      ...(percent === undefined ? {} : { percent }),
    },
    rateLimits: (Array.isArray(figures.rateLimits) ? figures.rateLimits : []).map(({ kind, percentUsed, resetsAt }) => ({
      kind,
      percentUsed,
      ...(resetsAt === undefined ? {} : { resetsAt }),
    })),
    ...(figures.cost === undefined ? {} : { cost: { usd: figures.cost.usd } }),
  }
}

function log($: EngineInterface, text: string): void {
  $.ui.log(`${FEATURE}: ${text}`, { to: 'debug' })
}

async function record($: EngineInterface, ctx: SessionContext, figures: UsageFigures): Promise<void> {
  // Figures without a context object carry no window, so the previous record
  // stays: it is still the latest valid reading.
  if (typeof figures.context !== 'object' || figures.context === null) {
    log($, 'skipped figures without a context')
    return
  }
  await writeJSON($, `${ctx.dir}/${USAGE_FILE}`, usageRecord(ctx, figures, await $.clock.now()))
}

// The feature's hooks, which register.ts calls for a spawn that listed
// usage. Each catches its own failures: a feature never fails a hook.

/** Writes the baseline: the window, and a fill once a response reported one. */
export async function sessionStart($: EngineInterface, ctx: SessionContext): Promise<void> {
  try {
    await record($, ctx, await $.session.usage())
  } catch (error) {
    log($, `could not record the baseline: ${describe(error)}`)
  }
}

/** Writes a measurement's figures. */
export async function measured($: EngineInterface, ctx: SessionContext, e: UsageFigures): Promise<void> {
  try {
    await record($, ctx, e)
  } catch (error) {
    log($, `could not record a measurement: ${describe(error)}`)
  }
}
