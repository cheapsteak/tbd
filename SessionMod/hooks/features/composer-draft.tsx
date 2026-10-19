// composer-draft: saves the prompt box to composer-draft.json on every change,
// so TBD can park a session with a draft in the box, and fills a saved draft
// back into the box when the session resumes in a new process.
import type { EngineInterface, Frozen, PromptBox, RenderElement, RenderInput } from 'claude-code'

import { describe, resolveContext, writeJSON } from '../shared/session.ts'
import type { SessionContext } from '../shared/session.ts'

export const FEATURE = 'composer-draft'
export const RESTORE_RETRY_MS = 500
export const NOTICE_MS = 3_000

const restoredIncarnation = { plugin: 'tbd', key: 'composerDraftRestoredIncarnation' } as const
const noticeVisible = { plugin: 'tbd', key: 'composerDraftNoticeVisible' } as const

type AbovePromptEvent = Frozen<RenderInput<'AbovePrompt'>>

export type DraftWriter = {
  queue(box: PromptBox): void
  flush(): Promise<void>
}

/**
 * Writes boxes one at a time. A box queued while a write runs replaces any box
 * queued behind it, so an older box never lands after a newer one. A write
 * that rejects is dropped and the next box is still written; `write` logs its
 * own failures.
 */
export function createDraftWriter(write: (box: PromptBox) => Promise<void>): DraftWriter {
  let queued: PromptBox | undefined
  let running: Promise<void> | undefined

  async function drain(): Promise<void> {
    while (queued !== undefined) {
      const box = queued
      queued = undefined
      try {
        await write(box)
      } catch {
        // Dropped: `write` reports its own failures.
      }
    }
    running = undefined
  }

  return {
    queue(box) {
      queued = box
      running ??= drain()
    },
    async flush() {
      while (running !== undefined) {
        await running
      }
    },
  }
}

/** The composer-draft.json record of a box: its text and cursor, or no draft. */
export function draftRecord(sessionId: string, box: PromptBox, now: number): object {
  if (box.text === '') {
    return { schemaVersion: 1, sessionId, hasDraft: false, savedAtMs: now }
  }
  return { schemaVersion: 1, sessionId, hasDraft: true, text: box.text, cursor: box.cursor, savedAtMs: now }
}

let writer: DraftWriter | undefined

function draftWriter($: EngineInterface): DraftWriter {
  writer ??= createDraftWriter(box => saveBox($, box))
  return writer
}

async function saveBox($: EngineInterface, box: PromptBox): Promise<void> {
  try {
    const ctx = await resolveContext($)
    if (ctx !== null) {
      await writeJSON($, `${ctx.dir}/composer-draft.json`, draftRecord(ctx.sessionId, box, await $.clock.now()))
    }
  } catch (error) {
    log($, `could not save the draft: ${describe(error)}`)
  }
}

/** The saved draft's text, or undefined when there is none or it cannot be read. */
async function savedDraft($: EngineInterface, ctx: SessionContext): Promise<string | undefined> {
  const file = await $.fs.read(`${ctx.dir}/composer-draft.json`).catch(() => undefined)
  if (file === undefined) {
    return undefined
  }
  try {
    const record = JSON.parse(file) as { hasDraft?: unknown; text?: unknown } | null
    return record?.hasDraft === true && typeof record.text === 'string' && record.text !== '' ? record.text : undefined
  } catch {
    return undefined
  }
}

/**
 * Fills `text`, the saved draft, into the empty box, retrying every
 * RESTORE_RETRY_MS while the box refuses it (not mounted yet, or under a
 * dialog). When the person's own text reaches the box first, the box is left
 * alone and the draft goes to composer-draft.unrestored. Resolves after one
 * attempt and never rejects; the retries run on timers.
 */
export async function restoreDraft($: EngineInterface, ctx: SessionContext, text: string): Promise<void> {
  try {
    const box = await $.prompt.read()
    if (box.text !== '') {
      await $.fs.write(`${ctx.dir}/composer-draft.unrestored`, text)
      await $.state.set(restoredIncarnation, ctx.incarnationId)
      log($, 'box was not empty, saved the draft to composer-draft.unrestored')
      return
    }
    const filled = await $.prompt.fill({ text, mode: 'replace' })
    if (!filled.isFilled) {
      $.clock.after(RESTORE_RETRY_MS, () => void restoreDraft($, ctx, text))
      return
    }
    await $.state.set(restoredIncarnation, ctx.incarnationId)
    await $.state.set(noticeVisible, true)
    $.clock.after(NOTICE_MS, () => void hideNotice($))
    log($, 'restored')
  } catch (error) {
    log($, `restore failed: ${describe(error)}`)
  }
}

async function hideNotice($: EngineInterface): Promise<void> {
  try {
    await $.state.set(noticeVisible, false)
  } catch (error) {
    log($, `could not hide the notice: ${describe(error)}`)
  }
}

function log($: EngineInterface, text: string): void {
  $.ui.log(`${FEATURE}: ${text}`, { to: 'debug' })
}

// The feature's hooks, which register.ts calls for a spawn that listed
// composer-draft. Each catches its own failures: a feature never fails a hook.

/** Restores the saved draft, once per process. */
export async function sessionStart($: EngineInterface, ctx: SessionContext): Promise<void> {
  try {
    // A notice still up was raised by an earlier load, whose timer went with it.
    if ((await $.state.get(noticeVisible)).value === true) {
      await $.state.set(noticeVisible, false)
    }
    // A reload fires session.start again in the same process; the draft is
    // already in the box there.
    if ((await $.state.get(restoredIncarnation)).value === ctx.incarnationId) {
      return
    }
    const text = await savedDraft($, ctx)
    if (text === undefined) {
      // Nothing to restore: save the box as it stands so the file exists, and
      // settle this process, so a later reload never takes the person's own
      // draft for one to restore.
      draftWriter($).queue(await $.prompt.read())
      await $.state.set(restoredIncarnation, ctx.incarnationId)
      return
    }
    void restoreDraft($, ctx, text)
  } catch (error) {
    log($, `session.start failed: ${describe(error)}`)
  }
}

/**
 * Saves the box one last time and waits for every queued write. An empty box
 * is not queued: the edit or clear that emptied it was saved already, and a
 * box the shutdown has unmounted reads empty too, which must not overwrite
 * the draft a park relies on.
 */
export async function sessionEnd($: EngineInterface, ctx: SessionContext): Promise<void> {
  try {
    const box = await $.prompt.read()
    const draft = draftWriter($)
    if (box.text !== '') {
      draft.queue(box)
    }
    await draft.flush()
  } catch (error) {
    log($, `session.end failed for ${ctx.sessionId}: ${describe(error)}`)
  }
}

/** The box after one of the person's edits; queued, never awaited. */
export function promptEdited($: EngineInterface, box: PromptBox): void {
  draftWriter($).queue(box)
}

/** The box after any other change: a clear, a recalled entry, a fill. */
export function promptChanged($: EngineInterface, box: PromptBox): void {
  draftWriter($).queue(box)
}

/** Draws the restore notice above what is drawn beneath, while it is visible. */
export async function abovePrompt(
  $: EngineInterface,
  e: AbovePromptEvent,
  below: () => Promise<RenderElement>,
): Promise<RenderElement> {
  const isVisible = await $.state.get(noticeVisible).then(
    read => read.value === true,
    () => false,
  )
  if (!isVisible) {
    return below()
  }
  const { Box, Text } = $.ui.resolve(e)
  return (
    <Box flexDirection="column">
      <Text dimColor>Restored your unsent draft</Text>
      {await below()}
    </Box>
  )
}
