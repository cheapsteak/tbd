# Claude cloud sessions, slice 1 — create, watch, land

**Date:** 2026-08-15
**Status:** Design, not yet implemented.
**Scope:** The first end-to-end path through the cloud-sessions design: create a
cloud session from a repo's `+` menu, see it as a row in that repo's tree, watch
it (attach and transcript), and land it into a local worktree.
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
- **Watch.** Selecting that row shows an attach terminal and a structured
  transcript of the conversation.
- **Land.** A row action converts the lane in place from remote to local:
  the branch is checked out on this machine, the row keeps its identity, and
  the conversation resumes in the first pane.

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
- **Dropped on read.** `WorktreeRecord.toModel()` (same file, :139-144) rebuilds
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

`Worktree.providerBinding` (`Models.swift`:261-266) currently derives the pair
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

**Verbs.** `create` runs `claude --cloud "<prompt>"` from the repository
checkout. `list` returns the union of a `claude_cloud_session` ledger (what this
machine started) with discovered sessions, under the parent design's three union
rules: two consecutive complete snapshots retire a resolved ledger row, a
ledger-only row carries `state: "unknown"` rather than a fabricated `running`,
and a discovered row always wins over a ledger row for the same id. `send` posts
one message, stripping a single trailing `\r` or `\n` as the submit gesture it is
and preserving interior newlines. `attach` runs `claude --cloud <id>` on the
pane's PTY. `transcript` reads the server-stored conversation, cursor-tailed.
`land` reports the session's repository and branch with a `resume_command` of
`claude --teleport <id>` and `forks: true`. Create idempotency is the parent
design's: the key and its state are written to the ledger before the invocation,
a pending row is expected during the daemon's single same-key retry, and a
pending row is resolved by the next complete discovery.

**The reserved name.** `claude-cloud` is reserved. A registry entry claiming it is
skipped with a visible flag rather than rejecting the whole file — the loader
currently throws for the entire registry on a duplicate name, and two of its three
call sites swallow that, so one bad entry silently removes every provider. The
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
assigned from the initializer at :53-59). Every verb the manager issues goes
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
`selectRemoteSession` (`Sources/TBDApp/AppState+Navigation.swift`:305-309) is the
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
  (via `activateRemoteSession`, :351-366) because the sessions it is called for
  have no worktree row to keep selected. The two entry points therefore do not
  fight: one is for lanes, one is for the sessions that never became lanes.
- **Attach keep-alive is unaffected.** `attachedRemoteSelections`
  (`Sources/TBDApp/AppState+RemoteAttach.swift`:134-152) and
  `remoteSessionHostSelection` (:166-168) read `selectedRemoteSession` and the
  recency log exactly as they do now, so a cloud lane joins the bounded keep-alive
  set on the same terms as any other remote session.

### The pager's invariant is preserved

`DetailSectionHostPager` (`ContentView.swift`:509-560 doc comment, :561 onward) is
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

- `available(capabilities:gone:)` (:40-45) builds the ordered tab list. It gains a
  `transcript` arm between attach and log. **Attach is dropped when the session is
  `gone`; transcript is not** — reading a retired session's conversation is still
  useful, which is exactly the reasoning that already keeps `log` available for a
  tombstoned row.
- `initialTab(available:requested:)` (:55-60) honors a one-shot navigation hint
  when it names an available tab and otherwise takes the list's first entry. It
  needs no change; the new case flows through it.
- `showsPicker(available:)` (:66-68) renders the segmented control only when there
  is a real choice — `available.count > 1`. No change.
- `showsSendField(capabilities:gone:snapshotFresh:)` (:75-79) is independent of
  the tab list. No change; cloud declares `send`, so the send field renders for a
  live cloud lane with a fresh snapshot.

The picker itself is at `RemoteSessionDetailView.swift`:173-182, the send field
is gated just below it at :186-192, and `RemoteLogTabView` (:607-659) is the
existing read-only scrollback pane the new tab sits beside.

**What a cloud lane's picker shows.** Cloud declares `transcript` and `attach`
but not `log`, so `available` returns `[.attach, .transcript]`, `showsPicker` is
true, and the segmented control offers exactly those two, in that order, with
Attach selected by default. A **gone** cloud lane returns `[.transcript]` alone —
one tab, so no picker renders and the transcript content fills the pane
unconditionally, which is the shape a single-tab provider already gets. A provider
declaring none of the three still reaches the existing empty state.

### The `transcript` data path

`remote.transcript` does not exist. `RPCRouter+RemoteHandlers.swift` has
handlers for providers, sessions, create, stop, send, log, rename, dismiss,
setPin and reportAttachExit (:57, :64, :86, :152, :189, :225, :263, :293, :315,
:341) and nothing else. A new `handleRemoteTranscript` joins them, gated by the
same `remoteGate()` (:26-29) as every sibling.

**The Transcript segment renders provider JSONL through a simpler path in this
slice, rather than reusing the structured table renderer.** The recommendation is
the cheaper option, and the trade-off is real.

`TableTranscriptPaneView` (`Sources/TBDApp/Panes/Transcript/Table/TableTranscriptPaneView.swift`:12-14)
is terminal-and-session-keyed end to end. It takes a `terminalID` and a
`worktreeID`, and resolves content by looking up the terminal in
`appState.terminals[worktreeID]`, reading `terminal.claudeSessionID` off it, and
indexing `appState.sessionTranscripts` by that session id (:68-79). It is hosted
from exactly one place, `PanePlaceholder.swift`:352, and `PanePlaceholder` takes a
`LocalWorktree` (:49). A cloud lane has no terminal row, no Claude session id, and
no `LocalWorktree`. Making the renderer provider-fed means introducing a second
keying axis through the poll loop, the transcript store, the overlay coordinator
and the row-height cache — a change to a load-bearing local rendering path, which
under the repository's own rules would itself want a default-off flag and a soak.

So slice 1 adds `RemoteTranscriptTabView` beside `RemoteLogTabView`: it calls
`remote.transcript` on appear and on a refresh token, receives already-parsed
`TranscriptItem`s, and renders them with the same `SelectableTranscriptRow` used
by the table renderer, inside a plain scroll view.

**The honest cost.** There are then two renderers over the same record format, so
an improvement to a tool card lands in one and not the other until they converge;
and the remote view has no height cache, so a very long cloud conversation scrolls
less smoothly than a local one. Both are visible, neither is silent, and neither
loses data. The convergence path, when a second provider declares `transcript` or
when a cloud conversation gets long enough to hurt, is to re-key
`TableTranscriptPaneView` on a transcript *source* rather than on a terminal — at
which point the remote view becomes a second caller of one renderer rather than a
second renderer.

Daemon-side, `handleRemoteTranscript` invokes the verb, appends stdout to the
TBD-owned transcript root `~/tbd/remote-transcripts/<provider>/<sessionID>/`
(path helper in `TBDConstants`, honoring `TBD_HOME`), stores the cursor returned
in the stderr envelope for the next call, and parses the accumulated file through
`TranscriptParser`. Parsing stays daemon-side, as `session.messages` already does.

**The parent design's single-choke-point resolver is a prerequisite of this
slice**, not a follow-up. `TranscriptParser` is reached from several handlers that
are not guarded alike, and admitting a second permitted root is only safe where
the boundary is actually checked. The resolver — one function taking an untrusted
path and returning either a validated path under one of the two permitted roots or
a refusal, with `TranscriptParser`'s entry points reachable only through it —
ships before the TBD-owned root is admitted to it.

Because a remote transcript's file paths refer to a different machine, the
renderer suppresses its clickable local file links for remote rows rather than
dead-ending or opening an unrelated local file.

### Must fix in this slice: attach announces contract major 1

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
   branch, and spawns the first pane running `resume_command`.
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
`ConfigRecord.toModel()` (`Sources/TBDDaemon/Database/ConfigStore.swift`:68-116)
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
returns `[.attach, .transcript]` for a live cloud lane and `[.transcript]` for a
gone one; `showsPicker` is true in the first case and false in the second;
`initialTab` lands on Attach in the first and Transcript in the second, and a
one-shot Log hint against a provider that does not declare `log` is discarded
rather than producing a blank pane. A provider declaring `log` and not
`transcript` behaves exactly as it does now.

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
never spawns a subprocess; a verb naming a registered provider still spawns one; a
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
3. **The transcript-root choke point (§5).** One resolver, every `TranscriptParser`
   entry point behind it. The TBD-owned root cannot be admitted safely before the
   boundary is actually checked.
4. **The flag and its capabilities plumbing (§7).** Migration, record, model,
   `DaemonCapabilitiesResult`, Settings toggle. The provider is constructed behind
   this flag, so the flag exists first or the construction has to be rewired.
5. **The dispatcher and the provider's `describe`, `create` and `list` (§3).**
   Including the ledger table and its union rules. Until a cloud session can be
   created and enumerated there is no row to route, watch or land, so this is the
   step that makes every later one testable by hand.
6. **The create surface.** A repository already has a remote-create entry point:
   `RepoSectionView.newRemoteSessionMenuItem`
   (`Sources/TBDApp/Sidebar/RepoSectionView.swift`:430-444) enumerates
   `appState.remoteProviders` and opens `RemoteCreateSheet` prefilled with the
   repository (:453-462), and the cloud provider joins that list for free once
   the dispatcher registers it. What this step adds is the same entry on the
   repository's `+` button, which today opens `WorktreeProfilePickerView` (:256-268)
   — the affordance a user already reaches for to start a lane. Both entries are
   omitted, not disabled, when the flag is off, matching how capability-gated
   remote items are already omitted rather than grayed out.
7. **Routing (§4).** The derived remote selection and its two call sites. Only
   observable once a cloud row exists, which is why it follows step 5.
8. **The watch surface (§5).** The `transcript` verb, the `remote.transcript`
   handler, the new tab and its gate arm, and — in the same pass, because they
   share the one `RemoteProviderStatus` lookup — the negotiated major and the
   attach argv reaching the attach environment.
9. **Land (§6).** The `Context` plumbing with the filesystem fix in the same edit,
   the `worktree.land` RPC, preconditions, in-place conversion, and the follow-up
   archive.

Step 9 last because it is the only step that mutates a row's location, so every
earlier step is exercised against a stable lane before the conversion is
introduced into the mix.

## 10. Rejected alternatives

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

## Open question: does `claude --cloud <id>` write a local transcript?

**Unresolved. This slice is written so it works either way, and the answer changes
only how much the `transcript` verb has to carry.**

Interactive Claude Code sessions always persist to disk — `--no-session-persistence`
is documented as working only with `--print` — so attaching to a cloud session
with `claude --cloud <id>` may already write an ordinary transcript JSONL locally,
under the Claude projects store for whatever directory the pane ran in.

**If it does**, two things follow. Attaching once seeds a session's transcript for
free, so the `transcript` verb becomes the path for *never-attached* sessions
rather than the only path — which makes the verb's cursor-tailing a latency
optimization rather than the sole source of conversation data. And the attach
process **must** be pointed at the TBD-owned transcript root rather than the
default store, or a cloud conversation surfaces as a local session of whichever
worktree the pane ran in: `handleSessionList`
(`Sources/TBDDaemon/Server/RPCRouter+SessionHandlers.swift`:9-22) resolves a
projects directory from the worktree's path (:16) and hands it to
`ClaudeSessionScanner.listSessions(projectDir:)` (:20), so anything the attach
process writes under that resolved root is indistinguishable from a local session
of that lane. Pointing attach elsewhere is one environment entry on the attach
spawn, and the TBD-owned root already exists for the verb's output.

**If it does not**, the `transcript` verb is the only source of conversation data,
the attach pane contributes nothing to it, and no redirection is needed.

Either way the transcript tab reads from the TBD-owned root and never from the
Claude projects store, so nothing in §5 depends on the answer. What depends on it
is whether the attach spawn carries a redirection, and how quickly a
freshly-attached lane's transcript fills in.

**The test that settles it** is one command on a Mac: attach to a cloud session
with `claude --cloud <id>`, then look for a new JSONL file appearing under
`~/.claude/projects/`. It is worth running before step 8 of the work order.
