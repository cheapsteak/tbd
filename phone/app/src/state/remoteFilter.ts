/**
 * A tap on a repo header's filter chip, from the tap to the laptop's answer (spec
 * `docs/specs/2026-11-22-phone-remote-session-filter-design.md`, "A tap"). The chip flips at once:
 * the phone holds its own value for the repo (`UIState.remoteFilterPending`), which wins over the
 * layout's in `sessionsView`, until the laptop's list settles it. Everything here is pure; the
 * request is `toggleRemoteFilter`'s (`actions/shell.ts`).
 *
 * A pending value goes:
 * - when a layout arrives whose value for the repo agrees with it, before the reply or after;
 * - at the first layout after the laptop took the request, whatever that layout says, so a change
 *   another client made since, on the laptop or on another phone, shows and never leaves the chip
 *   stuck on the phone's own value; or at the reply itself, when the list's layout agrees already;
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

/** The phone's own filter value for one repo, while its tap waits on the laptop. */
export interface RemoteFilterPending {
  /** The value the chip shows. */
  value: boolean;
  /** The tap's number. Only the reply to this tap settles it. */
  seq: number;
  /** True once the laptop took the request: the next layout settles it, whatever it says. */
  confirmed: boolean;
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

/** Whether `repoID`'s pending entry in `ui` is tap `seq`'s. */
function isTap(ui: UIState, repoID: string, seq: number): boolean {
  return Object.hasOwn(ui.remoteFilterPending, repoID) && ui.remoteFilterPending[repoID]!.seq === seq;
}

/** `ui` once tap `seq` set repo `repoID`'s filter to `value`, on its way to the laptop. */
export function withTap(ui: UIState, repoID: string, value: boolean, seq: number): UIState {
  return { ...ui, remoteFilterPending: withEntry(ui.remoteFilterPending, repoID, { value, seq, confirmed: false }) };
}

/**
 * `ui` once the laptop took tap `seq`'s request for `repoID`: its pending value goes when `d`'s
 * layout agrees already, and otherwise waits for the next layout. `ui` itself when the pending
 * value is another tap's, or gone.
 */
export function tapTaken(ui: UIState, d: SessionsData, repoID: string, seq: number): UIState {
  if (!isTap(ui, repoID, seq)) return ui;
  const entry = ui.remoteFilterPending[repoID]!;
  const next = layoutFilterOn(d.layout, repoID) === entry.value ? null : { ...entry, confirmed: true };
  return { ...ui, remoteFilterPending: withEntry(ui.remoteFilterPending, repoID, next) };
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
 * `ui` once a layout arrived, `layout`: each pending value goes that `layout` agrees with, that the
 * laptop took already, or whose repo `layout` no longer lists. `ui` itself when none goes.
 */
export function followLayout(ui: UIState, layout: readonly PhoneGroupLayout[]): UIState {
  let pending = ui.remoteFilterPending;
  for (const repoID of Object.keys(ui.remoteFilterPending)) {
    const entry = ui.remoteFilterPending[repoID]!;
    const fromLayout = layoutFilterOn(layout, repoID);
    if (entry.confirmed || fromLayout === null || fromLayout === entry.value) pending = withEntry(pending, repoID, null);
  }
  return pending === ui.remoteFilterPending ? ui : { ...ui, remoteFilterPending: pending };
}
