/**
 * Each event from the laptop, folded into the state by the slice it is about. Everything here
 * is pure: the effects a change of route calls for, opening or closing a transcript, are the
 * shell actions' (`onEvent` in `actions/shell.ts`).
 */

import type { AppEvent } from '../protocol/types.ts';
import { applyPromptChanged, clearStaleRefusals } from './prompts.ts';
import { findSession, pendingOpenTarget, resolveRoute, sameRoute } from './route.ts';
import { applySessionsChanged } from './sessionsData.ts';
import { nextToast } from './store.ts';
import type { AppState, PendingOpen, Route, SessionsData, UIState } from './store.ts';
import { addReceipt, applyTranscriptEvent } from './transcript.ts';

/** The slice functions `applyEvent` calls, as a seam for tests. */
export interface EventSlices {
  applyTranscriptEvent: typeof applyTranscriptEvent;
  applyPromptChanged: typeof applyPromptChanged;
  addReceipt: typeof addReceipt;
}

const SLICES: EventSlices = { applyTranscriptEvent, applyPromptChanged, addReceipt };

/**
 * `state` with `event` folded in:
 * - `sessions.changed` merges into the list (`applySessionsChanged`), and the route follows
 *   the list (`applySessions`);
 * - `transcript.*` goes to the transcript slice (`applyTranscriptEvent`);
 * - `prompt.changed` goes to the prompt slice (`applyPromptChanged`, with the session the route
 *   shows), and each receipt that gives goes to the transcript (`addReceipt`), in order.
 *
 * It returns `state` itself when no slice changed.
 */
export function applyEvent(state: AppState, event: AppEvent): AppState {
  return applyEventWith(state, event, SLICES);
}

/** `applyEvent`, with the slice functions given. */
export function applyEventWith(state: AppState, event: AppEvent, slices: EventSlices): AppState {
  switch (event.event) {
    case 'sessions.changed':
      return applySessions(state, applySessionsChanged(state.sessions, event.data));
    case 'transcript.append':
    case 'transcript.update':
    case 'transcript.reset': {
      const transcript = slices.applyTranscriptEvent(state.transcript, event);
      return transcript === state.transcript ? state : { ...state, transcript };
    }
    case 'prompt.changed': {
      const { route } = state.ui;
      const { prompts, receipts } = slices.applyPromptChanged(state.prompts, event.data, route.screen === 'session' ? route.ref : null);
      let transcript = state.transcript;
      for (const receipt of receipts) {
        transcript = slices.addReceipt(transcript, event.data.session, receipt.id, receipt.text);
      }
      if (prompts === state.prompts && transcript === state.transcript) return state;
      return { ...state, prompts, transcript };
    }
  }
}

/**
 * `state` with the list `sessions`, and the route kept to it:
 * 1. A session route whose session no row lists goes back to the sessions list, once every
 *    row the layout places has arrived (`resolveRoute`).
 * 2. Then a pending open that the list now shows opens, and is cleared. A `{ worktreeID }`
 *    open with a toast template shows it, `{name}` replaced by the row's name.
 *
 * A prompt card's refusal goes once its session's `answer` capability turns from unavailable to
 * available (`clearStaleRefusals`).
 *
 * A change of screen clears the menu and every sheet, since they act on the session the screen
 * showed. The one exception is `new`, which acts on a repo, not a session: it stays when the
 * route goes back to the sessions list, which it opens from, so a session that leaves the list
 * does not close it. A route to a session closes `new` too, so it never stays over the session
 * a create opened. Opening a session also marks its row (`lastRowID`).
 *
 * A session route that stands while no row lists its session, as while a partial snapshot's
 * rows are on their way, closes the menu and every sheet too, as a route to a session does.
 * The session screen waits for the row then, and they would act on a session the list does not
 * show; a menu left set would open again when the row comes.
 */
export function applySessions(state: AppState, sessions: SessionsData): AppState {
  return { ...state, sessions, ui: followList(state.ui, sessions), prompts: clearStaleRefusals(state.prompts, state.sessions, sessions) };
}

/**
 * `state` waiting to open `p`, which opens at once when the list shows it already: a reply
 * can come after the `sessions.changed` that lists what it made.
 */
export function withPendingOpen(state: AppState, p: PendingOpen): AppState {
  return { ...state, ui: followList({ ...state.ui, pendingOpen: p }, state.sessions) };
}

function followList(ui: UIState, d: SessionsData): UIState {
  // `resolveRoute` keeps the route or goes back to the list, so it leaves no row to mark.
  const next = closeWhileUnlisted(moveTo(ui, resolveRoute(ui.route, d), null), d);
  const pending = next.pendingOpen;
  if (pending === null) return next;
  const target = pendingOpenTarget(pending, d);
  if (target === null) return next;
  const done: UIState = { ...moveTo(next, target.route, target.row.id), pendingOpen: null };
  if ('ref' in pending || pending.toast === null) return done;
  const name = target.row.name;
  // A function, so a `$` in the name is not read as a replacement pattern.
  return { ...done, toast: nextToast(done, pending.toast.replaceAll('{name}', () => name)) };
}

/**
 * `ui` showing `route`, with `rowID` marked as the row opened last when it is not null, or `ui`
 * itself when it shows that screen already. It keeps only a `new` sheet, and only on the way to
 * the sessions list (`applySessions`).
 */
function moveTo(ui: UIState, route: Route, rowID: string | null): UIState {
  if (sameRoute(ui.route, route)) return ui;
  return {
    ...ui,
    route,
    menu: null,
    sheet: route.screen === 'sessions' && ui.sheet?.name === 'new' ? ui.sheet : null,
    lastRowID: rowID ?? ui.lastRowID,
  };
}

/**
 * `ui` with no menu and no sheet when its route shows a session that no row of `d` lists, or
 * `ui` itself when it shows the list, finds its session, or has neither open.
 */
function closeWhileUnlisted(ui: UIState, d: SessionsData): UIState {
  if (ui.route.screen !== 'session' || (ui.menu === null && ui.sheet === null)) return ui;
  if (findSession(d, ui.route.ref) !== null) return ui;
  return { ...ui, menu: null, sheet: null };
}
