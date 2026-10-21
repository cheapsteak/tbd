// The session mod: the tbd plugin's hooks module. Each feature lives in a
// file of its own under features/ and exports the hooks it needs; this entry
// point registers one hook per event and hands each event to the features
// this spawn listed in TBD_MOD_FEATURES. A spawn that listed none passes
// every event straight on.
//
// Dispatch is written out per feature rather than looped over a list: the
// engine follows `$` only into functions it can name at the call site, so a
// feature's hooks are imported function declarations, called directly. A new
// feature adds its import and one line in each hook it uses.
import type {
  EngineInterface,
  Frozen,
  PromptChangeInput,
  PromptChangeResult,
  PromptEditInput,
  PromptEditResult,
  Register,
} from 'claude-code'

import {
  FEATURE as COMPOSER_DRAFT,
  abovePrompt as composerDraftAbovePrompt,
  promptChanged as composerDraftPromptChanged,
  promptEdited as composerDraftPromptEdited,
  sessionEnd as composerDraftSessionEnd,
  sessionStart as composerDraftSessionStart,
} from './features/composer-draft.tsx'
import {
  FEATURE as TRANSCRIPT_STREAM,
  sessionAppend as transcriptStreamSessionAppend,
  transcriptStream,
  turnComplete as transcriptStreamTurnComplete,
  turnStart as transcriptStreamTurnStart,
  turnStep as transcriptStreamTurnStep,
} from './features/transcript-stream.ts'
import {
  FEATURE as USAGE,
  measured as usageMeasured,
  sessionStart as usageSessionStart,
} from './features/usage.ts'
import {
  FEATURE as PROMPT_ANSWER,
  permissionRequested as promptAnswerPermissionRequested,
  toolCalled as promptAnswerToolCalled,
} from './features/prompt-answer.ts'
import { readChannelEnv, startPolling } from './shared/channel.ts'
import type { ChannelEnv } from './shared/channel.ts'
import { readSessionEnv, resolveContext, startHeartbeat } from './shared/session.ts'
import type { SessionEnv } from './shared/session.ts'

// Whether this load's channel poll runs: one per load, however many
// session.start events it sees.
let isPolling = false

/** The channel, when this spawn listed prompt-answer and was given it; else null. */
export async function promptAnswerChannel($: EngineInterface): Promise<ChannelEnv | null> {
  const env = await readSessionEnv($)
  if (env === null || !env.features.has(PROMPT_ANSWER)) {
    return null
  }
  return readChannelEnv($)
}

// The two hooks that run on every change of the prompt box. They take the
// environment as an argument, so a test can call them directly: the test kit
// raises neither event.

/**
 * prompt.edit: hands the box after the edit to the features and returns it
 * to the editor unchanged. Nothing past `next` waits on more than the
 * environment read at load, so typing never waits on a feature, and features
 * see boxes in the order of the edits.
 */
export async function promptEdit(
  $: EngineInterface,
  env: SessionEnv | null,
  e: Frozen<PromptEditInput>,
  next: (e: Frozen<PromptEditInput>) => Promise<PromptEditResult>,
): Promise<PromptEditResult> {
  const box = await next(e)
  if (env !== null && env.features.has(COMPOSER_DRAFT)) {
    composerDraftPromptEdited($, { text: box.text, cursor: box.cursor })
  }
  return box
}

/** prompt.change: hands the box as it now stands, and who changed it, to the features. Observe only. */
export async function promptChange(
  $: EngineInterface,
  env: SessionEnv | null,
  e: Frozen<PromptChangeInput>,
  next: (e: Frozen<PromptChangeInput>) => Promise<PromptChangeResult>,
): Promise<PromptChangeResult> {
  if (env !== null && env.features.has(COMPOSER_DRAFT)) {
    composerDraftPromptChanged($, { text: e.text, cursor: e.cursor }, e.origin)
  }
  return next(e)
}

// Every hook carries a `.catch` that passes the event on: a hook that throws
// or overruns leaves the event as it would be without the mod. The box goes
// back to the editor whatever a feature does with it.
export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const ctx = await resolveContext($)
    if (ctx !== null) {
      startHeartbeat($)
      if (ctx.features.has(COMPOSER_DRAFT)) {
        await composerDraftSessionStart($, ctx)
      }
      if (ctx.features.has(USAGE)) {
        await usageSessionStart($, ctx)
      }
    }
    const channel = await promptAnswerChannel($)
    if (channel !== null && !isPolling) {
      isPolling = true
      startPolling($, channel)
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('session.measure', async ($, e, next) => {
    const ctx = await resolveContext($)
    if (ctx !== null && ctx.features.has(USAGE)) {
      await usageMeasured($, ctx, e)
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('session.end', async ($, e, next) => {
    const ctx = await resolveContext($)
    if (ctx !== null && ctx.features.has(COMPOSER_DRAFT)) {
      await composerDraftSessionEnd($, ctx)
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('prompt.edit', async ($, e, next) => promptEdit($, await readSessionEnv($), e, next))
    .catch(($, e, next) => next(e))

  on('prompt.change', async ($, e, next) => promptChange($, await readSessionEnv($), e, next))
    .catch(($, e, next) => next(e))

  // The model's answer, chunk by chunk. Every chunk goes on at once; a
  // feature that fails mid-stream leaves the rest of the stream to pass.
  on('turn.step', async function* ($, e, next) {
    const env = await readSessionEnv($)
    if (env === null || !env.features.has(TRANSCRIPT_STREAM)) {
      return yield* next(e)
    }
    return yield* transcriptStreamTurnStep(transcriptStream($), e, next)
  }).catch(async function* ($, e, next) {
    return yield* next(e)
  })

  on('session.append', async ($, e, next) => {
    const env = await readSessionEnv($)
    if (env === null || !env.features.has(TRANSCRIPT_STREAM)) {
      return next(e)
    }
    return transcriptStreamSessionAppend(transcriptStream($), e, next)
  }).catch(($, e, next) => next(e))

  on('turn.start', async ($, e, next) => {
    const env = await readSessionEnv($)
    if (env === null || !env.features.has(TRANSCRIPT_STREAM)) {
      return next(e)
    }
    return transcriptStreamTurnStart(transcriptStream($), e, next)
  }).catch(($, e, next) => next(e))

  on('turn.complete', async ($, e, next) => {
    const env = await readSessionEnv($)
    if (env === null || !env.features.has(TRANSCRIPT_STREAM)) {
      return next(e)
    }
    return transcriptStreamTurnComplete(transcriptStream($), e, next)
  }).catch(($, e, next) => next(e))

  // prompt-answer: every call is recorded while it runs, and AskUserQuestion
  // is answered here. A spawn without the feature passes the call straight on.
  on('tool.call', async ($, e, next) => {
    const channel = await promptAnswerChannel($)
    if (channel === null) {
      return next(e)
    }
    return promptAnswerToolCalled($, channel, e, next)
  }).catch(($, e, next) => next(e))

  // prompt-answer: a permission dialog waits for TBD's answer while the
  // terminal can still answer it.
  on('classic.PermissionRequest', async ($, e, next) => {
    const channel = await promptAnswerChannel($)
    if (channel === null) {
      return next(e)
    }
    return promptAnswerPermissionRequested($, channel, e, next)
  }).catch(($, e, next) => next(e))

  // The band above the prompt yields to a survey. A feature that draws there
  // wraps what is drawn beneath it, and a second one would wrap the first.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const env = await readSessionEnv($)
    if (env === null || e.props.hasSurvey || !env.features.has(COMPOSER_DRAFT)) {
      return next(e)
    }
    return composerDraftAbovePrompt($, e, () => next(e))
  }).catch(($, e, next) => next(e))
}
