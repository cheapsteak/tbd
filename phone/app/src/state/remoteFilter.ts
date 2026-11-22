/**
 * A tap on a repo header's filter chip, from the tap to the laptop's answer (spec
 * `docs/specs/2026-11-22-phone-remote-session-filter-design.md`, "A tap"). The chip flips at once:
 * the phone holds its own value for the repo (`UIState.remoteFilterPending`), which wins over the
 * layout's in `sessionsView`, until the laptop's list settles it. Everything here is pure; the
 * request, and the timer that ends a wait the list never settles, are `toggleRemoteFilter`'s
 * (`actions/shell.ts`).
 *
 * A pending value goes:
 * - when a layout arrives whose value for the repo agrees with it, before the reply or after. A
 *   tap made while an earlier request of the repo's was unanswered is the exception: that
 *   earlier write can still change the list, so a layout that agrees may be from before it, and
 *   only the tap's own reply lets agreement settle it (`stage: 'queued'`);
 * - at the reply, when the list's layout agrees already;
 * - once the laptop took the request, at the first `sessions.changed` after the reply, whatever
 *   it carries, so a change another client made since, on the laptop or on another phone, shows
 *   and never leaves the chip stuck on the phone's own value. The laptop sends a layout only when
 *   it differs from the phone's, so a change undone before the laptop gathers its list again
 *   sends none, and may send no event at all: then the value goes `TAKEN_WAIT_MS` after the reply
 *   (`tapExpired`);
 * - when a layout no longer lists its repo;
 * - when the request fails, and a toast gives the laptop's reason.
 *
 * Each tap has a number (`seq`), one more than the last. A reply settles the pending value only
 * while it is still its own tap's, so the reply to an older tap, success or failure, never undoes a
 * newer one: two quick taps, on and then off, end on off whatever becomes of the first request.
 */

import type { PhoneGroupLayout } from '../protocol/types.ts';
import { repoIDOf } from './sessionsView.ts';
import { emptyRecord, nextToast } from './store.ts';
import type { SessionsData, UIState } from './store.ts';

/**
 * How long the daemon's sessions publisher waits after a change before it gathers the list
 * again (`PhoneAppConstants.sessionsDebounce`).
 */
export const SESSIONS_DEBOUNCE_MS = 500;

/**
 * How long a value the laptop took waits for a `sessions.changed` before it goes (`tapExpired`):
 * twice the publisher's debounce, time for the list gathered after the write to arrive.
 */
export const TAKEN_WAIT_MS = 2 * SESSIONS_DEBOUNCE_MS;

/**
 * Where a tap's request is:
 * - `sent`: it went at once, with none of the repo's earlier requests unanswered. A layout that
 *   agrees with the tap settles it.
 * - `queued`: the tap came while an earlier request of the repo's was unanswered, so its own goes
 *   once that one is answered. A layout that agrees settles it only after its own reply.
 * - `taken`: the laptop took it. The next `sessions.changed` settles it, whatever it carries, or
 *   `tapExpired` when none comes.
 */
export type RemoteFilterStage = 'sent' | 'queued' | 'taken';

/** The phone's own filter value for one repo, while its tap waits on the laptop. */
export interface RemoteFilterPending {
  /** The value the chip shows. */
  value: boolean;
  /** The tap's number. Only the reply to this tap settles it. */
  seq: number;
  /** Where the tap's request is. */
  stage: RemoteFilterStage;
}

/** `layout`'s repo group for `repoID`, or null when it has none. */
function repoGroup(layout: readonly PhoneGroupLayout[], repoID: string): PhoneGroupLayout | null {
  return layout.find((g) => repoIDOf(g) === repoID) ?? null;
}

/** The filter value `layout` gives repo `repoID`, or null when it has no repo group for it. */
export function layoutFilterOn(layout: readonly PhoneGroupLayout[], repoID: string): boolean | null {
  const group = repoGroup(layout, repoID);
  return group === null ? null : group.remoteFilterOn === true;
}

/**
 * The filter value the chip of repo `repoID` shows: the phone's own while a tap waits, else the
 * list's. Null when the list has no repo group for it, so there is no chip to tap.
 */
export function shownFilterOn(ui: UIState, d: SessionsData, repoID: string): boolean | null {
  const fromLayout = layoutFilterOn(d.layout, repoID);
  if (fromLayout === null) return null;
  return Object.hasOwn(ui.remoteFilterPending, repoID) ? ui.remoteFilterPending[repoID]!.value : fromLayout;
}

/** The pending values alone, by repo ID, as `sessionsView` takes them. */
export function pendingValues(pending: UIState['remoteFilterPending']): Record<string, boolean> {
  const out = emptyRecord<boolean>();
  for (const id of Object.keys(pending)) out[id] = pending[id]!.value;
  return out;
}

/** `pending` with `repoID`'s entry set to `entry`, or removed when `entry` is null. */
function withEntry(
  pending: UIState['remoteFilterPending'], repoID: string, entry: RemoteFilterPending | null,
): UIState['remoteFilterPending'] {
  const out = emptyRecord<RemoteFilterPending>();
  for (const id of Object.keys(pending)) if (id !== repoID) out[id] = pending[id]!;
  if (entry !== null) out[repoID] = entry;
  return out;
}

/** `ui` without each pending value `drop` picks, or `ui` itself when it picks none. */
function without(ui: UIState, drop: (repoID: string, entry: RemoteFilterPending) => boolean): UIState {
  let pending = ui.remoteFilterPending;
  for (const repoID of Object.keys(ui.remoteFilterPending)) {
    if (drop(repoID, ui.remoteFilterPending[repoID]!)) pending = withEntry(pending, repoID, null);
  }
  return pending === ui.remoteFilterPending ? ui : { ...ui, remoteFilterPending: pending };
}

/** Whether `repoID`'s pending entry in `ui` is tap `seq`'s. */
function isTap(ui: UIState, repoID: string, seq: number): boolean {
  return Object.hasOwn(ui.remoteFilterPending, repoID) && ui.remoteFilterPending[repoID]!.seq === seq;
}

/**
 * `ui` once tap `seq` set repo `repoID`'s filter to `value`, on its way to the laptop: `queued`
 * when an earlier request of the repo's is unanswered, so this one goes after it.
 */
export function withTap(ui: UIState, repoID: string, value: boolean, seq: number, queued: boolean): UIState {
  const entry: RemoteFilterPending = { value, seq, stage: queued ? 'queued' : 'sent' };
  return { ...ui, remoteFilterPending: withEntry(ui.remoteFilterPending, repoID, entry) };
}

/**
 * `ui` once the laptop took tap `seq`'s request for `repoID`: its pending value goes when `d`'s
 * layout agrees already, and otherwise waits as `taken` for the next `sessions.changed`. `ui`
 * itself when the pending value is another tap's, or gone.
 */
export function tapTaken(ui: UIState, d: SessionsData, repoID: string, seq: number): UIState {
  if (!isTap(ui, repoID, seq)) return ui;
  const entry = ui.remoteFilterPending[repoID]!;
  const agrees = layoutFilterOn(d.layout, repoID) === entry.value;
  const next: RemoteFilterPending | null = agrees ? null : { ...entry, stage: 'taken' };
  return { ...ui, remoteFilterPending: withEntry(ui.remoteFilterPending, repoID, next) };
}

/**
 * `ui` once `TAKEN_WAIT_MS` passed after the laptop took tap `seq`'s request for `repoID` and no
 * `sessions.changed` came: its pending value goes, and the chip shows the list's. `ui` itself when
 * the pending value is gone, another tap's, or not yet taken.
 */
export function tapExpired(ui: UIState, repoID: string, seq: number): UIState {
  if (!isTap(ui, repoID, seq) || ui.remoteFilterPending[repoID]!.stage !== 'taken') return ui;
  return { ...ui, remoteFilterPending: withEntry(ui.remoteFilterPending, repoID, null) };
}

/**
 * `ui` once tap `seq`'s request for `repoID` failed: its pending value goes, so the chip shows the
 * list's value again, and `text`, the laptop's reason, shows as a toast unless it is null. `ui`
 * itself when the pending value is another tap's, or gone: a newer tap stands, and its own reply
 * speaks for it.
 */
export function tapFailed(ui: UIState, repoID: string, seq: number, text: string | null): UIState {
  if (!isTap(ui, repoID, seq)) return ui;
  const settled: UIState = { ...ui, remoteFilterPending: withEntry(ui.remoteFilterPending, repoID, null) };
  return text === null ? settled : { ...settled, toast: nextToast(settled, text) };
}

/**
 * `ui` once a layout arrived, `layout`: each pending value goes that the laptop took already,
 * whose repo `layout` no longer lists, or that `layout` agrees with, unless it is `queued`. `ui`
 * itself when none goes.
 */
export function followLayout(ui: UIState, layout: readonly PhoneGroupLayout[]): UIState {
  return without(ui, (repoID, entry) => {
    const fromLayout = layoutFilterOn(layout, repoID);
    return entry.stage === 'taken' || fromLayout === null || (entry.stage === 'sent' && fromLayout === entry.value);
  });
}

/**
 * `ui` once a `sessions.changed` arrived, whatever it carries: each pending value the laptop took
 * goes. `ui` itself when none was taken.
 */
export function followSessionsChanged(ui: UIState): UIState {
  return without(ui, (_repoID, entry) => entry.stage === 'taken');
}
