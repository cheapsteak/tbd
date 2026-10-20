// The session-mod channel's client: the mod's half of the daemon's mod.sock
// (docs/specs/2026-10-20-mod-channel-prompt-answer-design.md, "The channel").
//
// The mod always initiates. It keeps one held poll open for items the daemon
// sends it, and makes short requests for its reports. Every request names the
// terminal and incarnation the process was spawned under and carries the
// token the daemon minted for that incarnation; the daemon sets all four
// variables on a spawn with any mod feature on.
//
// Reports that stand while something stays open (an open dialog) are kept
// here too, so the poll loop can post them again once it reaches the daemon
// after losing it: a restarted daemon holds nothing in memory.
import type { EngineInterface, HttpInit } from 'claude-code'

import { describe } from './session.ts'

export type ChannelEnv = { socket: string; token: string; terminalId: string; incarnationId: string }

export type ChannelReply = { status: number; json: unknown }

/** One item a poll delivers. */
export type ChannelItem = { seq: number; kind: string; body: unknown }

/** Waits after the first, second, third and every later failed poll in a row. */
export const POLL_BACKOFF_MS: readonly number[] = [1_000, 2_000, 5_000, 10_000]

let channelEnv: Promise<ChannelEnv | null> | undefined

/** Reports to post again after the daemon comes back, by key (a tool use id). */
const standingReports = new Map<string, { path: string; body: unknown }>()

/**
 * The channel's address and credentials, or null when the spawn lacks any of
 * them (an older daemon, or no mod feature on). Read once per load.
 */
export function readChannelEnv($: EngineInterface): Promise<ChannelEnv | null> {
  channelEnv ??= readEnv($).catch(error => {
    $.ui.log(`session mod channel: could not read the environment: ${describe(error)}`, { to: 'debug' })
    return null
  })
  return channelEnv
}

async function readEnv($: EngineInterface): Promise<ChannelEnv | null> {
  const socket = await $.env.get('TBD_MOD_SOCKET')
  const token = await $.env.get('TBD_MOD_TOKEN')
  const terminalId = await $.env.get('TBD_TERMINAL_ID')
  const incarnationId = await $.env.get('TBD_TERMINAL_INCARNATION_ID')
  if (!socket || !token || !terminalId || !incarnationId) {
    return null
  }
  return { socket, token, terminalId, incarnationId }
}

/**
 * One request over mod.sock. Resolves the status and the body parsed as JSON
 * (null when it is not JSON), or null when the request itself failed: the
 * socket is missing, the daemon is down, or the fetch was aborted. Never
 * rejects.
 */
export async function request(
  $: EngineInterface,
  env: ChannelEnv,
  method: string,
  path: string,
  body?: unknown,
): Promise<ChannelReply | null> {
  const headers: Record<string, string> = {
    Authorization: `Bearer ${env.token}`,
    'X-TBD-Terminal': env.terminalId,
    'X-TBD-Incarnation': env.incarnationId,
  }
  const init: HttpInit = { method, headers, socketPath: env.socket }
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json'
    init.body = JSON.stringify(body)
  }
  let text: string
  let status: number
  try {
    const response = await $.http.fetch(`http://tbd${path}`, init)
    text = response.text
    status = response.status
  } catch (error) {
    $.ui.log(`session mod channel: ${method} ${routeName(path)} failed: ${describe(error)}`, { to: 'debug' })
    return null
  }
  let json: unknown = null
  try {
    json = text === '' ? null : JSON.parse(text)
  } catch {
    json = null
  }
  return { status, json }
}

/**
 * Keeps one poll open for as long as the module is loaded. A failed poll is
 * retried after POLL_BACKOFF_MS; the first poll to succeed after a failure
 * posts the standing reports again. `after` starts at 0 and only rises: the
 * daemon keeps sequence numbers rising across its restarts, so an item at or
 * below the last one seen is a resend and is dropped.
 *
 * The caller starts it once per load.
 */
export function startPolling($: EngineInterface, env: ChannelEnv): void {
  // Rooted in a timer, not in the hook that starts it: the loop outlives
  // that hook's dispatch.
  $.clock.after(0, () => void pollLoop($, env))
}

async function pollLoop($: EngineInterface, env: ChannelEnv): Promise<void> {
  let lastSeq = 0
  let failures = 0
  for (;;) {
    try {
      const items = pollItems(await request($, env, 'GET', `/v1/poll?after=${lastSeq}`))
      if (items === null) {
        const delay = backoffDelay(failures)
        failures += 1
        $.ui.log(`session mod channel: poll failed (${failures} in a row), retrying in ${delay} ms`, { to: 'debug' })
        await $.clock.sleep(delay)
        continue
      }
      if (failures > 0) {
        failures = 0
        $.ui.log('session mod channel: poll reached the daemon again', { to: 'debug' })
        await repostStandingReports($, env)
      }
      for (const item of items) {
        if (item.seq <= lastSeq) {
          continue
        }
        lastSeq = item.seq
        // No feature reads items yet; message delivery is the first.
        $.ui.log(`session mod channel: no handler for item ${item.seq} (${item.kind})`, { to: 'debug' })
      }
    } catch (error) {
      // A step that threw is retried as a failed poll, never ends the loop.
      $.ui.log(`session mod channel: poll step failed: ${describe(error)}`, { to: 'debug' })
      const delay = backoffDelay(failures)
      failures += 1
      try {
        await $.clock.sleep(delay)
      } catch {
        // Nothing to do but try again.
      }
    }
  }
}

/** The wait after `failures` failed polls in a row before this one. */
function backoffDelay(failures: number): number {
  return POLL_BACKOFF_MS[Math.min(failures, POLL_BACKOFF_MS.length - 1)] ?? 10_000
}

/** A poll reply's items, sorted by sequence, or null for a failed poll. */
function pollItems(reply: ChannelReply | null): ChannelItem[] | null {
  if (reply === null || reply.status !== 200 || !isRecord(reply.json) || !Array.isArray(reply.json.items)) {
    return null
  }
  const items: ChannelItem[] = []
  for (const raw of reply.json.items) {
    if (isRecord(raw) && typeof raw.seq === 'number' && Number.isFinite(raw.seq)) {
      items.push({ seq: raw.seq, kind: typeof raw.kind === 'string' ? raw.kind : '', body: raw.body })
    }
  }
  return items.sort((a, b) => a.seq - b.seq)
}

/** Keeps `body` to post to `path` again whenever the poll loop reconnects, until withdrawn. */
export function standReport(key: string, path: string, body: unknown): void {
  standingReports.set(key, { path, body })
}

/** Stops posting `key` again. Harmless for a key not standing. */
export function withdrawReport(key: string): boolean {
  return standingReports.delete(key)
}

export function isReportStanding(key: string): boolean {
  return standingReports.has(key)
}

/** The body standing under `key`, or undefined once withdrawn. */
export function standingReportBody(key: string): unknown {
  return standingReports.get(key)?.body
}

/**
 * Posts every standing report once more, oldest first. Each is looked up
 * again just before its post, so one withdrawn while an earlier post was in
 * flight (its dialog closed) is skipped. Failures are logged and left.
 */
export async function repostStandingReports($: EngineInterface, env: ChannelEnv): Promise<void> {
  for (const key of [...standingReports.keys()]) {
    const report = standingReports.get(key)
    if (report === undefined) {
      continue
    }
    const reply = await request($, env, 'POST', report.path, report.body)
    if (reply === null || reply.status !== 200) {
      $.ui.log(`session mod channel: could not post ${key} again (${reply?.status ?? 'no reply'})`, { to: 'debug' })
    }
  }
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** A path without tool use ids or a query, for logs. */
function routeName(path: string): string {
  return path.replace(/\?.*$/, '').replace(/^\/v1\/prompts\/(?!open$)[^/]+/, '/v1/prompts/<id>')
}
