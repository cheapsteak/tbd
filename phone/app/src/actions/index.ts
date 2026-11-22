/**
 * The app's actions: everything that sends a request, changes the state, or leaves the frame.
 * Components call them through `useActions` (`state/context.tsx`), and `main.tsx` wires the
 * client's callbacks to the shell's (`onEvent`, `onChannelUp`, `onChannelDown`), and the
 * loader's route messages to `onRoute`.
 *
 * Four modules make them, each owned by one part of plan 6: `shell.ts` (6a), `transcript.ts`
 * (6c), `prompts.ts` and `sheets.ts` (6d). Each exports
 * `xActions(ctx: ActionContext, self: () => Actions)`, which returns a plain object of its
 * actions. `self()` gives every action, so a module calls another's through it. `Actions` is
 * built from the four modules' return types, so a part changes its own module's actions
 * without touching another file. Three rules keep that working:
 * - **Annotate every action's return type.** `Actions` comes from the modules' return types,
 *   so an action whose return type is inferred from a `self()` call makes the type circular.
 * - **No two modules share an action name.** The objects are spread into one, so a second
 *   action of the same name would silently replace the first. `shell.test.ts` checks it.
 * - **An action never rejects.** One that returns a Promise resolves once its work has settled,
 *   with every outcome, errors included, put in the store, so a caller needs no `catch`. A
 *   rejection nobody handles is logged by the browser, and the end-to-end tests fail on it.
 *   The client rejects a state request in flight at a drop with `AppError('superseded')`;
 *   that outcome is silent.
 */

import type { AppClient } from '../client/client.ts';
import type { HostLink } from '../host.ts';
import type { HistoryLink } from '../state/historyLink.ts';
import type { Store } from '../state/store.ts';
import { promptActions } from './prompts.ts';
import { sheetActions } from './sheets.ts';
import { shellActions } from './shell.ts';
import { transcriptActions } from './transcript.ts';

export interface ActionContext {
  store: Store;
  client: Pick<AppClient, 'request' | 'stream' | 'lastSeq'>;
  link: Pick<HostLink, 'openLink'>;
  /**
   * The history entries the loader keeps for the app. The shell's navigation asks for one to be
   * added or rewritten, and the back chevron asks the loader to go back; `main.tsx` passes the
   * loader's `route` messages to `onRoute`.
   */
  entries: Pick<HistoryLink, 'push' | 'replace' | 'back'>;
  /** The time in milliseconds, for anything that ages. */
  now: () => number;
  /**
   * Runs `run` once `ms` milliseconds have passed, for anything that waits. Defaults to
   * `setTimeout`; a test passes its own, which runs `run` when the test says, without sleeping.
   */
  after?: (ms: number, run: () => void) => void;
}

export type Actions = ReturnType<typeof shellActions> & ReturnType<typeof transcriptActions>
  & ReturnType<typeof promptActions> & ReturnType<typeof sheetActions>;

/** Every action, from the four modules, sharing `ctx`. */
export function createActions(ctx: ActionContext): Actions {
  let actions: Actions | null = null;
  const self = (): Actions => {
    if (actions === null) throw new Error('TBD phone app: an action ran before createActions returned');
    return actions;
  };
  actions = {
    ...shellActions(ctx, self),
    ...transcriptActions(ctx, self),
    ...promptActions(ctx, self),
    ...sheetActions(ctx, self),
  };
  return actions;
}
