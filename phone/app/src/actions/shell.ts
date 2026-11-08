/**
 * The shell's actions: the channel and the subscription, navigation, sheets, menus, toasts
 * and links. `main.tsx` wires the client to three of them: `onEvent`, `onChannelUp` and
 * `onChannelDown`.
 */

import { AppError } from '../client/client.ts';
import type { AppEvent, PhoneSessionRef, SessionsSubscribeParams, SessionsSubscribeResult } from '../protocol/types.ts';
import { applyEvent, applySessions, withPendingOpen } from '../state/events.ts';
import { findSession, sameRoute } from '../state/route.ts';
import { applySnapshot } from '../state/sessionsData.ts';
import { emptyRecord, nextToast, SESSIONS_ROUTE } from '../state/store.ts';
import type { AppState, MenuState, PendingOpen, SheetState, UIState } from '../state/store.ts';
import type { ActionContext, Actions } from './index.ts';

export function shellActions(ctx: ActionContext, self: () => Actions) {
  const { store } = ctx;

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
   * Updates the state with `fn`, then opens or closes the transcript when that moved the route
   * rather than a tap did: a pending open that became the route, or an open session that left
   * every row.
   */
  function updateAndFollowRoute(fn: (s: AppState) => AppState): void {
    const before = store.get().ui.route;
    store.update(fn);
    const after = store.get().ui.route;
    if (sameRoute(before, after)) return;
    if (after.screen === 'session') self().openTranscript(after.ref);
    else self().closeTranscript();
  }

  /**
   * Sends `sessions.subscribe`: with the stream and the last `seq` the client saw, so the
   * laptop can replay what the phone missed, or with `{}` when the client has not both.
   */
  function subscribe(): void {
    const { stream, lastSeq } = ctx.client;
    const params: SessionsSubscribeParams = stream !== null && lastSeq !== null ? { stream, sinceSeq: lastSeq } : {};
    ctx.client.request('sessions.subscribe', params).then(subscribed, subscribeFailed);
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
     * for the subscribe reply.
     */
    onChannelUp(): void {
      setConn({ up: true });
      subscribe();
      self().resumeTranscriptOnUp();
    },

    onChannelDown(): void {
      setConn({ up: false });
    },

    /** "Try again" after a refused subscribe. It does nothing unless an error shows, so a second tap sends nothing more. */
    retrySubscribe(): void {
      if (store.get().conn.error === null) return;
      setConn({ error: null });
      subscribe();
    },

    /**
     * Shows `ref`'s session and opens its transcript, clearing the menu, the sheet and any
     * pending open: the user chose where to go, so a fork or create still on its way no longer
     * takes them anywhere. A ref no row lists does nothing: the laptop acts only on sessions its
     * list shows. Nor does the session the route shows already: a tap on it goes nowhere, so it
     * keeps the transcript as it is and leaves a pending open waiting.
     */
    openSession(ref: PhoneSessionRef): void {
      const s = store.get();
      if (sameRoute(s.ui.route, { screen: 'session', ref })) return;
      const found = findSession(s.sessions, ref);
      if (found === null) return;
      setUI((ui) => ({
        ...ui, route: { screen: 'session', ref }, lastRowID: found.row.id, menu: null, sheet: null, pendingOpen: null,
      }));
      self().openTranscript(ref);
    },

    /**
     * Back to the sessions list, closing the transcript, the menu and the sheet, and clearing
     * any pending open, as `openSession` does. On the sessions list it does nothing.
     */
    back(): void {
      if (store.get().ui.route.screen === 'sessions') return;
      setUI((ui) => ({ ...ui, route: SESSIONS_ROUTE, menu: null, sheet: null, pendingOpen: null }));
      self().closeTranscript();
    },

    /**
     * Waits to open `p` until the list shows it, and opens it at once when it does already
     * (`PendingOpen` in `state/store.ts`). It replaces any open still waiting.
     */
    openPending(p: PendingOpen): void {
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

    /** Asks the loader to open `url`, behind its own sheet. */
    openLink(url: string): void {
      ctx.link.openLink(url);
    },
  };
}
