// What every session-mod feature shares: the spawn's environment, the
// per-session directory and the liveness heartbeat.
//
// The daemon sets TBD_SESSIONS_DIR, TBD_MOD_FEATURES and
// TBD_TERMINAL_INCARNATION_ID on a spawn made while a feature flag is on, and
// none of them otherwise. Module variables start over at each load, so the
// environment is read once per load and the heartbeat restarts with it.
import type { EngineInterface, Timer } from 'claude-code'

export const MOD_VERSION = 1
export const HEARTBEAT_MS = 30_000
export const KNOWN_FEATURES: readonly string[] = ['composer-draft', 'transcript-stream']

/** The spawn's environment: where session directories live, and what runs. */
export type SessionEnv = {
  sessionsDir: string
  incarnationId: string
  /** TBD_MOD_FEATURES ∩ KNOWN_FEATURES. */
  features: ReadonlySet<string>
}

export type SessionContext = {
  /** `<TBD_SESSIONS_DIR>/<sessionId>`. */
  dir: string
  sessionId: string
  incarnationId: string
  features: ReadonlySet<string>
}

// A session ID becomes a path component only when it is a plain token.
const SAFE_SESSION_ID = /^[A-Za-z0-9_-]{1,128}$/

let sessionEnv: Promise<SessionEnv | null> | undefined
let heartbeat: Timer | undefined

/**
 * The spawn's environment, or null when the spawn listed no features (or
 * named no sessions directory). Read once per load.
 */
export function readSessionEnv($: EngineInterface): Promise<SessionEnv | null> {
  sessionEnv ??= readEnv($).catch(error => {
    $.ui.log(`session mod: could not read the environment: ${describe(error)}`, { to: 'debug' })
    return null
  })
  return sessionEnv
}

async function readEnv($: EngineInterface): Promise<SessionEnv | null> {
  const sessionsDir = await $.env.get('TBD_SESSIONS_DIR')
  const featureList = await $.env.get('TBD_MOD_FEATURES')
  const incarnationId = await $.env.get('TBD_TERMINAL_INCARNATION_ID')
  if (!sessionsDir || !featureList) {
    return null
  }
  const requested = new Set(featureList.split(',').map(name => name.trim()))
  return {
    sessionsDir,
    incarnationId: incarnationId ?? '',
    features: new Set(KNOWN_FEATURES.filter(name => requested.has(name))),
  }
}

/**
 * The session this process runs now. The ID is read at each call, so a
 * /clear that moves the process to a new session moves its writes too. Null
 * without a feature list, or when the ID is not safe to use as a path.
 */
export async function resolveContext($: EngineInterface): Promise<SessionContext | null> {
  const env = await readSessionEnv($)
  if (env === null) {
    return null
  }
  const sessionId = await $.session.id()
  if (!SAFE_SESSION_ID.test(sessionId)) {
    return null
  }
  return {
    dir: `${env.sessionsDir}/${sessionId}`,
    sessionId,
    incarnationId: env.incarnationId,
    features: env.features,
  }
}

export async function writeJSON($: EngineInterface, path: string, value: unknown): Promise<void> {
  await $.fs.write(path, JSON.stringify(value))
}

/** Writes alive.json now and every HEARTBEAT_MS after, until the next load. */
export function startHeartbeat($: EngineInterface): void {
  heartbeat?.cancel()
  void beat($)
  heartbeat = $.clock.every(HEARTBEAT_MS, () => void beat($))
}

async function beat($: EngineInterface): Promise<void> {
  try {
    const ctx = await resolveContext($)
    if (ctx === null) {
      return
    }
    await writeJSON($, `${ctx.dir}/alive.json`, {
      schemaVersion: 1,
      sessionId: ctx.sessionId,
      incarnationId: ctx.incarnationId,
      modVersion: MOD_VERSION,
      features: [...ctx.features],
      // The daemon reads it as an integer.
      heartbeatAtMs: Math.trunc(await $.clock.now()),
    })
  } catch (error) {
    $.ui.log(`session mod: could not write alive.json: ${describe(error)}`, { to: 'debug' })
  }
}

export function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
