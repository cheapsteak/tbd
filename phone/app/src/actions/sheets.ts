// The sheet and menu actions: profiles, switching account, forking, the model, and New. What they
// load and what they wait on go in the sheet slice (`state/sheets.ts`). Part 6d fills them; New's
// three (`loadProviders`, `createWorktree`, `createRemote`) come with the New sheet and do nothing
// yet.
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
//   <profile>" (for null, the session's profile name, or "Default account" when it has none), and
//   opens the new tab once the list shows it (`openPending({ ref }, mark)`), unless the user has
//   navigated since the mark.
// - `setModel(model, from): Promise<void>` – `session.setModel` on the session the route shows,
//   with `model` trimmed of the white space around it (the laptop's own trim, `trimLikeLaptop`).
//   On success it closes the menu or sheet the gesture was made on, if it still shows, and toasts
//   "Model set to <model>". The session's status plays no part: the laptop takes a model change
//   while a session works and answers for itself.
// - `loadProviders(repoID)`, `createWorktree(repoID, message)`, `createRemote(params)` – New's;
//   for now each does nothing and resolves at once.
//
// **The target.** `from` is the session the menu or sheet showed when the user tapped. Each of
// the three acts only on the session the route shows at the moment of the gesture, read from the
// store in one read, and only when that is `from`, the list shows it (`findSession`), and its
// capability (`switchProfile`, `fork`, `model`) is available. So a menu or sheet still on screen
// for a moment after an event moved the route acts on nothing, never on the session the route
// moved to. `switchProfile` and a `fork` with a profile also need that profile in the profiles
// last loaded, the list the user picked from, and a switch never goes to the current profile.
// `setModel` needs a name that is not blank once trimmed.
//
// **One request per gesture.** A session gets one of the three at a time: the action marks it
// acting (`beginAct`) in the same store update that reads the target, before anything is sent,
// and does nothing while the mark stands. The mark goes when the request settles, on every path.
//
// **Errors** show their message as they come, `not_confirmed` included; `superseded` is silent.
// A refused switch or model change goes to the session's `ui.refusal`, which the composer shows,
// and also to the sheet open over the session when it failed, if one is, since the sheet covers
// the composer. A fork's error goes to that open sheet (`failed` in the slice) when there is one,
// and to `ui.refusal` otherwise, as when it was made from the account menu or the sheet was closed
// meanwhile. An error closes nothing: a menu or sheet closes only on success.
//
// **Never retry one of these automatically under a new request ID.** Each but the loads acts,
// and one that failed with `not_confirmed`, `bad_reply`, `internal` or `too_large` may have
// happened all the same (`ACTING_METHODS` in `client/client.ts`): a retry under a new ID could
// restart a session twice, or make a second fork. Show the error, and leave the choice to the
// user. Like every action, none rejects (`actions/index.ts`).

import { AppError, BAD_PARAMS_TEXT } from '../client/client.ts';
import type { PhoneRemoteCreateParams, PhoneSession, PhoneSessionRef, SessionForkParams } from '../protocol/types.ts';
import { refKey, sameRef } from '../protocol/wire.ts';
import { trimLikeLaptop, withText } from '../state/prompts.ts';
import { findSession } from '../state/route.ts';
import {
  accountName, beginAct, currentProfileID, endAct, failIn, isActing, loadedProfiles, profileByID, profilesEnded, profilesLoading,
} from '../state/sheets.ts';
import type { ActingKind, ProfilesLoad, SheetsState } from '../state/sheets.ts';
import { nextToast } from '../state/store.ts';
import type { AppState, MenuState, SheetState, UIState } from '../state/store.ts';
import type { ActionContext, Actions } from './index.ts';

/** The capability each acting request needs. */
const CAPABILITY = { switch: 'switchProfile', fork: 'fork', model: 'model' } as const;

/** Where an acting request goes: the session, its `refKey`, the session as the list showed it, and the menu or sheet the gesture was made on. */
interface ActTarget {
  ref: PhoneSessionRef;
  key: string;
  session: PhoneSession;
  surface: SheetState | MenuState | null;
}

/**
 * Where a `kind` request goes, read from `s` at the moment of the gesture: the session the route
 * shows, when it is `from`, the list shows it with the capability available, and nothing else is
 * on its way for it; or null when nothing must go out.
 */
function actTarget(s: AppState, from: PhoneSessionRef | undefined, kind: ActingKind): ActTarget | null {
  const { route } = s.ui;
  if (from === undefined || route.screen !== 'session' || !sameRef(route.ref, from)) return null;
  const found = findSession(s.sessions, route.ref);
  if (found === null || !found.session.capabilities[CAPABILITY[kind]].available) return null;
  const { ref } = found.session;
  if (isActing(s.sheets, ref)) return null;
  return { ref, key: refKey(ref), session: found.session, surface: s.ui.sheet ?? s.ui.menu };
}

/** `s` with `to`'s session marked acting as `kind`. */
function begun(s: AppState, to: ActTarget, kind: ActingKind): AppState {
  return { ...s, sheets: beginAct(s.sheets, to.ref, kind) };
}

/**
 * How an acting request ended: taken, with the toast to show, or failed, with the words to show
 * (null for none) and whether they go to the composer even while a sheet shows them.
 */
type Settled = { taken: true; toast: string } | { taken: false; text: string | null; composerToo: boolean };

/** The words for a failed request: the error's message, none for `superseded`, the client's words for a fault in its own setup. */
function errorText(error: unknown): string | null {
  if (!(error instanceof AppError)) return BAD_PARAMS_TEXT;
  return error.code === 'superseded' ? null : error.message;
}

/** The sheet open over `ref`'s session in `ui`, or null: one the route's session shows, never New. */
function sheetOver(ui: UIState, ref: PhoneSessionRef): SheetState | null {
  const { route, sheet } = ui;
  if (sheet === null || sheet.name === 'new' || route.screen !== 'session' || !sameRef(route.ref, ref)) return null;
  return sheet;
}

/**
 * `s` once `to`'s request settled as `how`: the mark gone, and then
 * - when taken, the menu or sheet the gesture was made on closed, if it still shows, and the toast;
 * - when failed, the words in the sheet open over the session, if one is, and in the session's
 *   `ui.refusal` when `composerToo` is set or no sheet shows them.
 */
function settle(s: AppState, to: ActTarget, how: Settled): AppState {
  let sheets: SheetsState = endAct(s.sheets, to.ref);
  let ui = s.ui;
  if (how.taken) {
    if (to.surface !== null && ui.sheet === to.surface) ui = { ...ui, sheet: null };
    if (to.surface !== null && ui.menu === to.surface) ui = { ...ui, menu: null };
    ui = { ...ui, toast: nextToast(ui, how.toast) };
  } else if (how.text !== null) {
    const sheet = sheetOver(ui, to.ref);
    if (sheet !== null) sheets = failIn(sheets, sheet, how.text);
    if (how.composerToo || sheet === null) {
      const refusal = withText(ui.refusal, to.key, how.text);
      if (refusal !== ui.refusal) ui = { ...ui, refusal };
    }
  }
  if (sheets === s.sheets && ui === s.ui) return s;
  return { ...s, sheets, ui };
}

export function sheetActions(ctx: ActionContext, self: () => Actions) {
  const { store, client } = ctx;
  /** The number of the last `profiles.list` sent, so only the newest lands. */
  let loads = 0;

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
        const to = actTarget(s, from, 'switch');
        const profiles = loadedProfiles(s.sheets);
        if (to === null || profiles === null) return s;
        const profile = profileByID(profiles, profileID);
        if (profile === null || profile.id === currentProfileID(to.session, profiles)) return s;
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
        how = { taken: false, text: errorText(error), composerToo: true };
      }
      store.update((s) => settle(s, to, how));
    },

    async fork(profileID: string | null, from: PhoneSessionRef): Promise<void> {
      const sent: { to: ActTarget | null; name: string } = { to: null, name: '' };
      store.update((s) => {
        const to = actTarget(s, from, 'fork');
        if (to === null) return s;
        if (profileID === null) {
          sent.name = accountName(to.session);
        } else {
          const profiles = loadedProfiles(s.sheets);
          const profile = profiles === null ? null : profileByID(profiles, profileID);
          if (profile === null) return s;
          sent.name = profile.name;
        }
        sent.to = to;
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
        how = { taken: false, text: errorText(error), composerToo: false };
      }
      store.update((s) => settle(s, to, how));
      if (made !== null) self().openPending({ ref: made }, mark);
    },

    async setModel(model: string, from: PhoneSessionRef): Promise<void> {
      const name = trimLikeLaptop(model);
      const sent: { to: ActTarget | null } = { to: null };
      store.update((s) => {
        const to = name === '' ? null : actTarget(s, from, 'model');
        if (to === null) return s;
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
        how = { taken: false, text: errorText(error), composerToo: true };
      }
      store.update((s) => settle(s, to, how));
    },

    async loadProviders(repoID: string): Promise<void> {},
    async createWorktree(repoID: string, message: string): Promise<void> {},
    async createRemote(params: PhoneRemoteCreateParams): Promise<void> {},
  };
}
