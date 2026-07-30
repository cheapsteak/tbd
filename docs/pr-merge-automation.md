# PR merge automation

This doc records how TBD should automate PR merging, and why it does not ship a merge gate of its own. TBD once had one: a compiled `MergeGate` in `Sources/TBDDaemon/Nightwatch/`, backed by a `clearance` ledger and an `audit_log` table, hung off a `PRStatusManager` callback that fired on every PR-status refresh. It was deleted — not because it was disconnected, but because it was **redundant**. Every invariant it tried to hold is already held, better, by the forge. (It was also inert: it built its input from hardcoded placeholders — `headSHA: "unknown"`, `hasApprovedReview: false` — so in production it could only ever escalate, writing audit rows that recorded that one decision over and over and that nobody read.)

Read this before building anything that decides whether a PR may merge.

## Path 1 — Rely on GitHub

This is the answer. Everything TBD's gate was designed to do, branch protection and auto-merge already do, with zero TBD code.

### Branch protection supplies the invariant

The invariant the deleted gate existed to protect was: *an approval must not survive a change to the code it approved.* That is precisely GitHub's **"dismiss stale pull request approvals when new commits are pushed"** setting. Configure on `main`:

- **Required approvals** — how many reviews a PR needs.
- **Dismiss stale approvals on push** — the invariant above. An approval is bound to a head SHA; a new push voids it.
- **Required status checks** — `test`, `Lint`, and `claude-review` (see [`docs/pr-review-gate.md`](pr-review-gate.md)).
- **Block force-push** (and deletion) on the protected branch — otherwise the history a review examined can be rewritten under it.

**CODEOWNERS** covers what the original Nightwatch design called an "impact map": a path glob maps to a required reviewer, so a PR touching a consequential directory cannot merge without that reviewer's approval. It is a checked-in file, edited by a PR, enforced by the forge.

### Auto-merge is the mechanism

A human — *or an agent* — enables auto-merge on an approved PR:

```
gh pr merge --auto --squash <pr>
```

GitHub then merges it later, once every required check and protection is satisfied, and refuses forever if they are not. Enabling auto-merge is a **request**, not a merge.

A **merge queue** closes the remaining stale-base window: it re-tests each PR against the current target head before merging, so a PR that was green against an older base cannot land broken. Turn it on when merge volume makes that window real.

### Where judgment lives

*When* an agent should enable auto-merge is prompt policy, not code. Today the mechanism is per-repo custom instructions: `Repo.customInstructions` (`Sources/TBDShared/Models.swift:16`, edited in `Sources/TBDApp/RepoInstructionsView.swift`), which `SystemPromptBuilder` folds into the spawned session's system prompt and exports as `TBD_PROMPT_INSTRUCTIONS` (`Sources/TBDDaemon/Lifecycle/SystemPromptBuilder.swift:67-70`, `:93`; documented for agents at `Sources/TBDShared/TBDSkillContent.swift:173`). Richer repo-specific merge policy, if it is ever wanted, extends that surface.

**TBD ships no policy.** It carries the operator's text to the agent and stops there.

The one agent that acts on PRs autonomously today is the Watch Desk (`DaywatchRunner` / `DeskSessionManager`) — a Claude session in a tmux pane driving `gh`, `tbd`, and tmux. It is governed entirely by prompt text. That is fine precisely because of the next section.

### Why this is architecturally superior, not merely cheaper

The agent **requests**; the forge **re-verifies and executes or refuses**.

Forge-side enforcement sits *outside the trust boundary of the machine running the agents*. An agent with a shell can invoke `gh pr merge` — but it cannot merge what branch protection refuses, because the decision is made on a machine it does not control, against state it cannot forge. No daemon-side gate can make that claim: the daemon and the agent share a host and a credential, so any agent that can run `gh` can also do whatever the gate could have done, and can bypass the gate entirely by not calling it.

The consequence worth naming: **local policy can add caution but can never widen what protections permit.** It is monotonic by construction. A buggy, stale, or absent local check degrades to "the forge decides" — never to "anything merges."

This is exactly the two-layer contract the original Nightwatch design specified — the requester must never merge, the executor must never trust the requester's view of PR state (§16, [`docs/specs/2026-07-03-nightwatch-daywatch-design.md:796-800`](specs/2026-07-03-nightwatch-daywatch-design.md)) — and never built. GitHub already implements it.

**Merge authorization is out of scope for TBD; it is delegated to the forge.**

## Path 2 — Extend the existing hooks system

Only if Path 1 proves insufficient — and only for *reacting*, never for authorizing.

TBD already has a hook mechanism; do not build a second one. `HookResolver` (`Sources/TBDShared/HookResolver.swift`) resolves a script per event, first match wins, no chaining (`:51-53`):

1. `~/tbd/repos/<repoID>/hooks/<event>` — user-local per-repo, written by the app (`TBDConstants.hookPath`, `Sources/TBDShared/Constants.swift:91`)
2. `<repo>/.worktree-hooks/<event>` — checked into the repo
3. `conductor.json` and `.dmux-hooks/<name>` — deprecated, warn on resolve (`:64-78`)
4. `~/tbd/hooks/default/<event>` — global

Around it: a timeout-bounded executor (`:90-93`), a CLI (`Sources/TBDCLI/Commands/HooksCommand.swift:7`), a settings editor (`Sources/TBDApp/Settings/RepoHooksSettingsView.swift:4`), and user docs at [`docs/worktree-hooks.md`](worktree-hooks.md).

**The machinery exists; the gap is the event vocabulary.** `HookEvent` is `setup`, `preSession`, `archive`, `preMerge`, `postMerge` (`Sources/TBDShared/HookResolver.swift:9-14`) — all worktree-lifecycle. Nothing in it is PR-shaped.

A PR-shaped event would look like the existing ones: an executable named after the event, receiving the payload as environment variables. Sketch, for a `prStatusChanged` event:

| Variable | Value |
| --- | --- |
| `TBD_EVENT` | `prStatusChanged` |
| `TBD_WORKTREE_ID` | UUID of the worktree the PR belongs to |
| `TBD_PR_NUMBER` / `TBD_PR_REPO` | PR identity |
| `TBD_PR_HEAD_SHA` | head SHA the status was computed against |
| `TBD_PR_STATE` | open / merged / closed |
| `TBD_PR_REVIEW_DECISION` | approved / changes requested / review required |
| `TBD_PR_CHECKS_STATE` | passing / failing / pending |

This is precisely the seam `PRStatusManager.onPRStatusComputed` occupied — a callback fired on every computed PR status, which the deleted merge gate hung off. That callback is removed in the same change as the gate. Reintroducing this capability as a hook event would therefore be a **deliberate** design act, with a name, a payload contract, and a doc — rather than the accidental one it was.

**The limit, stated plainly.** A local hook cannot enforce anything an agent with a shell can bypass: it runs on the same machine, with the same credentials, and an agent that never triggers it is unaffected by it. Hooks are for **reacting and notifying** — post a status somewhere, nudge a worktree, write a note. Authorization belongs to the forge.
