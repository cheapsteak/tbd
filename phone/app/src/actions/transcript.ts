/**
 * The transcript actions: opening and closing the one transcript the laptop sends this phone,
 * resuming it after a dropped channel, its older pages, and its rows' details (spec section 7).
 * The slice they fill is `state/transcript.ts`; a detail's chunk rules are `state/detail.ts`.
 *
 * **Which reply counts.** The laptop keeps one transcript open per phone, and opening another
 * replaces the first. Each open, a resume included, takes a fresh token from `newRequestID`
 * (the client does not show the wire's request ID) and puts it in the slice's `openRequestID`
 * (`beginOpen`, `beginResume`). Its reply counts only while that is still its token, so the
 * reply to an open that a later open or a close replaced changes nothing. An older page takes a
 * fresh token too, in the slice's `olderRequestID`, and counts only while that is still its token:
 * every open, reset and close ends that wait, and a resume keeps it. One that no longer counts
 * still holds the one page turn (`stalePage`) until it settles.
 *
 * **Across a dropped channel.** The client rejects a `transcript.open` or `transcript.close`
 * still unanswered at a channel up as `superseded`, and never sends it again (`STATE_METHODS`
 * in `client/client.ts`). That rejection is silent here, because `resumeTranscriptOnUp` sends
 * what replaces it, in `onUp`'s turn, right after `sessions.subscribe` and ahead of the
 * client's resends:
 * - **A transcript the phone shows** (`phase` is `open`) goes out with `resume: true`. The
 *   slice stays `open` meanwhile, its rows, cursor and any older page on its way standing. The
 *   laptop keeps its feed when the subscribe replays the stream, and replays what the phone
 *   missed before its reply, `{resumed: true}`, which keeps the rows. Otherwise its reply is a
 *   page, which replaces them. A resume superseded at another drop is still a resume at the
 *   next up.
 * - **An open that never landed** (`opening`, or `failed`) goes out again as a fresh open,
 *   since the phone has no page of it to keep.
 * - **A close still unanswered**, with no transcript open since, goes out again: the laptop may
 *   still be sending that transcript.
 *
 * Every action resolves and never rejects (`actions/index.ts`); `superseded` is silent.
 */

import { AppError, newRequestID } from '../client/client.ts';
import type {
  PhoneItem, PhoneSessionRef, TranscriptDetailParams, TranscriptDetailPart, TranscriptDetailResult, TranscriptOpenResult,
  TranscriptPage,
} from '../protocol/types.ts';
import { sameRef } from '../protocol/wire.ts';
import { addChunk, askOf, badReply, detailParts, failDetail, startDetail } from '../state/detail.ts';
import type { DetailState } from '../state/detail.ts';
import { applyPage, beginOpen, beginResume, clearTranscript, prependPage } from '../state/transcript.ts';
import type { TranscriptState } from '../state/transcript.ts';
import type { ActionContext, Actions } from './index.ts';

function isSuperseded(error: unknown): boolean {
  return error instanceof AppError && error.code === 'superseded';
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** How one `transcript.detail` request settled. */
type ReadOutcome = { ok: true; result: TranscriptDetailResult } | { ok: false; error: unknown };

/**
 * The most `transcript.detail` requests on the wire at once, across every row. The client sends
 * at most `MAX_IN_FLIGHT` (32) requests at a time and queues the rest, so a laptop that stops
 * answering detail reads must not take its slots: with 4, the reader still sees four rows load
 * side by side, which is as many as a phone's screen opens at a time, and 28 slots stay free for
 * the subscribe, sends, pages and session actions. Further reads wait in `readDetail`.
 */
export const MAX_DETAIL_READS = 4;

/** A detail read waiting for a slot: `go(true)` sends it, `go(false)` drops it unsent. */
interface QueuedRead {
  wanted: () => boolean;
  go: (send: boolean) => void;
}

/** The slice an open's reply leaves: its page in place of the rows, or the rows kept when it resumed. */
function opened(t: TranscriptState, result: TranscriptOpenResult): TranscriptState {
  return { ...(result.page === undefined ? t : applyPage(t, result.page)), phase: 'open' };
}

export function transcriptActions(ctx: ActionContext, self: () => Actions) {
  const { store } = ctx;

  function setTranscript(fn: (t: TranscriptState) => TranscriptState): void {
    store.update((s) => {
      const transcript = fn(s.transcript);
      return transcript === s.transcript ? s : { ...s, transcript };
    });
  }

  /**
   * The token of the last `transcript.close` sent, so the reply to an earlier close does not
   * end the wait for a later one. Kept here and not in the store, since nothing renders it.
   */
  let closeToken: string | null = null;

  /**
   * Opens `ref`'s transcript (`beginOpen`), or with `resume` resumes the one the slice shows
   * (`beginResume`), and sends `transcript.open`. The request goes out before this returns, so a
   * call from `onUp` goes out in its turn. Its reply, while it still counts:
   * - a page replaces the rows, and `resumed: true` keeps them;
   * - a refused resume opens again, fresh, once. The laptop refuses a resume it can no longer
   *   honour ("The transcript changed while it was opened. Try again.") and expects the phone
   *   to open again, and a fresh open meets the same checks a resume does;
   * - any other error fails the open with the laptop's message.
   */
  function open(ref: PhoneSessionRef, showDetails: boolean, resume: boolean): void {
    const token = newRequestID();
    setTranscript((t) => (resume ? beginResume(t, token) : beginOpen(t, ref, showDetails, token)));
    ctx.client.request('transcript.open', { session: ref, showDetails, resume }).then(
      (result) => {
        setTranscript((t) => (t.openRequestID === token ? opened(t, result) : t));
      },
      (error: unknown) => {
        if (isSuperseded(error) || store.get().transcript.openRequestID !== token) return;
        if (resume) {
          open(ref, showDetails, false);
          return;
        }
        setTranscript((t) => ({
          ...clearTranscript(t), ref: t.ref, showDetails: t.showDetails, openRequestID: t.openRequestID, phase: 'failed',
          error: messageOf(error),
        }));
      },
    );
  }

  /**
   * Empties the slice and sends `transcript.close {}`, which the slice waits on (`pendingClose`)
   * until the laptop answers. A superseded close leaves the wait standing, so the next channel
   * up sends a fresh one.
   */
  function close(): void {
    const token = newRequestID();
    closeToken = token;
    setTranscript((t) => ({ ...clearTranscript(t), pendingClose: true }));
    const answered = (): void => {
      if (closeToken !== token) return;
      closeToken = null;
      setTranscript((t) => (t.pendingClose ? { ...t, pendingClose: false } : t));
    };
    ctx.client.request('transcript.close', {}).then(answered, (error: unknown) => {
      if (!isSuperseded(error)) answered();
    });
  }

  /** How many detail requests are on the wire, at most `MAX_DETAIL_READS`. */
  let readsOut = 0;

  /** The detail reads waiting for a slot, oldest first. */
  const queued: QueuedRead[] = [];

  /**
   * Drops each queued read no longer wanted, unsent, and sends the oldest wanted ones while a
   * slot is free. It runs when a read settles and at every change of the state, so a collapse,
   * a reset or a close drops the reads it made unwanted at once.
   */
  function pump(): void {
    for (let i = 0; i < queued.length; ) {
      const q = queued[i]!;
      if (!q.wanted()) {
        queued.splice(i, 1);
        q.go(false);
      } else if (readsOut < MAX_DETAIL_READS) {
        queued.splice(i, 1);
        readsOut += 1;
        q.go(true);
      } else {
        i += 1;
      }
    }
  }

  /**
   * Takes a slot: at once when one is free and no read waits, so the request goes out in the
   * caller's turn, and otherwise in turn. False when the read was dropped unsent.
   */
  function takeSlot(wanted: () => boolean): true | Promise<boolean> {
    if (queued.length === 0 && readsOut < MAX_DETAIL_READS) {
      readsOut += 1;
      return true;
    }
    return new Promise<boolean>((go) => {
      queued.push({ wanted, go });
    });
  }

  /**
   * The outcome of asking `params`, with at most `MAX_DETAIL_READS` requests on the wire across
   * all rows: past them it waits its turn. Null when `wanted` turns false while it waits, as
   * when its detail is collapsed, replaced or closed: nothing is asked then.
   */
  async function readDetail(params: TranscriptDetailParams, wanted: () => boolean): Promise<ReadOutcome | null> {
    const slot = takeSlot(wanted);
    if (slot !== true) {
      if (!(await slot)) return null;
      if (!wanted()) {
        readsOut -= 1;
        pump();
        return null;
      }
    }
    try {
      return { ok: true, result: await ctx.client.request('transcript.detail', params) };
    } catch (error) {
      return { ok: false, error };
    } finally {
      readsOut -= 1;
      pump();
    }
  }

  /**
   * The request row `rowKey`'s detail waits on, with the row's item: while the transcript is
   * open, the slice holds a loading detail for the row, and the row holds an item. Null
   * otherwise.
   */
  function askFor(rowKey: number): { params: TranscriptDetailParams; item: PhoneItem } | null {
    const t = store.get().transcript;
    const d = t.details[rowKey];
    if (t.phase !== 'open' || t.ref === null || d === undefined || d.phase !== 'loading') return null;
    const row = t.rows.find((r) => r.key === rowKey);
    if (row === undefined || row.kind !== 'item') return null;
    const ask = askOf(d);
    return { params: { session: t.ref, itemID: row.item.id, part: ask.part, chunk: ask.chunk }, item: row.item };
  }

  /** The loop loading each row's detail, by row key, while it runs (`drive`). */
  const driving = new Map<number, Promise<void>>();

  /**
   * Loads row `rowKey`'s detail, and resolves once it is no longer loading. One loop runs per
   * row, and it sends one request at a time, so a row has at most one request on the wire;
   * a call while the row's loop runs returns that loop.
   */
  function drive(rowKey: number): Promise<void> {
    const running = driving.get(rowKey);
    if (running !== undefined) return running;
    if (askFor(rowKey) === null) return Promise.resolve();
    const loop = load(rowKey);
    driving.set(rowKey, loop);
    return loop;
  }

  /**
   * `drive`'s loop. At each step it asks for what the row's detail waits on now, so a detail
   * replaced while a request is out, by a collapse and a tap or by its item changing
   * (`followItem`), carries on from where it stands. A reply counts only for the detail the
   * slice holds when it lands, and only while that detail still waits on just that request, of
   * the same item text for a message's text. Otherwise the loop asks again for what the detail
   * waits on then, or stops when it waits on nothing.
   */
  async function load(rowKey: number): Promise<void> {
    try {
      for (let want = askFor(rowKey); want !== null; want = askFor(rowKey)) {
        const { params, item } = want;
        const counts = (): boolean => {
          const now = askFor(rowKey);
          return now !== null && sameRead(now.params, params) && (params.part !== 'text' || now.item.text === item.text);
        };
        const outcome = await readDetail(params, counts);
        if (outcome === null || !counts()) continue;
        const d = store.get().transcript.details[rowKey]!;
        if (!outcome.ok) {
          if (isSuperseded(outcome.error)) dropDetail(rowKey, d);
          else putDetail(rowKey, d, failDetail(d, messageOf(outcome.error)));
          return;
        }
        const { result } = outcome;
        putDetail(rowKey, d, (result.itemID === params.itemID ? addChunk(d, result) : badReply(d)).next);
      }
    } finally {
      driving.delete(rowKey);
    }
  }

  /** Every loading detail with no loop gets one: a tool's detail that `followItem` set loading. */
  function driveAll(): void {
    const t = store.get().transcript;
    if (t.phase !== 'open') return;
    for (const key of Object.keys(t.details)) {
      const rowKey = Number(key);
      if (t.details[rowKey]!.phase === 'loading' && !driving.has(rowKey)) void drive(rowKey);
    }
  }

  store.subscribe(() => {
    if (queued.length > 0) pump();
    driveAll();
  });

  /** Puts `next` as row `rowKey`'s detail, when `was` is still the one there. */
  function putDetail(rowKey: number, was: DetailState, next: DetailState): void {
    if (next === was) return;
    setTranscript((t) => (t.details[rowKey] === was ? { ...t, details: { ...t.details, [rowKey]: next } } : t));
  }

  /** Removes row `rowKey`'s detail, when `was` is still the one there. */
  function dropDetail(rowKey: number, was: DetailState): void {
    setTranscript((t) => {
      if (t.details[rowKey] !== was) return t;
      const details = { ...t.details };
      delete details[rowKey];
      return { ...t, details };
    });
  }

  return {
    /** Opens `ref`'s transcript from its tail, with the "Show details" setting. */
    openTranscript(ref: PhoneSessionRef): void {
      open(ref, store.get().ui.showDetails, false);
    },

    /** Closes the open transcript, or one still opening. With none, it does nothing. */
    closeTranscript(): void {
      if (store.get().transcript.ref === null) return;
      close();
    },

    /** The channel came up: what this file's header lists, sent in `onUp`'s turn. */
    resumeTranscriptOnUp(): void {
      const t = store.get().transcript;
      if (t.ref !== null) open(t.ref, t.showDetails, t.phase === 'open');
      else if (t.pendingClose) close();
    },

    /** "Show details" changed: the open transcript opens again with it. */
    onShowDetailsChanged(): void {
      const { ref } = store.get().transcript;
      if (ref !== null) self().openTranscript(ref);
    },

    /**
     * Asks for the page above the rows and puts it above them (`prependPage`). It does nothing
     * unless the transcript is open with a cursor, no older page is on its way, for these rows
     * or for rows a page replaced (`stalePage`), the start is not reached, and the last older
     * page did not fail. So at most one page is on the wire. Each page takes a fresh token
     * (`olderRequestID`), and its reply counts only while the slice still waits on that token.
     * A page whose open, reset or close came first changes no row: it clears `stalePage`, a
     * change the list sees, so it asks again for the rows it shows now if it still wants their
     * page. On an error:
     * - `stale_cursor` or `not_open` opens the transcript again, from its tail;
     * - any other error ends the wait and sets `olderFailed`, so nothing asks again until the
     *   reader scrolls (`clearOlderFailed`). A failing load never retries in a loop.
     */
    async loadOlder(): Promise<void> {
      const t = store.get().transcript;
      if (t.ref === null || t.phase !== 'open' || t.cursor === null) return;
      if (t.olderRequestID !== null || t.stalePage || t.reachedStart || t.olderFailed) return;
      const ref = t.ref;
      const token = newRequestID();
      setTranscript((s) => ({ ...s, olderRequestID: token }));
      // An open, a reset or a close replaced the rows this page was for, so the slice no longer waits on it.
      const stale = (): boolean => store.get().transcript.olderRequestID !== token;
      const settledStale = (): void => setTranscript((s) => (s.stalePage ? { ...s, stalePage: false } : s));
      /** The slice with `fn` applied, while it still waits on this page. */
      const settle = (fn: (s: TranscriptState) => TranscriptState): void => setTranscript((s) => (s.olderRequestID === token ? fn(s) : s));
      let page: TranscriptPage;
      try {
        page = await ctx.client.request('transcript.page', { session: ref, cursor: t.cursor });
      } catch (error) {
        if (stale()) {
          settledStale();
          return;
        }
        if (error instanceof AppError && (error.code === 'stale_cursor' || error.code === 'not_open')) {
          // The page settled, so the open does not wait for it.
          settle((s) => ({ ...s, olderRequestID: null }));
          self().openTranscript(ref);
          return;
        }
        settle((s) => ({ ...s, olderRequestID: null, olderFailed: !isSuperseded(error) }));
        return;
      }
      if (stale()) settledStale();
      else settle((s) => prependPage(s, page));
    },

    /** The reader scrolled: an older page that failed may be asked for again. */
    clearOlderFailed(): void {
      setTranscript((t) => (t.olderFailed ? { ...t, olderFailed: false } : t));
    },

    /**
     * Opens or closes one part of the row with key `rowKey`, loading its chunks, and resolves
     * once they landed or failed. `part` is the part the row names (`detailParts`).
     * - **A tap on a row whose detail shows** (loading, loaded, too large, or failed for a tool or
     *   a subagent) collapses it: the detail leaves the slice with what arrived of it, the reply
     *   on its way is dropped, and nothing more is asked.
     * - **Any other tap**, on a closed row or on a failed "Show more", which has no collapse,
     *   starts the detail over from its first chunk, while the transcript is open and the row
     *   holds an item.
     *
     * The row's loop loads it (`drive`), and each reply counts only for the detail the slice
     * holds when it lands, while that detail still waits on just that request and the
     * transcript is open (`load`). So a reply that lands after a collapse, a reset, a reopen, a
     * close or a switch to another session changes nothing and asks for nothing: each of those
     * drops the detail, and a reopen leaves the slice `opening` until its page drops every
     * detail. A resume is the one new open that keeps the details, because it keeps the rows:
     * `transcript.detail` is a read, which the client sends again after a dropped channel, so
     * its reply still comes and the load carries on.
     *
     * A row has at most one request on the wire, since one loop runs per row: a tap while the
     * request of a collapsed detail of the row is unanswered waits for it, and takes its reply
     * when it asked for the same first chunk. All rows together have at most
     * `MAX_DETAIL_READS` (`readDetail`): a read past them waits its turn, and one whose detail
     * is collapsed or replaced meanwhile is never sent. A detail the slice changes as its item
     * changes (`followItem`) carries on under the same loop, or one starts for it.
     *
     * A reply for another item ID than the one asked for fails the detail with `BAD_REPLY_TEXT`.
     * An error fails it with the error's message: `not_found`, "That detail is not in the
     * transcript.", is the usual one, since the laptop keeps the place of its last 8,192 items
     * only and a remote prepend can move an item's ID. `superseded`, which the client never
     * sends for a read today, removes the detail silently, so the row closes and nothing waits.
     */
    async toggleDetail(rowKey: number, part: TranscriptDetailPart): Promise<void> {
      const t = store.get().transcript;
      const shown = t.details[rowKey];
      if (shown !== undefined && (shown.phase !== 'failed' || part !== 'text')) {
        dropDetail(rowKey, shown);
        return;
      }
      const row = t.rows.find((r) => r.key === rowKey);
      if (t.phase !== 'open' || t.ref === null || row === undefined || row.kind !== 'item') return;
      const d = startDetail(detailParts(part, row.item));
      setTranscript((s) => ({ ...s, details: { ...s.details, [rowKey]: d } }));
      await drive(rowKey);
    },
  };
}

/** Whether two detail requests ask the same: one session, item, part and chunk. */
function sameRead(a: TranscriptDetailParams, b: TranscriptDetailParams): boolean {
  return sameRef(a.session, b.session) && a.itemID === b.itemID && a.part === b.part && a.chunk === b.chunk;
}
