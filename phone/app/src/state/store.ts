/**
 * The app's state, and the small external store that holds it. React reads the store through
 * `useSyncExternalStore` (`context.tsx`); everything else reads and writes it through the
 * actions (`actions/`). This module imports nothing from React, so Node tests load it.
 *
 * The state is plain, immutable data. An update builds a new object for each part it changes
 * and keeps every other part as the same object, so a `!==` check tells what changed. A
 * function that changes nothing returns its input itself.
 */

import type { HostEnv } from '../env.ts';
import type { PhoneGroupLayout, PhoneRow, PhoneSessionRef } from '../protocol/types.ts';
import { emptyPrompts } from './prompts.ts';
import type { PromptsState } from './prompts.ts';
import { emptyTranscript } from './transcript.ts';
import type { TranscriptState } from './transcript.ts';

/** The screen the app shows: the sessions list, or one session. */
export type Route = { screen: 'sessions' } | { screen: 'session'; ref: PhoneSessionRef };

/** The sheet over the screen. Every sheet but `new` acts on the open session. */
export type SheetState = { name: 'menu' } | { name: 'switch' } | { name: 'switch-confirm'; profileID: string } | { name: 'fork' }
  | { name: 'model' } | { name: 'new'; repoID: string; repoName: string };

/** The open session header's dropdown: the account menu, which may be asking about one profile, or the model menu. */
export type MenuState = { name: 'account'; askProfileID: string | null } | { name: 'model' };

/**
 * A session to open once the list shows it: one the laptop made for this phone (a fork, a
 * created remote session) but has not listed yet. The phone acts only on sessions its list
 * shows, so it opens one only then (`resolvePendingOpen` in `route.ts`).
 * - `{ ref }`: opens that session. It toasts nothing; the action that made it toasts when the
 *   laptop replies.
 * - `{ worktreeID, toast }`: waits for the worktree row with that ID to list a session, and
 *   opens its first one. `toast` is a template: when it is not null, opening shows it with
 *   every `{name}` replaced by the row's name, so `'Created {name}'` reads "Created fix-login".
 *
 * Opening it clears `pendingOpen`.
 */
export type PendingOpen = { ref: PhoneSessionRef } | { worktreeID: string; toast: string | null };

export interface UIState {
  route: Route;
  sheet: SheetState | null;
  menu: MenuState | null;
  showDetails: boolean;
  /** Collapsed groups, by group ID. A group is expanded when its ID is absent. */
  collapsed: Readonly<Record<string, true>>;
  /** The row of the session opened last, which the list marks. */
  lastRowID: string | null;
  /** The toast showing. Each new toast has a new `id`, so the same text twice shows twice. */
  toast: { id: number; text: string } | null;
  pendingOpen: PendingOpen | null;
  /** Why the laptop refused the last action on a session, shown with it, by `refKey` of the session. */
  refusal: Readonly<Record<string, string>>;
  /** Unsent composer text, by `refKey` of the session. */
  drafts: Readonly<Record<string, string>>;
}

/**
 * The sessions list as the laptop sent it. `layout` is the laptop sidebar's groups, each with
 * its rows' IDs in order; `rows` holds each row by its ID, on a null prototype, so a row ID
 * such as `constructor` reads no inherited member.
 *
 * A placement in `layout` can name a row that `rows` does not hold: a snapshot with `more` set
 * sends its remaining rows as later events. Everything that reads the list skips such a
 * placement until its row arrives.
 */
export interface SessionsData {
  layout: readonly PhoneGroupLayout[];
  rows: Readonly<Record<string, PhoneRow>>;
}

export interface AppState {
  /**
   * The channel to the laptop. `subscribed` turns true at the first `sessions.subscribe` reply
   * and stays true across drops, so the list stays on screen while the loader reconnects.
   * `error` is a refused subscribe's message, shown with "Try again" while `subscribed` is false.
   */
  conn: { up: boolean; subscribed: boolean; error: string | null };
  /** The loader's view of the screen, null until its first `env` message. */
  env: HostEnv | null;
  sessions: SessionsData;
  ui: UIState;
  transcript: TranscriptState;
  prompts: PromptsState;
}

export interface Store {
  get(): AppState;
  /**
   * Replaces the state with `fn`'s result, and notifies every listener when the result is a
   * new object. `fn` returns the state itself to change nothing.
   */
  update(fn: (s: AppState) => AppState): void;
  /** Adds a listener, and returns the function that removes it. */
  subscribe(l: () => void): () => void;
}

/** The sessions route. It is shared, since a route is never changed in place. */
export const SESSIONS_ROUTE: Route = Object.freeze({ screen: 'sessions' });

/** A record with no prototype, so a key such as `constructor` reads nothing inherited. */
export function emptyRecord<V>(): Record<string, V> {
  return Object.create(null) as Record<string, V>;
}

export function initialState(): AppState {
  return {
    conn: { up: false, subscribed: false, error: null },
    env: null,
    sessions: { layout: [], rows: emptyRecord() },
    ui: {
      route: SESSIONS_ROUTE,
      sheet: null,
      menu: null,
      showDetails: false,
      collapsed: emptyRecord(),
      lastRowID: null,
      toast: null,
      pendingOpen: null,
      refusal: emptyRecord(),
      drafts: emptyRecord(),
    },
    transcript: emptyTranscript(),
    prompts: emptyPrompts(),
  };
}

/**
 * The toast after `ui`'s: `text`, with an ID one past the one showing. The ID starts over at
 * 1 once no toast shows, which is enough for the Toast to tell one toast from the next.
 */
export function nextToast(ui: UIState, text: string): { id: number; text: string } {
  return { id: (ui.toast?.id ?? 0) + 1, text };
}

export function createStore(initial: AppState = initialState()): Store {
  let state = initial;
  const listeners = new Set<() => void>();
  return {
    get: () => state,
    update(fn) {
      const next = fn(state);
      if (next === state) return;
      state = next;
      // A copy, so a listener that subscribes or unsubscribes does not change this round.
      for (const listener of [...listeners]) listener();
    },
    subscribe(l) {
      listeners.add(l);
      return () => {
        listeners.delete(l);
      };
    },
  };
}
