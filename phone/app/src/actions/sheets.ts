// The sheet and menu actions: profiles, switching account, forking, the model, and New. What they
// load and what they wait on go in the sheet slice (`state/sheets.ts`).
//
// Contract:
// - `loadProfiles(): Promise<void>` – `profiles.list`, for the account menu and the Switch account
//   and Fork sheets, which each load afresh when they open. The slice shows it `loading` at once,
//   then `loaded` with the laptop's profiles, or `failed` with the error's message. A load that a
//   later one replaced changes nothing when it ends. The client never supersedes a read (it is
//   resent after a drop), so `superseded`, were it to come, changes nothing.
// - `switchProfile(profileID, from): Promise<void>` – `session.switchProfile` on the session the
//   route shows, with `profileID`. On success it closes the menu or sheet the gesture was made on,
//   if it still shows, and toasts "Restarted under <profile>".
// - `fork(profileID, from): Promise<void>` – `session.fork` on the session the route shows, under
//   `profileID`, or with no `profileID` at all when it is null, which the laptop reads as the
//   session's own profile. It takes a mark (`navMark`) as it sends; on success it closes the menu
//   or sheet the gesture was made on, if it still shows, toasts "Forked into a new tab, under
//   <profile>" (for null, the name the Fork sheet's "Same account as now" row showed,
//   `sameAccountName`), and opens the new tab once the list shows it (`openPending({ ref },
//   mark)`), unless the user has navigated since the mark.
// - `setModel(model, from): Promise<void>` – `session.setModel` on the session the route shows,
//   with `model` trimmed of the white space around it (the laptop's own trim, `trimLikeLaptop`).
//   On success it closes the menu or sheet the gesture was made on, if it still shows, and toasts
//   "Model set to <model>". The session's status plays no part: the laptop takes a model change
//   while a session works and answers for itself.
// - `loadProviders(repoID): Promise<void>` – `remote.providers` with `repoID`, so the laptop
//   prefills each provider's form for that repo, for the New sheet's remote form, which loads
//   afresh each time it shows. The slice shows it `loading` at once, then `loaded` with the
//   laptop's providers, or `failed` with the error's message, as `loadProfiles` does, and a load
//   that a later one replaced changes nothing when it ends.
// - `createWorktree(repoID, message): Promise<void>` – `worktree.create` in `repoID` with
//   `message` as the new session's first message, sent as typed. It takes a mark (`navMark`) as it
//   sends; on success it closes the New sheet of that repo, if one still shows, and opens the new
//   worktree's first session once the list shows it, toasting "Created <row name>" then
//   (`openPending({ worktreeID, toast: 'Created {name}' }, mark)`), unless the user has
//   navigated since the mark.
// - `createRemote(params): Promise<void>` – `remote.create` with `params`, as the New sheet built
//   them (`remoteCreateParams`). It takes a mark as it sends; on success it closes the New sheet
//   of that repo, if one still shows, toasts "Remote session started on <provider>", and opens
//   the new session once the list shows it (`openPending({ ref }, mark)`), unless the user has
//   navigated since the mark.
// - `claimLostCreate(sheet): void` – shows in `sheet`, a New sheet that has just opened, the
//   words of a create in its repo that failed while no New sheet showed them (below).
//
// **The repo.** A create goes only to the repo of the New sheet `ui.sheet` shows at the moment
// of the gesture, read from the store in one read: `repoID` must be that sheet's, the repo whose
// "+" the user tapped, as the daemon wrote it. `createWorktree` also needs a message that is not
// blank by the laptop's rule (`isBlankMessage`), and `createRemote` needs params the New sheet
// would enable Create for (`remoteParamsReady`) with the provider as the last providers load for
// that repo gave it. Either sends nothing and says nothing otherwise: the sheet that asked is
// gone, or never offered what was asked.
//
// **One create at a time**, whatever the repo: the action marks it (`beginCreate`) in the same
// store update that reads the target, before anything is sent, and does nothing while a create
// is on its way. The mark goes when the create settles, on every path. The New sheet shows
// "Creating…" meanwhile; a New sheet that opens for the same repo shows it too, and one for
// another repo shows its form with Create disabled.
//
// **A create's error** shows as it comes, `not_confirmed` included (the worktree or the session
// may exist all the same); `superseded` is silent. It shows in the New sheet of the create's repo
// that shows when it settles, which shows its form again, its values kept while it stayed open.
// When none shows, because the user closed it while the create was on its way, nothing toasts:
// the words are kept for the next New sheet that opens for that repo (`lostCreate`), which shows
// them. A closed sheet does not stop a create that succeeds from opening its session; only a
// navigation does, by the mark.
//
// **The target.** `from` is the session the menu or sheet showed when the user tapped. Each of
// the three acts only on the session the route shows at the moment of the gesture, read from the
// store in one read, and only when that is `from` and the list shows it (`findSession`). So a
// menu or sheet still on screen for a moment after an event moved the route acts on nothing,
// never on the session the route moved to. `switchProfile` and a `fork` with a profile also need
// that profile in the profiles last loaded, the list the user picked from. `setModel` needs a name
// that is not blank once trimmed. Each of these sends nothing and says nothing: the menu or sheet
// that asked is gone, or never offered what was asked.
//
// **Refused at the tap.** The menus and the sheets disable an acting button while its request
// cannot go out, and show why beside it, by the same rules the actions check (`state/sheets.ts`):
// the session's capability (`switchProfile`, `fork`, `model`, `unavailableReason`), and for a
// switch, that the session runs under that profile already (`switchBlock`). A gesture that meets
// one of these all the same, as when an event changed the session as the user tapped, sends
// nothing and shows the reason in the session's `ui.refusal`, and in the sheet it was made on
// while that shows (as an error does, below), unless the laptop gave none.
//
// **One request per gesture.** A session gets one of the three at a time: the action marks it
// acting (`beginAct`) in the same store update that reads the target, before anything is sent,
// and does nothing while the mark stands. The mark goes when the request settles, on every path.
//
// **Errors** show their message as they come, `not_confirmed` included; `superseded` is silent.
// They show in the sheet the gesture was made on (`failed` in the slice) while that sheet still
// shows over the session: the same sheet, and for `switch-confirm` the same profile. A refused
// switch or model change also goes to the session's `ui.refusal`, which the composer shows once
// the sheet is gone. A fork's error goes to `ui.refusal` only when no sheet shows it: made from
// the account menu, or the user moved to another sheet or closed it meanwhile. So an error never
// lands in a sheet that did not ask, and never goes unshown. An error closes nothing: a menu or
// sheet closes only on success.
//
// **Never retry one of these automatically under a new request ID.** Each but the loads acts,
// and one that failed with `not_confirmed`, `bad_reply`, `internal` or `too_large` may have
// happened all the same (`ACTING_METHODS` in `client/client.ts`): a retry under a new ID could
// restart a session twice, make a second fork, or a second worktree or remote session. Show
// the error, and leave the choice to the user. Like every action, none rejects (`actions/index.ts`).

import { AppError, BAD_PARAMS_TEXT } from '../client/client.ts';
import type { PhoneRemoteCreateParams, PhoneSession, PhoneSessionRef, SessionForkParams } from '../protocol/types.ts';
import { refKey, sameRef } from '../protocol/wire.ts';
import { isBlankMessage, trimLikeLaptop, withText } from '../state/prompts.ts';
import { findSession } from '../state/route.ts';
import {
  beginAct, beginCreate, claimLostCreate, endAct, endCreate, failIn, isActing, keepLostCreate, loadedProfiles, loadedProviders,
  profileByID, profilesEnded, profilesLoading, providersEnded, providersLoading, remoteParamsReady, sameAccountName, switchBlock,
  unavailableReason,
} from '../state/sheets.ts';
import type { ActingKind, CreateInFlight, ProfilesLoad, ProvidersLoad } from '../state/sheets.ts';
import { nextToast } from '../state/store.ts';
import type { AppState, MenuState, SheetState, UIState } from '../state/store.ts';
import type { ActionContext, Actions } from './index.ts';

/**
 * Where an acting request goes: the session, its `refKey`, the session as the list showed it, and
 * the sheet or the menu the gesture was made on (at most one shows at a time).
 */
interface ActTarget {
  ref: PhoneSessionRef;
  key: string;
  session: PhoneSession;
  sheet: SheetState | null;
  menu: MenuState | null;
}

/**
 * Where a request goes, read from `s` at the moment of the gesture: the session the route shows,
 * when it is `from`, the list shows it, and nothing else is on its way for it; or null when
 * nothing must go out.
 */
function actTarget(s: AppState, from: PhoneSessionRef | undefined): ActTarget | null {
  const { route } = s.ui;
  if (from === undefined || route.screen !== 'session' || !sameRef(route.ref, from)) return null;
  const found = findSession(s.sessions, route.ref);
  if (found === null) return null;
  const { ref } = found.session;
  if (isActing(s.sheets, ref)) return null;
  return { ref, key: refKey(ref), session: found.session, sheet: s.ui.sheet, menu: s.ui.menu };
}

/** `s` with `to`'s session marked acting as `kind`. */
function begun(s: AppState, to: ActTarget, kind: ActingKind): AppState {
  return { ...s, sheets: beginAct(s.sheets, to.ref, kind) };
}

/** How an acting request ended: taken, with the toast to show, or failed, with the words to show (null for none). */
type Settled = { taken: true; toast: string } | { taken: false; text: string | null };

/** The words for a failed request: the error's message, none for `superseded`, the client's words for a fault in its own setup. */
function errorText(error: unknown): string | null {
  if (!(error instanceof AppError)) return BAD_PARAMS_TEXT;
  return error.code === 'superseded' ? null : error.message;
}

/**
 * The sheet `ui` holds when it is still the one `to`'s gesture was made on, over `to`'s session:
 * the same sheet, and for `switch-confirm` the same profile; else null.
 */
function gestureSheet(ui: UIState, to: ActTarget): SheetState | null {
  const { route, sheet } = ui;
  const made = to.sheet;
  if (sheet === null || made === null || route.screen !== 'session' || !sameRef(route.ref, to.ref)) return null;
  if (sheet.name !== made.name) return null;
  if (sheet.name === 'switch-confirm' && made.name === 'switch-confirm' && sheet.profileID !== made.profileID) return null;
  return sheet;
}

/**
 * `s` with `text`, the words of `to`'s refused or failed request, where they show: in the sheet the
 * gesture was made on while it still shows (`gestureSheet`), and in the session's `ui.refusal`
 * when `composerToo` is set or no sheet shows them.
 */
function withWords(s: AppState, to: ActTarget, text: string, composerToo: boolean): AppState {
  const sheet = gestureSheet(s.ui, to);
  const sheets = sheet === null ? s.sheets : failIn(s.sheets, sheet, text);
  let ui = s.ui;
  if (composerToo || sheet === null) {
    const refusal = withText(ui.refusal, to.key, text);
    if (refusal !== ui.refusal) ui = { ...ui, refusal };
  }
  if (sheets === s.sheets && ui === s.ui) return s;
  return { ...s, sheets, ui };
}

/**
 * `s` once a gesture for `to` was refused at the tap with `reason`: the reason in the session's
 * `ui.refusal`, and in the sheet the gesture was made on while it shows (`withWords`); nothing
 * when the laptop gave no reason.
 */
function refused(s: AppState, to: ActTarget, reason: string): AppState {
  return reason === '' ? s : withWords(s, to, reason, true);
}

/**
 * `s` once `to`'s `kind` request settled as `how`: the mark gone, and then, when taken, the menu
 * or sheet the gesture was made on closed, if it still shows, and the toast; when failed, the
 * words shown (`withWords`), in the composer too for a switch or a model change.
 */
function settle(s: AppState, to: ActTarget, kind: ActingKind, how: Settled): AppState {
  const sheets = endAct(s.sheets, to.ref);
  let next: AppState = sheets === s.sheets ? s : { ...s, sheets };
  if (how.taken) {
    let ui = next.ui;
    if (to.sheet !== null && ui.sheet === to.sheet) ui = { ...ui, sheet: null };
    if (to.menu !== null && ui.menu === to.menu) ui = { ...ui, menu: null };
    next = { ...next, ui: { ...ui, toast: nextToast(ui, how.toast) } };
  } else if (how.text !== null) {
    next = withWords(next, to, how.text, kind !== 'fork');
  }
  return next;
}

/** The New sheet `ui` shows, when it is one for `repoID`; else null. */
function newSheetFor(ui: UIState, repoID: string): SheetState | null {
  const { sheet } = ui;
  return sheet !== null && sheet.name === 'new' && sheet.repoID === repoID ? sheet : null;
}

/**
 * `s` with `c` on its way (`beginCreate`) when a create may go out for `repoID` now: a New sheet
 * for it shows, `ready` holds, and no create is on its way; else `s` itself.
 */
function startedCreate(s: AppState, c: CreateInFlight, ready: boolean): AppState {
  if (!ready || s.sheets.creating !== null || newSheetFor(s.ui, c.repoID) === null) return s;
  return { ...s, sheets: beginCreate(s.sheets, c) };
}

/**
 * `s` once create `c` settled as `how`: the mark gone, and then, when taken, the New sheet of its
 * repo closed, if one shows, and the toast, if any; when failed, the words in that sheet, or kept
 * for the next one of its repo when none shows (`keepLostCreate`). Nothing for `superseded`.
 */
function settleCreate(s: AppState, c: CreateInFlight, how: { taken: true; toast: string | null } | { taken: false; text: string | null }): AppState {
  let sheets = endCreate(s.sheets);
  let ui = s.ui;
  const sheet = newSheetFor(ui, c.repoID);
  if (how.taken) {
    if (sheet !== null) ui = { ...ui, sheet: null };
    if (how.toast !== null) ui = { ...ui, toast: nextToast(ui, how.toast) };
  } else if (how.text !== null) {
    sheets = sheet !== null ? failIn(sheets, sheet, how.text) : keepLostCreate(sheets, c.repoID, how.text);
  }
  if (sheets === s.sheets && ui === s.ui) return s;
  return { ...s, sheets, ui };
}

export function sheetActions(ctx: ActionContext, self: () => Actions) {
  const { store, client } = ctx;
  /** The number of the last `profiles.list` sent, so only the newest lands. */
  let loads = 0;
  /** The number of the last `remote.providers` sent, so only the newest lands. */
  let providerLoads = 0;

  return {
    async loadProfiles(): Promise<void> {
      const id = ++loads;
      store.update((s) => ({ ...s, sheets: profilesLoading(s.sheets, id) }));
      let next: ProfilesLoad;
      try {
        const result = await client.request('profiles.list', {});
        next = { phase: 'loaded', profiles: result.profiles };
      } catch (error) {
        const text = errorText(error);
        if (text === null) return;
        next = { phase: 'failed', message: text };
      }
      store.update((s) => {
        const sheets = profilesEnded(s.sheets, id, next);
        return sheets === s.sheets ? s : { ...s, sheets };
      });
    },

    async switchProfile(profileID: string, from: PhoneSessionRef): Promise<void> {
      const sent: { to: ActTarget | null; name: string } = { to: null, name: '' };
      store.update((s) => {
        const to = actTarget(s, from);
        const profiles = loadedProfiles(s.sheets);
        if (to === null || profiles === null) return s;
        const profile = profileByID(profiles, profileID);
        if (profile === null) return s;
        const block = switchBlock(to.session, profiles, profile);
        if (block !== null) return refused(s, to, block);
        sent.to = to;
        sent.name = profile.name;
        return begun(s, to, 'switch');
      });
      const to = sent.to;
      if (to === null) return;
      let how: Settled;
      try {
        await client.request('session.switchProfile', { session: to.ref, profileID });
        how = { taken: true, toast: `Restarted under ${sent.name}` };
      } catch (error) {
        how = { taken: false, text: errorText(error) };
      }
      store.update((s) => settle(s, to, 'switch', how));
    },

    async fork(profileID: string | null, from: PhoneSessionRef): Promise<void> {
      const sent: { to: ActTarget | null; name: string } = { to: null, name: '' };
      store.update((s) => {
        const to = actTarget(s, from);
        if (to === null) return s;
        const profiles = loadedProfiles(s.sheets);
        let name: string;
        if (profileID === null) {
          name = sameAccountName(to.session, profiles);
        } else {
          const profile = profiles === null ? null : profileByID(profiles, profileID);
          if (profile === null) return s;
          name = profile.name;
        }
        const block = unavailableReason(to.session, 'fork');
        if (block !== null) return refused(s, to, block);
        sent.to = to;
        sent.name = name;
        return begun(s, to, 'fork');
      });
      const to = sent.to;
      if (to === null) return;
      // Taken as the request goes out: a navigation from here on means the user chose where to go.
      const mark = self().navMark();
      const params: SessionForkParams = profileID === null ? { session: to.ref } : { session: to.ref, profileID };
      let how: Settled;
      let made: PhoneSessionRef | null = null;
      try {
        const result = await client.request('session.fork', params);
        made = result.session;
        how = { taken: true, toast: `Forked into a new tab, under ${sent.name}` };
      } catch (error) {
        how = { taken: false, text: errorText(error) };
      }
      store.update((s) => settle(s, to, 'fork', how));
      if (made !== null) self().openPending({ ref: made }, mark);
    },

    async setModel(model: string, from: PhoneSessionRef): Promise<void> {
      const name = trimLikeLaptop(model);
      const sent: { to: ActTarget | null } = { to: null };
      store.update((s) => {
        const to = name === '' ? null : actTarget(s, from);
        if (to === null) return s;
        const block = unavailableReason(to.session, 'model');
        if (block !== null) return refused(s, to, block);
        sent.to = to;
        return begun(s, to, 'model');
      });
      const to = sent.to;
      if (to === null) return;
      let how: Settled;
      try {
        await client.request('session.setModel', { session: to.ref, model: name });
        how = { taken: true, toast: `Model set to ${name}` };
      } catch (error) {
        how = { taken: false, text: errorText(error) };
      }
      store.update((s) => settle(s, to, 'model', how));
    },

    async loadProviders(repoID: string): Promise<void> {
      const id = ++providerLoads;
      store.update((s) => ({ ...s, sheets: providersLoading(s.sheets, id, repoID) }));
      let next: ProvidersLoad;
      try {
        const result = await client.request('remote.providers', { repoID });
        next = { phase: 'loaded', repoID, providers: result.providers };
      } catch (error) {
        const text = errorText(error);
        if (text === null) return;
        next = { phase: 'failed', repoID, message: text };
      }
      store.update((s) => {
        const sheets = providersEnded(s.sheets, id, next);
        return sheets === s.sheets ? s : { ...s, sheets };
      });
    },

    async createWorktree(repoID: string, message: string): Promise<void> {
      const c: CreateInFlight = { repoID, mode: 'local' };
      const ready = typeof message === 'string' && !isBlankMessage(message);
      const sent = { yes: false };
      store.update((s) => {
        const next = startedCreate(s, c, ready);
        sent.yes = next !== s;
        return next;
      });
      if (!sent.yes) return;
      // Taken as the request goes out: a navigation from here on means the user chose where to go.
      const mark = self().navMark();
      let worktreeID: string | null = null;
      let text: string | null = null;
      try {
        worktreeID = (await client.request('worktree.create', { repoID, message })).worktreeID;
      } catch (error) {
        text = errorText(error);
      }
      store.update((s) => settleCreate(s, c, worktreeID === null ? { taken: false, text } : { taken: true, toast: null }));
      if (worktreeID !== null) self().openPending({ worktreeID, toast: 'Created {name}' }, mark);
    },

    async createRemote(params: PhoneRemoteCreateParams): Promise<void> {
      const c: CreateInFlight = { repoID: params.repoID, mode: 'remote' };
      const sent = { yes: false };
      store.update((s) => {
        const provider = loadedProviders(s.sheets, params.repoID)?.find((p) => p.name === params.provider) ?? null;
        const next = startedCreate(s, c, provider !== null && remoteParamsReady(params, provider));
        sent.yes = next !== s;
        return next;
      });
      if (!sent.yes) return;
      const mark = self().navMark();
      let made: PhoneSessionRef | null = null;
      let text: string | null = null;
      try {
        made = (await client.request('remote.create', params)).session;
      } catch (error) {
        text = errorText(error);
      }
      store.update((s) => settleCreate(
        s, c, made === null ? { taken: false, text } : { taken: true, toast: `Remote session started on ${params.provider}` },
      ));
      if (made !== null) self().openPending({ ref: made }, mark);
    },

    /**
     * Shows in `sheet`, a New sheet that has just opened, the words of a create in its repo that
     * failed while no New sheet showed them (`lostCreate`), and keeps them no longer. The New sheet
     * calls it as it opens.
     */
    claimLostCreate(sheet: SheetState): void {
      store.update((s) => {
        const sheets = claimLostCreate(s.sheets, sheet);
        return sheets === s.sheets ? s : { ...s, sheets };
      });
    },
  };
}
