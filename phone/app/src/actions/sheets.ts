// Filled by plan 6 part 6d
//
// The sheet and menu actions: profiles, switching account, forking, the model, and New.
// Part 6d fills them. Until then each does nothing. What they load and what a create waits on
// go in the sheet slice (`state/sheets.ts`), which part 6d fills too; a refused switch or model
// change goes in `ui.refusal`, by `refKey` of the session.
//
// Contract, once filled:
// - `loadProfiles(): Promise<void>` – `profiles.list`, for the account menu and the Switch
//   account and Fork sheets.
// - `switchProfile(profileID): Promise<void>` – `session.switchProfile` on the open session.
// - `fork(profileID): Promise<void>` – `session.fork` on the open session, under `profileID`
//   or, when it is null, the session's own profile. The new tab opens once the list shows it
//   (`openPending` with `{ ref }` and the mark, below).
// - `setModel(model): Promise<void>` – `session.setModel` on the open session.
// - `loadProviders(repoID): Promise<void>` – `remote.providers`, prefilled for `repoID`.
// - `createWorktree(repoID, message): Promise<void>` – `worktree.create`. The new session
//   opens once the list shows it: `openPending` with `{ worktreeID, toast: 'Created {name}' }`
//   and the mark, which opens the new row's first session and toasts "Created <row name>".
//   The reply's `session`, when it has one, is that first session.
// - `createRemote(params): Promise<void>` – `remote.create`, then `openPending` with `{ ref }`
//   and the mark.
// Each resolves once the laptop replied or the request failed. Like every action, none
// rejects (`actions/index.ts`); `superseded` is silent.
//
// A pending open waits only while the user stays put: `openSession` and `back` clear it
// (`PendingOpen` in `state/store.ts`), so a new tab or worktree the user has moved away from
// never pulls them back to it. The user can move before the reply comes, too, while no open
// waits yet. So `fork`, `createWorktree` and `createRemote` each call `self().navMark()` when
// they send the request, and pass that mark to `openPending` with the reply:
// `openPending(p, mark)` does nothing when the user has navigated since the mark.
//
// **Never retry one of these automatically under a new request ID.** Each but the two loads
// acts, and one that failed with `not_confirmed`, `bad_reply`, `internal` or `too_large` may
// have happened all the same (`ACTING_METHODS` in `client/client.ts`): a retry under a new ID
// could restart a session twice, or make a second fork or worktree. Show the error, and leave
// the choice to the user.
//
// The stub: each does nothing, and resolves at once.

import type { PhoneRemoteCreateParams } from '../protocol/types.ts';
import type { ActionContext, Actions } from './index.ts';

export function sheetActions(ctx: ActionContext, self: () => Actions) {
  return {
    async loadProfiles(): Promise<void> {},
    async switchProfile(profileID: string): Promise<void> {},
    async fork(profileID: string | null): Promise<void> {},
    async setModel(model: string): Promise<void> {},
    async loadProviders(repoID: string): Promise<void> {},
    async createWorktree(repoID: string, message: string): Promise<void> {},
    async createRemote(params: PhoneRemoteCreateParams): Promise<void> {},
  };
}
