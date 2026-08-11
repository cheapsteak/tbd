# Remote agent sessions as worktrees in the tree

**Date:** 2026-08-10
**Status:** Approved; not yet implemented.
**Depends on:** [`docs/remote-provider-contract.md`](../remote-provider-contract.md) (contract v1),
[`2026-07-24-remote-agent-backends-design.md`](2026-07-24-remote-agent-backends-design.md) (mirror, RPC family, provider manager),
[`2026-08-01-provider-desk-read-only-design.md`](2026-08-01-provider-desk-read-only-design.md) (Provider Desk).

## Summary

A remote agent session becomes a `Worktree` row. It nests in the sidebar tree
under the lane that spawned it, sorts and reparents like any other row, carries
a PR badge, and archives. `tbd worktree create --provider <name>` creates one,
so an orchestrator lane fans out to a remote box with the command it already
uses locally.

Two facts make this cheaper than it looks. Tree placement is already UI-only —
`--position child|sibling|root` sets `parentWorktreeID` and never affects the
git base — so a parent edge costs nothing but a column. And the parent edge is
TBD-side state the provider never learns about, so the contract needs no new
verb.

The work divides in two. A behavior-preserving refactor introduces
`WorktreeLocation` and a `LocalWorktree` type that makes local-only subsystems
structurally unable to see a remote row. On top of it, remote rows join the
tree, the CLI grows a provider path, and archive gains a remote meaning.

## Why this reverses a v1 non-goal

The remote-backends design lists "making remote sessions appear as worktrees" as
a non-goal and keeps remote sessions a parallel concept — their own model,
their own sidebar section, their own RPC family. That was the right call for
v1: it shipped a working transport, mirror, and attach path without paying for
a model change whose value was speculative.

The value stopped being speculative. Fanning work out across many lanes is
TBD's central workflow, and it runs through the worktree tree and the CLI.
A session that lives outside both can be watched but not orchestrated: it has
no parent, no position, no `tbd worktree` verb, and no place in the hierarchy an
agent reads to understand what it spawned. The only route to a remote box today
transfers an already-pushed branch, which moves an existing task rather than
starting a new lane.

Parallel models also duplicate. Each worktree feature reaching remote sessions
needs a second implementation — a second row view, a second action menu, a
second create sheet — and the two drift. Unification pays that back once.

## Model

### Location on the worktree row

A migration adds three columns to `worktree`, with the GRDB record and the
`TBDShared` Codable model updated in the same commit:

- `location TEXT NOT NULL DEFAULT 'local'`
- `providerName TEXT` — null for local rows
- `providerSessionID TEXT` — null for local rows

They surface as one value:

```swift
public enum WorktreeLocation: Equatable, Sendable {
    case local
    case remote(provider: String, sessionID: String)
}
```

Backfilling `'local'` is correct: every existing row is local. Because the
default states a fact rather than a preference, no later migration has to force
it — the trap `auto_hibernate_enabled` fell into does not apply.

### Two tables, two owners

The `remote_session` mirror keeps its current job unchanged: provider-owned
liveness (`state`, `agentState`, `gone`, `missingCount`, `lastSeen`). The
`worktree` row holds TBD-owned policy — `parentWorktreeID`, `sortOrder`,
`pinnedAt`, `displayName`, `status`, notes — plus the
`(providerName, providerSessionID)` binding that joins them.

Authority splits by kind of fact, and neither side overrides the other. The
party running the process owns liveness; the party the user talks to owns
policy. So **`worktree.status` on a remote row means TBD's own lifecycle
(`active` or `archived`) and never mirrors provider liveness.** A lane whose box
died is `status: active` with `state: exited`. Those are different facts, and a
row that collapses them lies about one of them.

### A worktree row exists exactly when the session resolves to a local repo

`RemoteRepoMatching.resolveRepoID` already maps a session's `meta["repo"]` onto
a registered repo. That resolution decides whether a row exists at all:

- A session TBD created gets a row, stamped with its parent.
- A session created elsewhere — by hand on the box, from another laptop, or by
  a branch transfer — gets a row on first sighting, at top level in its matched
  repo. `tbd worktree reparent` is location-neutral, so it can move under the
  lane that owns it afterwards.
- A session matching no registered repo gets no row and appears only in the
  Provider Desk.

The row is created once at first sighting and never re-derived, matching how
`resolvedRepoID` is already pinned.

## The local/remote boundary

Most of the daemon assumes a worktree has files on this disk. Reaching that
code with a remote row destroys data. `WorktreeLifecycle+Reconcile` is the proof
case: it archives every DB row whose `path` is absent from git's worktree list,
capturing scrollback and killing tmux windows on the way. A remote row's path is
never in that list, so an unguarded reconcile tears down every remote lane on
every sweep. A second loop in the same function rewrites the `tmuxServer` of any
row whose value differs from the repo's canonical name, which a remote row's
empty string always does.

#### What a remote row stores in the local-only columns

`worktree.path` is `NOT NULL UNIQUE`, so a remote row cannot leave it empty:
the empty string admits exactly one remote row per install, and the second lane
of a fan-out aborts on the constraint. A remote row therefore stores a
synthetic `remote://<provider>/<sessionID>` URI, with each component
percent-encoded so the mapping stays injective whatever delimiters a provider
puts in its identifiers. The value is derived inside `WorktreeStore.create`
from the row's `location`, not passed by callers, so it cannot be forgotten at
a new call site. It is visibly not a filesystem path, which means a remote row
that ever reaches path-consuming code fails loudly instead of quietly operating
on the current directory.

`tmuxServer` stays empty on a remote row: there is no tmux server, the column
is not unique, and reconcile's canonicalization loop is fenced from remote rows
anyway.

No one would think to hand-write a guard in reconcile. The boundary therefore
has to be one the compiler enforces.

### Readers break; writers do not

`Worktree` keeps storing a non-optional path, renamed behind the existing
`path:` argument label and `CodingKeys` mapping. All 158 construction sites and
the wire format stay untouched. The stored property becomes:

```swift
public var localPath: String     // stays non-optional; wire key and column stay `path`
```

Non-optional, because making it optional was rejected below on what the
enumeration would produce. The rename alone does the work: every current reader
of `worktree.path` becomes a compile error. That is the
audit: the change enumerates the code that assumes a local checkout without
churning the code that merely builds a row.

### Fix at the fetch, not at the dereference

Readers are then repaired upstream, where the worktree is obtained:

```swift
db.worktrees.get(id:)   → getLocal(id:)    // returns LocalWorktree?
db.worktrees.list(...)  → listLocal(...)   // returns [LocalWorktree]
```

`LocalWorktree` wraps a `Worktree` proven local, exposing `path` and
`tmuxServer` non-optional and forwarding every other member to the wrapped
value through `@dynamicMemberLookup`. Handler bodies do not change: `worktree.id`,
`worktree.branch`, and `worktree.path` all keep compiling.

This works because the daemon obtains worktrees by lookup rather than by
parameter. Only 20 functions in `Sources/` take a `Worktree` parameter, while 57
call sites fetch by id and 31 fetch a list. Converting at the fetch means the
guard lands at a `guard let ... else { throw }` that already exists and already
carries a message, and the caller's caller never learns about it. There is no
outward ripple.

Measured against the tree at the time of writing. Fetch sites, which are what
the change edits:

- 46 of the 57 `get(` sites are local-only and move to `getLocal`
- 11 stay location-neutral: parent resolver, notes, worktree handlers, adopt,
  revive-fresh
- 10 of the 31 `list(` sites live in reconcile alone

Dereferences of a worktree's `path`, which are what the change mostly leaves
alone — 161 in total:

- 128 in `TBDDaemon`, of which 110 sit in local-only subsystems and change
  nothing, because those subsystems now receive a `LocalWorktree`
- 18 daemon lines in location-neutral code, 27 in `TBDApp`, 5 in `TBDCLI`, and 1
  in `TBDShared` are audited individually

App-side sites convert at view boundaries rather than at a fetch, since SwiftUI
views hold a worktree as a stored property. `FileViewerPanel`, `PanePlaceholder`,
and `PinnedTerminalDock` take a `LocalWorktree` from parents that already present
them conditionally. `RowActionMenuActions` and `StatusBarView` replace the
`path.isEmpty` checks they already carry with a real conversion.

`@dynamicMemberLookup` forwards reads but not mutation, so a handler that
mutates a fetched row reaches through `.worktree` explicitly. That residue is
mechanical.

### What becomes unreachable

Terminal spawn, hibernation, archive-as-directory-removal, scratch, the file
viewer, the Claude trust seeder, relocate, forget, adopt-existing-directory, and
reconcile cannot see a remote row — not because someone remembered a guard, but
because `listLocal` does not return one.

## Creation and the CLI

`tbd worktree create` grows `--provider <name>` and a repeatable
`--param key=value`. Existing flags keep working and feed the contract's
well-known parameter names, so the orchestrator case carries no provider-specific
syntax:

```
tbd worktree create --provider agentbox --prompt "implement the retry backoff"
```

`--position` already defaults to `child` and already resolves the parent from
`TBD_WORKTREE_ID`, so a lane fanning out gets nested children for free.

Flags that mean nothing remotely — `--claude-settings`, `--folder` — are
**rejected by name** rather than ignored.

One command serves both locations. A separate `tbd remote create` would re-fork
at the CLI the model this design unifies in the database.

`tbd worktree list` returns remote lanes alongside local ones and reports
`location` in `--json`, which is what lets an orchestrator poll its own fan-out.

### Creation flow

The daemon mints the worktree UUID first and writes a `.creating` row carrying
the parent stamp, sort order, and display name. It then calls `remote.create`
with an idempotency key (existing machinery, including the
retry-once-on-timeout path), and on success flips the row to `.active`, bound
to `(provider, session.id)`. A failed create marks the row `.failed` rather
than deleting it: reconcile is fenced from remote rows, so a remote row needs
an explicit terminal state, and a row that silently vanishes cannot be told
apart from a create that never ran.

Writing the row first is what lets the session know its own identity, below.

### A remote lane knows its own worktree UUID

TBD sets `TBD_WORKTREE_ID` in shells it spawns, and it never spawns a remote
one. Without that variable, nothing running inside a remote lane can use a
`tbd` verb keyed on ambient identity — `tbd link`, `tbd terminal send`, or any
hook that reads it. An orchestrator's remote children would be reachable from
the laptop but unable to act as lanes themselves.

So the minted UUID travels three ways:

- **Out**, on `create`'s stdin as a sibling of `params`:
  `{"params": {…}, "idempotency_key": "…", "tbd": {"worktree_id": "…"}}`. This
  is TBD metadata rather than a create param — it never appears in
  `create_params`, never renders in the create sheet, and `--param` cannot set
  or override it.
- **Into the session**, as `TBD_WORKTREE_ID` in the agent's environment. The
  provider's job.
- **Back**, echoed as `meta["tbd_worktree_id"]` on the Session object.

The echo is what makes the binding self-healing. If the row write fails after a
successful create, adoption reads the echo and recreates the same row id, so
the variable already exported on the box still resolves. Without it, adoption
would mint a second UUID and the box would hold a dangling one.

Both this and the dirty-checkout key are additive within contract v1, and a
provider that implements neither behaves exactly as it does today: no echo
means adoption mints a UUID as usual, and the lane simply is not self-aware.

## Default resolution

Provider defaults exist in the contract as `create_params[].default`, but today
only the SwiftUI create sheet applies them. A CLI calling `remote.create` would
get none, and the two surfaces would resolve one command two ways. Resolution
therefore moves into the `remote.create` handler, where both surfaces reach it.

Most specific wins:

1. **Explicit `--param`, or an edited field in the create sheet.**
2. **The user's `defaults` map** in `~/tbd/agent-providers.json`.
3. **TBD ambient derivation**, for the well-known names only: `repo` from the
   lane's repo, `branch` generated, `prompt`, `title`.
4. **The provider's `describe` default.**

The registry entry grows one optional key, keeping this a user-authored file
with no migration and no DB column:

```json
[{ "name": "agentbox",
   "exec": "/Users/me/.local/bin/agentbox",
   "args": ["provider"],
   "defaults": { "permission_mode": "acceptEdits" } }]
```

A user default outranks ambient derivation. Writing `"branch": "main"` yields
`main`, not a generated `tbd/<slug>`, because the user wrote it deliberately.
One rule covers every field, with no per-name exceptions.

The key structure admits a per-repo layer between 2 and 3 later without a
migration. This design does not build one.

## Lifecycle

### Archive

Archive stops the provider session, then marks the row `archived`. One action,
two effects, on one code path whether triggered by hand, by a row action, or by
`AutoArchiveOnMergeCoordinator` when a PR merges. Stop is idempotent per
contract, so archiving an already-exited lane flips the row and nothing else.

The contract anticipated TBD-side archival and deliberately declined to add a
verb for it. Archive composes the two facts the contract already exposes: the
provider's `stop`, and TBD's own row state.

Archive refuses on an active lane unless forced, paralleling how local archive
refuses on uncommitted changes. Two guards:

- `agentState == .working` — do not tear down a session mid-task by accident.
- A dirty remote checkout, reported through an optional well-known `meta` key.

The second guard exists because TBD cannot see a remote working tree. Stopping a
box session can destroy work that was never pushed, and the `working` guard does
not help: an idle agent sitting on a dirty tree looks safe to stop. A provider
that knows its checkout is dirty reports it; TBD then treats the lane like a
local one with uncommitted changes. Providers that report nothing degrade to a
warning, so the guard is inert until a provider adopts it. It is additive within
contract v1, which lets providers add response fields at any time.

`--force` overrides both.

### Revive

An archived remote lane has no session to return to. Revive is unsupported and
says so. Recreating a session on the same branch and rebinding the row —
the shape `ReviveFresh` already uses locally — is additive and needs no model
change, so it can follow if the absence chafes.

### `gone` and `archived` compose

`archived` is a decision the user made. `gone` is TBD reporting that a session
stopped being listed for two consecutive snapshots. They sit on different axes
owned by different parties, so a row carries both independently:

- **active, present** — a running lane.
- **active, gone** — the lane vanished while being watched. This is the state
  that wants attention, and the reason `gone` exists at all: a session that
  simply stopped being drawn is indistinguishable from a TBD bug.
- **archived, present** — archived, but the provider still lists it. Transient,
  or the stop did not take.
- **archived, gone** — the ordinary end state.

The seven-day tombstone applies to the **mirror row, not the worktree row**. The
mirror entry ages out; the lane stays in the Archived list with its branch and
PR, exactly like an archived local worktree.

A lane that goes `gone` while still `active` stays that way until the user
archives or dismisses it. Nothing mutates it in the background. Auto-archiving
after the tombstone window would save one keystroke per rare event and cost a
background mutation of persisted state, a default-off flag, and a soak.

### Does not apply

Hibernation, relocate, forget, scratch promote, and adopt-existing-directory
have no remote meaning and are unreachable through `LocalWorktree`. Orphan GC
needs no change: it keys on filesystem paths and snapshot refs, and a remote row
has neither.

## Sidebar

`WorktreeRowView` renders remote rows, passing `isRemote: true` — a parameter
`RowStatusIndicator.leading` already accepts, for a `LeadingRowIndicator.remote`
case that already exists. `WorktreeSubtreeView` needs no change: it recurses on
`parentWorktreeID`, so nesting, indentation, the depth cap, drag reorder, and
`sortOrder` all apply to remote children unmodified.

`RepoSectionView.matchedRemoteSessions`, which appends matched sessions after a
repo's local worktrees, retires. Remote lanes are ordinary rows in the same
list, interleaved by `sortOrder`.

### Stating uncertainty

`RemoteSessionPayload.projectedForStaleSnapshot()` demotes a stale row's state to
`unknown`, so a cached `working` value cannot keep rendering as current activity.
In the flat Remote section that demotion reads correctly, because every
neighbouring row is remote. In the tree it does not: a row with no suffix
indicator already means "idle, nothing happening" to every local sibling beside
it, and a demoted remote row would render identically while meaning the
opposite.

A new `SuffixRowIndicator` case therefore renders whenever TBD cannot vouch for
a row's state — `agentState == .unknown`, or a stale provider snapshot. It sits
in the attention slot deliberately: an unreachable box is worth noticing.

`gone` keeps its current visual treatment — dimmed with a dismiss action, which
parallels how archived scratch rows dim — now applied by `WorktreeRowView`.

Provider health renders once at provider level, not per row. Rows say the state
is unknown; the banner says why. This keeps `RemoteProviderStatus` the single
source of freshness that the Provider Desk already established.

### Two surfaces, not three

`RemoteSectionView` retires. The Provider Desk keeps provider health, the
two-axis status strip, and the sessions that resolve to no registered repo.

Selection and attach are unchanged. `RemoteSessionDetailView`,
`RemoteAttachTerminalView`, `RemoteReconnectPolicy`, and the session action menu
key on `(provider, sessionID)`, which the worktree row carries.

## Flag and migration

**No new flag.** Everything here stays inert unless `remote_backends_enabled` is
on and a provider is registered, and local rendering does not change — remote
rows do not exist to render otherwise. A second flag would gate a flag.

The `LocalWorktree` refactor preserves behavior and carries no flag. Its safety
comes from the compiler and from reconcile tests, not from a toggle.

**The migration adds columns and backfills nothing.** Existing mirror rows get
their worktree rows from the adoption path on the next snapshot — code this
design needs anyway, exercising the same path an externally created session
takes. Backfilling in the migration would be a second implementation of adoption
that runs once.

## Testing

All tests run against the existing stub provider fixture, with no network and no
AWS, under `TBD_HOME` isolation.

Boundary, the tests that would have caught the hazard:

- Reconcile leaves remote rows alone: no archive, no terminal teardown, no
  `tmuxServer` rewrite.
- `getLocal`/`listLocal` exclude remote rows; the 11 neutral fetches still
  return them.
- Two remote rows for the same repo both persist — the synthetic path keeps
  `worktree.path`'s UNIQUE constraint from admitting only one remote lane.
- An orphan-GC sweep leaves a remote row intact.

Behavior:

- Parameter resolution honors all four layers, including a user default beating
  ambient derivation.
- Archive stops then archives; refuses on `working`; refuses on a
  provider-reported dirty checkout; flips an already-exited lane without error;
  `--force` overrides both guards.
- Adoption places an unparented session at top level in its matched repo,
  creates no row for an unmatched session, and does not re-derive an existing
  row.
- `gone` and `archived` compose across all four combinations; the mirror
  tombstone does not delete the worktree row.
- Flag off: no remote rows, no provider processes, RPC returns disabled. Flag
  on: the above.

CLI:

- `--provider` with repeated `--param`; local-only flags rejected by name;
  `list --json` reports `location`.

## Rejected alternatives

**A parent edge on the mirror row, leaving remote sessions their own model.**
Cheaper — a column on `remote_session` and a merged child list in the sidebar.
Rejected because every worktree-keyed feature would need a second remote-aware
path or would silently not apply, which is the duplication that motivated
unification.

**Making `path` optional.** The compiler would enumerate all 161 dereferences
and 158 constructors. Rejected on what the enumeration produces: the honest
handling at a local-only site is "this should never have been called", so the
110 daemon lines in local-only subsystems would gain `guard let ... else
{ return }` and turn a design error into a silent no-op.

**Keeping `path` non-optional and guarding at runtime.** Smallest diff, and the
codebase already does this for the short-lived `.creating` placeholder, guarded
ad hoc in three places. Rejected because a permanent state cannot rely on a
transient state's defenses: the guards nobody wrote stop being races never lost
and become ordinary bugs. Reconcile is the demonstration.

**Generating CLI flags from `describe`.** Nicer to type than `--param k=v`, but
help text would vary by which providers are registered, and ArgumentParser wants
a static command shape.

**A synthetic provider node holding unmatched sessions in the tree.** Rejected
because it puts repo-less sessions into a tree organized by repo. The Provider
Desk already holds them.

**Auto-archiving a `gone` lane after the tombstone window.** Rejected for v1:
a background mutation of persisted state needs a default-off flag and a soak to
save one keystroke per rare event.

## Deliberate cuts

No per-repo defaults layer, though the key structure admits one. No revive for
archived remote lanes. No remote file or diff viewing, which needs a `files`
capability the contract does not have. No change to attach, log, send, or the
reconnect policy.
