/**
 * The app's side of the history the loader keeps for it. The shell's navigation asks for an
 * entry to be added or rewritten, or for the back chevron's move, and this turns each into a
 * `HistoryRequest` for the loader (`HostLink.postHistory` in `host.ts`). The loader carries it
 * out, and names the entry the browser lands on in a `route` message, which `main.tsx` passes to
 * `seen` and then to the shell's `onRoute`.
 *
 * Each request carries the move count of the last route message, so the loader can drop one the
 * browser's own move has overtaken: the user swiped back just as a tap asked for an entry.
 */

import type { HistoryRequest } from '../host.ts';
import { encodeRoute } from './routeState.ts';
import type { Route } from './store.ts';

export class HistoryLink {
  readonly #post: (request: HistoryRequest) => void;
  /** The move count of the last route message, 0 before the first. */
  #move = 0;

  /** `post` sends a request to the loader. */
  constructor(post: (request: HistoryRequest) => void) {
    this.#post = post;
  }

  /** Records `move`, a route message's count, for the requests that follow. */
  seen(move: number): void {
    this.#move = move;
  }

  /** Asks for an entry for `route` after the current one. */
  push(route: Route): void {
    this.#post({ op: 'push', state: encodeRoute(route), move: this.#move });
  }

  /** Asks for the current entry to be rewritten to `route`. */
  replace(route: Route): void {
    this.#post({ op: 'replace', state: encodeRoute(route), move: this.#move });
  }

  /** The back chevron: asks the loader to go back one entry, or to show the list. */
  back(): void {
    this.#post({ op: 'back', move: this.#move });
  }
}
