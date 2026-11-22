/**
 * The shell's actions: the channel and the subscription, navigation, sheets, menus, toasts,
 * the sessions list's folding and filter chips, and links. `main.tsx` wires the client to three
 * of them, `onEvent`, `onChannelUp` and `onChannelDown`, and the loader's route messages to a
 * fourth, `onRoute`.
 *
 * Navigation keeps the history entries the loader holds for the app (`ctx.entries`) in step
 * with the route, so the phone's back button steps back through the worktrees the user moved
 * between:
 * - a move to another worktree adds an entry: from the list to a session, from a session to one
 *   in another row, or a pending open that lands in another row;
 * - a move within one worktree rewrites the current entry, so a tap on another tab, or a fork
 *   that opens beside its session, adds none;
 * - so does a move an event makes, such as the shown session leaving the list;
 * - the back chevron (`back`) asks the loader to go back, and the route message that answers
 *   sets the screen, as one does for the browser's own back and forward (`onRoute`).
 */

import { AppError } from '../client/client.ts';
import type { AppEvent, PhoneSessionRef, SessionsSubscribeParams, SessionsSubscribeResult } from '../protocol/types.ts';
import { applyEvent, applySessions, withPendingOpen } from '../state/events.ts';
import { shownFilterOn, tapFailed, tapTaken, withTap } from '../state/remoteFilter.ts';
import { findSession, restoreRef, sameRoute } from '../state/route.ts';
import { decodeRoute } from '../state/routeState.ts';
import { applySnapshot, isComplete } from '../state/sessionsData.ts';
import { emptyRecord, nextToast, SESSIONS_ROUTE } from '../state/store.ts';
import type { AppState, MenuState, PendingOpen, Route, SessionsData, SheetState, UIState } from '../state/store.ts';
import type { ActionContext, Actions } from './index.ts';
import { errorText } from './sheets.ts';

export function shellActions(ctx: ActionContext, self: () => Actions) {
  const { store } = ctx;
  /** The number of the last tap on a filter chip, so a reply settles only its own tap (`state/remoteFilter.ts`). */
  let filterTaps = 0;
  /**
   * Per repo ID, a promise that settles once the repo's last `repo.setRemoteFilter` has, success
   * or failure: the tail of its chain of sends (`toggleRemoteFilter`). A repo has an entry only
   * from a send until the reply to its last send has been handled.
   */
  const filterChains = new Map<string, Promise<void>>();

  function setUI(fn: (ui: UIState) => UIState): void {
    store.update((s) => {
      const ui = fn(s.ui);
      return ui === s.ui ? s : { ...s, ui };
    });
  }

  function setConn(conn: Partial<AppState['conn']>): void {
    store.update((s) => ({ ...s, conn: { ...s.conn, ...conn } }));
  }

  /**
   * Updates the state with `fn`, then follows a move of the route that it made rather than a
   * tap did: a pending open that became the route, or an open session that left every row. It
   * opens or closes the transcript, and keeps the history entry in step (`record`). A restore
   * (`PendingOpen`) adds no entry, because the entry it came from names its session already: one
   * that lands rewrites that entry, and one the complete list dropped rewrites it to the list,
   * which shows.
   */
  function updateAndFollowRoute(fn: (s: AppState) => AppState): void {
    const before = store.get();
    store.update(fn);
    const after = store.get();
    const route = after.ui.route;
    const restore = restoreRef(before.ui.pendingOpen);
    const restoreEnded = restore !== null && after.ui.pendingOpen === null;
    if (sameRoute(before.ui.route, route)) {
      if (restoreEnded) ctx.entries.replace(route);
      return;
    }
    if (route.screen === 'session') self().openTranscript(route.ref);
    else self().closeTranscript();
    if (restoreEnded && sameRoute(route, { screen: 'session', ref: restore })) ctx.entries.replace(route);
    else record(before, after);
  }

  /**
   * Asks the loader's history to match a move from the screen `before` showed to the one `after`
   * shows: a new entry for a move to a session in another worktree, from the list or from
   * another row; the current entry rewritten for anything else. Which row holds each session
   * comes from `after`'s list when it holds the session (`sameWorktree`).
   */
  function record(before: AppState, after: AppState): void {
    const route = after.ui.route;
    if (route.screen === 'session' && !sameWorktree(before, after)) ctx.entries.push(route);
    else ctx.entries.replace(route);
  }

  /**
   * How many subscribes are unanswered, superseded ones included until the client fails them.
   * Kept here and not in the store, since nothing renders it: `retrySubscribe` reads it.
   */
  let subscribesInFlight = 0;

  /**
   * Sends `sessions.subscribe`: with the stream and the last `seq` the client saw, so the
   * laptop can replay what the phone missed, or with `{}` when the client has not both.
   */
  function subscribe(): void {
    const { stream, lastSeq } = ctx.client;
    const params: SessionsSubscribeParams = stream !== null && lastSeq !== null ? { stream, sinceSeq: lastSeq } : {};
    subscribesInFlight++;
    ctx.client.request('sessions.subscribe', params).then(
      (result) => {
        subscribesInFlight--;
        subscribed(result);
      },
      (error: unknown) => {
        subscribesInFlight--;
        subscribeFailed(error);
      },
    );
  }

  /**
   * A subscribe reply. A snapshot replaces the list, and the route follows it; a replay leaves
   * the list as it is, because the events it replays follow and update it.
   */
  function subscribed(result: SessionsSubscribeResult): void {
    updateAndFollowRoute((s) => {
      const next = { ...s, conn: { ...s.conn, subscribed: true, error: null } };
      return result.replayed ? next : applySessions(next, applySnapshot(result));
    });
  }

  /**
   * A refused subscribe. It shows the laptop's message with "Try again", even after a
   * reconnect, since without a subscription the list is stale. A subscribe that a channel up
   * superseded is silent: `onChannelUp` sent its replacement.
   */
  function subscribeFailed(error: unknown): void {
    if (error instanceof AppError && error.code === 'superseded') return;
    const message = error instanceof Error ? error.message : String(error);
    setConn({ subscribed: false, error: message });
  }

  return {
    /** One event from the client, folded into the state; a change of route it makes opens or closes the transcript. */
    onEvent(event: AppEvent): void {
      updateAndFollowRoute((s) => applyEvent(s, event));
    },

    /**
     * The channel came up. The client calls this inside its `onUp`, so the requests made here
     * go out first: `sessions.subscribe`, then the transcript's resume, which does not wait
     * for the subscribe reply. It clears a refused subscribe's error, so the loading screen
     * shows while the new subscribe is in flight, in place of the old message and "Try again".
     */
    onChannelUp(): void {
      setConn({ up: true, error: null });
      subscribe();
      self().resumeTranscriptOnUp();
    },

    onChannelDown(): void {
      setConn({ up: false });
    },

    /**
     * "Try again" after a refused subscribe. It does nothing unless an error shows and no
     * subscribe is in flight, so a second tap sends nothing more and never a second subscribe
     * beside one a channel up sent. Nor does it while the channel is down: a subscribe sent then
     * could not go out before the next channel up, which sends its own. So the message stays,
     * under the loader's "Reconnecting…", until `onChannelUp` clears it.
     */
    retrySubscribe(): void {
      const { conn } = store.get();
      if (!conn.up || conn.error === null || subscribesInFlight > 0) return;
      setConn({ error: null });
      subscribe();
    },

    /**
     * Shows `ref`'s session and opens its transcript, clearing the menu, the sheet and any
     * pending open: the user chose where to go, so a fork or create still on its way no longer
     * takes them anywhere. A ref no row lists does nothing: the laptop acts only on sessions its
     * list shows. Nor does the session the route shows already: a tap on it goes nowhere, so it
     * keeps the transcript as it is, leaves a pending open waiting, and is not a navigation
     * (`navMark`).
     */
    openSession(ref: PhoneSessionRef): void {
      const s = store.get();
      if (sameRoute(s.ui.route, { screen: 'session', ref })) return;
      const found = findSession(s.sessions, ref);
      if (found === null) return;
      setUI((ui) => ({
        ...ui, route: { screen: 'session', ref }, lastRowID: found.row.id, menu: null, sheet: null, pendingOpen: null,
        nav: ui.nav + 1,
      }));
      self().openTranscript(ref);
      record(s, store.get());
    },

    /**
     * The back chevron. It asks the loader's history to go back and changes nothing itself: the
     * route message that answers sets the screen (`onRoute`), going back one entry, or to the
     * list when the entry before is not one of the app's. So the chevron and the browser's back
     * agree, and the browser's forward returns to the session the chevron left. On the sessions
     * list it does nothing.
     */
    back(): void {
      if (store.get().ui.route.screen === 'sessions') return;
      ctx.entries.back();
    },

    /**
     * The browser is on the history entry whose route string is `state` (null for the sessions
     * list): the frame started on it, the user went back or forward, or the loader answered the
     * chevron. It shows that screen as a tap would: it closes the menu and the sheet, clears any
     * pending open, and counts as the user's navigation (`navMark`), so a fork or create still in
     * flight never takes the user away afterwards. It asks for no entry for the move itself.
     * - A session a row lists shows, and its transcript opens.
     * - A session that the complete list does not hold, or a string that names no route, shows
     *   the list, and the entry is rewritten to match.
     * - A session the list may still bring, because it has not fully arrived, as at start, waits
     *   as a restore (`PendingOpen`) while the list shows.
     *
     * When the screen it names shows already, the screen stays, and the rest is as for any route
     * message: the menu and the sheet close, any pending open is cleared, and it counts as a
     * navigation.
     */
    onRoute(state: string | null): void {
      const s = store.get();
      const decoded = state === null ? SESSIONS_ROUTE : decodeRoute(state);
      let target: Route = decoded ?? SESSIONS_ROUTE;
      let rewrite = decoded === null;
      let rowID: string | null = null;
      let restore: PendingOpen | null = null;
      if (target.screen === 'session') {
        const found = findSession(s.sessions, target.ref);
        if (found !== null) {
          rowID = found.row.id;
        } else if (listComplete(s)) {
          target = SESSIONS_ROUTE;
          rewrite = true;
        } else {
          restore = { ref: target.ref, restore: true };
        }
      }
      if (sameRoute(s.ui.route, target)) {
        setUI((ui) => ({ ...ui, menu: null, sheet: null, pendingOpen: null, nav: ui.nav + 1 }));
      } else {
        const shown = restore === null ? target : SESSIONS_ROUTE;
        setUI((ui) => ({
          ...ui, route: shown, lastRowID: rowID ?? ui.lastRowID, menu: null, sheet: null, pendingOpen: restore, nav: ui.nav + 1,
        }));
        if (!sameRoute(s.ui.route, shown)) {
          if (shown.screen === 'session') self().openTranscript(shown.ref);
          else self().closeTranscript();
        }
      }
      if (rewrite) ctx.entries.replace(SESSIONS_ROUTE);
    },

    /**
     * The count of the user's navigations so far (`UIState.nav`). A fork or create takes it when
     * it sends its request, and passes it to `openPending` with the reply.
     */
    navMark(): number {
      return store.get().ui.nav;
    },

    /**
     * Waits to open `p` until the list shows it, and opens it at once when it does already
     * (`PendingOpen` in `state/store.ts`). It replaces any open still waiting. With `since`, a
     * mark from `navMark`, it does nothing when the user has navigated since that mark: they
     * chose where to go while the request that made `p` was in flight.
     */
    openPending(p: PendingOpen, since?: number): void {
      if (since !== undefined && since !== store.get().ui.nav) return;
      updateAndFollowRoute((s) => withPendingOpen(s, p));
    },

    /** Opens `sheet` over the screen, closing any menu. */
    openSheet(sheet: SheetState): void {
      setUI((ui) => ({ ...ui, sheet, menu: null }));
    },

    closeSheet(): void {
      setUI((ui) => (ui.sheet === null ? ui : { ...ui, sheet: null }));
    },

    /** Opens the header's `menu`, closing any sheet. */
    openMenu(menu: MenuState): void {
      setUI((ui) => ({ ...ui, menu, sheet: null }));
    },

    closeMenu(): void {
      setUI((ui) => (ui.menu === null ? ui : { ...ui, menu: null }));
    },

    /** Shows `text` as a new toast, even when it is the text showing. */
    toast(text: string): void {
      setUI((ui) => ({ ...ui, toast: nextToast(ui, text) }));
    },

    /** Takes toast `id` down. A newer toast stays. The Toast calls it when its time is up. */
    clearToast(id: number): void {
      setUI((ui) => (ui.toast?.id === id ? { ...ui, toast: null } : ui));
    },

    /** Sets "Show details", and has the open transcript follow it when it changed. */
    setShowDetails(on: boolean): void {
      if (store.get().ui.showDetails === on) return;
      setUI((ui) => ({ ...ui, showDetails: on }));
      self().onShowDetailsChanged();
    },

    /**
     * Marks row `rowID` as the one opened last, which the sessions list shows selected, or
     * marks none for null. `openSession` and a pending open that opens mark the row themselves.
     */
    setLastRow(rowID: string | null): void {
      setUI((ui) => (ui.lastRowID === rowID ? ui : { ...ui, lastRowID: rowID }));
    },

    /** Collapses group `groupID`, or expands it when it is collapsed. */
    toggleRepo(groupID: string): void {
      setUI((ui) => {
        const collapsed = emptyRecord<true>();
        for (const id of Object.keys(ui.collapsed)) if (id !== groupID) collapsed[id] = true;
        if (!Object.hasOwn(ui.collapsed, groupID)) collapsed[groupID] = true;
        return { ...ui, collapsed };
      });
    },

    /**
     * A tap on repo `repoID`'s filter chip. The chip flips at once: the phone holds the flipped
     * value for the repo (`withTap`) and sends it in `repo.setRemoteFilter`. The laptop's list
     * settles it (`followLayout` in `state/remoteFilter.ts`); a failure flips it back and toasts
     * the laptop's reason, unless a newer tap on the chip followed. A repo the list does not show
     * sends nothing. It resolves once the reply has settled.
     *
     * A repo's requests go one at a time. The client posts them in the order they were made, even
     * across a drop, but the laptop runs each request on its own, so two in flight together can be
     * written in either order, and on, then off, could end on. So a tap's request goes at once
     * when none of the repo's is unanswered, and otherwise once the one before it has settled,
     * whether it succeeded or failed (`filterChains`). It carries the value of its own tap, so the
     * last tap's value is the last one written. Another repo's taps never wait on this one's.
     *
     * One the client could not confirm after a drop fails as `not_confirmed`, and the chip flips
     * back; the laptop's next layout shows what it holds.
     */
    async toggleRemoteFilter(repoID: string): Promise<void> {
      const seq = ++filterTaps;
      const sent: { hidden: boolean | null } = { hidden: null };
      store.update((s) => {
        const shown = shownFilterOn(s.ui, s.sessions, repoID);
        if (shown === null) return s;
        sent.hidden = !shown;
        return { ...s, ui: withTap(s.ui, repoID, !shown, seq) };
      });
      const hidden = sent.hidden;
      if (hidden === null) return;
      const post = () => ctx.client.request('repo.setRemoteFilter', { repoID, hidden });
      const before = filterChains.get(repoID);
      const reply = before === undefined ? post() : before.then(post);
      const settled = reply.then(() => {}, () => {});
      filterChains.set(repoID, settled);
      try {
        await reply;
        store.update((s) => {
          const ui = tapTaken(s.ui, s.sessions, repoID, seq);
          return ui === s.ui ? s : { ...s, ui };
        });
      } catch (error) {
        const text = errorText(error);
        setUI((ui) => tapFailed(ui, repoID, seq, text));
      } finally {
        // No later tap queued behind this one: the repo's chain is idle.
        if (filterChains.get(repoID) === settled) filterChains.delete(repoID);
      }
    },

    /** Asks the loader to open `url`, behind its own sheet. */
    openLink(url: string): void {
      ctx.link.openLink(url);
    },
  };
}

/**
 * Whether the list has fully arrived: a subscribe has answered, and every row the layout places
 * is here. A session it does not hold then is gone, not on its way.
 */
function listComplete(s: AppState): boolean {
  return s.conn.subscribed && isComplete(s.sessions);
}

/**
 * Whether `before` and `after` both show a session, and one row holds both: the same worktree,
 * or the same remote session's row. Both sessions are looked up in `after`'s list, the newer one,
 * and the session `before` showed in `before`'s own list when `after`'s does not hold it. So a
 * partial list that lacked the row `before` showed, whose row came back in `after`'s list, does
 * not count as a move to another row.
 */
function sameWorktree(before: AppState, after: AppState): boolean {
  const row = shownRowID(before.ui.route, after.sessions, before.sessions);
  return row !== null && row === shownRowID(after.ui.route, after.sessions);
}

/**
 * The ID of the row that lists the session `route` shows, in the first of `lists` that holds
 * it, or null on the sessions list or when none of them does.
 */
function shownRowID(route: Route, ...lists: SessionsData[]): string | null {
  if (route.screen === 'sessions') return null;
  for (const d of lists) {
    const found = findSession(d, route.ref);
    if (found !== null) return found.row.id;
  }
  return null;
}
