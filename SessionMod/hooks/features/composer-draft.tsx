// composer-draft: saves the prompt box to composer-draft.json on every change,
// so TBD can park a session with a draft in the box, and fills a saved draft
// back into the box when the session resumes in a new process.
import type {
  EngineInterface,
  Frozen,
  PromptBox,
  PromptChangeOrigin,
  RenderElement,
  RenderInput,
} from 'claude-code'

import { describe, resolveContext, writeJSON } from '../shared/session.ts'
import type { SessionContext } from '../shared/session.ts'

export const FEATURE = 'composer-draft'
export const RESTORE_RETRY_MS = 500
export const NOTICE_MS = 3_000

/** The plugin's own name, as a `plugin` origin names the plugin that filled. */
const PLUGIN = 'tbd'

/** Between two drafts in composer-draft.unrestored. */
const UNRESTORED_SEPARATOR = '\n\n--- unrestored draft ---\n\n'

const restoredIncarnation = { plugin: 'tbd', key: 'composerDraftRestoredIncarnation' } as const
const notice = { plugin: 'tbd', key: 'composerDraftNotice' } as const
const restorableMark = { plugin: 'tbd', key: 'composerDraftRestorable' } as const

type AbovePromptEvent = Frozen<RenderInput<'AbovePrompt'>>

/**
 * A box to save, and what it does to the restorable mark: whether the box's
 * text holds all of the draft. `restorable` sets the mark; left out, the box
 * keeps the mark as the boxes before it left it.
 */
export type QueuedBox = { box: PromptBox; restorable?: boolean }

export type DraftWriter = {
  queue(box: PromptBox, restorable?: boolean): void
  flush(): Promise<void>
}

/**
 * Writes boxes one at a time. A box queued while a write runs replaces any box
 * queued behind it, so an older box never lands after a newer one; a box that
 * keeps the mark takes over the mark the box it replaces set, so dropping that
 * box never drops its mark. An empty box sets the mark restorable. A write
 * that rejects is dropped and the next box is still written; `write` logs its
 * own failures.
 */
export function createDraftWriter(write: (queued: QueuedBox) => Promise<void>): DraftWriter {
  let queued: QueuedBox | undefined
  let running: Promise<void> | undefined

  async function drain(): Promise<void> {
    while (queued !== undefined) {
      const next = queued
      queued = undefined
      try {
        await write(next)
      } catch {
        // Dropped: `write` reports its own failures.
      }
    }
    running = undefined
  }

  return {
    queue(box, restorable) {
      const mark = box.text === '' ? true : (restorable ?? queued?.restorable)
      queued = mark === undefined ? { box } : { box, restorable: mark }
      running ??= drain()
    },
    async flush() {
      while (running !== undefined) {
        await running
      }
    },
  }
}

/**
 * The composer-draft.json record of a box: its text, cursor and whether the
 * text holds all of the draft, or no draft. The daemon reads the numbers as
 * integers, so they are written whole.
 */
export function draftRecord(sessionId: string, box: PromptBox, restorable: boolean, now: number): object {
  const savedAtMs = Math.trunc(now)
  if (box.text === '') {
    return { schemaVersion: 1, sessionId, hasDraft: false, savedAtMs }
  }
  return {
    schemaVersion: 1,
    sessionId,
    hasDraft: true,
    text: box.text,
    cursor: Math.trunc(box.cursor),
    restorable,
    savedAtMs,
  }
}

let writer: DraftWriter | undefined

/**
 * The restorable mark this load holds; undefined until the first box that
 * keeps it reads it from `$.state`, where it outlives a reload. Only the
 * writer, which runs one box at a time, reads or sets it.
 */
let restorable: boolean | undefined

/** True from the start of a restore until it lands, settles otherwise, or fails. */
let restoring = false

/**
 * The draft the pending restore is filling, until the change its fill raised
 * arrives: that change carries the draft's mark.
 */
let ownFill: SavedText | undefined

function draftWriter($: EngineInterface): DraftWriter {
  writer ??= createDraftWriter(queued => saveBox($, queued))
  return writer
}

async function saveBox($: EngineInterface, queued: QueuedBox): Promise<void> {
  try {
    const ctx = await resolveContext($)
    if (ctx !== null) {
      const mark = await settleMark($, queued.restorable)
      await writeJSON($, `${ctx.dir}/composer-draft.json`, draftRecord(ctx.sessionId, queued.box, mark, await $.clock.now()))
    }
  } catch (error) {
    log($, `could not save the draft: ${describe(error)}`)
  }
}

/** Applies a box's change to the mark, and answers the mark the box is saved with. */
async function settleMark($: EngineInterface, change: boolean | undefined): Promise<boolean> {
  if (change === undefined) {
    restorable ??= await readMark($)
    return restorable
  }
  if (change !== restorable) {
    restorable = change
    try {
      await $.state.set(restorableMark, change)
    } catch (error) {
      log($, `could not keep the restorable mark: ${describe(error)}`)
    }
  }
  return change
}

/**
 * The mark an earlier load kept. Never set means nothing marked the box. A
 * read that fails could hide a mark, so it reads as not restorable.
 */
async function readMark($: EngineInterface): Promise<boolean> {
  try {
    return (await $.state.get(restorableMark)).value ?? true
  } catch (error) {
    log($, `could not read the restorable mark: ${describe(error)}`)
    return false
  }
}

/** A saved draft: its text, and whether that text holds all of it. */
type SavedText = { text: string; restorable: boolean }

/** What composer-draft.json holds at a session's start. */
type SavedDraft =
  /** No file, or a file recording an empty box. */
  | { kind: 'none' }
  | ({ kind: 'draft' } & SavedText)
  /** A file that is there but cannot be read: it may hold a draft, so it is kept. */
  | { kind: 'unreadable'; reason: string }

async function readSavedDraft($: EngineInterface, ctx: SessionContext): Promise<SavedDraft> {
  const path = `${ctx.dir}/composer-draft.json`
  if (!(await $.fs.exists(path))) {
    return { kind: 'none' }
  }
  let file: string
  try {
    file = await $.fs.read(path)
  } catch (error) {
    return { kind: 'unreadable', reason: describe(error) }
  }
  let record: unknown
  try {
    record = JSON.parse(file)
  } catch {
    return { kind: 'unreadable', reason: 'not JSON' }
  }
  const fields =
    typeof record === 'object' && record !== null
      ? (record as { hasDraft?: unknown; text?: unknown; restorable?: unknown })
      : {}
  if (typeof fields.hasDraft !== 'boolean') {
    return { kind: 'unreadable', reason: 'no hasDraft' }
  }
  if (!fields.hasDraft) {
    return { kind: 'none' }
  }
  if (typeof fields.text !== 'string' || fields.text === '') {
    return { kind: 'unreadable', reason: 'a draft without text' }
  }
  return { kind: 'draft', text: fields.text, restorable: fields.restorable === true }
}

/**
 * Fills the saved draft into the empty box, retrying every RESTORE_RETRY_MS
 * while the box refuses it (not mounted yet, or under a dialog). When the
 * person's own text reaches the box first, the box is left alone and the
 * draft is added to composer-draft.unrestored. Each outcome is recorded in
 * composer-draft.restore.json. Resolves after one attempt and never rejects;
 * the retries run on timers.
 */
export async function restoreDraft($: EngineInterface, ctx: SessionContext, draft: SavedText): Promise<void> {
  try {
    const box = await $.prompt.read()
    if (box.text !== '') {
      await keepUnrestored($, ctx, draft.text)
      await $.state.set(restoredIncarnation, ctx.incarnationId)
      restoring = false
      await recordRestore($, ctx, 'unrestored')
      return
    }
    ownFill = draft
    const filled = await $.prompt.fill({ text: draft.text, mode: 'replace' })
    if (!filled.isFilled) {
      // Still pending: the retry runs on a timer.
      ownFill = undefined
      $.clock.after(RESTORE_RETRY_MS, () => void restoreDraft($, ctx, draft))
      return
    }
    await $.state.set(restoredIncarnation, ctx.incarnationId)
    restoring = false
    await $.state.set(notice, draft.restorable ? 'restored' : 'restoredWithoutPaste')
    $.clock.after(NOTICE_MS, () => void hideNotice($))
    log($, 'restored')
    await recordRestore($, ctx, 'restored')
  } catch (error) {
    restoring = false
    log($, `restore failed: ${describe(error)}`)
  }
}

/**
 * Adds a draft to composer-draft.unrestored: as the whole text when there is
 * no file, else after the drafts already there and UNRESTORED_SEPARATOR, so a
 * later rescue never replaces an earlier one. A file that is there but cannot
 * be read is left alone, since writing it would drop the drafts it holds.
 */
async function keepUnrestored($: EngineInterface, ctx: SessionContext, text: string): Promise<void> {
  const path = `${ctx.dir}/composer-draft.unrestored`
  let kept: string | undefined
  if (await $.fs.exists(path)) {
    try {
      kept = await $.fs.read(path)
    } catch (error) {
      log($, `could not read composer-draft.unrestored, left it alone and dropped the draft: ${describe(error)}`)
      return
    }
  }
  await $.fs.write(path, kept === undefined ? text : `${kept}${UNRESTORED_SEPARATOR}${text}`)
  log($, 'box was not empty, saved the draft to composer-draft.unrestored')
}

/**
 * Overwrites composer-draft.restore.json with a restore's outcome, so the soak
 * can count restores from the session directories without Claude's debug log.
 */
async function recordRestore($: EngineInterface, ctx: SessionContext, outcome: 'restored' | 'unrestored'): Promise<void> {
  try {
    await writeJSON($, `${ctx.dir}/composer-draft.restore.json`, {
      schemaVersion: 1,
      sessionId: ctx.sessionId,
      incarnationId: ctx.incarnationId,
      outcome,
      atMs: Math.trunc(await $.clock.now()),
    })
  } catch (error) {
    log($, `could not record the restore: ${describe(error)}`)
  }
}

async function hideNotice($: EngineInterface): Promise<void> {
  try {
    await $.state.set(notice, 'hidden')
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
    const shown = (await $.state.get(notice)).value
    if (shown !== undefined && shown !== 'hidden') {
      await $.state.set(notice, 'hidden')
    }
    // A reload fires session.start again in the same process; the draft is
    // already in the box there.
    if ((await $.state.get(restoredIncarnation)).value === ctx.incarnationId) {
      return
    }
    const saved = await readSavedDraft($, ctx)
    if (saved.kind === 'unreadable') {
      // It may hold a draft: neither overwrite it nor settle this process.
      log($, `could not read composer-draft.json, left it alone: ${saved.reason}`)
      return
    }
    if (saved.kind === 'none') {
      // Nothing to restore: save the box as it stands so the file exists, and
      // settle this process, so a later reload never takes the person's own
      // draft for one to restore.
      draftWriter($).queue(await $.prompt.read())
      await $.state.set(restoredIncarnation, ctx.incarnationId)
      return
    }
    restoring = true
    void restoreDraft($, ctx, { text: saved.text, restorable: saved.restorable })
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

/**
 * The box after one of the person's edits; queued, never awaited. An edit
 * keeps the mark: typing after a paste does not put the paste in the text. An
 * empty box is not saved while a restore is pending, because it would
 * overwrite the saved draft before the fill lands.
 */
export function promptEdited($: EngineInterface, box: PromptBox): void {
  if (restoring && box.text === '') {
    return
  }
  draftWriter($).queue(box)
}

/**
 * The box after any other change: a clear, a recalled entry, a fill. Such a
 * change can put content in the box that its text does not hold (a collapsed
 * paste, an image), so any origin but a clear or a plugin's fill marks a box
 * it leaves non-empty as not restorable. The feature's own restore fill
 * carries the saved draft's mark, and loses it when the engine changed the
 * text it filled (an over-long text collapsed). An empty box is not saved
 * while a restore is pending.
 */
export function promptChanged($: EngineInterface, box: PromptBox, origin: Frozen<PromptChangeOrigin>): void {
  if (restoring && box.text === '') {
    return
  }
  draftWriter($).queue(box, markAfterChange(box, origin))
}

function markAfterChange(box: PromptBox, origin: Frozen<PromptChangeOrigin>): boolean | undefined {
  switch (origin.kind) {
    case 'clear':
      return true
    case 'plugin': {
      if (origin.name !== PLUGIN || ownFill === undefined) {
        return undefined
      }
      const fill = ownFill
      ownFill = undefined
      return fill.restorable && box.text === fill.text
    }
    default:
      return box.text === ''
  }
}

/**
 * Draws the restore notice above what is drawn beneath, while it is visible.
 * A draft marked not restorable came back as its text alone, without the
 * content its paste placeholders stand for, and the notice says so.
 */
export async function abovePrompt(
  $: EngineInterface,
  e: AbovePromptEvent,
  below: () => Promise<RenderElement>,
): Promise<RenderElement> {
  const shown = await $.state.get(notice).then(
    read => read.value ?? 'hidden',
    () => 'hidden',
  )
  if (shown === 'hidden') {
    return below()
  }
  const { Box, Text } = $.ui.resolve(e)
  return (
    <Box flexDirection="column">
      <Text dimColor>
        {shown === 'restored' ? 'Restored your unsent draft' : 'Restored your unsent draft, but not its pasted text'}
      </Text>
      {await below()}
    </Box>
  )
}
