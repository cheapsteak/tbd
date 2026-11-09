/**
 * The sheet slice of `AppState`: what the account and model menus and the sheets load from the
 * laptop or wait on (part 6d). Which sheet or menu shows stays in `ui.sheet` and `ui.menu`, and a
 * refused switch or model change goes to `ui.refusal`, as the composer's refusal does. The sheet
 * actions (`actions/sheets.ts`) write this slice, so their outcomes land in the store as every
 * action's do. Everything here is pure.
 *
 * - **Profiles** (`profiles`): the last `profiles.list`, loaded afresh each time the account menu,
 *   the Switch account sheet or the Fork sheet opens. A load that a later one replaced changes
 *   nothing when it ends (`id`).
 * - **Acting** (`acting`): each session whose switch, fork or model change from this phone is on
 *   its way, by `refKey`. `beginAct` marks it, and nothing else does, so one gesture sends one
 *   request; `endAct` clears it once the request settles, whatever the outcome. While a session
 *   is marked, none of the three goes out for it, and the menus and sheets disable their acting
 *   buttons.
 * - **A failure in a sheet** (`failed`): the words of the last action that failed while a sheet
 *   was open over its session, and that sheet, by identity. The sheet shows them while it is the
 *   one `ui.sheet` holds; any move to another sheet, or closing it, makes a new `ui.sheet`, so the
 *   words go with it. The next action clears them.
 *
 * Records are on a null prototype, so an ID such as `constructor` reads nothing inherited. Each
 * function returns a new object when it changes anything and `s` itself when it does not.
 *
 * Below the slice are the menus' and the sheets' shared rules: the model names, which profile is
 * the current one, the profiles in the Fork sheet's order, what stops an acting request (the one
 * check the buttons and the actions both make), and the words they show.
 */

import type { PhoneProfile, PhoneSession, PhoneSessionRef } from '../protocol/types.ts';
import { refKey } from '../protocol/wire.ts';
import { PROFILE_KIND_WORDS } from './status.ts';
import { emptyRecord } from './store.ts';
import type { SheetState } from './store.ts';

// MARK: - The slice

/**
 * Where `profiles.list` stands: never asked (`idle`), on its way (`loading`, with the load's
 * `id`), answered (`loaded`, the laptop's profiles in its order), or failed (`failed`, with the
 * words to show).
 */
export type ProfilesLoad =
  | { phase: 'idle' }
  | { phase: 'loading'; id: number }
  | { phase: 'loaded'; profiles: readonly PhoneProfile[] }
  | { phase: 'failed'; message: string };

/** Which of a session's acting requests is on its way. */
export type ActingKind = 'switch' | 'fork' | 'model';

export interface SheetsState {
  profiles: ProfilesLoad;
  /** The sessions whose switch, fork or model change is on its way, by `refKey`. */
  acting: Readonly<Record<string, ActingKind>>;
  /** The last action's failure, shown in `sheet` while `ui.sheet` is that very object; null for none. */
  failed: { sheet: SheetState; text: string } | null;
}

export function emptySheets(): SheetsState {
  return { profiles: { phase: 'idle' }, acting: emptyRecord(), failed: null };
}

/** Whether a switch, fork or model change for `ref`'s session is on its way. */
export function isActing(s: SheetsState, ref: PhoneSessionRef): boolean {
  return Object.hasOwn(s.acting, refKey(ref));
}

/**
 * `s` with `ref`'s session marked as acting (`kind`) and no failure showing, or `s` itself when
 * the session is marked already.
 */
export function beginAct(s: SheetsState, ref: PhoneSessionRef, kind: ActingKind): SheetsState {
  const k = refKey(ref);
  if (Object.hasOwn(s.acting, k)) return s;
  const acting = emptyRecord<ActingKind>();
  for (const key of Object.keys(s.acting)) acting[key] = s.acting[key]!;
  acting[k] = kind;
  return { ...s, acting, failed: null };
}

/** `s` with `ref`'s session no longer marked as acting, or `s` itself when it was not. */
export function endAct(s: SheetsState, ref: PhoneSessionRef): SheetsState {
  const k = refKey(ref);
  if (!Object.hasOwn(s.acting, k)) return s;
  const acting = emptyRecord<ActingKind>();
  for (const key of Object.keys(s.acting)) if (key !== k) acting[key] = s.acting[key]!;
  return { ...s, acting };
}

/** `s` with `text` showing in `sheet` (`failed`). */
export function failIn(s: SheetsState, sheet: SheetState, text: string): SheetsState {
  return { ...s, failed: { sheet, text } };
}

/** The failure to show in `sheet`, the sheet `ui.sheet` holds now, or null. */
export function failureIn(s: SheetsState, sheet: SheetState | null): string | null {
  return sheet !== null && s.failed !== null && s.failed.sheet === sheet ? s.failed.text : null;
}

/** `s` with a new `profiles.list` on its way, numbered `id`. */
export function profilesLoading(s: SheetsState, id: number): SheetsState {
  return { ...s, profiles: { phase: 'loading', id } };
}

/**
 * `s` with load `id` ended in `next`, or `s` itself when a later load replaced it: only the load
 * on its way, by its `id`, lands.
 */
export function profilesEnded(s: SheetsState, id: number, next: ProfilesLoad): SheetsState {
  return s.profiles.phase === 'loading' && s.profiles.id === id ? { ...s, profiles: next } : s;
}

/** The profiles the last load gave, or null while none is loaded. */
export function loadedProfiles(s: SheetsState): readonly PhoneProfile[] | null {
  return s.profiles.phase === 'loaded' ? s.profiles.profiles : null;
}

// MARK: - Rules the menus and the sheets share

/** The model names the model menu and the Model sheet offer, in order (spec section 8.3). */
export const MODEL_NAMES: readonly string[] = Object.freeze(['default', 'opus', 'sonnet', 'haiku']);

/** The profile with ID `id` in `profiles`, or null. */
export function profileByID(profiles: readonly PhoneProfile[], id: string): PhoneProfile | null {
  return profiles.find((p) => p.id === id) ?? null;
}

/**
 * The ID of `session`'s current profile: its `profileID`, or the default profile's when it has
 * none, as a session with no profile runs on the laptop's own login; null when `profiles` has no
 * default either.
 */
export function currentProfileID(session: PhoneSession, profiles: readonly PhoneProfile[]): string | null {
  return session.profileID ?? profiles.find((p) => p.isDefault)?.id ?? null;
}

/** `profiles` in the Fork sheet's order: the one with ID `currentID` first, the rest as the laptop sent them. */
export function forkOrder(profiles: readonly PhoneProfile[], currentID: string | null): readonly PhoneProfile[] {
  const current = profiles.filter((p) => p.id === currentID);
  return [...current, ...profiles.filter((p) => p.id !== currentID)];
}

/** What a profile's kind is called (`PROFILE_KIND_WORDS`), or the kind as the laptop sent it when it has no name. */
export function kindWords(kind: string): string {
  return Object.hasOwn(PROFILE_KIND_WORDS, kind) ? PROFILE_KIND_WORDS[kind]! : kind;
}

/** The line under a profile's name in the account menu and the Switch account sheet: its kind, and " · default" for the default. */
export function profileDetail(p: PhoneProfile): string {
  return `${kindWords(p.kind)}${p.isDefault ? ' · default' : ''}`;
}

/** The name the header shows for `session`'s account (`SessionHeader`). */
export function accountName(session: PhoneSession): string {
  return session.profileName ?? 'Default account';
}

/**
 * The name of the profile the Fork sheet's "Same account as now" row shows, which a fork with no
 * profile runs under: the current profile's (`currentProfileID`) when `profiles`, the list last
 * loaded, holds it, else the header's (`accountName`).
 */
export function sameAccountName(session: PhoneSession, profiles: readonly PhoneProfile[] | null): string {
  if (profiles === null) return accountName(session);
  const id = currentProfileID(session, profiles);
  const current = id === null ? null : profileByID(profiles, id);
  return current === null ? accountName(session) : current.name;
}

/** The session capability each acting request needs. */
const CAPABILITY = { switch: 'switchProfile', fork: 'fork', model: 'model' } as const;

/**
 * Why a `kind` request cannot go out for `session` by its capability: the laptop's reason, `''`
 * when it gave none, or null while the capability is available. The menus and the sheets disable
 * the acting button and show the reason beside it; the actions refuse with it.
 */
export function unavailableReason(session: PhoneSession, kind: ActingKind): string | null {
  const capability = session.capabilities[CAPABILITY[kind]];
  return capability.available ? null : (capability.reason ?? '');
}

/**
 * Why a switch of `session` to `profile`, picked from `profiles`, cannot go out: the capability's
 * reason (`unavailableReason`), or that the session runs under `profile` already; null when it
 * can.
 */
export function switchBlock(session: PhoneSession, profiles: readonly PhoneProfile[], profile: PhoneProfile): string | null {
  const reason = unavailableReason(session, 'switch');
  if (reason !== null) return reason;
  return profile.id === currentProfileID(session, profiles) ? `This session already runs under ${profile.name}.` : null;
}

/** The note under "Restart this session under X?": what a restart stops (mock `restartNote`). */
export function restartNote(session: PhoneSession): string {
  return `The conversation stays. ${session.status.chip === 'working' ? 'The turn that is running now stops.' : 'Claude restarts in this tab.'}`;
}
