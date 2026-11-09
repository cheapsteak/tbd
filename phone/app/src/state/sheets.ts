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
 * - **A failure in a sheet or a menu** (`failed`): the words of the last action that failed while a
 *   sheet or the account menu's ask was open over its session, or of a create that failed while
 *   its New sheet showed, and that sheet or menu, by identity (`on`). It shows them while it is the
 *   one `ui.sheet` or `ui.menu` holds; any move to another sheet or menu, or closing it, makes a
 *   new one, so the words go with it. The next action clears them.
 * - **Providers** (`providers`): the last `remote.providers`, for the New sheet's repo, loaded
 *   afresh each time the sheet shows its remote form. A load that a later one replaced changes
 *   nothing when it ends (`id`), and a list loaded for one repo never shows for another.
 * - **Creating** (`creating`): the create on its way from this phone, a worktree or a remote
 *   session, its repo, and the navigation mark its session opens by (`navMark`); null for none.
 *   `beginCreate` marks it, and nothing else does, so one gesture sends one create; `endCreate`
 *   clears it once the create settles, whatever the outcome. One create at a time, whatever the
 *   repo: while one is on its way none goes out.
 * - **Moving on** (`newSheetShown`): while a create is on its way, a New sheet that shows for
 *   another repo is the user moving on from it, as a navigation is. The create's mark becomes
 *   null, so its session opens nowhere and its success toasts nothing: its row just appears in the
 *   list. A New sheet that shows for the create's own repo while it is on its way takes it back,
 *   with the mark of that moment, as that sheet shows "Creating…" and says the session opens when
 *   it is ready.
 * - **Waiting to open** (`awaitingOpen`): the open a create handed to `openPending`, by identity,
 *   while it waits for the list to show the new session. Only a create that settled
 *   hands one over, so a New sheet that shows meanwhile, for any repo, its own included, is a new
 *   form and the user moving on: it drops that open (the action clears `ui.pendingOpen` when it is
 *   still that one), so the session's arrival never closes the sheet and the form in it.
 * - **A create's failure no sheet showed** (`lostCreates`): the words of each create that failed
 *   while no New sheet of its repo showed, by repo. The next New sheet that shows for that repo
 *   shows them (`newSheetShown` makes them its `failed`), so they are never lost unseen; a create
 *   that begins for that repo drops them.
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
import { isBlankMessage, own, trimLikeLaptop, withKey, withoutKey, withValue } from './prompts.ts';
import { PROFILE_KIND_WORDS } from './status.ts';
import { emptyRecord } from './store.ts';
import type { MenuState, PendingOpen, SheetState } from './store.ts';

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

/**
 * The create on its way as the slice holds it: what `CreateInFlight` says, and the navigation mark
 * (`navMark`) its session opens by, or null once the user moved on from it (`newSheetShown`).
 */
export interface CreateOnItsWay extends CreateInFlight {
  mark: number | null;
}

export interface SheetsState {
  profiles: ProfilesLoad;
  /** The sessions whose switch, fork or model change is on its way, by `refKey`. */
  acting: Readonly<Record<string, ActingKind>>;
  /** The last action's failure, shown in `on` while `ui.sheet` or `ui.menu` is that very object; null for none. */
  failed: { on: SheetState | MenuState; text: string } | null;
  providers: ProvidersLoad;
  /** The create on its way, or null. */
  creating: CreateOnItsWay | null;
  /** The last open a create that settled handed to `openPending`, by identity, or null. It may have opened since. */
  awaitingOpen: PendingOpen | null;
  /** The words of each create that failed while no New sheet of its repo showed, by repo. */
  lostCreates: Readonly<Record<string, string>>;
}

export function emptySheets(): SheetsState {
  return {
    profiles: { phase: 'idle' }, acting: emptyRecord(), failed: null, providers: { phase: 'idle' }, creating: null,
    awaitingOpen: null, lostCreates: emptyRecord(),
  };
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
  return Object.hasOwn(s.acting, k) ? s : { ...s, acting: withKey(s.acting, k, kind), failed: null };
}

/** `s` with `ref`'s session no longer marked as acting, or `s` itself when it was not. */
export function endAct(s: SheetsState, ref: PhoneSessionRef): SheetsState {
  const acting = withoutKey(s.acting, refKey(ref));
  return acting === s.acting ? s : { ...s, acting };
}

/** `s` with `text` showing in `on`, a sheet or a menu (`failed`). */
export function failIn(s: SheetsState, on: SheetState | MenuState, text: string): SheetsState {
  return { ...s, failed: { on, text } };
}

/** The failure to show in `on`, the sheet `ui.sheet` or the menu `ui.menu` holds now, or null. */
export function failureIn(s: SheetsState, on: SheetState | MenuState | null): string | null {
  return on !== null && s.failed !== null && s.failed.on === on ? s.failed.text : null;
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
 * `s` with `c` on its way, its session to open by `mark` (`navMark`), and no failure showing; the
 * words kept for `c`'s repo go too, as the user has started again there. `s` itself while another
 * create is on its way: this is the one check that keeps a second create from going out.
 */
export function beginCreate(s: SheetsState, c: CreateInFlight, mark: number): SheetsState {
  if (s.creating !== null) return s;
  return { ...s, creating: { repoID: c.repoID, mode: c.mode, mark }, failed: null, lostCreates: withoutKey(s.lostCreates, c.repoID) };
}

/** `s` with no create on its way, or `s` itself when none was. */
export function endCreate(s: SheetsState): SheetsState {
  return s.creating === null ? s : { ...s, creating: null };
}

/** `s` keeping `text`, the words of a create in `repoID` that no New sheet showed when it failed, for the next one that shows there. */
export function keepLostCreate(s: SheetsState, repoID: string, text: string): SheetsState {
  return { ...s, lostCreates: withValue(s.lostCreates, repoID, text) };
}

/** `s` with `open`, which a create that settled handed to `openPending`, waiting for the list. */
export function awaitOpen(s: SheetsState, open: PendingOpen): SheetsState {
  return { ...s, awaitingOpen: open };
}

/**
 * `s` once `sheet`, a New sheet, shows, at the navigation count `nav` (`UIState.nav`):
 * 1. The words kept for its repo (`keepLostCreate`) show in it (`failed`) and are kept no longer.
 * 2. The create on its way, when it is for another repo, is one the user moved on from: its mark
 *    becomes null. When it is for this repo, the user is back with it: its mark becomes `nav`.
 * 3. An open waiting for a create that settled (`awaitingOpen`) is dropped, whatever its repo: the
 *    sheet is a new form, not the create's. The caller clears `ui.pendingOpen` too while it is
 *    that open.
 *
 * `s` itself when `sheet` is no New sheet, or none of these changes anything.
 */
export function newSheetShown(s: SheetsState, sheet: SheetState, nav: number): SheetsState {
  if (sheet.name !== 'new') return s;
  const { repoID } = sheet;
  let next = s;
  const lost = own(s.lostCreates, repoID);
  if (lost !== undefined) next = { ...next, failed: { on: sheet, text: lost }, lostCreates: withoutKey(s.lostCreates, repoID) };
  const c = next.creating;
  if (c !== null) {
    const mark = c.repoID === repoID ? nav : null;
    if (c.mark !== mark) next = { ...next, creating: { ...c, mark } };
  }
  if (next.awaitingOpen !== null) next = { ...next, awaitingOpen: null };
  return next;
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
  return own(PROFILE_KIND_WORDS, kind) ?? kind;
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
 * (`strings`), the switches turned (`bools`), and whether the browser could read what was typed in
 * a number field as a number (`badInput`, the input's `validity.badInput`: it then gives its text
 * as `""`). A field with no change reads its prefill (`fieldText`, `fieldOn`). Records on a null
 * prototype, so a field named `__proto__` is a field.
 */
export interface FieldEdits {
  strings: Readonly<Record<string, string>>;
  bools: Readonly<Record<string, boolean>>;
  badInput: Readonly<Record<string, boolean>>;
}

/** A form nobody has changed. */
export const NO_EDITS: FieldEdits = Object.freeze({ strings: emptyRecord<string>(), bools: emptyRecord<boolean>(), badInput: emptyRecord<boolean>() });

/** What a number field says when its text is not a whole number (`fieldProblem`). */
export const WHOLE_NUMBER_TEXT = 'Whole numbers only.';

/** `edits` with `text` typed or picked in the field named `name`. */
export function withFieldText(edits: FieldEdits, name: string, text: string): FieldEdits {
  return { ...edits, strings: withValue(edits.strings, name, text) };
}

/** `edits` with the switch named `name` turned `on`. */
export function withFieldOn(edits: FieldEdits, name: string, on: boolean): FieldEdits {
  return { ...edits, bools: withValue(edits.bools, name, on) };
}

/** `edits` with what was typed in the number field named `name` readable as a number or not (`bad`). */
export function withFieldBadInput(edits: FieldEdits, name: string, bad: boolean): FieldEdits {
  const badInput = withValue(edits.badInput, name, bad);
  return badInput === edits.badInput ? edits : { ...edits, badInput };
}

/**
 * Whether `text` is a whole number as the laptop reads one (Swift's `Int(_:)`, 64 bits): ASCII
 * digits, with a plus or a minus sign or none, and nothing else. The laptop trims white space
 * first (`buildParamsJSON` in `RemoteCreateFormLogic.swift`), and so does every caller here
 * (`trimLikeLaptop`).
 */
export function isWholeNumber(text: string): boolean {
  if (!/^[+-]?[0-9]+$/.test(text)) return false;
  const n = BigInt(text);
  return n >= -(2n ** 63n) && n < 2n ** 63n;
}

/**
 * Why a field's text cannot go, which the New sheet shows under it and which holds Create: for an
 * `int` field, text the browser could not read as a number, or text that is not a whole number
 * (`WHOLE_NUMBER_TEXT`), since the laptop refuses either. Null for any other field, and for a
 * blank one.
 */
export function fieldProblem(f: PhoneFormField, edits: FieldEdits): string | null {
  if (f.type !== 'int') return null;
  const text = trimLikeLaptop(fieldText(f, edits));
  return own(edits.badInput, f.name) === true || (text !== '' && !isWholeNumber(text)) ? WHOLE_NUMBER_TEXT : null;
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
 * choice the form does not hold, and an `int` field's only when it is a whole number as the
 * laptop reads it (`isWholeNumber`), trimmed and with no plus sign, since a number input shows no
 * other text it is given. The laptop reads the number the same either way.
 */
export function fieldText(f: PhoneFormField, edits: FieldEdits): string {
  const typed = own(edits.strings, f.name);
  if (typed !== undefined) return typed;
  const prefill = f.prefill ?? '';
  if (f.type === 'enum') return (f.values ?? []).includes(prefill) ? prefill : '';
  if (f.type === 'int') {
    const whole = trimLikeLaptop(prefill);
    return isWholeNumber(whole) ? whole.replace(/^\+/, '') : '';
  }
  return prefill;
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
 * holds every field that is not a switch, its text trimmed as the laptop trims it, `""` for one
 * left blank; `bools` holds every switch. An `enum` field's choice goes exactly as the provider
 * listed it, untrimmed, since the laptop takes only a value that equals one of the field's
 * values as listed (`vettedFormStrings` in `PhoneAppService+Create.swift`), and a select offers
 * nothing else. A blank field goes as `""` and is not left out, because
 * the laptop lays the phone's values over its own prefill: a field left out would keep its
 * prefill, so a user who cleared it would get it all the same. The laptop leaves a blank field out
 * of the session's params when it is optional, and refuses it when it is required. `message` goes
 * as typed when the provider takes a first message, and as `""` when it does not, since the laptop
 * refuses one there.
 */
export function remoteCreateParams(repoID: string, provider: PhoneProvider, message: string, edits: FieldEdits): PhoneRemoteCreateParams {
  const strings = emptyRecord<string>();
  const bools = emptyRecord<boolean>();
  for (const f of provider.fields) {
    if (isBoolField(f)) {
      bools[f.name] = fieldOn(f, edits);
      continue;
    }
    const text = fieldText(f, edits);
    strings[f.name] = f.type === 'enum' ? text : trimLikeLaptop(text);
  }
  return { provider: provider.name, repoID, message: provider.acceptsPrompt ? message : '', strings, bools };
}

/**
 * Whether Create may send `params` to `provider`: it is available and is the one `params` names;
 * the message is not blank (`isBlankMessage`) when it takes one, and is `""` when it does not;
 * every required field that is not a switch has a value; every switch is set; an `int` field holds
 * a whole number or is blank; and nothing names a field the form does not hold, a switch as text,
 * or a choice an `enum` field does not offer, compared exactly with its values as listed, as the
 * laptop compares them (`vettedFormStrings`). The New sheet enables Create by it, and by
 * `fieldProblem` for what the params cannot show, and `createRemote` checks it again at the tap.
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
    if (f.type === 'int' && !isWholeNumber(trimLikeLaptop(value))) return false;
  }
  return true;
}
