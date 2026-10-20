// prompt-answer: lets TBD answer this session's permission dialogs and
// AskUserQuestion from cards in the transcript pane, while the terminal stays
// able to answer each (docs/specs/2026-10-20-mod-channel-prompt-answer-design.md,
// "Answering prompts").
//
// - tool.call records every call in flight, so a permission dialog, whose
//   payload carries no tool call id, can be paired with its call by input.
// - classic.PermissionRequest opens the dialog's card and waits on its own
//   held request for TBD's answer. Holding a `$` call keeps the hook's own
//   ten-second clock stopped; a plain promise would not.
// - AskUserQuestion is answered from tool.call, which races the dialog
//   (`next(e)`) against TBD's answer.
//
// Whoever answers second loses: Claude Code takes the first answer, and the
// mod tells the daemon which it was (a receipt for TBD's, `closed` for the
// terminal's). Every way out of a hook withdraws its dialog's entry.
import type {
  ClassicEventOf,
  ClassicResultOf,
  EngineInterface,
  Frozen,
  Next,
  NextBudget,
  PermissionRequestDecision,
  ToolCallInput,
  ToolCallResult,
} from 'claude-code'

import {
  isRecord,
  isReportStanding,
  request,
  standReport,
  standingReportBody,
  withdrawReport,
} from '../shared/channel.ts'
import type { ChannelEnv } from '../shared/channel.ts'

export const FEATURE = 'prompt-answer'

/** Consecutive failed answer waits a dialog survives (a daemon restart) before it is left to the terminal. */
export const ANSWER_RETRY_LIMIT = 5
/** The pause between failed answer waits. It is the hook's own time, so the retries stay inside its budget. */
export const ANSWER_RETRY_MS = 1_000
/** The least hook budget a retry pause may start with; below it the dialog is left to the terminal. */
export const ANSWER_BUDGET_FLOOR_MS = 2_000

const OPEN_PATH = '/v1/prompts/open'
const QUESTION_TOOL = 'AskUserQuestion'

// The keys tool.call's input carries beside the tool's own arguments.
const RESERVED_KEYS = new Set(['tool', 'tool_use_id', 'agentId', 'requestMeta', 'consent'])

type PermissionRequestInput = ClassicEventOf['classic.PermissionRequest']
type PermissionRequestResult = ClassicResultOf['classic.PermissionRequest']

type ToolCallNext = Next<'tool.call'>
type PermissionRequestNext = Next<'classic.PermissionRequest'>

/** A tool call whose `next(e)` has not settled. */
type CallInFlight = {
  toolUseId: string
  /** The call's arguments, keys sorted, as JSON: what a permission payload's tool_input is compared by. */
  args: string
  agentId: string | undefined
  /** Set once a permission dialog has claimed the call. */
  isPaired: boolean
  /**
   * Set once the permission hook returned TBD's deny. Whether it took effect
   * shows only when the tool's `next(e)` settles: a terminal Yes before it
   * does not abort the hook, and Claude Code then ignores the deny.
   */
  isDenyReturned: boolean
}

/** Calls in flight by tool use id, oldest first (a Map keeps insertion order). */
const callsInFlight = new Map<string, CallInFlight>()

/** What a wait for TBD's answer ended with. */
type AnswerOutcome =
  | { kind: 'decision'; decision: Record<string, unknown> }
  | { kind: 'resolved' }
  | { kind: 'aborted' }
  | { kind: 'failed' }
  | { kind: 'outOfBudget' }

// MARK: - tool.call

/**
 * tool.call: records the call while `next(e)` runs. AskUserQuestion is also
 * answered here; any other call whose dialog is still open when the tool
 * finishes was answered Yes in the terminal, and the mod says so.
 */
export async function toolCalled(
  $: EngineInterface,
  env: ChannelEnv,
  e: Frozen<ToolCallInput>,
  next: ToolCallNext,
): Promise<ToolCallResult> {
  const toolUseId: unknown = e.tool_use_id
  if (typeof toolUseId !== 'string' || toolUseId === '') {
    return next(e)
  }
  const args = argsOf(e)
  callsInFlight.set(toolUseId, {
    toolUseId,
    args: stableJSON(args),
    agentId: typeof e.agentId === 'string' ? e.agentId : undefined,
    isPaired: false,
    isDenyReturned: false,
  })
  let result: ToolCallResult | undefined
  try {
    if (String(e.tool) === QUESTION_TOOL) {
      result = await answerQuestion($, env, e, next, toolUseId, args)
    } else {
      result = await next(e)
    }
    return result
  } finally {
    const isDenyReturned = callsInFlight.get(toolUseId)?.isDenyReturned === true
    callsInFlight.delete(toolUseId)
    if (isDenyReturned) {
      // TBD's deny took effect when the call ended denied or errored; a call
      // that ran means the terminal's Yes came first. A call that threw says
      // neither, and the daemon reports the answer unconfirmed.
      if (result !== undefined) {
        const wasDenied = 'deny' in result || result.isError === true
        postQuietly($, env, wasDenied ? 'receipt' : 'closed', toolUseId)
      }
    } else if (withdrawReport(toolUseId)) {
      postQuietly($, env, 'closed', toolUseId)
    }
  }
}

async function answerQuestion(
  $: EngineInterface,
  env: ChannelEnv,
  e: Frozen<ToolCallInput>,
  next: ToolCallNext,
  toolUseId: string,
  args: Record<string, unknown>,
): Promise<ToolCallResult> {
  // Opens the dialog in the terminal. While it is pending the hook's clock is
  // stopped, so racing it against a plain promise is safe.
  const dialog = next(e)
  let isDialogSettled = false
  const dialogSettled = dialog.then(
    result => {
      isDialogSettled = true
      return { kind: 'terminal' as const, result }
    },
    error => {
      isDialogSettled = true
      throw error
    },
  )
  // A dialog TBD answered settles after the hook has returned; nothing reads it.
  dialogSettled.catch(() => {})

  const isOpen = await openDialog($, env, {
    toolUseID: toolUseId,
    sessionID: await $.session.id(),
    toolName: QUESTION_TOOL,
    toolInput: args,
    suggestions: null,
  })
  if (!isOpen) {
    return dialog
  }

  const answered = awaitAnswer($, env, toolUseId, next.signal, next.budget, () => isDialogSettled).then(outcome => ({
    kind: 'tbd' as const,
    outcome,
  }))
  const first = await Promise.race([dialogSettled, answered])
  if (first.kind === 'terminal') {
    // The finally in toolCalled posts `closed`.
    return first.result
  }

  const outcome = first.outcome
  if (outcome.kind === 'decision') {
    const updatedInput = outcome.decision.updatedInput
    if (
      outcome.decision.behavior === 'allow' &&
      isRecord(updatedInput) &&
      updatedInput.questions !== undefined &&
      isRecord(updatedInput.answers) &&
      !next.signal.aborted &&
      !isDialogSettled
    ) {
      withdrawReport(toolUseId)
      postQuietly($, env, 'receipt', toolUseId)
      return { result: { questions: updatedInput.questions, answers: updatedInput.answers } } as ToolCallResult
    }
    $.ui.log(`prompt-answer: question ${toolUseId} got no usable answer`, { to: 'debug' })
  }
  // TBD's side ended without an answer: the terminal keeps the dialog, and the
  // finally posts `closed` once it settles.
  return dialog
}

// MARK: - classic.PermissionRequest

/**
 * classic.PermissionRequest: pairs the dialog with its call, opens its card,
 * and waits for TBD's answer while the dialog stays usable in the terminal.
 * Never sets `interrupt`.
 */
export async function permissionRequested(
  $: EngineInterface,
  env: ChannelEnv,
  e: Frozen<PermissionRequestInput>,
  next: PermissionRequestNext,
): Promise<PermissionRequestResult> {
  if (e.tool_name === QUESTION_TOOL) {
    return next(e)
  }
  const call = pairCall(e.tool_input, typeof e.agent_id === 'string' ? e.agent_id : undefined)
  if (call === null) {
    return next(e)
  }
  const toolUseId = call.toolUseId
  const isOpen = await openDialog($, env, {
    toolUseID: toolUseId,
    sessionID: await $.session.id(),
    toolName: e.tool_name,
    toolInput: e.tool_input ?? null,
    suggestions: e.permission_suggestions ?? null,
  })
  if (!isOpen) {
    return next(e)
  }

  const outcome = await awaitAnswer($, env, toolUseId, next.signal, next.budget, () => !isReportStanding(toolUseId))
  if (outcome.kind === 'decision' && !next.signal.aborted && withdrawReport(toolUseId)) {
    const decision = permissionDecision(outcome.decision)
    if (decision !== null) {
      if (decision.behavior === 'deny') {
        // Confirmed by toolCalled once the call ends: a terminal Yes may have
        // come first, and then the tool runs whatever the card said.
        call.isDenyReturned = true
      } else {
        // An allow and a terminal Yes end alike (the tool runs), so the
        // receipt goes at once.
        postQuietly($, env, 'receipt', toolUseId)
      }
      return { decision }
    }
    $.ui.log(`prompt-answer: dialog ${toolUseId} got an unusable decision`, { to: 'debug' })
    postQuietly($, env, 'closed', toolUseId)
    return next(e)
  }
  // The terminal answered (No or Escape abort the hook), the daemon resolved
  // the prompt, it could not be reached, or the hook's budget ran low: the
  // dialog stays the terminal's.
  if (withdrawReport(toolUseId) && outcome.kind !== 'resolved' && outcome.kind !== 'outOfBudget') {
    postQuietly($, env, 'closed', toolUseId)
  }
  return next(e)
}

/**
 * The oldest unpaired call in flight with exactly these arguments in the same
 * agent, claimed; null when none matches. Calls with identical arguments are
 * interchangeable, so the oldest is as good as any.
 */
function pairCall(toolInput: unknown, agentId: string | undefined): CallInFlight | null {
  const args = stableJSON(toolInput)
  for (const call of callsInFlight.values()) {
    if (!call.isPaired && call.args === args && call.agentId === agentId) {
      call.isPaired = true
      return call
    }
  }
  return null
}

/** A decision as Claude Code takes it, or null for a shape it would refuse. Drops `interrupt`. */
function permissionDecision(raw: Record<string, unknown>): PermissionRequestDecision | null {
  if (raw.behavior === 'allow') {
    const decision: Record<string, unknown> = { behavior: 'allow' }
    if (isRecord(raw.updatedInput)) {
      decision.updatedInput = raw.updatedInput
    }
    if (Array.isArray(raw.updatedPermissions)) {
      decision.updatedPermissions = raw.updatedPermissions
    }
    return decision as PermissionRequestDecision
  }
  if (raw.behavior === 'deny') {
    const decision: Record<string, unknown> = { behavior: 'deny' }
    if (typeof raw.message === 'string') {
      decision.message = raw.message
    }
    return decision as PermissionRequestDecision
  }
  return null
}

// MARK: - The dialog's requests

/**
 * Posts `open` and, when the daemon takes it, keeps it standing so the poll
 * loop posts it again after a reconnect. False when the daemon refused it
 * (the feature is off) or could not be reached.
 */
async function openDialog($: EngineInterface, env: ChannelEnv, body: { toolUseID: string } & Record<string, unknown>): Promise<boolean> {
  const reply = await request($, env, 'POST', OPEN_PATH, body)
  if (reply === null || reply.status !== 200) {
    $.ui.log(`prompt-answer: ${body.toolUseID} was not opened (${reply?.status ?? 'no reply'})`, { to: 'debug' })
    return false
  }
  // Standing, the poll loop posts it again after a reconnect
  // (repostStandingReports in channel.ts).
  standReport(body.toolUseID, OPEN_PATH, body)
  return true
}

/**
 * Waits on held answer requests, one after another, until TBD answers, the
 * daemon resolves the prompt, `signal` aborts, or `isOver` says the dialog
 * ended. A failed wait (a daemon restart) is retried after ANSWER_RETRY_MS,
 * posting the dialog open again first, until ANSWER_RETRY_LIMIT in a row, or
 * until the hook's budget would not outlast the pause (ANSWER_BUDGET_FLOOR_MS).
 */
async function awaitAnswer(
  $: EngineInterface,
  env: ChannelEnv,
  toolUseId: string,
  signal: AbortSignal,
  budget: NextBudget,
  isOver: () => boolean,
): Promise<AnswerOutcome> {
  const path = `/v1/prompts/${encodeURIComponent(toolUseId)}/answer`
  let failures = 0
  for (;;) {
    if (signal.aborted) {
      return { kind: 'aborted' }
    }
    if (isOver()) {
      return { kind: 'resolved' }
    }
    if (failures > 0) {
      // The pause is the hook's own time; past its budget the hook is skipped.
      if (budget.remainingMs < ANSWER_BUDGET_FLOOR_MS) {
        return { kind: 'outOfBudget' }
      }
      try {
        await $.clock.sleep(ANSWER_RETRY_MS, { signal })
      } catch {
        return { kind: 'aborted' }
      }
      // A restarted daemon has forgotten the prompt: open it again first.
      const body = standingReportBody(toolUseId)
      if (body !== undefined && (await request($, env, 'POST', OPEN_PATH, body)) === null) {
        failures += 1
        if (failures >= ANSWER_RETRY_LIMIT) {
          return { kind: 'failed' }
        }
        continue
      }
    }
    const reply = await untilAborted(request($, env, 'GET', path), signal)
    if (signal.aborted) {
      return { kind: 'aborted' }
    }
    const json = reply?.status === 200 && isRecord(reply.json) ? reply.json : null
    if (json?.state === 'decision' && isRecord(json.decision)) {
      return { kind: 'decision', decision: json.decision }
    }
    if (json?.state === 'resolved') {
      return { kind: 'resolved' }
    }
    if (json?.state === 'pending') {
      failures = 0
      continue
    }
    failures += 1
    $.ui.log(`prompt-answer: answer wait for ${toolUseId} failed (${reply?.status ?? 'no reply'})`, { to: 'debug' })
    if (failures >= ANSWER_RETRY_LIMIT) {
      return { kind: 'failed' }
    }
  }
}

/** Resolves `work`, or null as soon as `signal` aborts. */
function untilAborted<T>(work: Promise<T>, signal: AbortSignal): Promise<T | null> {
  if (signal.aborted) {
    return Promise.resolve(null)
  }
  return new Promise<T | null>(resolve => {
    const onAbort = (): void => resolve(null)
    signal.addEventListener('abort', onAbort, { once: true })
    work.then(
      value => {
        signal.removeEventListener('abort', onAbort)
        resolve(value)
      },
      () => {
        signal.removeEventListener('abort', onAbort)
        resolve(null)
      },
    )
  })
}

/** Posts `receipt` or `closed` for a dialog without holding the hook on it. */
function postQuietly($: EngineInterface, env: ChannelEnv, report: 'receipt' | 'closed', toolUseId: string): void {
  const body = report === 'closed' ? { by: 'terminal' } : {}
  // request never rejects; it logs its own failure.
  void request($, env, 'POST', `/v1/prompts/${encodeURIComponent(toolUseId)}/${report}`, body)
}

// MARK: - Pairing keys

/** tool.call's input less the keys that are not the tool's arguments. */
function argsOf(e: Frozen<ToolCallInput>): Record<string, unknown> {
  const args: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(e)) {
    if (!RESERVED_KEYS.has(key)) {
      args[key] = value
    }
  }
  return args
}

/** JSON with every object's keys sorted, so equal values compare equal as text. */
export function stableJSON(value: unknown): string {
  return JSON.stringify(sortKeys(value)) ?? 'undefined'
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(sortKeys)
  }
  if (isRecord(value)) {
    const sorted: Record<string, unknown> = {}
    for (const key of Object.keys(value).sort()) {
      sorted[key] = sortKeys(value[key])
    }
    return sorted
  }
  return value
}
