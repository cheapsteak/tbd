// Filled by plan 6 part 6d
//
// The sheet and menu actions: profiles, switching account, forking, the model, and New.
// Part 6d fills them. Until then each does nothing.
//
// Contract, once filled:
// - `loadProfiles(): Promise<void>` – `profiles.list`, for the account menu and the Switch
//   account and Fork sheets.
// - `switchProfile(profileID): Promise<void>` – `session.switchProfile` on the open session.
// - `fork(profileID): Promise<void>` – `session.fork` on the open session, under `profileID`
//   or, when it is null, the session's own profile. The new tab opens once the list shows it
//   (`openPending` with `{ ref }`).
// - `setModel(model): Promise<void>` – `session.setModel` on the open session.
// - `loadProviders(repoID): Promise<void>` – `remote.providers`, prefilled for `repoID`.
// - `createWorktree(repoID, message): Promise<void>` – `worktree.create`. The new session
//   opens once the list shows it: `openPending` with `{ ref }` when the reply names it, or
//   with `{ worktreeID, toast: 'Created {name}' }` when it does not.
// - `createRemote(params): Promise<void>` – `remote.create`, then `openPending` with `{ ref }`.
// Each resolves once the laptop replied or the request failed. Like every action, none
// rejects (`actions/index.ts`); `superseded` is silent.
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
