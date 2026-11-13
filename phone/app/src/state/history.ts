/**
 * The app's entries in the browser's session history, so that the phone's back button, iOS
 * Safari's edge swipe and Android's system back step back through the worktrees the user moved
 * between before they leave the app. Every History API call the app makes is in this file.
 *
 * Each entry's state is `{ tbd: { route, index } }`: the route it shows, and how many of the
 * app's entries come before it. The first is index 0, the entry the frame had when the app
 * started. No call passes a URL, so the frame's address never changes: its origin is opaque, and
 * an entry needs nothing but its state.
 *
 * Moving between entries is same-document, so the frame never reloads and the loader's page
 * never sees a second `load`. The frame shares its session history with the loader's page,
 * which is why the app goes back only through `RouteHistory.stepBack`, and never forward or by
 * more than one entry (`app/src-policy.test.js`).
 */

import { decodePhoneSessionRef } from '../protocol/wire.ts';
import { SESSIONS_ROUTE } from './store.ts';
import type { Route } from './store.ts';

/**
 * The part of the History API the app uses, as a seam for tests. `windowHistory` is the
 * browser's.
 */
export interface HistoryPort {
  /** The current entry's state. */
  readonly state: unknown;
  /** Adds an entry after the current one, holding `data`, and drops every entry after it. */
  pushState(data: unknown): void;
  /** Rewrites the current entry's state to `data`. */
  replaceState(data: unknown): void;
  /** Goes back one entry. The browser moves later, and tells the move with a `popstate`. */
  back(): void;
  /** Calls `listener` with each `popstate`'s state, and returns the function that stops it. */
  onPopState(listener: (state: unknown) => void): () => void;
}

/** `win`'s History API, as a `HistoryPort`. */
export function windowHistory(win: Window): HistoryPort {
  return {
    get state(): unknown {
      return win.history.state;
    },
    pushState(data: unknown): void {
      win.history.pushState(data, '');
    },
    replaceState(data: unknown): void {
      win.history.replaceState(data, '');
    },
    back(): void {
      win.history.back();
    },
    onPopState(listener: (state: unknown) => void): () => void {
      const handle = (event: PopStateEvent): void => listener(event.state);
      win.addEventListener('popstate', handle);
      return () => win.removeEventListener('popstate', handle);
    },
  };
}

/** What one of the app's entries holds: the route it shows, and how many app entries come before it. */
export interface RouteEntry {
  route: Route;
  index: number;
}

/**
 * `state`, an entry's state, as one of the app's entries, or null when it is not one: it has no
 * `tbd` object, or that object does not hold a route and an index. The state is the browser's
 * copy of what the app wrote, but it is read as untrusted all the same.
 */
export function readEntry(state: unknown): RouteEntry | null {
  const tbd = ownField(state, 'tbd');
  const index = ownField(tbd, 'index');
  if (typeof index !== 'number' || !Number.isSafeInteger(index) || index < 0) return null;
  const route = readRoute(ownField(tbd, 'route'));
  return route === null ? null : { route, index };
}

/** `raw` as a route, or null when it is not one. */
function readRoute(raw: unknown): Route | null {
  const screen = ownField(raw, 'screen');
  if (screen === 'sessions') return SESSIONS_ROUTE;
  if (screen !== 'session') return null;
  try {
    return { screen: 'session', ref: decodePhoneSessionRef(ownField(raw, 'ref')) };
  } catch {
    return null;
  }
}

/** Field `key` of `o` when `o` is an object that holds it itself, else undefined. */
function ownField(o: unknown, key: string): unknown {
  if (typeof o !== 'object' || o === null || !Object.hasOwn(o, key)) return undefined;
  return (o as Record<string, unknown>)[key];
}

/**
 * The app's entries in the browser's history, over `port`. Making one takes the current entry
 * as the app's first, index 0, showing `route`. The shell actions decide when a move adds an
 * entry and when it rewrites the current one (`actions/shell.ts`).
 */
export class RouteHistory {
  readonly #port: HistoryPort;

  constructor(port: HistoryPort, route: Route) {
    this.#port = port;
    port.replaceState(entryState(route, 0));
  }

  /** Adds an entry showing `route` after the current one, which drops any entries forward of it. */
  push(route: Route): void {
    // A current entry that is not the app's counts as the first, so `stepBack` never leaves it.
    const index = this.#index();
    this.#port.pushState(entryState(route, index === null ? 0 : index + 1));
  }

  /** Rewrites the current entry to show `route`, keeping its index. */
  replace(route: Route): void {
    this.#port.replaceState(entryState(route, this.#index() ?? 0));
  }

  /**
   * Goes back one entry when the current entry is one the app added, and returns whether it
   * did. Its index is above 0 then, so the entry before it is the app's own, in this document:
   * the move reloads nothing and leaves neither the frame nor the loader's page. The browser
   * moves later, and `onPop` reports the route it reached. Otherwise it does nothing and
   * returns false, so a back from the app's first entry never takes the user out of the app.
   */
  stepBack(): boolean {
    const index = this.#index();
    if (index === null || index === 0) return false;
    this.#port.back();
    return true;
  }

  /**
   * Calls `listener` with the route of each of the app's entries the browser moves to, by its
   * back or forward button or by `stepBack`. A move to an entry that is not the app's is
   * ignored. It returns the function that stops it.
   */
  onPop(listener: (route: Route) => void): () => void {
    return this.#port.onPopState((state) => {
      const entry = readEntry(state);
      if (entry !== null) listener(entry.route);
    });
  }

  /** The current entry's index, or null when the current entry is not the app's. */
  #index(): number | null {
    return readEntry(this.#port.state)?.index ?? null;
  }
}

/** The state of an entry that shows `route`, at `index`. */
function entryState(route: Route, index: number): { tbd: RouteEntry } {
  return { tbd: { route, index } };
}
