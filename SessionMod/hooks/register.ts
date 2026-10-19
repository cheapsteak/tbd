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
import { readSessionEnv, resolveContext, startHeartbeat } from './shared/session.ts'
import type { SessionEnv } from './shared/session.ts'

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

/** prompt.change: hands the box as it now stands to the features. Observe only. */
export async function promptChange(
  $: EngineInterface,
  env: SessionEnv | null,
  e: Frozen<PromptChangeInput>,
  next: (e: Frozen<PromptChangeInput>) => Promise<PromptChangeResult>,
): Promise<PromptChangeResult> {
  if (env !== null && env.features.has(COMPOSER_DRAFT)) {
    composerDraftPromptChanged($, { text: e.text, cursor: e.cursor })
  }
  return next(e)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const ctx = await resolveContext($)
    if (ctx !== null) {
      startHeartbeat($)
      if (ctx.features.has(COMPOSER_DRAFT)) {
        await composerDraftSessionStart($, ctx)
      }
    }
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    const ctx = await resolveContext($)
    if (ctx !== null && ctx.features.has(COMPOSER_DRAFT)) {
      await composerDraftSessionEnd($, ctx)
    }
    return next(e)
  })

  // The box goes back to the editor whatever a feature does with it.
  on('prompt.edit', async ($, e, next) => promptEdit($, await readSessionEnv($), e, next))
    .catch(($, e, next) => next(e))

  on('prompt.change', async ($, e, next) => promptChange($, await readSessionEnv($), e, next))

  // The band above the prompt yields to a survey. A feature that draws there
  // wraps what is drawn beneath it, and a second one would wrap the first.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const env = await readSessionEnv($)
    if (env === null || e.props.hasSurvey || !env.features.has(COMPOSER_DRAFT)) {
      return next(e)
    }
    return composerDraftAbovePrompt($, e, () => next(e))
  })
}
