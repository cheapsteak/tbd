/**
 * The transcript actions: opening and closing the one transcript the laptop sends this phone,
 * resuming it after a dropped channel, its older pages, and its rows' details (spec section 7).
 * The slice they fill is `state/transcript.ts`; a detail's chunk rules are `state/detail.ts`.
 *
 * **Which reply counts.** The laptop keeps one transcript open per phone, and opening another
 * replaces the first. Each open, a resume included, takes a fresh token from `newRequestID`
 * (the client does not show the wire's request ID) and puts it in the slice's `openRequestID`
 * (`beginOpen`, `beginResume`). Its reply counts only while that is still its token, so the
 * reply to an open that a later open or a close replaced changes nothing. An older page counts
 * only while the slice still waits for it (`loadingOlder`): every open, reset and close ends
 * that wait, and a resume keeps it.
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

import { AppError, BAD_REPLY_TEXT, newRequestID } from '../client/client.ts';
import type {
  PhoneSessionRef, TranscriptDetailParams, TranscriptDetailPart, TranscriptDetailResult, TranscriptOpenResult, TranscriptPage,
} from '../protocol/types.ts';
import { sameRef } from '../protocol/wire.ts';
import { addChunk, askOf, cancelDetail, detailParts, failDetail, isOpen, startDetail } from '../state/detail.ts';
import type { DetailState } from '../state/detail.ts';
import { applyPage, beginOpen, beginResume, emptyTranscript, prependPage } from '../state/transcript.ts';
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

/** A `transcript.detail` request on the wire for one row: what it asked, and how it settles. */
interface DetailRead {
  params: TranscriptDetailParams;
  settled: Promise<ReadOutcome>;
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
   * Whether a `transcript.page` is unanswered, for whichever open sent it. At most one goes out
   * at a time: one that a newer open made stale still holds the turn until it settles.
   */
  let pageInFlight = false;

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
          ...emptyTranscript(), nextKey: t.nextKey, ref: t.ref, showDetails: t.showDetails, openRequestID: t.openRequestID,
          phase: 'failed', error: messageOf(error),
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
    setTranscript((t) => ({ ...emptyTranscript(), nextKey: t.nextKey, pendingClose: true }));
    const answered = (): void => {
      if (closeToken !== token) return;
      closeToken = null;
      setTranscript((t) => (t.pendingClose ? { ...t, pendingClose: false } : t));
    };
    ctx.client.request('transcript.close', {}).then(answered, (error: unknown) => {
      if (!isSuperseded(error)) answered();
    });
  }

  /**
   * The `transcript.detail` request each row has on the wire, by row key, until it settles. A
   * request cannot be taken back, so a collapse leaves its row's request running, and the next
   * tap on that row waits for it (`readDetail`).
   */
  const reads = new Map<number, DetailRead>();

  /**
   * The outcome of asking `params` for row `rowKey`, with at most one request on the wire per
   * row. While an earlier request for the row is unanswered, as after a tap, a collapse and a
   * tap, it waits for that one to settle: its outcome is the answer when it asked the same, and
   * otherwise this asks once it is gone. So a laptop that never answers holds one request per
   * row, however often the row is tapped, and the client's 32 slots stay free for the rest.
   * Null when `wanted` turns false while it waits: the detail was collapsed or replaced, and
   * nothing is asked for it.
   */
  async function readDetail(rowKey: number, params: TranscriptDetailParams, wanted: () => boolean): Promise<ReadOutcome | null> {
    for (let prior = reads.get(rowKey); prior !== undefined; prior = reads.get(rowKey)) {
      const outcome = await prior.settled;
      if (!wanted()) return null;
      if (sameRead(prior.params, params)) return outcome;
    }
    const settled = ctx.client.request('transcript.detail', params).then(
      (result): ReadOutcome => ({ ok: true, result }),
      (error: unknown): ReadOutcome => ({ ok: false, error }),
    );
    const read: DetailRead = { params, settled };
    reads.set(rowKey, read);
    // Registered first, so it runs before anyone awaiting `settled` looks at `reads` again.
    void settled.then(() => {
      if (reads.get(rowKey) === read) reads.delete(rowKey);
    });
    return settled;
  }

  /** Whether the slice still holds `d` as row `rowKey`'s detail, in an open transcript. */
  function stillAsked(rowKey: number, d: DetailState): boolean {
    const t = store.get().transcript;
    return t.phase === 'open' && t.details[rowKey] === d;
  }

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
     * unless the transcript is open with a cursor, no older page is on its way, the start is not
     * reached, and the last older page did not fail. A page whose open, reset or close came
     * first changes nothing. On an error:
     * - `stale_cursor` or `not_open` opens the transcript again, from its tail;
     * - any other error ends the wait and sets `olderFailed`, so nothing asks again until the
     *   reader scrolls (`clearOlderFailed`). A failing load never retries in a loop.
     */
    async loadOlder(): Promise<void> {
      const t = store.get().transcript;
      if (pageInFlight || t.ref === null || t.phase !== 'open' || t.cursor === null) return;
      if (t.loadingOlder || t.reachedStart || t.olderFailed) return;
      const ref = t.ref;
      pageInFlight = true;
      setTranscript((s) => ({ ...s, loadingOlder: true }));
      let page: TranscriptPage;
      try {
        page = await ctx.client.request('transcript.page', { session: ref, cursor: t.cursor });
      } catch (error) {
        pageInFlight = false;
        // An open, a reset or a close replaced the rows this page was for.
        if (!store.get().transcript.loadingOlder) return;
        if (error instanceof AppError && (error.code === 'stale_cursor' || error.code === 'not_open')) {
          self().openTranscript(ref);
          return;
        }
        setTranscript((s) => ({ ...s, loadingOlder: false, olderFailed: !isSuperseded(error) }));
        return;
      }
      pageInFlight = false;
      setTranscript((s) => (s.loadingOlder ? prependPage(s, page) : s));
    },

    /** The reader scrolled: an older page that failed may be asked for again. */
    clearOlderFailed(): void {
      setTranscript((t) => (t.olderFailed ? { ...t, olderFailed: false } : t));
    },

    /**
     * Opens or closes one part of the row with key `rowKey`, loading its chunks, and resolves
     * once they landed or failed. `part` is the part the row names (`detailParts`).
     * - **A tap on a row whose detail shows** (loading, loaded or too large) collapses it
     *   (`cancelDetail`): the reply on its way is dropped, and nothing more is asked.
     * - **Any other tap**, on a closed row, a collapsed one or a failed one, starts the detail
     *   over from its first chunk, while the transcript is open and the row holds an item.
     *
     * Each reply counts only while the slice still holds this very detail under `rowKey` and the
     * transcript is open (`stillAsked`). So a reply that lands after a collapse, a second tap,
     * a reset, a reopen, a close or a switch to another session changes nothing and asks for
     * nothing: each of those replaces or drops the detail, and a reopen leaves the slice
     * `opening` until its page drops every detail. A resume is the one new open that keeps the
     * details, because it keeps the rows: `transcript.detail` is a read, which the client sends
     * again after a dropped channel, so its reply still comes and the load carries on.
     *
     * A row has at most one request on the wire (`readDetail`): a tap while the request of a
     * collapsed detail of the row is unanswered waits for it, and takes its reply when it asked
     * for the same first chunk.
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
      if (isOpen(shown) && shown.phase !== 'failed') {
        putDetail(rowKey, shown, cancelDetail(shown));
        return;
      }
      const row = t.rows.find((r) => r.key === rowKey);
      if (t.phase !== 'open' || t.ref === null || row === undefined || row.kind !== 'item') return;
      const session = t.ref;
      const itemID = row.item.id;
      let d = startDetail(detailParts(part, row.item));
      setTranscript((s) => ({ ...s, details: { ...s.details, [rowKey]: d } }));
      for (;;) {
        const ask = askOf(d);
        const asked = d;
        const outcome = await readDetail(rowKey, { session, itemID, part: ask.part, chunk: ask.chunk }, () => stillAsked(rowKey, asked));
        if (outcome === null || !stillAsked(rowKey, d)) return;
        if (!outcome.ok) {
          if (isSuperseded(outcome.error)) dropDetail(rowKey, d);
          else putDetail(rowKey, d, failDetail(d, messageOf(outcome.error)));
          return;
        }
        const { result } = outcome;
        const step = result.itemID === itemID ? addChunk(d, result) : { next: failDetail(d, BAD_REPLY_TEXT), ask: null };
        putDetail(rowKey, d, step.next);
        if (step.ask === null) return;
        d = step.next;
      }
    },
  };
}

/** Whether two detail requests ask the same: one session, item, part and chunk. */
function sameRead(a: TranscriptDetailParams, b: TranscriptDetailParams): boolean {
  return sameRef(a.session, b.session) && a.itemID === b.itemID && a.part === b.part && a.chunk === b.chunk;
}
