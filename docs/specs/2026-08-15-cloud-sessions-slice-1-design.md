# Claude cloud sessions, slice 1 — create, watch, land

**Date:** 2026-08-15
**Status:** Design, not yet implemented.
**Scope:** The first end-to-end path through the cloud-sessions design: create a
cloud session from a repo's `+` menu, see it as a row in that repo's tree, watch
it through a structured transcript (with an attach terminal beside it where the
account is entitled to one), and land it into a local worktree.
**Parent design:** [`2026-08-07-claude-cloud-sessions-design.md`](2026-08-07-claude-cloud-sessions-design.md).
Everything here is downstream of that document and contradicts none of it.
**Also depends on:**
[`2026-08-10-remote-sessions-in-worktree-tree-design.md`](2026-08-10-remote-sessions-in-worktree-tree-design.md)
(adoption, the local/remote boundary, archive composition),
[`../remote-provider-contract.md`](../remote-provider-contract.md) (contract v2),
[`../theory-placement.md`](../theory-placement.md) (the placement battery).

## 1. Summary and non-goals

A **cloud session** is a Claude Code session running on Anthropic's hosted
infrastructure, reachable from `claude --cloud` in a terminal. The parent design
makes such sessions ordinary remote sessions: TBD talks to them through a
provider named `claude-cloud` that is compiled into the daemon rather than
registered as an executable, and a session that resolves to a registered
repository becomes a worktree row in that repository's tree like any other lane.

This slice builds the shortest path that is genuinely useful, end to end:

- **Create.** A cloud session is created from the repository's `+` menu, behind
  a flag that ships off.
- **Appear.** The session is adopted as a worktree row in that repository's
  tree, nested and sorted like every other lane.
- **Watch.** Selecting that row shows a structured transcript of the
  conversation — the same renderer a local lane gets, tool cards and all —
  with an attach terminal beside it.
- **Land.** A row action converts the lane in place from remote to local:
  the branch is checked out on this machine, the row keeps its identity, and
  the conversation resumes in the first pane.

**Done is create → transcript → land.** Attach is implemented and declared, but
whether a given account may attach to a running cloud session is an entitlement
the vendor grants server-side, and it is off by default (§10). On an account
without it the Attach segment is present and shows a call to action naming the
condition, rather than a terminal that dies on connect; on an account with it,
attach works. The slice is complete either way, because the transcript — not
the attach pane — is the watch surface, and it depends on nothing attach needs.

Four things the parent design specifies are deliberately **out of scope here**,
each for a reason that is about sequencing rather than doubt:

- **`.tbd-remotes.json` and its trust-on-first-use gate** (parent design Part 4).
  Repository-declared remotes are a second, independent decision surface with its
  own approval flow; nothing in create-watch-land needs it, because slice 1's
  create is always an explicit per-creation choice.
- **Resolution ladder tiers 2 through 4** (the repository declaration, the user's
  global default, provider `describe` defaults). Tier 1 — the explicit choice in
  the create sheet — always wins and is always available, so the ladder's lower
  tiers add convenience to a surface that already works without them.
- **Archive and unarchive for remote lanes.** `worktree.archive`, `worktree.forget`
  and the auto-archive-on-merge rail each refuse a remote row today, and teaching
  all three the capability composition from the 08-10 design is a self-contained
  piece of work that a lane can live without while it is being watched and landed.
  The one exception is the retirement that follows a successful land, specified
  in §6.
- **Retiring the flat Remote section** (`RemoteSectionView`). It stays as it is.
  Removing it is a sidebar change whose risk is unrelated to anything here, and
  keeping it costs a duplicate surface for sessions that resolve to no registered
  repository — which is what it is for anyway.

**Delivery is one branch and one pull request, opened when the whole path works
end to end.** §9 orders the work to minimize rework, not to produce a sequence of
independently shippable increments; several of the steps below are unobservable
on their own, and splitting them would mean shipping code paths with nothing
behind them.

## 2. The shared model change

This is the foundation, and it is the one piece nothing else can be built on top
of.

`Worktree` gains an optional **origin** field beside `location`:

```swift
public struct WorktreeOrigin: Codable, Equatable, Hashable, Sendable {
    public let provider: String
    public let sessionID: String
}

// on Worktree, beside `location`:
public var origin: WorktreeOrigin?
```

`location` answers *where this lane's files are now*. `origin` answers *which
provider session this lane came from*. A lane that has been landed answers the
first with `.local` and the second with the cloud session it was reconstructed
from, and until this field exists there is nowhere to put that second answer.

**The round trip destroys provenance in both directions today**, so this is not
merely a missing field:

- **Erased on write.** `WorktreeRecord.init(from:)`
  (`Sources/TBDDaemon/Database/WorktreeStore.swift`:86-95) switches on
  `wt.location` and sets `providerName` and `providerSessionID` to `nil` for the
  `.local` case. Writing a landed row through the domain model clears its origin
  columns.
- **Dropped on read.** `WorktreeRecord.toModel()` (same file, :139-143) rebuilds
  `.remote(provider:sessionID:)` only when the stored `location` string is
  `"remote"` **and** both columns are present, and falls through to `.local`
  otherwise — so whatever survived a write is discarded on the way back.

A landed row would therefore round-trip clean, and the sidebar would forget which
cloud session it had reconstructed the moment the daemon reloaded it.

**Why provenance becomes its own field rather than a payload on `.local`.**
`WorktreeLocation` (`Sources/TBDShared/Models.swift`:126-167) is `.local` |
`.remote(provider:sessionID:)`, and `.local` carries no associated values. The two
facts are orthogonal — where the files are now, and which session the lane came
from — and the reason neither can be expressed today is exactly that the enum
conflates them. Keeping `.local` payload-free means every existing `switch` over
`WorktreeLocation` across the daemon and the app compiles untouched; only the
record mapping and the model change. Adding associated values to `.local` would
express the same fact while forcing every match site to be revisited, which is
the more invasive answer to a smaller question.

**No new column, and no migration for this.** `v70_worktree_location`
(`Sources/TBDDaemon/Database/Database.swift`:1231-1238) already added
`providerName` and `providerSessionID`, and `v72_worktree_provider_session_index`
(:1301-1307) indexes the pair non-uniquely where `providerName IS NOT NULL`. What
widens is the **invariant** those columns obey: they are set whenever a row has a
provider session behind it, **past or present**, rather than only alongside
`location = 'remote'`. The record type's own comments on those two properties
(:41-42, "set only alongside location == \"remote\"") state the narrow rule and
are part of the edit.

The mapping becomes symmetric and single-sourced:

- **Write.** `providerName` / `providerSessionID` come from `wt.origin`, whatever
  `wt.location` says. `location` is written from `wt.location` as it is today.
- **Read.** `origin` is reconstructed from the two columns whenever both are
  present. `location` is `.remote(...)` when the stored string is `"remote"` and
  an origin exists, and `.local` otherwise — the existing rule, unchanged.
- **Consistency.** A `.remote` location without a matching origin is a
  programming error, not a state to handle. `Worktree`'s initializer defaults
  `origin` to the location's pair when the caller passes none, so all 158 existing
  construction sites keep compiling and keep satisfying the invariant by
  construction.

`Worktree.providerBinding` (`Models.swift`:264-267) currently derives the pair
from `location` and returns `nil` for a local row. It reads `origin` instead, so
it keeps meaning "the provider session behind this row" across the landing.

The wire format needs nothing new: `Worktree`'s hand-written `CodingKeys` already
carry `locationKind`, `providerName` and `providerSessionID` (`Models.swift`:360),
and the origin rides those same two keys. A landed row encodes as
`locationKind: "local"` with the pair set, which an older peer reads exactly as it
reads a local row today.

Per the shared-model rule, the record change, the `TBDShared` model change, and
the flag's migration (§7) land in one commit, with `origin` optional so existing
rows and existing JSON still decode.

`WorktreeStore.findRemote(provider:sessionID:)` (`WorktreeStore.swift`:579-587)
filters on the two columns directly and never consults `location`, so it keeps
matching a landed row and keeps adoption from minting a second row for a session
whose lane has already landed. That property is why the columns are the right
place for provenance and not merely an available one.

## 3. The compiled `claude-cloud` provider

Most of this is transcription from the parent design's Part 2, restated here only
so this document stands alone. The parent is the authority for the full rules;
nothing below re-decides any of them.

**Why it is compiled.** How to talk to one vendor's session API is a mechanism,
not a theory: there is one API, and no project's convention changes its shape
([`../theory-placement.md`](../theory-placement.md), the two-reasonable-projects
test). Mechanisms compile.

**What `describe` declares.** `contract_versions: [2]` only — nothing exposed
terminates a running cloud session, so the provider cannot implement `stop`, and
major 1 requires it. Capabilities are `send`, `attach`, `transcript`, `land`,
`archive` and `unarchive`; neither `stop` nor `log` is declared. `create_params`
are `repo`, `branch`, `prompt` and `environment`, the last typed `string` because
`describe` answers offline and the set of configured cloud environments is
knowable only from the account.

`describe` is **static and offline**, exactly as the parent design fixes it. It
answers from compiled constants, touches no network, and its answer does not vary
with the signed-in account — including for `attach`, which is declared because the
provider implements it. Whether a given account is permitted to use it is a
separate, runtime question, and §5 is where that is answered.

**Verbs.** `create` runs `claude --cloud "<prompt>"` from the repository
checkout, on a pseudo-terminal, and reads the session id out of what it prints
(below). `list` returns the union of a `claude_cloud_session` ledger (what this
machine started) with discovered sessions, under the parent design's three union
rules: two consecutive complete snapshots retire a resolved ledger row, a
ledger-only row carries `state: "unknown"` rather than a fabricated `running`,
and a discovered row always wins over a ledger row for the same id. `send` posts
one message through `claude -p "<msg>" --cloud <id> --output-format json`,
stripping a single trailing `\r` or `\n` as the submit gesture it is and
preserving interior newlines; the response is
`{"ok": true, "session_id": "…", "url": "…"}`, and `ok` plus a `session_id`
matching the id sent is the success condition. `attach` runs
`claude --cloud <id>` on the pane's PTY. `transcript` reads the server-stored
conversation, cursor-tailed. `land` reports the session's repository and branch
with a `resume_command` of `claude --teleport <id>` and `forks: true`. Create
idempotency is the parent design's: the key and its state are written to the
ledger before the invocation, a pending row is expected during the daemon's
single same-key retry, and a pending row is resolved by the next complete
discovery.

### `create` needs a pseudo-terminal; nothing else does

This is the one place the built-in provider cannot be a plain subprocess. The
vendor CLI refuses `--cloud` creation when stdout is not a terminal, by design
and loudly (§10), so the obvious implementation — spawn `claude`, capture the
pipe, read the id — does not merely degrade, it never works.

The asymmetry is worth stating because it decides where the complexity goes:
**`send`, `land`, `transcript`, `archive` and `unarchive` need no terminal**;
`send`'s `--print` form is explicitly a non-interactive invocation and returns
JSON on an ordinary pipe. Only `create` needs a PTY, and only on the daemon
side — `attach` runs on the pane's own PTY, which the app already allocates.

**The provider allocates the PTY through the engine that already bounds every
other spawn.** `runBoundedProcess`
(`Sources/TBDDaemon/Tmux/BoundedProcessRunner.swift`:283) is what `ProviderRunner`
uses, and it owns the properties this call needs as much as any other: a
watchdog-backed deadline that survives executor starvation, incremental draining
so a chatty child cannot deadlock on a full buffer, and a single-resume guard.
It builds its own `Pipe()`s, so it gains one opt-in stdio mode that substitutes
an `openpty(3)` pair for them, handing the replica to the child as stdin, stdout
and stderr and reading the primary. That is the same allocation
`TmuxControlConnection.start()`
(`Sources/TBDDaemon/Tmux/ControlMode/TmuxControlConnection.swift`:63-111, `openpty`
at :70) already performs for the control-mode connection, including the detail
that matters: the parent closes its copy of the replica after spawn so the
primary sees EOF when the child exits.

A second bounded runner is the alternative, and it is the wrong one — the
deadline discipline in that function took a starvation bug and a regression
suite to get right, and a PTY-shaped copy of it would be a second place for that
to rot.

**PTY mode is create-only, and the reason is a real loss.** A pseudo-terminal is
one file descriptor, so the child's stdout and stderr merge on it. `transcript`
returns its continuation cursor in a stderr envelope precisely so a control
record never mixes into the JSONL data stream, and that separation cannot
survive a PTY. So the mode is opt-in per invocation rather than a property of
the provider, and `create` — which returns no envelope — is the only verb that
sets it.

### Reading the session id out of `create`'s output

`create` is fire-and-forget: it exits 0 immediately without attaching, having
printed three lines naming the created session, its web URL, and the command
that would resume it (§10). There is no JSON form — `--print` is refused
alongside `--cloud` — so those lines are the only channel the id travels on.

The provider strips ANSI control sequences from the captured output and takes
the first token matching `session_[A-Za-z0-9]+`, requiring that every match in
the output name the **same** id. All three printed lines carry it, so a single
distinct id is the healthy case and disagreement is a signal, not noise.

**Reading a command's own stdout is not screen-scraping.** The repository's rule
forbids inferring an agent's state from a rendered terminal screen; this reads
the result line of a non-interactive command TBD itself invoked, which is the
same category as parsing `git`'s output. Nothing here reads a TUI, and nothing
here infers state — liveness and agent state come from `list`, exactly as the
contract requires.

**A parse that finds nothing fails loudly and is classified.** Zero matches, or
more than one distinct id, is a `create` failure: the provider synthesizes exit
code 2 with an error object whose message quotes what it received, which
`ProviderFailureClass.classify` (`Sources/TBDShared/RemoteProvider.swift`:99-103)
reads as `contractBug` and `RemoteProviderManager.recordFailure` turns into
`.error` health with that message on screen. `contractBug` is the honest class:
the built-in provider could not satisfy the contract, and the remedy is a fix to
TBD rather than a retry or a re-authentication.

The ledger is what makes that failure safe. The idempotency key and its state
are written **before** the invocation, so a create whose output could not be
read leaves a `pending` row rather than nothing — and the session, which very
likely exists, is adopted by the next complete discovery through the parent
design's pending-row matching. An unreadable answer costs the provenance link,
never the session.

### The session title comes from discovery, never from what was submitted

The vendor derives a session's title server-side; it is a summary of the opening
instruction, not that instruction's text (§10 records the measured pair). So
nothing in TBD may treat the submitted `prompt` as the lane's name.

Nothing does, and this slice must not change that. Adoption already reads the
title off the provider's own payload:
`RemoteSessionAdopter.displayName(session:)`
(`Sources/TBDDaemon/Remote/RemoteSessionAdopter.swift`:228-232) takes
`session.title` when the provider reports one and falls back to the session id,
and `claude-cloud`'s `create_params` are `repo`, `branch`, `prompt` and
`environment` — no `title` among them, so there is nothing for TBD to have
submitted and nothing to reconcile. The create surface (§9, step 7) therefore
writes no display name of its own; the row's name arrives with the row.

**Create asks for one out-of-band `list`.** Because the row arrives by adoption
rather than being minted by the create call, and the poll loop's interval is 60
seconds (`RemoteProviderManager.pollInterval`), a lane created from the `+` menu
would otherwise sit invisible for up to a minute after a create that already
succeeded. A successful `create` triggers exactly one immediate poll for that
provider, which is the shape `recordAttachExit`
(`Sources/TBDDaemon/Remote/RemoteProviderManager.swift`:479-491) already uses to
refresh state after a locally-observed event, and it is bounded the same way:
one extra `list` per create, never a loop.

**The reserved name.** `claude-cloud` is reserved. A registry entry claiming it is
skipped with a visible flag rather than rejecting the whole file — the loader
(`RemoteProviderRegistry.load`, `Sources/TBDShared/RemoteProvider.swift`:363-377)
currently throws for the entire registry on a duplicate name (:372-374), and two of
its three call sites swallow that, so one bad entry silently removes every
provider. The
reservation is unconditional and does not depend on the flag in §7: a name that
became available when a feature was off, and unavailable when it was turned on,
would change which providers load as a side effect of a toggle.

### How the dispatcher selects the built-in conformance

This is the part that is genuinely new here, because the parent design names the
shape without saying where it attaches.

`RemoteProviderInvoking` (`Sources/TBDDaemon/Remote/ProviderRunner.swift`:42-45)
is a one-method protocol with exactly one production conformance —
`ProviderRunner` (:58), which spawns the registered executable — and exactly one
injection site: `RemoteProviderManager`'s `runner` property (`RemoteProviderManager.swift`:18,
assigned in the initializer at :51-59). Every verb the manager issues goes
through that one property (:122 for `describe`, :260 for `list`, :388 for the
pass-through path).

The built-in provider is a second conformance, and the selection lands at that
single injection site rather than at each call:

```swift
struct ProviderDispatcher: RemoteProviderInvoking {
    let subprocess: any RemoteProviderInvoking   // ProviderRunner
    let builtIns: [String: any RemoteProviderInvoking]

    func run(_ config: RemoteProviderConfig, verb: [String], stdin: Data?,
             timeout: TimeInterval, contractVersion: Int) async throws -> ProviderResult {
        let target = builtIns[config.name] ?? subprocess
        return try await target.run(config, verb: verb, stdin: stdin,
                                    timeout: timeout, contractVersion: contractVersion)
    }
}
```

Three properties make this the right seam:

- **One place decides.** The manager holds a dispatcher instead of a runner and
  is otherwise unchanged, so no verb path grows a "is this the built-in one"
  branch that a later verb could forget.
- **The built-in provider is put through the same machinery.** It synthesizes the
  same `ProviderResult` envelope a subprocess produces, including a fabricated
  exit code, so it passes through `ProviderFailureClass.classify` and the same
  health, auth-banner and staleness handling as an external provider.
- **The test seam is unchanged.** `FakeProviderInvoker`
  (`Tests/TBDDaemonTests/RemoteProviderManagerTests.swift`:21) conforms to the
  same protocol and can stand in either for the subprocess arm or for a built-in
  entry, so cloud behavior is testable with no network and no credential store.

`RemoteProviderConfig` (`Sources/TBDShared/RemoteProvider.swift`:6-14) requires
`exec`, which the built-in provider has no honest value for. The manager
synthesizes a config for the reserved name whose `exec` is the resolved `claude`
executable — resolved daemon-side through a `ClaudeExecutableResolver` in the
shape `CodexExecutableResolver` (`Sources/TBDDaemon/Codex/CodexHomeManager.swift`:343)
already establishes for the other vendor CLI. That value is never used to compose
a verb invocation, because the dispatcher routes the reserved name in-process
before `exec` is read; it exists so the app-side attach path in §5 has a real
path to spawn, and §5 specifies how that path is composed.

**Version negotiation is a prerequisite inside this slice, not an assumption.**
`RemoteProviderManager.describeProvider` currently hard-requires that
`describe.contractVersions` contains `1` (:139-142) and fails the provider with
"no common contract version" otherwise, so a `[2]`-only provider is refused by the
daemon as it stands. That guard becomes an intersection with TBD's own supported
set, taking the highest common major and failing only on an empty intersection.
The negotiated major is stored per provider beside `describes` and reaches all
three emitters of `TBD_CONTRACT_VERSION`:

- `ProviderRunner.run` (`ProviderRunner.swift`:64) — a parameter on
  `RemoteProviderInvoking`, so both conformances receive it.
- `ProviderEventsSupervisor` (`ProviderEventsSupervisor.swift`:253) — the same
  value, threaded when the manager spawns the stream.
- `RemoteAttachTerminalView.attachEnvironment`
  (`Sources/TBDApp/Remote/RemoteAttachTerminalView.swift`:82) — see §5, which is
  where that one is a must-fix rather than a parameter change.

## 4. Routing an adopted lane to a detail pane

An adopted remote row today shows an **empty detail area**. The path is:

`OtherSectionContent` (`Sources/TBDApp/ContentView.swift`:699-721) falls through
its section conditions to `WorktreeDetailAreaView` (:808) whenever a worktree is
selected; that view renders `TerminalContainerView`
(`Sources/TBDApp/Terminal/TerminalContainerView.swift`:29), which at :204 calls
`layoutContent(worktree: LocalWorktree(worktree))`. `LocalWorktree.init?`
(`Sources/TBDShared/LocalWorktree.swift`:34-39) returns `nil` for a row whose
location is remote, so `layoutContent` (:285-300) takes its final arm and renders
the "No terminals" placeholder. There is nothing wrong with any of that — it is
the local/remote boundary doing its job — but it means a cloud lane's own detail
area has nothing to say about the session behind it.

Meanwhile `RemoteSessionDetailView`, which has everything to say about it, is
reachable only through `AppState.selectedRemoteSession`: `DetailSectionHostPager.targetTab`
(`ContentView.swift`:640-649) returns `.remote` whenever that value is non-nil,
which routes to `RemoteSessionHostSlot` (:660-670) and thence to the detail view.
`selectRemoteSession` (`Sources/TBDApp/AppState+Navigation.swift`:305) is the
only writer, and it is called only from the flat section's rows.

**The decision: selecting an adopted cloud row also marks it the selected remote
session, so the detail area swaps to `RemoteSessionDetailView`.**

### The remote selection is derived, not separately maintained

The two selections are kept consistent by making one a function of the other
rather than by writing both at every gesture.

`AppState.selectedWorktreeIDs`'s `didSet` (`Sources/TBDApp/AppState.swift`:224-230)
unconditionally clears `selectedRemoteSession` whenever a worktree becomes
selected. That single line becomes a call to a pure derivation:

```swift
nonisolated static func remoteSelection(
    forSelection ids: Set<UUID>, worktrees: [Worktree]
) -> RemoteSessionSelection? {
    guard ids.count == 1, let id = ids.first,
          let wt = worktrees.first(where: { $0.id == id }),
          case let .remote(provider, sessionID) = wt.location
    else { return nil }
    return RemoteSessionSelection(provider: provider, sessionID: sessionID)
}
```

Single-selection only: a multi-selection has no one session to show, and every
other case — a local row, an empty selection, an unknown id — yields `nil`, which
is exactly today's behavior. The derivation keys on `location`, not on `origin`:
a landed row has an origin but its files are here, so it belongs to the worktree
detail area.

`AppState.reconcileRemoteSelection()` applies that derivation and is called from
**two** places, which is what makes each of the consistency questions answer
itself:

- The `didSet` above, so a selection change re-derives.
- Every path that replaces the worktree list — the connect-time refresh and each
  worktree delta — so a change to a *selected row's own location* re-derives even
  though the selection did not move.

That second call site is what clears the remote-session selection when Land
converts the row. Land does not clear anything itself. The daemon converts the
row and broadcasts it, the app applies the delta, the derivation re-runs, the
selected row is now `.local`, `selectedRemoteSession` becomes `nil`, `targetTab`
returns `.other`, and the detail area is the worktree detail area — which now has
real terminal panes to render, because `LocalWorktree.init?` succeeds. There is no
window in which a lane with local panes is showing a remote session view, and no
second piece of code that has to remember to clear a selection.

The remaining transitions fall out of the same rule:

- **Selecting a different row** — the `didSet` re-derives from the new selection.
- **Deselecting** — an empty set derives `nil`.
- **The row disappearing** — the worktree list no longer contains the id, so the
  derivation finds no row and yields `nil`.
- **The session leaving the provider's inventory** — `pruneRemoteSessionState`
  (`Sources/TBDApp/AppState+Remote.swift`:81-89) already clears
  `selectedRemoteSession` when the selected session is absent from a successful
  refresh, and keeps doing so.
- **The daemon dropping** — `targetTab` checks `isConnected` first and returns
  `.other` regardless of any selection, so a stale remote selection cannot
  survive a disconnect on screen.

### Two selections that are no longer mutually exclusive

An adopted cloud row is selected in `selectedWorktreeIDs` *and* named by
`selectedRemoteSession` at the same time. That combination cannot arise today, so
it needs stating:

- **The sidebar keeps highlighting the worktree row**, because the row's id stays
  in `selectedWorktreeIDs`. Nothing strips it. This is the opposite of the flat
  section's rows, whose ids are stripped back out of the set in the same `didSet`
  (:196-208) precisely because they are not real `Worktree.id`s. An adopted lane's
  id is a real one, and every consumer of `selectedWorktreeIDs` continues to hold.
- **Navigation records a worktree entry**, not a remote-session entry — the
  `recordNavigation(.worktrees(...))` at :230 is unchanged. Back and forward
  replay the worktree selection, and the derivation re-runs on replay, so the
  detail pane comes back with it. The flat section's own entry point keeps
  recording `.remoteSession` entries for sessions that own no row.
- **`selectRemoteSession` is untouched.** It still clears `selectedWorktreeIDs`
  (via `activateRemoteSession`, :350-364) because the sessions it is called for
  have no worktree row to keep selected. The two entry points therefore do not
  fight: one is for lanes, one is for the sessions that never became lanes.
- **Attach keep-alive is unaffected.** `attachedRemoteSelections`
  (`Sources/TBDApp/AppState+RemoteAttach.swift`:150-152) and
  `remoteSessionHostSelection` (:166-168) read `selectedRemoteSession` and the
  recency log exactly as they do now, so a cloud lane joins the bounded keep-alive
  set on the same terms as any other remote session.

### The pager's invariant is preserved

`DetailSectionHostPager` (`ContentView.swift`, doc comment :509-559, declaration at
:560) is
an `NSTabViewController` with `tabStyle = .unspecified` (:578) — an invisible
pager holding exactly three tab items. Two distinct properties depend on that
shape, and this change must break neither:

- **The `.remote` tab item is mounted once and never removed**, so
  `RemoteAttachPager` and every live attach connection it holds survive an
  excursion to a worktree or repo section. Unmounting it would turn "switch back"
  into a full reconnect.
- **The non-selected tab's content view is genuinely detached from the window**
  (`window == nil`), which a SwiftUI `ZStack` with `.opacity(0)` would not do.
  `TBDTerminalView`'s shared click-passthrough `NSEvent` monitor decides whether
  to fire from `window != nil` plus a geometric bounds check rather than from
  SwiftUI hit-testing, so a merely-invisible remote terminal sharing a screen rect
  with a visible page would swallow clicks meant for the other page.

Nothing here adds a tab, removes one, reassigns a host's `rootView`, or
`.id()`-keys anything. The change is confined to which value `selectedRemoteSession`
holds; `targetTab` is a pure function of that value and already routes correctly
once it is set, and its unit tests extend to the new case without new machinery.

## 5. The watch surface

`RemoteSessionDetailView` gains a **Transcript** segment beside Attach and Log.

`RemoteSessionDetailTab` (`Sources/TBDApp/Remote/RemoteSessionDetailView.swift`:11-14)
is a two-case enum today (`attach`, `log`) and gains `transcript`. The four pure
gates that decide what renders live in
`Sources/TBDApp/Remote/RemoteSessionDetailGates.swift` and are unit-tested in
`Tests/TBDAppTests/RemoteSessionDetailGatesTests.swift`:

- `available(capabilities:gone:)` (:40-46) builds the ordered tab list. It gains
  a `transcript` arm, placed **first** — ahead of attach and log — so a provider
  that offers a structured conversation lands the user there rather than in a
  terminal. **Attach is dropped when the session is `gone`; transcript is not** —
  reading a retired session's conversation is still useful, which is exactly the
  reasoning that already keeps `log` available for a tombstoned row.
- `initialTab(available:requested:)` (:55-62) honors a one-shot navigation hint
  when it names an available tab and otherwise takes the list's first entry. It
  needs no change; the new case flows through it, and the ordering above is what
  makes Transcript the landing tab.
- `showsPicker(available:)` (:66-68) renders the segmented control only when there
  is a real choice — `available.count > 1`. No change.
- `showsSendField(capabilities:gone:snapshotFresh:)` (:75-79) is independent of
  the tab list. No change; cloud declares `send`, so the send field renders for a
  live cloud lane with a fresh snapshot.

The picker itself is at `RemoteSessionDetailView.swift`:173-182, the send field
is gated just below it at :186-192, and `RemoteLogTabView` (:607-659) is the
existing read-only scrollback pane the new tab sits beside.

Ordering `transcript` first changes nothing for any provider registered today,
because `transcript` is a v2 capability and no external provider declares it —
the first provider to reach that arm is the built-in one.

**The view's placeholder tab has to stop naming a real tab, or the ordering
above means nothing.** `selectedTab` is `@State` defaulting to `.attach` (:112),
reset to `.attach` on every selection change (:230), and `effectiveTab` (:159-161)
passes it to `initialTab` as `requested` — which honors a requested tab whenever
it is available. So a placeholder that names `.attach` beats the list's own first
entry for any provider that declares attach. It works today only because the
one provider shape that exercises the fallback is `log`-only, where `.attach` is
absent from the list by luck rather than by design, and the doc comment at
:152-158 says as much. `selectedTab` therefore becomes optional with `nil` as the
placeholder, reset to `nil` rather than `.attach`, and the Picker binds through a
computed binding over `effectiveTab`. "No tab has been chosen yet" then has a
representation, and `available`'s ordering decides the landing tab for every
provider rather than for one shape of provider.

**What a cloud lane's picker shows.** Cloud declares `transcript` and `attach`
but not `log`, so `available` returns `[.transcript, .attach]`, `showsPicker` is
true, and the segmented control offers exactly those two, in that order, with
Transcript selected by default. A **gone** cloud lane returns `[.transcript]`
alone — one tab, so no picker renders and the transcript content fills the pane
unconditionally, which is the shape a single-tab provider already gets. A provider
declaring none of the three still reaches the existing empty state.

### The `transcript` data path

`remote.transcript` does not exist. `RPCRouter+RemoteHandlers.swift` has
handlers for providers, sessions, create, stop, send, log, rename, dismiss,
setPin and reportAttachExit (:57, :64, :86, :152, :189, :225, :263, :293, :315,
:341) and nothing else. A new `handleRemoteTranscript` joins them, gated by the
same `remoteGate()` (:25-28) as every sibling.

**The Transcript segment renders through the real structured renderer — the same
tool cards, the same row-height cache, the same overlay a local lane gets.** A
cloud lane has no attach guarantee and no `log`, so the transcript is not a
secondary view of the conversation; it is the *only* watch surface. A degraded
renderer would therefore not be a lesser second opinion, it would be the whole
experience — a wall of prose where a local lane shows an Edit card with a diff, a
Bash card with its command and output, an Agent card that drills into a subagent
thread. That is the argument for paying the seam's cost rather than the simpler
view's.

**The seam already exists one layer down, which is what makes this affordable.**
The renderer proper — `TableTranscriptView`, the view-based `NSTableView` that
hosts one `SelectableTranscriptRow` per cell behind an explicit height cache —
takes render nodes and a `TranscriptCardContext`, and neither mentions a terminal
or a worktree. It already has a **second, non-terminal caller**:
`HistoryPaneView` (`Sources/TBDApp/Panes/HistoryPaneView.swift`:452-471) builds
the same `TranscriptPresentation` and hosts the same table with
`TranscriptCardContext(terminalID: nil, …)`, over messages it fetched by file
path rather than from a terminal. So the cards, the presentation build, the
height cache and the workbench index are already source-agnostic in production,
not merely in principle.

What is terminal-keyed is the pane *above* it.
`TableTranscriptPaneView` (`Sources/TBDApp/Panes/Transcript/Table/TableTranscriptPaneView.swift`:12-14)
takes a `terminalID` and a `worktreeID` and resolves content along one fixed
chain: `appState.terminals[worktreeID]` → the terminal with that id (:67-69) →
`terminal.claudeSessionID` (:71-73) → `appState.sessionTranscripts[sessionID]`
(:75-78). Its poll loop (:264-275) fetches through `terminal.transcript`, keyed on
the same terminal id (:294-295). It is hosted from exactly one place,
`PanePlaceholder.swift`:352, and `PanePlaceholder` takes a `LocalWorktree` (:49).
A cloud lane has no terminal row, no Claude session id, and no `LocalWorktree`,
so that chain cannot serve it.

### The transcript source

`TableTranscriptPaneView` is keyed on a **source** rather than on a terminal:

```swift
enum TranscriptSource: Equatable, Hashable {
    case terminal(terminalID: UUID, worktreeID: UUID)
    case remote(provider: String, sessionID: String)
}
```

Exactly three things in that view are a function of the source, and everything
else in it is untouched:

- **The store key.** `.terminal` walks today's chain to `claudeSessionID`;
  `.remote` is the provider session id verbatim. Both answer with a `String?`,
  and `AppState.sessionTranscripts` is already `[String: [TranscriptItem]]`
  (`AppState.swift`:788) with an LRU eviction keyed the same way (:1068-1087).
  So the remote path is a **third writer into one store**, beside the live pane
  and `AppState+History.swift`:147-152 — not a second store. Every downstream
  consumer of that key — the rollover guard, the LRU touch, the `PaneIdentity`
  the table is `.id()`-keyed on — keeps working unchanged. The two id spaces do
  not overlap (a Claude session id is a UUID, a cloud session id is
  `session_`-prefixed), so one key space stays one key space; the store's
  fifty-entry LRU is shared, which is correct — a cloud transcript the user is
  reading deserves the same residency as a local one.
- **The fetch.** `.terminal` calls `terminal.transcript` with its tail-first
  two-phase open as it does now. `.remote` calls `remote.transcript` with the
  continuation cursor the daemon returned last time, and the daemon answers with
  the full accumulated item list plus the next cursor. The cursor lives daemon-side
  beside the spooled JSONL, not in the view, so it survives the pane being closed
  and reopened and survives a daemon restart.
- **The card terminal.** `TranscriptCardContext.terminalID` is already `UUID?`
  (`TranscriptCardContext.swift`:8). `.remote` supplies `nil`, which is exactly
  what `HistoryPaneView` supplies, and the cards already do the right thing with
  it: the truncation footers that would fetch a longer body over
  `terminal.transcriptItemFullBody` are gated on `terminalID != nil` and simply
  do not render (`GenericToolCardBody.swift`:30 and :47, with the fetches
  guarding again at :72 and :79).

**Hosting needs no new machinery, and `PanePlaceholder`'s `LocalWorktree`
constraint never binds**, because the remote path does not go through
`PanePlaceholder` at all. The Transcript tab hosts `TableTranscriptPaneView`
directly, which is precisely how `HistoryPaneView` hosts the table today. Two
environment values `PanePlaceholder` injects need answers at the new host, and
both are answered by what a remote transcript honestly is:

- **`\.openFilePreview` is not injected.** The Write, Edit and Read cards already
  gate their preview affordance on `openFilePreview != nil`
  (`WriteCardBody.swift`:42 and :45, `EditCardBody.swift`:74 and :77), so a path
  naming a file on another machine offers no button rather than a broken one.
- **`\.openTranscriptOverlay` is injected**, opening
  `overlayCoordinator.open(terminalID: nil, itemID:, sessionID: <session id>)`.
  `TranscriptOverlayView.lookupItem()` already has a second resolution path for
  exactly that shape — no terminal, a session id, items read from
  `AppState.sessionTranscripts` (:321-332) — so drilling into a tool card works
  with no new resolution. The parameter is called `historySessionID` today, which
  names its first caller rather than its meaning: it is the *session-keyed* path,
  and any non-terminal source uses it. It is renamed `sessionID` in this edit
  across its three sites (`TranscriptOverlayCoordinator.swift`:8-18 and :47,
  `TranscriptOverlayView.swift`:329, `HistoryPaneView.swift`:523-529).

**Local file links are suppressed for a remote transcript, and suppressed means
inert.** `overlayFileLinkAction`
(`Sources/TBDApp/Panes/Transcript/OverlayFileLinkAction.swift`:12-24) turns
`tbd-file:` and `file:` URLs into overlay file frames and lets everything else
fall through to the system handler. For a remote transcript both of those
outcomes are wrong — one opens an unrelated local file in the overlay, the other
hands it to Finder — so the action takes an `allowsLocalFiles` flag and returns
`.discarded` for both schemes when it is false. A path that names another
machine's disk does nothing when clicked, which is the only honest behavior
available.

### What the pane shows while it is not yet complete

Three states, and none of them may be silent:

- **Before the first page arrives**, the pane shows the same
  "Waiting for Claude to start the conversation…" empty state the live pane
  already renders before its first fetch (:140-152), so a fresh cloud lane reads
  as loading rather than as empty.
- **When the provider returns an incomplete stream** — a cursor came back and the
  provider has more to give — the pane renders what it has and keeps fetching. It
  never blocks on completeness, because a long conversation's first page is
  useful immediately and the tail is what the user is usually reading anyway.
- **When a fetch fails**, the pane shows the existing error state with a Retry
  button (`TableTranscriptPaneView.swift`:154-175) rather than an empty list. An
  empty transcript and an unreachable provider look identical otherwise, and the
  cloud lane has no second surface to disambiguate them.

**Every delay in this path takes an injected clock.** The pane's poll loop sleeps
through a bare `Task.sleep` carrying a legacy `swiftlint:disable no_raw_task_sleep`
suppression (:272-273); adding a second cadence for the remote source behind that
same suppression would be adding a new violation under cover of an old one. The
loop moves onto `clock: any Clock<Duration> = ContinuousClock()` as the view's
last initializer parameter, defaulted so no call site changes, and the
suppression is deleted rather than duplicated.

**The renderer's existing performance constraints hold unchanged**, and nothing
here relaxes them. Row cards must have no direct `ScrollView` child — the rule
that outlived the original renderer and is enforced by the
`no_scrollview_in_transcript_cards` SwiftLint rule
(`Sources/TBDApp/Panes/Transcript/CLAUDE.md`,
`docs/superpowers/specs/2026-05-23-transcript-card-rework-design.md`) — and the
remote path adds no card of its own, so there is nothing new to violate it. The
height cache measures each row once through `NSHostingController.sizeThatFits`,
and because the remote path feeds the same `TranscriptRenderNode`s through the
same `TranscriptPresentation.build`, it measures cloud rows on exactly the terms
it measures local ones.

**What this costs relative to a second, simpler view.** More of the pane view
changes: a source enum, three branch points inside it, one renamed overlay
parameter, one flag on the file-link action. What it does not cost is a second
renderer — no duplicate row cards to keep in step, no second height-cache story,
no surface where an improvement to a tool card lands in one place and not the
other. The daemon work, the RPC, the cursor and the store writes are identical
under either choice; they are not what the two options differ on.

### Daemon side

`handleRemoteTranscript` invokes the verb, appends stdout to the TBD-owned
transcript root `~/tbd/remote-transcripts/<provider>/<sessionID>/` (path helper in
`TBDConstants`, honoring `TBD_HOME`), stores the cursor returned in the stderr
envelope for the next call, and parses the accumulated file through
`TranscriptParser`. Parsing stays daemon-side, as `session.messages` already does.

`handleSessionMessages` (`RPCRouter+SessionHandlers.swift`:24) is not the model
for this handler and cannot be extended into it: it takes a **file path** from the
caller and constrains it to the Claude projects store (:49-55). A cloud session
has no local file and no Claude session id, so `remote.transcript` takes
`(provider, sessionID)` and resolves the path itself — the caller never names one.

**The parent design's single-choke-point resolver is a prerequisite of this
slice**, not a follow-up. `TranscriptParser` is reached from several handlers that
are not guarded alike, and admitting a second permitted root is only safe where
the boundary is actually checked. The resolver — one function taking an untrusted
path and returning either a validated path under one of the two permitted roots or
a refusal, with `TranscriptParser`'s entry points reachable only through it —
ships before the TBD-owned root is admitted to it.

### Must fix in this slice: attach announces contract major 1

**This is a correctness bug with nothing to do with cloud.** The app-side attach
spawn announces a contract major of `1` unconditionally while the daemon
negotiates one per provider, so the two disagree for any provider that declares
anything but `[1]` — a divergence that is wrong whichever provider is attached,
and would stay wrong if the cloud work were abandoned tomorrow. Cloud is what
makes it reachable, not what makes it wrong.

`RemoteAttachTerminalView.attachEnvironment`
(`Sources/TBDApp/Remote/RemoteAttachTerminalView.swift`:78-84) hardcodes
`env["TBD_CONTRACT_VERSION"] = "1"` at :82. The comment directly above it
(:62-77) already states the hazard: the contract requires the variable on every
invocation, the daemon's two emitters set it, and this is the third and only
app-side spawn site, so a provider that branches on the contract version would see
a different answer for `attach` than for every other verb.

That hazard becomes an actual failure for cloud. The `claude-cloud` provider
declares `contract_versions: [2]` **only** — it cannot implement `stop`, which
major 1 requires — so attaching to a cloud session with this constant in place
hands a v2-only provider a `1`. The app spawns `attach` itself, directly on the
pane's PTY, and never passes through `RemoteProviderInvoking`, so negotiated state
held in `RemoteProviderManager` is invisible to it.

**How the app learns the negotiated major.** `RemoteProviderStatus`
(`Sources/TBDShared/RemoteProvider.swift`:276-296) already crosses the wire on
`remote.providers` carrying `config`, `describe` and `health` (:277-279), and
`RemoteAttachPager` already has the status in hand one frame above the attach view:
at `Sources/TBDApp/Remote/RemoteAttachPager.swift`:58 it looks the status up by
provider name and takes `.config` off it to build the argv. So the status gains
two fields, both read at that same lookup:

- **`contractVersion: Int?`** — the major the daemon negotiated for this provider.
  `attachEnvironment` takes it as a parameter and emits it. Absent (an older
  daemon) falls back to `1`, matching what the constant emits today, which is the
  conservative reading rather than a new behavior.
- **`attachArgv: [String]?`** — the invocation prefix for a provider whose attach
  is not `<exec> [args…] attach <id>`. The app appends the session id and spawns
  it. Absent for every registered provider, where the app keeps composing
  `provider.argv + ["attach", sessionID]` exactly as it does now.

The second field exists because the built-in provider's attach is
`claude --cloud <id>`, and `RemoteProviderConfig.argv + ["attach", sessionID]`
would spell a command the vendor CLI does not have. Synthesizing an `exec` that
happens to compose correctly would be a coincidence that a later flag rename
breaks silently. Trust-wise `attachArgv` is a `resume_command`-class value: it
comes from the daemon's own built-in provider, never from repository content,
which is what the contract's `resume_command` rule permits.

One resolved value per concern, one lookup, no second source of truth. The
regression test that matters is that the negotiated major reaches
`RemoteProviderStatus` and is what the attach environment emits — that path
crosses a process boundary and is the one that would otherwise go on announcing
`1` forever.

### Attach is an entitlement question, not a capability question

Attaching to an existing cloud session is gated per account by the vendor, and
the gate is off by default (§10). The distinction that decides where this lands
in TBD's model:

- **A capability is what a provider implements.** `describe` answers it
  statically and offline, exactly as the parent design fixes it. The built-in
  provider implements `attach` — it knows the command, it composes the argv, it
  spawns on the pane's PTY — so it **declares** `attach`, and `describe` stays
  static. No probe, no network call, no dynamic capability list.
- **An entitlement is a runtime condition of the account.** It is the same kind
  of fact as "this provider's credential expired": nothing about what the
  provider can do, everything about whether this invocation will be permitted
  right now. TBD already has a path for exactly that kind of fact, and it is not
  the capability list.

Making `describe` dynamic would be the wrong answer twice over: it would put a
network call inside a verb the contract requires to answer offline, and it would
make a stable declaration flicker with an account setting — so the Attach tab
would appear and disappear rather than explaining itself.

**So the entitlement rides the provider call-to-action machinery that already
exists.** `RemoteProviderAuthCTAView`
(`Sources/TBDApp/Remote/RemoteProviderAuthCTAView.swift`) is the shared surface
for "a condition a retry cannot fix, with the provider's own words and its own
remediation", rendered from the pure
`RemoteProviderAuthPresentation`
(`Sources/TBDApp/Remote/RemoteProviderAuthPresentation.swift`:70-85) by two
call sites: the session detail pane's `authPrompt`
(`RemoteSessionDetailView.swift`:514-527) and the sidebar provider header's
popover (`RemoteSectionView.swift`:259-260). Its whole reason for existing is
that a user should see an explanation instead of an action that can only fail.

#### How TBD learns the condition

The app spawns attach directly on the pane's PTY, and per the contract and the
no-screen-scraping rule it may not read what that process prints — so the exit
code is the entire signal, and the failing attach exits **1**. Exit 1 is the
contract's catch-all permanent class, which is enough to know *that* retrying is
futile and not enough to know *why*. The "why" has to come from the daemon,
which is where the built-in provider lives.

`markRemoteSessionDetached` (`AppState.swift`:939-957) already reports an
auth-class exit to the daemon fire-and-forget so provider health moves without
waiting for the next 60s poll; the permanent class reports the same way.
`RemoteProviderManager.recordAttachExit` (:479-491) returns early today for
everything but `.authNeeded`, and gains a branch for the permanent class that
records an **attach-scoped block** against that provider.

**That block is deliberately not provider health.** `ProviderHealth.needsAuth`
says the provider itself cannot authenticate, and it has consequences — it
suppresses auto-attach for every session and blocks reconnect
(`AppState+RemoteAttach.swift`:48-59, `RemoteReconnectPolicy.isBlocked`:76-79).
A cloud provider whose `create`, `send`, `list` and `transcript` all work
perfectly is not in that state, and saying so would be a lie that also disables
nothing useful. The block is scoped to attach; the other tabs, the send field
and every non-attach verb are untouched.

`RemoteProviderStatus` therefore gains a third field beside the two above, read
at the same one lookup:

- **`attachBlocked: ProviderAttachBlock?`** — `nil` when attach is expected to
  work, and otherwise a small shared value carrying a title, a message, and an
  optional remediation label and command. Held in memory beside health rather
  than persisted: a daemon restart costs at most one more doomed attach, and a
  stale persisted block would outlive an entitlement the user was granted in
  between.

**The words come from the provider, which is TBD here, and that is consistent
rather than a loophole.** `RemoteProviderAuthPresentation` renders a provider's
message and remediation verbatim and keeps *TBD's own* fallback strings generic,
naming only the contract-level condition. The built-in provider is a provider, so
the entitlement's wording is its message on the same terms an external
provider's would be, and the generic fallbacks stay generic. The CTA's headline
is a literal today (`RemoteProviderAuthCTAView.swift`:31), so the presentation
gains a `title` defaulting to that string — every existing call site unchanged,
and the entitlement case supplying its own. There is no remediation command:
nothing TBD can run turns the entitlement on, so `command` is `nil` and the CTA
renders its label as plain text rather than a button, which it already does
(:57-64).

#### What renders, and what does not get spawned

- **The Attach segment stays in the picker.** The capability is declared and the
  tab list is a function of capabilities, so the segment is present and
  selecting it explains the condition. Removing the segment would leave the user
  wondering why a documented feature is absent.
- **Selecting it shows the CTA in place of the attach slot.** `contentArea`
  already controls attach visibility through `showsAttachSlot` while keeping
  `RemoteAttachPager` itself mounted unconditionally — the invariant its comment
  at :419-437 exists to protect — so the block makes `showsAttachSlot` (:485)
  false for
  this selection and renders the CTA where the terminal would be. No tab is
  added or removed and no host is remounted.
- **No further attach is spawned.** `attachEligibleRemoteSelections`
  (`AppState+RemoteAttach.swift`:48-59) excludes a selection whose provider
  carries an attach block, the same shape as its existing `.needsAuth` guard at
  :52 and
  for the same stated reason: a fresh attach would die on connect.

#### `RemoteAttachExitClass` must stop collapsing permanent into unexpected

`RemoteAttachExitClass.classify` (`Sources/TBDApp/Remote/RemoteAttachExitClass.swift`:33-40)
maps `.permanent`, `.contractBug` and `.transient` all onto `.unexpected`, and
`.unexpected` is the class that **arms automatic reconnect**. An entitlement
failure would therefore be read as a transport blip: retried at 5s, then 10s, 20s
and so on to the 300s cap (`RemoteReconnectPolicy.backoffInterval`:61-67), each
round spawning a process that cannot succeed, and each round worded on screen as
"Attach ended unexpectedly" (`RemoteSessionDetailView.swift`:535-540). It also
happens without the user ever opening the Attach tab, because auto-attach follows
selection rather than the selected tab.

So the class gains the `permanent` case the parent design specifies.
`ProviderFailureClass.permanent` and `.contractBug` map onto it; `.transient`
alone keeps `.unexpected`. Neither of the two is fixed by waiting, which is the
only thing automatic reconnect can offer.

The blocking rule lands in exactly one pure function rather than a fourth state
store. `RemoteReconnectPolicy.isBlocked` (:76-79) already receives the pending
entry, which carries the `exitCode` that created it (:12-26), so a permanent exit
is blocked regardless of provider health and regardless of elapsed time. Nothing
un-blocks it on its own; the explicit Reattach gesture clears the entry outright
(`AppState.swift`:966-970), which is the one path that should be able to try
again. `RemoteAttachTerminalView.isUnexpectedExit` (:50) keeps testing for
`.unexpected` exactly, so a permanent exit is never worded as a surprise.

**This changes reconnect behavior for external providers too, and that is the
point.** Exit 1 is the catch-all for a shim that failed for any reason it did not
classify, so a shim that dies transiently at exit 1 will now wait for a user
gesture instead of coming back on its own. That is a real cost and the right
trade: the contract gives a provider exit 3 to say "transient, retry me", and
retrying forever on the class that means the opposite is the defect. Both
branches are asserted.

#### What is not in this slice

The parent design also specifies a **cached eligibility preflight** — one check
against the undocumented surface at describe time, reflected by disabling the
affordance before anything is spawned, failing open when it cannot run. That
would remove the single doomed attach the exit-driven path spends to learn the
condition. It is not in this slice, because it needs an undocumented endpoint the
rest of slice 1 does not, and its whole benefit is one wasted process per account
per daemon lifetime. The exit-driven path is the floor and needs nothing
undocumented; the preflight is the improvement on top, and the evidence for
promoting it is a user meeting the dead terminal more than once.

## 6. Land

Land is an action on the adopted worktree row, enabled when the row's provider
declares the `land` capability. It converts the row **in place**: `.remote`
becomes `.local`, the git worktree is materialized, and the row keeps its id, its
display name, its PR badge, its position in the tree, and its children. One lane
throughout — landing is where a lane's files arrive on this machine, not where a
second lane begins.

### Row actions are assembled in exactly one place

`Sources/TBDApp/Helpers/RowActionMenu.swift` is the single source of truth for a
worktree row's actions, and it is pure: `items(context:)` (:230-238) branches on
the row's kind into `scratchItems` (:321), `mainItems` (:349-355) or `regularItems`
(:357-390), all as a function of a `Context` value (:105-181) built by
`RowActionMenuActions.context()` (`Sources/TBDApp/Sidebar/RowActionMenuActions.swift`:70-95).
`RowActionMenuActions.run(_:)` (:104-214) runs the side effect for a typed kind,
and the whole thing is mounted from `WorktreeRowView.swift`:468-470 through
`SidebarContextMenu`.

`RowActionMenu.Kind` (:20-52) gains `case land`, and `regularItems` places it in
the first section beside Rename and Archive.

**`RowActionMenu.Context` carries no notion of location, provider or
capabilities today**, so it gains two fields:

- **`isRemote: Bool`** — the row's location is `.remote`. Populated from
  `worktree.location`.
- **`providerCapabilities: [String]`** — the declared capabilities of the row's
  provider, or empty when the provider is unknown. Populated from
  `appState.remoteProviders`, matching on the row's provider name.

Land is offered when both are satisfied: `isRemote && providerCapabilities.contains("land")`.
Following the existing convention that capability-gated items are omitted rather
than grayed out, a remote row whose provider does not declare `land` simply has no
Land item.

### The same `Context` edit fixes a latent silent failure

`regularItems` (:357-390) appends `filesystemActions(context:)` **unconditionally**.
`pathIsEmpty` — which `RowActionMenuActions` populates as `localWorktree == nil`
(:84), and which is therefore true for every remote row — is consulted in exactly
one place in the whole file: the `guard` at :353 inside `mainItems`. So an adopted
remote row today offers "Open in Finder" and "Copy Path", and `run(_:)` silently
does nothing for both, because each arm is written `if let local = localWorktree`
(:111-120). The comment above those arms asserts that "both path actions are
hidden when `pathIsEmpty`, so the nil arm is unreachable through the menu — the
binding is what proves it." That assertion is true for main and creating rows and
false for remote ones, which is precisely how the gap stayed invisible.

The fix belongs in this edit and not in a separate change, for three reasons: it
is the same `Context` and the same two functions; the actions it removes are the
ones a *cloud lane in particular* will be right-clicked with, so shipping Land
next to two dead items would be shipping the bug into the feature; and the failure
is silent, which the repository's review gate treats as its own category.

`filesystemActions` (:309-319) splits by what each action actually needs. Open in
Finder and Copy Path need a directory on this disk and go behind `!pathIsEmpty`.
Copy Link (a deep link keyed on the worktree UUID) and Copy Branch Name need no
directory at all and stay unconditional — a remote lane has a branch worth copying
and a link worth sharing. `mainItems` keeps its own `guard`, so a `.creating` row
still yields an empty menu rather than a partial one.

### What Land does

`run(.land)` calls a new `worktree.land` RPC. The daemon:

1. Loads the row and refuses unless its location is `.remote`.
2. Invokes the provider's `land` verb and validates every returned field per the
   contract before any of it reaches git: `branch` must satisfy the contract's
   conservative ref-name pattern and must not begin with `-`; `remote_url` is only
   ever **compared** against the local repository's configured remote and never
   passed to git as a remote argument, which is what rules out the `ext::`
   transport family and its command execution; `resume_command` is accepted only
   because it came from the daemon's own built-in provider.
3. **Checks every precondition before creating anything**: the local repository's
   configured remote matches `remote_url`, the branch exists on the remote, the
   target worktree path is free, and the branch is not already checked out in
   another worktree — `git worktree add <path> <branch>` refuses to check one
   branch out twice.
4. Materializes the worktree through the existing lifecycle path, checks out the
   branch, and spawns the first pane running `resume_command` —
   `claude --teleport <id>`.

   **That first pane opens on Claude Code's folder-trust prompt**, because a
   freshly materialized worktree is a directory it has never seen (§10). The user
   answers it. TBD does not suppress it, pre-answer it, or type into the pane:
   trusting a checkout just pulled from a remote branch is a security decision,
   and this is the moment to ask. Land is complete when the pane is spawned with
   the resume command.
5. Writes the row: `location` becomes `.local`, `localPath` becomes the real path
   in place of the synthetic `remote://` URI, and `origin` keeps the provider and
   session id — which is what §2 exists for, what keeps `findRemote` from
   re-adopting the session into a fresh row, and what lets the row render where it
   came from.

**A failure at any step leaves the row `.remote` and unchanged.** Preconditions
are checked before anything is created, so there is never a half-built worktree or
a half-converted row, and the lane is exactly as it was.

Landing is always a user gesture and is never triggered by session state.

**After the conversion, the provider session is archived** — one verb call,
because `claude-cloud` declares `archive` and reports `forks: true`, so the work
has moved to this machine and a session nobody will return to should not sit in
the working set. It is never *stopped*, whatever a provider declares: landing is
a "bring this home" gesture, not a teardown, and the remote box may still hold
work that was never pushed. This is the only archive path slice 1 wires; the
row-level archive composition stays out of scope per §1. The archive runs after
the row has already converted and is best-effort: its failure is reported and does
not un-land the lane.

That archive does not travel back to the row. Mirroring a provider's `archived`
flag onto a row's status applies while the row is remote, and the lane is local
now — its filing state is TBD's own from that point.

## 7. The flag

`claude_cloud_enabled` — a new `config` column, **default OFF**. The behavior is
autonomous background polling against a network service, squarely inside the
default-off rule.

**The column is added with no SQL default**, so unset stays a genuine third
state. Migration `v78_config_claude_cloud` calls
`addColumnIfMissing(table:column:type:)` with `defaults:` **omitted** —
`v73_config_queued_prompt` (`Database.swift`:1334) and `v77_config_supervision_enabled`
(:1406) are the precedents, and the long comment above the former states the
reasoning that applies unchanged here. NULL means nobody has chosen; `0` and `1`
mean somebody did.

The shipped default therefore lives in exactly one place:
`ConfigRecord.toModel()` (`Sources/TBDDaemon/Database/ConfigStore.swift`:68-117)
resolving `claude_cloud_enabled ?? claudeCloudEnabledDefault`, where that
parameter defaults to `Config.claudeCloudEnabledDefault` and is overridable in
tests — the same shape `queuedPromptDefault` and `supervisionEnabledDefault`
already take on that function (:68-71), which exists so a test can prove that NULL
*follows* a changed default while an explicit `false` does not. Graduation is a
one-line edit to that constant. It reaches everyone who never touched the toggle
and preserves every explicit opt-out, which matters more here than for most flags,
because this feature calls a network service on a schedule and somebody who turned
it off did so deliberately.

### How it reaches the app

The path is the established one, and it is additive at every hop:

- **`ConfigRecord.toModel()`** resolves the tri-state into `Config.claudeCloudEnabled`.
- **`DaemonCapabilitiesResult`** (`Sources/TBDShared/RPCProtocol.swift`:2622-2733)
  gains the field, built at `RPCRouter.swift`:661-672 beside
  `remoteBackendsEnabled` (:670) and `remoteBackendsLive` (:671). Its hand-written
  `init(from decoder:)` (:2705-2732) decodes it as
  `decodeIfPresent(...) ?? Config.claudeCloudEnabledDefault`, following how
  `queuedPromptEnabled` is decoded rather than the `?? false` the older flags use:
  a daemon that does not send the field cannot serve the feature either, so
  falling through to the shipped default is the honest reading.
- **`AppState.daemonCapabilities`** (`Sources/TBDApp/AppState.swift`:1144) holds
  it. It is fetched on connect (:2389, deliberately before `refreshAll`) and
  re-fetched on config deltas through `refreshDaemonCapabilities()` (:1361-1364),
  called from the `.modelProfilesChanged` handler (:1930) — which the daemon
  reuses for config changes — so a toggle from another client propagates without
  a reconnect.
- **The view site reads it.** The create entry point in §1 is omitted when the
  flag is off, following `queuedPromptEnabled`'s gate
  (`Sources/TBDApp/AppState+Worktrees.swift`:74) and `remoteBackendsEnabled`'s
  toggle and caption (`Sources/TBDApp/Settings/SettingsView.swift`:499-512); the
  new Settings toggle follows `queuedPromptToggle` (:283-292).

### It needs the live/restart distinction

`remoteBackendsEnabled` is paired with `remoteBackendsLive` because the daemon
builds its provider manager only at boot: `Daemon.swift`:496-502 constructs
`RemoteProviderManager` inside `if mockMode == nil, config.remoteBackendsEnabled`,
so a user who flips the flag on without restarting still has a `nil` manager, and
`remoteBackendsLive` is what lets the app say "on, but needs a restart" without
calling a `remote.*` verb and parsing its error string.

**`claude_cloud_enabled` has the same shape and gets the same treatment**, because
the built-in provider is registered into the dispatcher at the same moment, inside
the same boot-time construction. A manager built while the cloud flag was off has
no `claude-cloud` entry at all, and flipping the flag cannot conjure one into a
running actor. So `DaemonCapabilitiesResult` carries `claudeCloudLive` alongside
`claudeCloudEnabled`, and the Settings caption distinguishes the two exactly as
`AppState.remoteBackendsStatusCaption` already does for the outer flag.

### It is a second gate inside the first, never a bypass

Every `remote.*` handler gates on `remoteBackendsEnabled` through `remoteGate()`
(`Sources/TBDDaemon/Server/RPCRouter+RemoteHandlers.swift`:26-29), and cloud is
reached through those same verbs, so `claude_cloud_enabled` is checked **inside**
that gate for invocations naming the reserved provider. Cloud requires both flags.
Tests assert all four combinations, not two.

The two stay separate rather than merging because `remote_backends_enabled` was
written to be *deletable* after soak, on the reasoning that the feature is inert
without a registered provider file. A provider compiled into the daemon is never
inert, so folding this into it would silently convert a disposable flag into a
permanent one. When `remote_backends_enabled` is eventually deleted, its gate is
removed and `claude_cloud_enabled` becomes the sole gate for cloud, with the
external-provider path ungated as the v1 rollout intends — and that deletion
migration leaves `claude_cloud_enabled` untouched, so turning the outer flag off
by deleting it cannot turn cloud on for anyone.

## 8. Testing

Every gated conditional gets a test per branch. All tests run under
`scripts/test.sh`, use the `TBD_HOME` isolation seams, and reach neither the
network nor a real credential store: the vendor transport sits behind an injected
client protocol and credential reads behind an injected seam.
`FakeProviderInvoker` (`Tests/TBDDaemonTests/RemoteProviderManagerTests.swift`:21)
is the seam for provider behavior, standing in for either arm of the dispatcher.
The built-in provider's own vendor-CLI invocations sit behind an injected spawn
seam, so no test runs a real `claude` binary; the PTY-mode assertions below drive
the bounded runner directly with a scripted child of their own, which is the one
place a real process is spawned and it is never the vendor's.

**The flag's three states are distinguishable.** A pre-migration row reads NULL
rather than `0`; a NULL row follows a change to `Config.claudeCloudEnabledDefault`
(asserted through `toModel`'s injectable default parameter); an explicit `false`
survives that same change. All four combinations of `remote_backends_enabled` and
`claude_cloud_enabled` are asserted, including that cloud verbs refuse when the
outer flag is on and the inner one is off. The live/enabled distinction is
asserted separately: a flag turned on after boot reports enabled-but-not-live.

**The model round-trip.** A landed row — `.local` location, origin set — survives
a write and a read with its provider and session id intact, which is the assertion
that would have caught both halves of the current erasure. A `.remote` row still
round-trips as it does now. `findRemote` matches a landed row, so a later snapshot
containing that session adopts nothing new. A row with neither column set reads
back with a `nil` origin and a `.local` location.

**The routing transition on Land.** Selecting an adopted remote row derives a
remote-session selection and routes `targetTab` to `.remote`; the worktree row
stays selected in `selectedWorktreeIDs`. Applying a worktree delta that flips that
same row to `.local` re-derives to `nil` and routes to `.other`, with no
intervening state in which a local row is showing a remote detail view. A
multi-selection including the row derives `nil`. Deselecting derives `nil`. A
disconnect routes to `.other` regardless of the derived value.

**The picker's shape for a `transcript`-without-`log` provider.** `available`
returns `[.transcript, .attach]` for a live cloud lane and `[.transcript]` for a
gone one; `showsPicker` is true in the first case and false in the second;
`initialTab` lands on Transcript in both, with no tab requested — the assertion
that would fail against the `.attach` placeholder, since `.attach` is available
in the first case and would win. A one-shot Log hint against a provider that
does not declare `log` is discarded rather than producing a blank pane, and an
explicit Attach hint is honored. A provider declaring `log` and not `transcript`
behaves exactly as it does now, on both the tab list and the landing tab.

**`create` on a pseudo-terminal.** The bounded runner's PTY mode hands the child
a terminal — asserted by spawning a probe that reports whether its stdout is a
tty and requiring the answer to be yes, with the same probe under the pipe mode
answering no, so the test discriminates rather than merely passing. The deadline,
the incremental drain and the single-resume guard are asserted to hold in PTY
mode as they do in pipe mode, including a child that outruns a pipe buffer and
one that never exits.

**Parsing `create`'s output.** The three-line success form yields the session id.
Output carrying ANSI control sequences around the same three lines yields the
same id. Output naming two different session ids, and output naming none, each
produce a `create` failure classified as `contractBug` with the received text in
the message — never a success with an empty id — and each leaves the ledger row
`pending` so a later complete snapshot can still adopt the session. A create
whose response carries a title unlike the submitted prompt still names the row
from the provider's `title`, and a create never writes a display name of its own.

**The entitlement path.** A permanent attach exit reported to the daemon records
an attach block on that provider and leaves its health untouched, so the send
field, the transcript tab and every non-attach verb stay available. The block
suppresses `showsAttachSlot` for that selection and renders the CTA in its place
while `RemoteAttachPager` stays mounted. `attachEligibleRemoteSelections` drops
a session whose provider carries a block and keeps one whose provider does not.
`RemoteAttachExitClass.classify` returns `.permanent` for exit 1 and exit 2,
`.unexpected` for exit 3, `.authNeeded` for exit 4 and `.clean` for 0 and `nil`;
`isBlocked` refuses a permanent entry against healthy provider health and an
elapsed backoff window, admits a transient one under the same conditions, and
Reattach clears either. A provider with no block behaves exactly as it does now,
reconnect included.

**The provider-fed renderer.** A `.remote` source resolves its store key to the
provider session id and renders the same nodes the local source renders from the
same items, asserted by building both presentations from one fixture and
comparing them. The remote source supplies `terminalID: nil` to the card
context, so no truncation footer renders and no item-full-body RPC is issued
even for an item marked truncated. Opening an item from a remote transcript
resolves through the session-keyed overlay path and finds the item, including one
nested in a subagent thread. A `file:` link in a remote transcript is discarded
rather than pushing a file frame or reaching the system handler, while the same
link in a local transcript still pushes a frame. The first fetch renders the
loading state rather than an empty list, an incomplete stream renders what
arrived and fetches again from the returned cursor, and a failed fetch renders
the error state with Retry rather than an empty list. The poll cadence is driven
through the injected clock in virtual time, with no wall-clock sleep in the test.

**Land's precondition failures each leave the row unchanged.** A remote mismatch,
a branch missing on the remote, an occupied target path, and a branch already
checked out in another worktree are each reported without creating a worktree, and
each leaves the row `.remote` at its synthetic path with its origin, display name,
parent edge and children intact. A `branch` beginning with `-` and an
`ext::`-style `remote_url` are both rejected before reaching git. On success the
same row id comes back `.local` at a real path with everything else preserved and
no second row for the session; the provider session is archived and never stopped;
a failed archive after a successful conversion leaves the row landed and reports.

**Version negotiation.** A provider declaring `[1, 2]` negotiates 2, one declaring
`[1]` negotiates 1, one declaring `[2]` alone negotiates 2 rather than being
refused, and one declaring `[3]` alone is refused with a clear error. All three
emitters agree for a given provider — and the one that matters is the third: the
negotiated major reaches `RemoteProviderStatus` and is what the attach environment
emits, since that path crosses a process boundary. A status without
`contractVersion` yields `1`. A status with `attachArgv` spawns it verbatim plus
the session id; without it, the composed `argv + ["attach", id]` is unchanged.

**Row actions.** A remote row whose provider declares `land` offers Land; one
whose provider does not, or whose provider is unknown, does not. A remote row
offers neither Open in Finder nor Copy Path, and still offers Copy Link and Copy
Branch Name. A local row's menu is byte-identical to what it produces today, and a
`.creating` row still yields an empty menu.

**The dispatcher.** A verb naming the reserved provider is served in-process and
never reaches `ProviderRunner`, so no registered-provider executable is spawned
for it; a verb naming a registered provider still goes through the runner; a
registry entry claiming the reserved name is skipped and flagged while every other
entry in the file still loads, with and without the cloud flag on.

**The transcript boundary.** Every read reaches `TranscriptParser` through the one
resolver; a path under the Claude projects store and a path under the TBD-owned
root are both accepted; anything else is refused, including a traversal that
escapes either root after normalization; the refusal holds for every entry point
alike, so one added later cannot be reached unguarded.

## 9. Work order

**Nothing opens a pull request until the whole path works end to end.** The order
below minimizes rework; it is not a sequence of independently shippable
increments, and several steps are unobservable on their own. Building it as
increments would mean shipping the routing change with nothing to route and the
provider with no flag to gate it.

1. **The shared model change (§2).** Origin field, record mapping, round-trip
   tests. Everything downstream reads provenance, and every later step written
   against the current erasing mapping would have to be rewritten.
2. **Contract v2 negotiation (§3).** Accept a `[2]`-only provider, store the
   negotiated major, thread it to the runner and the events supervisor, publish it
   on `RemoteProviderStatus`. The cloud provider cannot be described at all until
   this lands, so writing it first means writing it against a guard that rejects
   it.
3. **Pseudo-terminal mode in the bounded process runner (§3).** One opt-in stdio
   mode on `runBoundedProcess`, with its deadline, drain and single-resume
   properties re-asserted under it. `create` cannot be written against a pipe at
   all, so writing the provider first would mean writing it against a spawn that
   refuses every invocation.
4. **The transcript-root choke point (§5).** One resolver, every `TranscriptParser`
   entry point behind it. The TBD-owned root cannot be admitted safely before the
   boundary is actually checked.
5. **The flag and its capabilities plumbing (§7).** Migration, record, model,
   `DaemonCapabilitiesResult`, Settings toggle. The provider is constructed behind
   this flag, so the flag exists first or the construction has to be rewired.
6. **The dispatcher and the provider's `describe`, `create` and `list` (§3).**
   Including the ledger table, its union rules, the create-output parse and the
   one out-of-band `list` a successful create triggers. Until a cloud session can
   be created and enumerated there is no row to route, watch or land, so this is
   the step that makes every later one testable by hand.
7. **The create surface.** A repository already has a remote-create entry point:
   `RepoSectionView.newRemoteSessionMenuItem`
   (`Sources/TBDApp/Sidebar/RepoSectionView.swift`:430-444) enumerates
   `appState.remoteProviders` and opens `RemoteCreateSheet` prefilled with the
   repository (:453-462), and the cloud provider joins that list for free once
   the dispatcher registers it. What this step adds is the same entry on the
   repository's `+` button, which today opens `WorktreeProfilePickerView` (:256-268)
   — the affordance a user already reaches for to start a lane. Both entries are
   omitted, not disabled, when the flag is off, matching how capability-gated
   remote items are already omitted rather than grayed out.
8. **Routing (§4).** The derived remote selection and its two call sites. Only
   observable once a cloud row exists, which is why it follows step 6.
9. **The transcript source seam (§5).** Re-key `TableTranscriptPaneView` on a
   `TranscriptSource`, rename the overlay's session parameter, add the
   file-link flag, move the poll loop onto an injected clock — all with the
   local source as the only case that exists. This is a change to a load-bearing
   local rendering path, so it lands and is proven against the path it already
   serves *before* a second source can be blamed for a regression in it.
10. **The watch surface (§5).** The `transcript` verb, the `remote.transcript`
    handler, the remote source arm, the new tab with its gate arm and the
    placeholder-tab change, and — in the same pass, because they share the one
    `RemoteProviderStatus` lookup — the negotiated major, the attach argv and the
    attach block reaching the app, alongside the attach exit-class correction the
    block depends on.
11. **Land (§6).** The `Context` plumbing with the filesystem fix in the same edit,
    the `worktree.land` RPC, preconditions, in-place conversion, and the follow-up
    archive.

Step 11 last because it is the only step that mutates a row's location, so every
earlier step is exercised against a stable lane before the conversion is
introduced into the mix.

## 10. The vendor CLI surface, as measured

Everything in this section is measured behavior of `claude` 2.1.233 on macOS.
The rest of this document is written to it, and each finding's consequence is
stated in the section that owns it; this section is the single record of what
the surface does.

### `create` requires an interactive terminal

`claude --cloud "<description>"` with stdout piped creates nothing and says why:

```
Error: --cloud requires an interactive terminal. Non-interactive invocations (piped stdout, --init-only, --sdk-url) run locally and would silently ignore --cloud. Drop --cloud, or run from a TTY.
```

That is the good failure mode — the CLI refuses rather than quietly running the
work locally under a flag that asked for the cloud — but it means the obvious
provider implementation, spawning `claude` and reading its pipe, does not partly
work. It never works. §3 specifies the pseudo-terminal the provider allocates
for this one verb.

### `create` is fire-and-forget, and answers in three lines of prose

It does not attach. It exits 0 immediately, having printed exactly:

```
Created cloud session: Add probe pong reply
View: https://claude.ai/code/session_01AAAAAAAAAAAAAAAAAAAAAA?from=cli&m=0
Resume with: claude --teleport session_01AAAAAAAAAAAAAAAAAAAAAA
```

There is no structured form — `--print` is refused alongside `--cloud` — so
those lines are the only channel the session id travels on. §3 specifies the
parse and what a change in that format costs.

**The title is derived server-side, not echoed back.** A description of
"transcript persistence probe: reply with the single word pong" comes back
titled "Add probe pong reply". A
cloud session's name is the vendor's summary of the instruction, not the
instruction, so TBD reads it from `list`/discovery and never assumes it matches
what was sent (§3).

### `send` behaves exactly as the parent design specifies

`claude -p "<msg>" --cloud <session_id> --output-format json` returns:

```json
{"ok":true,"session_id":"session_01AAAAAAAAAAAAAAAAAAAAAA","url":"https://claude.ai/code/session_01AAAAAAAAAAAAAAAAAAAAAA?from=cli&m=0"}
```

An ordinary pipe, no terminal needed. The id form is the only valid one: `-p`
with a *description* rather than a session id is refused with "--cloud cannot be
combined with --print", so the argument's meaning is never ambiguous.

### `claude --teleport <id>` exists and prompts for folder trust

The command is available and reaches Claude Code's folder-trust prompt. That is
`land`'s `resume_command` (§6), so the landing path is sound as designed — with
one consequence worth stating rather than discovering: a landed lane's worktree
is a directory Claude Code has never seen, so **the first pane opens on the
folder-trust prompt**.

The user answers it. TBD neither suppresses it nor answers it on the user's
behalf: it is a security decision about a checkout just materialized from a
remote branch, which is exactly the moment the question is worth asking. Land is
complete when the pane is spawned with the resume command; what the agent asks
inside that pane is between the agent and the user.

### Attaching is gated per account, and the gate defaults off

`claude --cloud <session_id>` exits 1 with:

```
Error: Attaching to an existing cloud session is not enabled for your account.
```

The binary gates the attach branch on a server-side feature flag named
`tengu_remote_backend` that defaults off — `let Dt = rt("tengu_remote_backend", !1)`,
consulted before attach is taken — and carries no local override for it. The same
gate is what makes `--cloud` require a description when it is off. §5 specifies
how TBD reads this as an entitlement rather than as a missing capability.

### No local transcript JSONL is written

Across a create and an attach attempt, **zero** new `*.jsonl` files appeared
under either projects root: 4179 files before, 4179 after. Both roots were
checked, because TBD points `CLAUDE_CONFIG_DIR` at a per-profile directory — so
the host store (`~/.claude/projects`) and the profile store
(`$CLAUDE_CONFIG_DIR/projects`) are two different places a session could have
landed.

So **the `transcript` verb carries the entire watch story.** Nothing is seeded
locally for free, and nothing has to be redirected to keep a cloud conversation
out of the local session store. That is why §5's transcript path is the only
source of conversation data, and why the Transcript tab is the watch surface
rather than a convenience beside attach.

Whether a *successful* attach would write one is untested rather than refuted —
attach could not run at all under the account gate above. It is moot for the
default state, since an account without the entitlement never attaches and so
never writes. If the entitlement is granted and an attach does write locally, the
consequence is the parent design's: the attach process must be pointed at the
TBD-owned root, or a cloud conversation surfaces as a local session of whichever
worktree the pane ran in. `handleSessionList`
(`Sources/TBDDaemon/Server/RPCRouter+SessionHandlers.swift`:9-22) resolves a
projects directory from the worktree's path (:16) and hands it to
`ClaudeSessionScanner.listSessions(projectDir:)` (:20), so anything written under
that resolved root is indistinguishable from a local session of that lane.
Pointing attach elsewhere is one environment entry on the attach spawn, and the
TBD-owned root already exists for the verb's output.

## 11. Rejected alternatives

**Provenance as a payload on `WorktreeLocation.local`.** The same fact expressed
in the same enum, which is superficially tidier — one value answers both
questions. Rejected on what it costs to read: `.local` is matched throughout the
daemon and the app, and giving it an associated value makes every one of those
sites a compile error to be revisited, for a question none of them are asking.
The two facts are also genuinely orthogonal — where the files are, and where the
lane came from — and an enum that conflates them will conflate them again the next
time a lane acquires a third kind of history. A separate optional field leaves
every existing match site untouched and confines the change to the record mapping
and the model. The field-evidence signature that would reopen this: a third
location case whose provenance rules differ from `.local`'s, which would make one
optional field the thing that is conflating.

**Teaching the worktree detail area to render remote lanes.** `WorktreeDetailAreaView`
already has the selected worktree in hand, so branching there on location and
rendering the remote view instead of `TerminalContainerView` looks like the
smaller change. Rejected because `DetailSectionHostPager` exists specifically to
keep the remote host mounted across excursions to other sections, and rendering
`RemoteSessionDetailView` inside the `.other` tab would put it back in the tab
that is cheap to recreate on every switch — tearing down `RemoteAttachPager` and
every live attach connection it holds each time the user glances at a repo. It
would also mean two mount points for one view, whose keep-alive behavior would
then differ by which row selected it. Routing the selection instead reuses the
whole existing pager, adds no host, and leaves the detach invariant that protects
against cross-page keystroke leakage exactly where it is.

**A unified create sheet spanning local and remote lanes.** One dialog offering
"local worktree or cloud session" reads well and would put the resolution ladder
in one place. Rejected for this slice because it replaces a working create path
with a new one for every user, including everyone who will never turn the cloud
flag on — the ratio of risk to benefit is backwards when the whole cloud feature
is still behind a default-off flag. The repository's `+` menu is where a lane is
created today, cloud lanes are lanes, and adding an entry to a menu that already
enumerates ways to start one is additive and reversible. A unified sheet becomes
worth building when the resolution ladder's lower tiers land and there is
something for it to resolve; until then it would be a second surface with one
option on it.

**A second, simpler transcript view for remote lanes.** A `RemoteTranscriptTabView`
beside `RemoteLogTabView` — call `remote.transcript`, receive parsed
`TranscriptItem`s, render them in a plain scroll view — touches none of the local
rendering path and would ship sooner. Rejected on what the cloud lane would then
be: a session with no `log`, no attach guarantee, and a transcript that is its
entire watch surface, shown through a renderer with no tool cards. A local lane's
Edit card carries a diff, its Bash card a command and its output, its Agent card a
drill-in to the subagent thread; a cloud lane would get prose in place of every
one of those, which would not read as a lesser second view — it would read as the
feature. Two renderers over one record format is also a standing tax: every tool
card improvement lands in one of them, and the other decays quietly until someone
notices. The cost that made this look attractive is smaller than it appears —
`TableTranscriptView` and its height cache are already source-agnostic and already
serve a non-terminal caller in `HistoryPaneView`, so what has to change is the
resolution above the renderer, not the renderer. The field evidence that would
reopen it: the source seam proving unable to express a provider that reports
something the local path cannot, which would mean the two paths were never one.

**Making `describe` dynamic so `attach` is declared only when the account is
entitled.** The capability list would then tell the exact truth about what is
possible right now, and no CTA would be needed. Rejected because it breaks
`describe`'s defining property — the parent design fixes it as static and
offline — by putting a network round trip inside the one verb that must answer
without one, and because a capability that flickers with an account setting makes
the Attach segment appear and vanish rather than explain itself. Capability
answers what a provider implements; entitlement answers whether this account may
use it, which is the same shape as a credential having expired and belongs on the
same runtime path.

**A per-provider streaming transcript follow instead of cursor polling.** A live
stream would remove the refresh latency the tab has. Rejected on supervision
shape: a per-session stream is one process per session rather than one per
provider, which the contract's `events` design already declined for the same
reason. Cursor polling first; the evidence that would justify a stream is the
polling interval being visibly wrong in use.

**Synthesizing a `RemoteProviderConfig.exec` that composes into the right attach
command.** Setting `exec` to the resolved `claude` path and `args` to `["--cloud"]`
would make `argv + ["attach", sessionID]` almost work, which is the problem — it
would spell `claude --cloud attach <id>`, and any arrangement that did compose
correctly would do so by coincidence, breaking silently the next time either side
changed a flag. An explicit `attachArgv` says what is being spawned instead of
encoding it in the interaction of two fields that mean something else.
