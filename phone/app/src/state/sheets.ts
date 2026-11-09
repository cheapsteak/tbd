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
 *   was open over its session, or of a create that failed while its New sheet showed, and that
 *   sheet, by identity. The sheet shows them while it is the one `ui.sheet` holds; any move to
 *   another sheet, or closing it, makes a new `ui.sheet`, so the words go with it. The next action
 *   clears them.
 * - **Providers** (`providers`): the last `remote.providers`, for the New sheet's repo, loaded
 *   afresh each time the sheet shows its remote form. A load that a later one replaced changes
 *   nothing when it ends (`id`), and a list loaded for one repo never shows for another.
 * - **Creating** (`creating`): the create on its way from this phone, a worktree or a remote
 *   session, and its repo; null for none. `beginCreate` marks it, and nothing else does, so one
 *   gesture sends one create; `endCreate` clears it once the create settles, whatever the
 *   outcome. One create at a time, whatever the repo: while one is on its way none goes out.
 * - **A create's failure no sheet showed** (`lostCreate`): the words of a create that failed after
 *   the user closed its New sheet, and its repo. The next New sheet that opens for that repo
 *   shows them (`claimLostCreate` makes them its `failed`), so they are never lost unseen; a
 *   create that begins for that repo drops them.
 *
 * Records are on a null prototype, so an ID such as `constructor` reads nothing inherited. Each
 * function returns a new object when it changes anything and `s` itself when it does not.
 *
 * Below the slice are the menus' and the sheets' shared rules: the model names, which profile is
 * the current one, the profiles in the Fork sheet's order, what stops an acting request (the one
 * check the buttons and the actions both make), and the words they show. Then the New sheet's:
 * a provider's form, the `remote.create` params it makes, and when Create may send.
 */

import type {
  PhoneFormField, PhoneProfile, PhoneProvider, PhoneRemoteCreateParams, PhoneSession, PhoneSessionRef,
} from '../protocol/types.ts';
import { refKey } from '../protocol/wire.ts';
import { isBlankMessage, trimLikeLaptop } from './prompts.ts';
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

/**
 * Where `remote.providers` stands for the New sheet: never asked (`idle`), on its way for `repoID`
 * (`loading`, with the load's `id`), answered (`loaded`, the laptop's providers in its order, their
 * forms prefilled for `repoID`), or failed (`failed`, with the words to show).
 */
export type ProvidersLoad =
  | { phase: 'idle' }
  | { phase: 'loading'; id: number; repoID: string }
  | { phase: 'loaded'; repoID: string; providers: readonly PhoneProvider[] }
  | { phase: 'failed'; repoID: string; message: string };

/** Which of a session's acting requests is on its way. */
export type ActingKind = 'switch' | 'fork' | 'model';

/** What the New sheet creates: a local worktree, or a remote session. */
export type CreateMode = 'local' | 'remote';

/** A create on its way: the repo it was made in, from the New sheet's `repoID`, and what it creates. */
export interface CreateInFlight {
  repoID: string;
  mode: CreateMode;
}

export interface SheetsState {
  profiles: ProfilesLoad;
  /** The sessions whose switch, fork or model change is on its way, by `refKey`. */
  acting: Readonly<Record<string, ActingKind>>;
  /** The last action's failure, shown in `sheet` while `ui.sheet` is that very object; null for none. */
  failed: { sheet: SheetState; text: string } | null;
  providers: ProvidersLoad;
  /** The create on its way, or null. */
  creating: CreateInFlight | null;
  /** The words of a create that failed while no New sheet showed it, for the next one of its repo; or null. */
  lostCreate: { repoID: string; text: string } | null;
}

export function emptySheets(): SheetsState {
  return { profiles: { phase: 'idle' }, acting: emptyRecord(), failed: null, providers: { phase: 'idle' }, creating: null, lostCreate: null };
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

/** `s` with a new `remote.providers` for `repoID` on its way, numbered `id`. */
export function providersLoading(s: SheetsState, id: number, repoID: string): SheetsState {
  return { ...s, providers: { phase: 'loading', id, repoID } };
}

/** `s` with providers load `id` ended in `next`, or `s` itself when a later load replaced it. */
export function providersEnded(s: SheetsState, id: number, next: ProvidersLoad): SheetsState {
  return s.providers.phase === 'loading' && s.providers.id === id ? { ...s, providers: next } : s;
}

/** The providers the last load gave for `repoID`, or null while none is loaded for it. */
export function loadedProviders(s: SheetsState, repoID: string): readonly PhoneProvider[] | null {
  return s.providers.phase === 'loaded' && s.providers.repoID === repoID ? s.providers.providers : null;
}

/**
 * `s` with `c` on its way and no failure showing; a failure kept for `c`'s repo goes too, as the
 * user has started again there. `s` itself while another create is on its way.
 */
export function beginCreate(s: SheetsState, c: CreateInFlight): SheetsState {
  if (s.creating !== null) return s;
  const lostCreate = s.lostCreate !== null && s.lostCreate.repoID === c.repoID ? null : s.lostCreate;
  return { ...s, creating: c, failed: null, lostCreate };
}

/** `s` with no create on its way, or `s` itself when none was. */
export function endCreate(s: SheetsState): SheetsState {
  return s.creating === null ? s : { ...s, creating: null };
}

/** `s` keeping `text`, the words of a create in `repoID` that no New sheet showed when it failed, for the next one that opens there. */
export function keepLostCreate(s: SheetsState, repoID: string, text: string): SheetsState {
  return { ...s, lostCreate: { repoID, text } };
}

/**
 * `s` with the words of a create kept for `sheet`'s repo (`keepLostCreate`) showing in `sheet`
 * (`failIn`), and kept no longer; `s` itself when `sheet` is no New sheet or none are kept for
 * its repo.
 */
export function claimLostCreate(s: SheetsState, sheet: SheetState): SheetsState {
  const lost = s.lostCreate;
  if (lost === null || sheet.name !== 'new' || sheet.repoID !== lost.repoID) return s;
  return { ...s, failed: { sheet, text: lost.text }, lostCreate: null };
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

// MARK: - The New sheet's rules

/**
 * What the user changed in a provider's form, by field name: the text typed or the choice picked
 * (`strings`), and the switches turned (`bools`). A field with no change reads its prefill
 * (`fieldText`, `fieldOn`). Records on a null prototype, so a field named `__proto__` is a field.
 */
export interface FieldEdits {
  strings: Readonly<Record<string, string>>;
  bools: Readonly<Record<string, boolean>>;
}

/** A form nobody has changed. */
export const NO_EDITS: FieldEdits = Object.freeze({ strings: emptyRecord<string>(), bools: emptyRecord<boolean>() });

/** `edits` with `text` typed or picked in the field named `name`. */
export function withFieldText(edits: FieldEdits, name: string, text: string): FieldEdits {
  return { ...edits, strings: withValue(edits.strings, name, text) };
}

/** `edits` with the switch named `name` turned `on`. */
export function withFieldOn(edits: FieldEdits, name: string, on: boolean): FieldEdits {
  return { ...edits, bools: withValue(edits.bools, name, on) };
}

/** Whether `f` is an on/off switch, the one type whose value goes in `bools`. */
export function isBoolField(f: PhoneFormField): boolean {
  return f.type === 'bool';
}

/** A field's label: the provider's, or the field's name when it gave none, as the laptop's create sheet shows it. */
export function fieldLabel(f: PhoneFormField): string {
  return f.label ?? f.name;
}

/**
 * The text a field that is not a switch shows: what the user typed or picked, else its prefill.
 * An `enum` field's prefill counts only when it is one of its values, so its select never shows a
 * choice the form does not hold.
 */
export function fieldText(f: PhoneFormField, edits: FieldEdits): string {
  const typed = own(edits.strings, f.name);
  if (typed !== undefined) return typed;
  const prefill = f.prefill ?? '';
  return f.type === 'enum' && !(f.values ?? []).includes(prefill) ? '' : prefill;
}

/** Whether a switch is on: as the user turned it, else on when its prefill is `"true"`. */
export function fieldOn(f: PhoneFormField, edits: FieldEdits): boolean {
  return own(edits.bools, f.name) ?? f.prefill === 'true';
}

/**
 * The choices an `enum` field's select offers: a blank one (`''`) first, then its values. The
 * blank one is left out of a required field whose prefill is one of its values, as the laptop's
 * picker offers it only on a field that is not required; a required field with no such prefill
 * keeps it, so the select shows that nothing is picked yet rather than a value the form does not
 * hold.
 */
export function enumChoices(f: PhoneFormField): readonly string[] {
  const values = f.values ?? [];
  return f.required && values.includes(f.prefill ?? '') ? values : ['', ...values];
}

/**
 * The line under a provider in the New sheet: for an unavailable one, the laptop's reason, or null
 * when it gave none; "Needs nothing else" when its form adds no field; else how many it adds.
 */
export function providerDetail(p: PhoneProvider): string | null {
  if (!p.available) return p.reason === undefined || p.reason === '' ? null : p.reason;
  const n = p.fields.length;
  if (n === 0) return 'Needs nothing else';
  return n === 1 ? '1 more field' : `${n} more fields`;
}

/**
 * The `remote.create` params for `provider` in `repoID`, from the form as it shows: `strings`
 * holds every field that is not a switch, its text trimmed as the laptop trims it, and leaves out
 * one left empty; `bools` holds every switch. `message` goes as typed when the provider takes a
 * first message, and as `""` when it does not, since the laptop refuses one there.
 */
export function remoteCreateParams(repoID: string, provider: PhoneProvider, message: string, edits: FieldEdits): PhoneRemoteCreateParams {
  const strings = emptyRecord<string>();
  const bools = emptyRecord<boolean>();
  for (const f of provider.fields) {
    if (isBoolField(f)) {
      bools[f.name] = fieldOn(f, edits);
      continue;
    }
    const text = trimLikeLaptop(fieldText(f, edits));
    if (text !== '') strings[f.name] = text;
  }
  return { provider: provider.name, repoID, message: provider.acceptsPrompt ? message : '', strings, bools };
}

/**
 * Whether Create may send `params` to `provider`: it is available and is the one `params` names;
 * the message is not blank (`isBlankMessage`) when it takes one, and is `""` when it does not;
 * every required field that is not a switch has a value; every switch is set; and nothing names a
 * field the form does not hold, a switch as text, or a choice an `enum` field does not offer. The
 * New sheet enables Create by it, and `createRemote` checks it again at the tap.
 */
export function remoteParamsReady(params: PhoneRemoteCreateParams, provider: PhoneProvider): boolean {
  if (!provider.available || params.provider !== provider.name) return false;
  if (provider.acceptsPrompt ? isBlankMessage(params.message) : params.message !== '') return false;
  const fields = new Map(provider.fields.map((f) => [f.name, f]));
  for (const name of Object.keys(params.strings)) {
    const f = fields.get(name);
    if (f === undefined || isBoolField(f)) return false;
  }
  for (const name of Object.keys(params.bools)) {
    const f = fields.get(name);
    if (f === undefined || !isBoolField(f)) return false;
  }
  for (const f of provider.fields) {
    if (isBoolField(f)) {
      if (typeof own(params.bools, f.name) !== 'boolean') return false;
      continue;
    }
    const value = own(params.strings, f.name);
    if (value === undefined || trimLikeLaptop(value) === '') {
      if (f.required) return false;
      continue;
    }
    if (f.type === 'enum' && !(f.values ?? []).includes(value)) return false;
  }
  return true;
}

/** `r[key]` when it is `r`'s own, or undefined: never an inherited member such as `constructor`. */
function own<V>(r: Readonly<Record<string, V>>, key: string): V | undefined {
  return Object.hasOwn(r, key) ? r[key] : undefined;
}

/** A copy of `r` on a null prototype with `key` set to `value`, or `r` itself when it holds that already. */
function withValue<V>(r: Readonly<Record<string, V>>, key: string, value: V): Readonly<Record<string, V>> {
  if (own(r, key) === value) return r;
  const next = emptyRecord<V>();
  for (const k of Object.keys(r)) next[k] = r[k]!;
  next[key] = value;
  return next;
}
