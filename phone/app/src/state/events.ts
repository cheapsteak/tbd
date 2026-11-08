/**
 * Each event from the laptop, folded into the state by the slice it is about. Everything here
 * is pure: the effects a change of route calls for, opening or closing a transcript, are the
 * shell actions' (`onEvent` in `actions/shell.ts`).
 */

import type { AppEvent } from '../protocol/types.ts';
import { applyPromptChanged } from './prompts.ts';
import { pendingOpenTarget, resolveRoute, sameRoute } from './route.ts';
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
 * - `prompt.changed` goes to the prompt slice (`applyPromptChanged`), and each receipt that
 *   gives goes to the transcript (`addReceipt`), in order.
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
      const { prompts, receipts } = slices.applyPromptChanged(state.prompts, event.data);
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
 * A change of screen clears the menu and every sheet but `new`, since they act on the session
 * the screen showed; `new` acts on a repo. Opening a session also marks its row (`lastRowID`).
 */
export function applySessions(state: AppState, sessions: SessionsData): AppState {
  return { ...state, sessions, ui: followList(state.ui, sessions) };
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
  const next = moveTo(ui, resolveRoute(ui.route, d), null);
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
 * itself when it shows that screen already.
 */
function moveTo(ui: UIState, route: Route, rowID: string | null): UIState {
  if (sameRoute(ui.route, route)) return ui;
  return {
    ...ui,
    route,
    menu: null,
    sheet: ui.sheet?.name === 'new' ? ui.sheet : null,
    lastRowID: rowID ?? ui.lastRowID,
  };
}
