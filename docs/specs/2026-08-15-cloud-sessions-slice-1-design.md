# Claude cloud sessions, slice 1 — create, send, land, archive

**Date:** 2026-08-15
**Status:** Design, not yet implemented.
**Scope:** The first end-to-end path through the cloud-sessions design: create a
cloud session from a repo's `+` menu, see it as a row in that repo's tree, steer
it by sending it messages (with an attach terminal beside the send field where
the account is entitled to one), land it into a local worktree, and archive the
lane when it is done.
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
- **Send.** Selecting that row shows the remote session detail surface, whose
  send field posts a message to the session — the same field every other remote
  provider gets, over the provider's `send` verb. Where the account is entitled
  to it, an attach terminal sits beside it.
- **Land.** A row action converts the lane in place from remote to local:
  the branch is checked out on this machine, the row keeps its identity, and
  the conversation resumes in the first pane.
- **Archive.** A row action retires the lane from the working set, composing over
  what the provider declares, and says honestly what it did and did not do to the
  session behind it (§7).

**Done is create → send → land → archive.** Attach is implemented and declared,
but whether a given account may attach to a running cloud session is an
entitlement the vendor grants server-side, and it is off by default (§11). On an
account without it the Attach pane shows a call to action naming the condition,
rather than a terminal that dies on connect; on an account with it, attach works.
The slice is complete either way — each of those four gestures works without
attach — with one honest consequence: on an unentitled account TBD shows no reply
to a send, because the reply is on Anthropic's servers and nothing supported
reads it back (below).

### What the platform exposes, and what TBD builds against

Three facts about the vendor's surface decide the shape of this slice, and they
are the reason the watch surface is not in it.

- **No supported interface enumerates an account's cloud sessions or reads a
  cloud session's conversation.** The Compliance API's remote-session endpoints
  return Cowork sessions and exclude Claude Code on the web by name. The
  documented `/v1/claude_code/` namespace has a single endpoint, whose token
  grants no read access and no access to account data. Managed Agents is a
  separate product with its own session identifiers rather than a view onto
  these sessions.
- **Undocumented claude.ai endpoints exist, and TBD does not build against
  them.** Anthropic's Consumer Terms bar automated access to the Services
  outside the carve-out for use of an Anthropic API key, and a cloud session
  requires subscription login — so there is no API-key-shaped route to the same
  data, and no arrangement in which such a client is inside the terms. Driving
  those endpoints would put TBD's users outside the terms of the account they
  are signed into, for a feature they can already reach in a browser. This is a
  design constraint rather than a gap awaiting an implementation: `list` is
  ledger-only (§3) because of it, and adding a scraper is not the fix.
- **Interactive attach is gated per account.** The vendor CLI branches on a
  server-side flag (`tengu_remote_backend`) that defaults off and carries no
  local override; the documented remedy is to ask the account team to enable it
  (§11).

What is left is exactly the documented CLI — create, send, resume by teleport,
and attach where the account is entitled — and that is enough for create → send
→ land → archive.

Five things the parent design specifies are deliberately **out of scope here**:

- **The watch surface.** Reading a cloud session's conversation needs an
  interface that does not exist (above), so a lane's transcript is not TBD's to
  render. The parent design's `transcript` verb, the TBD-owned transcript root
  it spools into, and the single-choke-point path resolver that must precede
  admitting a second permitted root all arrive together, with a supported way to
  read a conversation. Until then a cloud lane is watched through the attach
  terminal where the account is entitled to one, and on claude.ai otherwise.
- **`.tbd-remotes.json` and its trust-on-first-use gate** (parent design Part 4).
  Repository-declared remotes are a second, independent decision surface with its
  own approval flow; nothing here needs it, because slice 1's create is always an
  explicit per-creation choice.
- **Resolution ladder tiers 2 through 4** (the repository declaration, the user's
  global default, provider `describe` defaults). Tier 1 — the explicit choice in
  the create sheet — always wins and is always available, so the ladder's lower
  tiers add convenience to a surface that already works without them.
- **Reviving a landed lane onto a fresh branch.** Land plus TBD's existing
  revive-fresh composes into it, and composing them is a second gesture rather
  than a second mechanism.
- **Retiring the flat Remote section** (`RemoteSectionView`). It stays as it is.
  Removing it is a sidebar change whose risk is unrelated to anything here, and
  keeping it costs a duplicate surface for sessions that resolve to no registered
  repository — which is what it is for anyway.

**Delivery is one branch and one pull request, opened when the whole path works
end to end.** §10 orders the work to minimize rework, not to produce a sequence of
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
the flag's migration (§8) land in one commit, with `origin` optional so existing
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
major 1 requires it. Capabilities are `send`, `attach` and `land`. Five
capability names are deliberately **not** declared, and each absence is a fact
about the surface rather than an unimplemented verb:

- **`stop`** — nothing exposed terminates a running cloud session.
- **`log`** — a cloud session has no terminal to scroll.
- **`transcript`** — no supported interface reads a cloud session's conversation
  (§1).
- **`archive` and `unarchive`** — the account's archive operation lives on the
  undocumented surface TBD does not use (§1). Archiving a cloud lane is
  therefore a filing change in TBD alone, which is exactly the third branch of
  the archive composition and is specified in §7.

`create_params` are `repo`, `branch`, `prompt` and `environment`, the last typed
`string` because `describe` answers offline and the set of configured cloud
environments is knowable only from the account.

`describe` is **static and offline**, exactly as the parent design fixes it. It
answers from compiled constants, touches no network, and its answer does not vary
with the signed-in account — including for `attach`, which is declared because the
provider implements it. Whether a given account is permitted to use it is a
separate, runtime question, and §5 is where that is answered.

**Verbs.** `create` runs `claude --cloud "<prompt>"` from the repository
checkout, on a pseudo-terminal, and reads the session id out of what it prints
(below). `list` returns the `claude_cloud_session` ledger — what this machine
started — and nothing else; it is always `complete: false`, which the next
subsection specifies. `send` posts one message through
`claude -p "<msg>" --cloud <id> --output-format json`; the response is
`{"ok": true, "session_id": "…", "url": "…"}`, and `ok` plus a `session_id`
matching the id sent is the success condition. `attach` runs
`claude --cloud <id>` on the pane's PTY. `land` reports the session's repository
and branch with a `resume_command` of `claude --teleport <id>` and `forks: true`.

**`send` implements the contract's byte interface on top of that call.** The
contract's `send` takes stdin bytes destined for a terminal and requires the
caller to append `\r` when it means Enter, and TBD sends a cloud session exactly
the bytes it sends any provider. The provider decodes them as UTF-8, strips a
single trailing `\r` or `\n` as the submit gesture it is, and passes the
remainder as one message — so a byte stream carrying interior newlines becomes
one multi-line message rather than several. What the contract fixes is the
caller's side of the wire; how a provider delivers those bytes to a session with
no terminal is the provider's business, and here it means enqueuing a message.
Exit 0 keeps its contract meaning: handed to the transport, not acted upon.

Create idempotency is the parent design's: the key and its state are written to
the ledger before the invocation, and a pending row is expected during the
daemon's single same-key retry rather than a reason to refuse it. What resolves a
pending row here is the create that wrote it, since the parent design's
discovery-driven resolution has no discovery to run against in this slice: a row
whose create returned a readable session id resolves immediately, and one whose
create failed both attempts stays `pending`, transitions to `failed` after ten
minutes, and is surfaced as an unresolved create the user can act on. The row is
retained rather than deleted on that transition, so the record of a create that
may have started a real session outlives the judgement that it did not.

### `list` is the ledger, and is permanently incomplete

No supported interface enumerates an account's cloud sessions (§1), so `list`
answers from the `claude_cloud_session` ledger alone: one row per session this
machine created, carrying the session id, the idempotency key and its state, the
creation time, the repository path, the branch, and the parameters used. Every
snapshot it returns declares **`complete: false`**, permanently and by
construction, because the ledger is a record of what TBD started and never a
claim about the account's inventory.

**That is safe by construction rather than by care.** The contract's rule for an
incomplete snapshot is that a caller may add, update and adopt on the strength of
it, and must not retire anything on it: no session may be advanced toward `gone`,
and freshness must not be refreshed. A provider that never claims completeness
therefore cannot cause a false retirement however wrong its view is — and a view
consisting only of what this machine started is exactly the case that rule exists
for. The parent design's ledger-retirement rule keys on two consecutive
**complete** snapshots, so it is inert here; a cloud lane leaves the working set
by the user archiving it (§7), which is the gesture that replaces the retirement
discovery would otherwise have driven.

**Honoring `complete` is a prerequisite of this slice, not a later refinement.**
`RemoteSessionStore.applySnapshot`
(`Sources/TBDDaemon/Database/RemoteSessionStore.swift`:176-223) increments
`missingCount` for every row absent from a snapshot (:205-210) and writes the
per-provider freshness key (:216-220) unconditionally, neither of which is
conditioned on completeness today. With a provider whose snapshots are always
incomplete, applying it as written would mark every cloud lane `gone` two polls
after it stopped being the only row returned. So `complete` reaches the store and
splits the three things a snapshot does, per the parent design: an incomplete
snapshot still **adopts** the sessions it sighted and still **clears degraded
health** — the provider answered — while advancing neither `missingCount` nor
freshness in either store.

**Mutations stay available against a provider that never completes a snapshot**,
which the freshness gate already gets right for its own reasons.
`RemoteProviderStatus.isStaleSnapshot`
(`Sources/TBDShared/RemoteProvider.swift`:344-348) is
`health != .ok && (lastSuccessfulSnapshotAt != nil || freshnessUnreadable)`, so a
provider confirmed never to have held a complete inventory is not stale: there
are no cached rows being projected as current, which is the thing staleness
suppresses. Send therefore renders for a cloud lane, and the send gate needs no
cloud-shaped exception.

### What a cloud lane cannot know about itself

Three degradations follow from a ledger-only `list`. Each is stated on screen
rather than papered over, because the alternative in every case is a cheerier
fiction the user would act on.

- **A lane's display name is its session id.** A title only ever arrives from
  discovery, and `RemoteSessionAdopter.displayName(session:)`
  (`Sources/TBDDaemon/Remote/RemoteSessionAdopter.swift`:228-232) already falls
  back to the session id when the provider reports none — which is short, stable
  and honest. The submitted `prompt` is never used as a name (below), so a cloud
  row reads as `session_01…` until the user renames it. Rename is TBD's own
  display name and works on a cloud row exactly as on any other.
- **`agent_state` is always `unknown`, and so is `state`.** The ledger knows a
  session was created; it does not know whether it lives, and the contract is
  explicit that `unknown` means only that no machine-readable state is available
  — never healthy, idle, or finished. The row must therefore not render like an
  idle local lane, and today it would: `RowStatusIndicator.suffix`
  (`Sources/TBDApp/Sidebar/RowStatusIndicator.swift`:125-143) has no case for
  "cannot vouch", and `WorktreeRowView.suffixIcon()`
  (`Sources/TBDApp/Sidebar/WorktreeRowView.swift`:287-313) derives `isWorking`
  from `hasWorkingTerminal`, which a row with no terminals answers `false`. A
  row with no suffix already means "idle, nothing happening" to every local
  sibling beside it. So this slice implements the uncertainty indicator the
  08-10 design specifies — a `SuffixRowIndicator` case rendered whenever TBD
  cannot vouch for a row's state, sitting in the attention slot — because for a
  cloud lane that is the steady state rather than an edge. The leading `.remote`
  marker (`LeadingRowIndicator.remote`, already rendered via
  `RowStatusIndicator.leading(isRemote:)`) keeps saying *where*; the suffix says
  *we do not know what*.
- **Sessions created outside TBD are invisible to it.** A session started on
  claude.ai, from the mobile app, or by `claude --cloud` in a terminal TBD did
  not spawn has no ledger row, so it is never listed, never adopted, and has no
  lane. There is no partial rendering of it to get wrong: it is simply absent,
  and the Settings caption for the flag says so in one sentence, so the absence
  reads as a property of the feature rather than as a bug.

### `create` needs a pseudo-terminal; nothing else does

This is the one place the built-in provider cannot be a plain subprocess. The
vendor CLI refuses `--cloud` creation when stdout is not a terminal, by design
and loudly (§11), so the obvious implementation — spawn `claude`, capture the
pipe, read the id — does not merely degrade, it never works.

The asymmetry is worth stating because it decides where the complexity goes:
**`send`, `list` and `land` need no terminal**; `send`'s `--print` form is
explicitly a non-interactive invocation and returns JSON on an ordinary pipe.
Only `create` needs a PTY, and only on the daemon side — `attach` runs on the
pane's own PTY, which the app already allocates.

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
one file descriptor, so the child's stdout and stderr merge on it. The contract
keeps those channels distinct deliberately — stdout carries the records or the
JSON envelope a verb answers with, stderr carries diagnostics and, for
`transcript`, the continuation cursor that must never mix into the data stream —
and none of that separation survives a PTY. So the mode is opt-in per invocation
rather than a property of the provider, and `create`, whose whole answer is three
lines of prose on stdout, is the only verb that sets it.

### Reading the session id out of `create`'s output

`create` is fire-and-forget: it exits 0 immediately without attaching, having
printed three lines naming the created session, its web URL, and the command
that would resume it (§11). There is no JSON form — `--print` is refused
alongside `--cloud` — so those lines are the only channel the id travels on.

The provider strips ANSI control sequences from the captured output and takes
the first token matching `session_[A-Za-z0-9]+`, requiring that every match in
the output name the **same** id. All three printed lines carry it, so a single
distinct id is the healthy case and disagreement is a signal, not noise.

**Reading a command's own stdout is not screen-scraping.** The repository's rule
forbids inferring an agent's state from a rendered terminal screen; this reads
the result line of a non-interactive command TBD itself invoked, which is the
same category as parsing `git`'s output. Nothing here reads a TUI, and nothing
here infers state — liveness and agent state are whatever `list`'s payload
reports, which for a ledger row is `unknown` (above), exactly as the contract
requires.

**A parse that finds nothing fails loudly and is classified.** Zero matches, or
more than one distinct id, is a `create` failure: the provider synthesizes exit
code 2 with an error object whose message quotes what it received, which
`ProviderFailureClass.classify` (`Sources/TBDShared/RemoteProvider.swift`:99-103)
reads as `contractBug` and `RemoteProviderManager.recordFailure` turns into
`.error` health with that message on screen. `contractBug` is the honest class:
the built-in provider could not satisfy the contract, and the remedy is a fix to
TBD rather than a retry or a re-authentication.

The ledger is what keeps that failure from being silent. The idempotency key and
its state are written **before** the invocation, so a create whose output could
not be read leaves a `pending` row rather than nothing, carrying the repository,
the branch and the prompt that were submitted. With no discovery to match such a
row against, nothing adopts the session later, so the row is what the user is
shown: a create that may well have started a real session TBD cannot name. It
names what was asked for and links to claude.ai, where the session — if it
exists — is listed. An unreadable answer costs the lane, not silently but
visibly, and the parent design's pending-row adoption arrives with discovery.

### The lane's name is never what was submitted

The vendor derives a session's title server-side; it is a summary of the opening
instruction, not that instruction's text (§11 records the measured pair). So
nothing in TBD may treat the submitted `prompt` as the lane's name.

Nothing does, and this slice must not change that. Adoption reads the title off
the provider's own payload: `RemoteSessionAdopter.displayName(session:)`
(`Sources/TBDDaemon/Remote/RemoteSessionAdopter.swift`:228-232) takes
`session.title` when the provider reports one and falls back to the session id,
and `claude-cloud`'s `create_params` are `repo`, `branch`, `prompt` and
`environment` — no `title` among them, so there is nothing for TBD to have
submitted and nothing to reconcile. A ledger row reports no title at all, so the
fallback is what every cloud lane wears until the user renames it (above). The
create surface (§10, step 7) writes no display name of its own; the row's name
arrives with the row.

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
reservation is unconditional and does not depend on the flag in §8: a name that
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

## 5. Steering, and getting attach ready

Selecting an adopted cloud row shows `RemoteSessionDetailView` (§4). Two things
render there in this slice: the **send field**, which is how a user steers the
session, and the **Attach** pane, which works where the account is entitled to
it and explains itself where it is not.

### The send field is the steering path

`showsSendField(capabilities:gone:snapshotFresh:)`
(`Sources/TBDApp/Remote/RemoteSessionDetailGates.swift`:75-79) gates the field on
three things — the provider declaring `send`, the session not being `gone`, and
the provider's snapshot not being stale — and the view renders it from that gate
at `Sources/TBDApp/Remote/RemoteSessionDetailView.swift`:186-192. All three hold
for a cloud lane: cloud declares `send`; a cloud lane is never `gone`, because
retiring a session takes a complete snapshot and there is never one; and a
provider that has never held a complete inventory is not stale (§3 argues both).
So the field renders for every live cloud lane, and the gate needs no
cloud-shaped exception.

What the field posts travels the ordinary path. The app sends the same bytes it
sends any provider through `remote.send`
(`Sources/TBDDaemon/Server/RPCRouter+RemoteHandlers.swift`:189); the provider
implements the contract's byte interface on top of
`claude -p "<msg>" --cloud <id> --output-format json` (§3 specifies the byte
handling, §11 records the measured call and its response).

**What happens after a send is the honest limit of this slice.** There is no
reply for TBD to render: the conversation lives on Anthropic's servers and no
supported interface reads it (§1). So a successful send confirms the message was
accepted and says where the answer will appear — in the attach terminal on an
entitled account, and on claude.ai otherwise, at the session URL the send
response itself returns (§11). It never implies TBD will show the answer, and the
send field is not styled as one half of a conversation view.

### What the tab list comes to for a cloud lane

`RemoteSessionDetailTab`
(`Sources/TBDApp/Remote/RemoteSessionDetailView.swift`:11-14) is `attach` and
`log`, and `available(capabilities:gone:)`
(`Sources/TBDApp/Remote/RemoteSessionDetailGates.swift`:40-45) builds the tab
list from the provider's declared capabilities. Cloud declares `attach` and not
`log`, so the list is `[.attach]` — a single entry, so `showsPicker` (:66-68) is
false and the attach content fills the pane with no segmented control, which is
the shape a single-tab provider already gets. None of the four gates changes
here; the cloud provider is a third capability shape flowing through them
unmodified.

The one case worth naming is a **gone** cloud lane, which drops attach and leaves
the tab list empty, reaching the view's existing "doesn't support attach or a log
view" empty state. That state is not reachable in practice, since nothing retires
a cloud session (§3), and it is the right answer if it ever is: with attach gone
there is genuinely nothing to put in the content area, while the row itself goes
on saying what it knows.

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
the gate is off by default (§11). The distinction that decides where this lands
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
A cloud provider whose `create`, `send`, `list` and `land` all work perfectly is
not in that state, and saying so would be a lie that also disables nothing
useful. The block is scoped to attach; the send field and every non-attach verb
are untouched.

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

- **Attach stays in the tab list.** The capability is declared and the tab list
  is a function of capabilities, so the tab is present — for a cloud lane it is
  the only one, rendered without a picker — and it explains the condition.
  Dropping it would leave the user wondering why a documented feature is absent.
- **The pane shows the CTA in place of the attach slot.** `contentArea`
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

#### The exit-driven path is the whole of what is available

The parent design also describes a **cached eligibility preflight** — one check
at describe time, reflected by disabling the affordance before anything is
spawned, failing open when it cannot run — which would save the single doomed
attach the exit-driven path spends to learn the condition. That check has no
supported interface behind it: the only surface that answers it is the
undocumented one TBD does not build against (§1). So the exit-driven path is not
a floor beneath a planned improvement; it is what a supported interface allows,
and it costs one process per account per daemon lifetime to learn a fact the
vendor exposes no other way.

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
   freshly materialized worktree is a directory it has never seen (§11). The user
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

**After the conversion, the cloud session keeps running, and the lane says so.**
`land` reports `forks: true`, so the landed checkout and the session diverge from
this moment; the parent design's answer to that is to retire the session where
the provider can, and to leave it running and say so where it cannot. Cloud
cannot: it declares neither `archive` nor `stop` (§3), so there is nothing to
call. The landed row therefore carries its origin (§2) and states plainly that
the session it came from is still in the account's working set, where the user
can archive it on claude.ai. TBD never *stops* a session on landing whatever a
provider declares — landing is a "bring this home" gesture, not a teardown, and
the remote box may still hold work that was never pushed.

Nothing about the session travels back to the row after the conversion. A row
whose files are on this machine takes its status from TBD alone, whatever a
provider later reports about the session that row once ran on.

## 7. Archiving a remote lane

Archive retires a lane from the working set, and a cloud lane needs the gesture
more than a local one does: nothing else takes it out of the tree. Retirement
driven by the provider needs a complete snapshot and there is never one (§3), so
a cloud lane that has been landed, abandoned, or answered stays in the active
tree until a person files it away.

**TBD offers that gesture today and refuses it.** `RowActionMenu.regularItems`
(`Sources/TBDApp/Helpers/RowActionMenu.swift`:357-390) puts Archive in the first
section of every non-scratch, non-main row's menu, gated only on
`hasActiveChildren`, so an adopted remote row shows it; `run(.archive)`
(`Sources/TBDApp/Sidebar/RowActionMenuActions.swift`:184-186) calls
`AppState.archiveWorktree`, which calls `worktree.archive`, which refuses. The
menu item is not the defect and does not change: what changes is that the daemon
stops refusing.

### The fences, and why lifting them is not enough

Three explicit fences refuse a remote row, each deliberate and each placed above
the row so the actuation record never claims an act that could not be attempted:

- **`worktree.archive`**
  (`Sources/TBDDaemon/Server/RPCRouter+WorktreeHandlers.swift`:217-221) — refuses
  loudly, with a message naming the lane, because it answers a user gesture.
- **`worktree.forget`** (same file, :324-328) — the same shape, on the stated
  ground that a remote lane has no checkout here to leave alone.
- **`AutoArchiveOnMergeCoordinator.handleMergedTransition`**
  (`Sources/TBDDaemon/PR/AutoArchiveOnMergeCoordinator.swift`:54-57) — skips
  silently rather than loudly, because it is a background rail rather than a
  gesture.

Underneath them the refusal is structural rather than conditional.
`beginArchiveWorktree`
(`Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Archive.swift`:47-49),
`forgetWorktree` (`.../WorktreeLifecycle+Forget.swift`:38) and
`beginReviveWorktree` (`.../WorktreeLifecycle+Archive.swift`:292-295) all resolve
their row through `WorktreeStore.getLocal`, and `LocalWorktree.init?`
(`Sources/TBDShared/LocalWorktree.swift`:34-39) returns nil for a remote row. So
deleting a fence would convert a clear refusal into `worktreeNotFound`, and
nothing more.

That is the right structure, because the local archive path is local all the way
down: it syncs the branch from `git worktree list`, captures HEAD from the
directory, captures each terminal's scrollback into Closed Terminals, kills the
tmux windows, deletes the terminal and tab rows, and — in phase 2 — runs the
archive hook and removes the git worktree. Not one of those has a meaning for a
lane whose files are on another machine.

### A remote lane archives through its own path

`handleWorktreeArchive` branches on location instead of refusing on it. The
`.local` arm is today's path, untouched. The `.remote` arm calls a second
lifecycle entry that shares only what is genuinely about the row:

1. Load the row through `WorktreeStore.get` — not `getLocal`, which is the whole
   point of a separate path.
2. Refuse `.main` and `.creating`, which `WorktreeStore.archive`
   (`Sources/TBDDaemon/Database/WorktreeStore.swift`:646-672) already enforces in
   the same transaction that flips the status.
3. Honor `assertArchivable` (:686-703) unless forced. Its SQL counts direct
   children with status `.active` or `.creating` and is location-blind, so a
   remote lane with an active child is refused exactly as a local one is — and a
   remote lane can have children, since adoption nests rows on
   `parentWorktreeID`.
4. Compose over the provider's declared capabilities (next subsection), then flip
   the row through `WorktreeStore.archive(id:)`.

No tmux, no scrollback capture, no git, no phase 2, no archive hook. The hook is
worth naming: it runs with the worktree's path as its working directory, and a
remote lane has no directory to run it in.

### The composition, and which branch `claude-cloud` takes

What archive does to the session behind the row is the three-way composition the
08-10 design specifies, and this document does not restate the rule beyond naming
its branches: a provider declaring `archive` has the verb called and then the row
marked; one declaring only `stop` has the session stopped and then the row
marked; one declaring neither has the row marked and nothing else, with the
session left running and the UI saying so.

**`claude-cloud` takes the third branch, and takes it permanently.** It declares
neither `archive` nor `unarchive` — the account's archive operation lives on the
undocumented surface TBD does not build against (§1) — and it declares no `stop`,
because nothing exposed terminates a running cloud session. So archiving a cloud
lane calls nothing at all: it is a filing change inside TBD, and the session goes
on existing exactly as it did.

**What the row shows, so nobody reads it as a teardown.** An archived cloud lane
says, in the Archived list and in its detail header, that it was filed away here
and that the cloud session is still in the account's working set, naming
claude.ai as where to retire it for real. The words to avoid are the ones the
local path earns: nothing was stopped, closed, torn down, or cleaned up. The one
sentence a user needs is that TBD stopped showing the lane and Anthropic did not
stop the session.

**The termination guards do not apply.** The 08-10 design scopes the `working`
guard and the dirty-remote-checkout guard to the paths that actually end a
session — the `stop` path always, and the `archive`-verb path where the same
provider also declares `stop` — because destroying unpushed work is the only
thing they defend against. A row-only archive destroys nothing, so it is never
refused on those grounds. Nothing here relaxes a guard; the guarded branches are
simply not the branch cloud takes.

**No actuation row is written for a row-only archive.** `.worktreeArchive` maps
to the `dispose` kind (`Sources/TBDDaemon/Actuation/ActuationSurface.swift`:150-151),
and this branch disposes of nothing: it kills no process and ends no session. The
precedent is the 08-10 design's forced `repo.remove`, which cascades local
worktrees and writes no actuation row for the remote lanes it drops, because none
of their sessions were torn down and the record may only claim acts that were
attempted. The branches that do call a provider verb record theirs as they would
for any other actuated act.

### What happens to the mirror row, and to the next `list`

**The `remote_session` mirror row is untouched.** It is provider-owned liveness —
what the manager last observed — while `worktree.status` is TBD's own filing
decision, and archiving a lane is the second of those. Keeping the mirror is what
lets an archived lane still say whether its session is still being listed.

**The next snapshot does not resurrect the lane.** `RemoteSessionAdopter.adoptOne`
(`Sources/TBDDaemon/Remote/RemoteSessionAdopter.swift`:98-102) ends adoption for
any session that already has a row — "created once, never re-derived, whatever
the payload now says" — so a session that keeps appearing in every `list` after
its lane was archived mints nothing and changes nothing.

**Nor does it un-archive it.** The parent design's mirroring of a payload's
`archived` flag onto the row is not in this slice, and could not act here if it
were: the ledger reports no such flag, and a provider that never learns TBD filed
a lane away would report `archived: false` forever. When that mirroring does land
with discovery, it carries a provider's own filing state and therefore applies
only where the provider holds one — which is to say, where it declares `archive`.

`remote.dismiss`'s `dismissed` column stays a separate axis: it hides a bare
session row from the Provider Desk and says nothing about a lane. Archiving a
lane does not set it, and dismissing a session does not archive a lane.

### Where an archived remote lane shows up

`AppState.visibleWorktrees`
(`Sources/TBDApp/AppState+ArchiveTombstones.swift`:39-44) filters on
`status != .archived` and the tombstone set alone — no reference to location — so
an archived remote row leaves the tree the moment its status flips, with no
change to that function. It is confirmed rather than modified.

**The Archived list needs one change, and without it the lane would vanish
entirely.** `ArchivedWorktreesView` hides rows with no conversations by default
(`Sources/TBDApp/ArchivedWorktreesView.swift`:136, filter at :251-256), where
"conversations" means `liveClaudeSessionCount ?? archivedClaudeSessions?.count`
(:677-679) — local Claude sessions, of which a remote lane has none. A cloud lane
would therefore leave the tree and not appear in the list that is supposed to
have received it. So a row with a provider origin passes that filter
unconditionally, the way an in-flight revive already does. The filter's premise —
"no conversations means nothing to come back to" — is a statement about local
sessions, and it is simply not true of a lane whose conversation is on a server.

### Unarchive is the same branch, run backwards

Reviving a lane archived by the row-only branch flips the row back and calls
nothing, which is the 08-10 design's first revive case: nothing was retired on
the provider, so there is nothing to undo there. `WorktreeStore.revive(id:)`
(`Sources/TBDDaemon/Database/WorktreeStore.swift`:709-721) is location-blind and
does the flip; `beginReviveWorktree` is not — it resolves through `getLocal` and
then materializes a directory — so revive branches on location exactly as archive
does, and the remote arm is the row flip alone.

The lane comes back saying what it knew before: its state is `unknown`, its name
is its session id, and whether the session is still there is what the mirror row
answers. The 08-10 design's other revive cases — an `unarchive` verb, a
terminated session, a retirement TBD cannot lift — describe providers cloud is
not, and they arrive with the providers that declare those capabilities.

### `worktree.forget` stays refused

Forget means "stop tracking this checkout but leave its files alone", and a
remote lane has no checkout here to leave alone. That is a category error rather
than an unimplemented feature, and it is how the 08-10 design classifies forget,
alongside hibernate, relocate, scratch promote and adopt-existing-directory:
operations with no remote meaning, kept unreachable through `LocalWorktree`. The
fence stays exactly as it is, comment included — it already states that ground
rather than a missing capability. Archive is the retirement gesture for a lane,
and archive is the one this section makes work on a remote row.

### The auto-archive-on-merge rail does not take remote lanes

The rail's guard stays, and a remote lane does not participate.

Two reasons, and the second is the one that would still hold if the first were
fixed. First, the rail has no signal for a remote lane: it fires on a merged PR
transition, and PR polling is fenced away from remote rows because everything
below it is keyed on the worktree's path — `git` and `gh` both run inside a
directory that does not exist for a remote lane. The 08-10 design's answer is to
re-key that poll on the branch rather than to relax the fence, and until that
lands a remote lane carries no PR status and reaches no merged transition.

Second, when the badge does come back, an automatic archive of a lane whose
session keeps running is a background mutation with no user gesture behind it —
filing away a lane whose agent may still be working, in the one branch of the
composition where TBD cannot even ask the provider what state it is in. That is
the shape the repository's default-off rule exists for, and the honest row state
("archived here, still running there") is one a person should be choosing. The
guard's comment changes to say this; the guard does not.

## 8. The flag

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

## 9. Testing

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

**The detail surface's shape for an `attach`-only provider.** `available`
returns `[.attach]` for a live cloud lane and `[]` for a gone one; `showsPicker`
is false in both, so the attach content fills the pane in the first case and the
empty state fills it in the second. `showsSendField` is true for a live cloud
lane whose provider has never recorded a complete snapshot — the case that would
regress if freshness were conflated with "has answered" — and false once the
session is `gone`. A one-shot Log hint against a provider that does not declare
`log` is discarded rather than producing a blank pane. A provider declaring `log`
and not `attach` behaves exactly as it does now, on both the tab list and the
landing tab.

**The row states its uncertainty.** A row whose agent state is `unknown` renders
the uncertainty suffix rather than nothing, and a local row with an idle session
still renders nothing — the pair that discriminates, since the defect being fixed
is the two looking identical. A row whose agent state is `working` still renders
the working indicator, so the new case did not take the slot from an existing
one.

**The ledger's snapshots never retire anything.** An always-`complete: false`
provider whose `list` omits a session it sighted on an earlier poll leaves that
row's `missingCount` where it was, never marks it `gone` however many polls it
takes, and never
advances freshness in either the in-memory stamp or the persisted `tbd_meta` key
— asserted across a manager restart, so the recovered value is still absent.
The same snapshot still adopts a session it has not seen before and still clears
a degraded health state, so a provider whose steady state is incomplete recovers
from a transport failure and keeps Send available. A `complete: true` snapshot
from any other provider retires on the existing two-absence rule, unchanged.

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
`pending` and surfaced as an unresolved create rather than silently dropped. A
create never writes a display name of its own, so the row is named from the
provider's payload — the session id, for a ledger row — and never from the
submitted prompt.

**The entitlement path.** A permanent attach exit reported to the daemon records
an attach block on that provider and leaves its health untouched, so the send
field and every non-attach verb stay available. The block
suppresses `showsAttachSlot` for that selection and renders the CTA in its place
while `RemoteAttachPager` stays mounted. `attachEligibleRemoteSelections` drops
a session whose provider carries a block and keeps one whose provider does not.
`RemoteAttachExitClass.classify` returns `.permanent` for exit 1 and exit 2,
`.unexpected` for exit 3, `.authNeeded` for exit 4 and `.clean` for 0 and `nil`;
`isBlocked` refuses a permanent entry against healthy provider health and an
elapsed backoff window, admits a transient one under the same conditions, and
Reattach clears either. A provider with no block behaves exactly as it does now,
reconnect included.

**Archive's three branches.** A provider declaring `archive` has the verb called
and then its row marked `archived`; one declaring only `stop` has `stop` called
and then its row marked; one declaring neither has its row marked with **no**
provider invocation at all, asserted against a fake invoker that records every
verb it was asked for. Each branch ends with the row `archived`. The row-only
branch writes no actuation row, while the two verb branches write theirs. The
`working` and dirty-checkout guards refuse the `stop` branch and the
`archive`-with-`stop` branch, and never refuse the row-only branch — including
against a lane whose `agent_state` is `working`, which is the assertion that
would fail if the guards were applied to the path that ends nothing.

**The row-only branch is honest on screen.** The archived cloud lane's copy names
the session as still running and never claims a stop, a teardown or a
provider-side retirement — asserted on the composed string rather than on a
substring blacklist, so a rewording that reintroduces the claim fails.

**Unarchiving a row-only archive.** Revive on that lane flips the row back to
`active` and invokes nothing on the provider, and the lane returns with the same
id, origin, branch, parent edge and children. Revive on a local worktree still
runs the whole local path, so the branch did not swallow it.

**Each fence, after.** `worktree.archive` on a remote row archives it instead of
returning its refusal string; on a local row it behaves exactly as today. A
remote row with an active child is refused by `assertArchivable` in both the
local and remote arms alike. `worktree.forget` on a remote row still refuses.
`AutoArchiveOnMergeCoordinator.handleMergedTransition` still returns `false` for
a remote row and still archives a local one.

**`visibleWorktrees` drops an archived remote row.** A remote row flipped to
`archived` leaves the visible set, and the same row while `active` stays in it —
the assertion that the location-blind filter needed no change. The archived
lane then appears in the Archived list under the default `hideEmpty` filter,
which it would not under the filter as written today.

**Land's precondition failures each leave the row unchanged.** A remote mismatch,
a branch missing on the remote, an occupied target path, and a branch already
checked out in another worktree are each reported without creating a worktree, and
each leaves the row `.remote` at its synthetic path with its origin, display name,
parent edge and children intact. A `branch` beginning with `-` and an
`ext::`-style `remote_url` are both rejected before reaching git. On success the
same row id comes back `.local` at a real path with everything else preserved and
no second row for the session. No provider verb is invoked by the landing at
all — asserted against a fake invoker — since cloud declares neither `archive`
nor `stop`, and the landed row states that its session is still running.

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

## 10. Work order

**Nothing opens a pull request until the whole path works end to end.** The order
below minimizes rework; it is not a sequence of independently shippable
increments, and several steps are unobservable on their own. Building it as
increments would mean shipping the routing change with nothing to route and the
provider with no flag to gate it.

1. **The shared model change (§2).** Origin field, record mapping, round-trip
   tests. Everything downstream reads provenance, and every later step written
   against the erasing mapping would have to be rewritten.
2. **Contract v2 negotiation (§3).** Accept a `[2]`-only provider, store the
   negotiated major, thread it to the runner and the events supervisor, publish it
   on `RemoteProviderStatus`. The cloud provider cannot be described at all until
   this lands, so writing it first means writing it against a guard that rejects
   it.
3. **Snapshot completeness (§3).** `complete` on the `list` envelope, honored in
   `RemoteSessionStore.applySnapshot`: no `missingCount`, no freshness in either
   store, adoption and health unchanged. The built-in provider's snapshots are
   always incomplete, so a provider written before this lands would mark its own
   lanes `gone` two polls after creating them.
4. **Pseudo-terminal mode in the bounded process runner (§3).** One opt-in stdio
   mode on `runBoundedProcess`, with its deadline, drain and single-resume
   properties re-asserted under it. `create` cannot be written against a pipe at
   all, so writing the provider first would mean writing it against a spawn that
   refuses every invocation.
5. **The flag and its capabilities plumbing (§8).** Migration, record, model,
   `DaemonCapabilitiesResult`, Settings toggle. The provider is constructed behind
   this flag, so the flag exists first or the construction has to be rewired.
6. **The dispatcher and the provider's `describe`, `create`, `list` and `send`
   (§3).** Including the ledger table, the create-output parse and the one
   out-of-band `list` a successful create triggers. Until a cloud session can be
   created and enumerated there is no row to route, steer, land or archive, so
   this is the step that makes every later one testable by hand.
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
8. **Routing, and the row's uncertainty indicator (§4, §3).** The derived remote
   selection and its two call sites, plus the suffix indicator that keeps a
   permanently `unknown` lane from rendering as an idle one. Only observable once
   a cloud row exists, which is why it follows step 6 — and the send field needs
   nothing beyond the routing, since its gate already passes for this provider.
9. **Attach readiness (§5).** The negotiated major, the attach argv and the
   attach block reaching the app through the one `RemoteProviderStatus` lookup,
   alongside the attach exit-class correction the block depends on. They land
   together because they share that lookup.
10. **Archive (§7).** The remote arm of `worktree.archive` and of revive, the
    capability composition, the row copy, the Archived list's filter, and the two
    fences that stay. It precedes Land because Land's honesty about the surviving
    cloud session is the same statement this step has to get right, and because a
    lane created in step 6 is otherwise stuck in the tree for the rest of the
    build.
11. **Land (§6).** The `Context` plumbing with the filesystem fix in the same
    edit, the `worktree.land` RPC, preconditions, and the in-place conversion.

Step 11 last because it is the only step that mutates a row's location, so every
earlier step is exercised against a stable lane before the conversion is
introduced into the mix.

## 11. The vendor CLI surface, as measured

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
"transcript persistence probe: reply with the single word pong" comes back titled
"Add probe pong reply", and that title is on the created-session line rather than
in any structured field TBD can read. A cloud session's name is the vendor's
summary of the instruction rather than the instruction, so TBD takes a name only
from a provider payload that carries one and never from what was sent — which in
this slice means every cloud lane wears its session id (§3). Taking the
title out of that line instead is a format dependency with no cross-check: the id
has a strict shape and appears three times, so a parse that finds none or finds
two different ones is detectable, while a display string lifted out of prose is
wrong silently the first time the sentence is reworded.

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

So **nothing about a cloud conversation reaches this machine on its own.**
Nothing is seeded locally for free, and nothing has to be redirected to keep a
cloud conversation out of the local session store. That is the other half of why
there is no watch surface in this slice (§1): not only is there no supported
interface to read the conversation from, there is no local artifact of it either.

Whether a *successful* attach would write one is untested rather than refuted —
attach could not run at all under the account gate above. It is moot for the
default state, since an account without the entitlement never attaches and so
never writes. If the entitlement is granted and an attach does write locally, the
consequence is the parent design's: the attach process must be pointed at a
TBD-owned root, or a cloud conversation surfaces as a local session of whichever
worktree the pane ran in. `handleSessionList`
(`Sources/TBDDaemon/Server/RPCRouter+SessionHandlers.swift`:9-22) resolves a
projects directory from the worktree's path (:16) and hands it to
`ClaudeSessionScanner.listSessions(projectDir:)` (:20), so anything written under
that resolved root is indistinguishable from a local session of that lane.
Pointing attach elsewhere is one environment entry on the attach spawn, and it
is the first thing to check on an entitled account rather than something to
discover from a stray session row.

## 12. Rejected alternatives

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

**Building against the undocumented claude.ai endpoints.** They are there, the
web client uses them, and they would answer every question this slice has to do
without: which sessions the account has, what each one is called, what its agent
is doing, what the conversation says, and whether attach is permitted. Taking
them would turn a ledger into an inventory and a blank pane into a transcript.

Rejected on terms rather than on taste. Anthropic's Consumer Terms bar automated
access to the Services outside the carve-out for use of an Anthropic API key, and
a cloud session is reachable only under a subscription login — so there is no
key-shaped route to the same data and no configuration in which such a client is
inside the terms. A tool that quietly puts its users outside the terms of the
account they are signed into is not a tool this repository ships, and the cost
falls on the user rather than on TBD.

Two lesser reasons agree with the first without being needed by it. An
undocumented endpoint has no compatibility promise, so the feature would break on
a deployment nobody announced, in a way the user would read as TBD being broken.
And the boundary is the load-bearing part of the design: the whole point of
`describe` being static, `list` being ledger-only and attach being learned from
an exit code is that every one of them holds against a supported interface. What
would reopen this is a supported interface — a documented endpoint, an
API-key-authenticated route, or a stated permission — not a smaller or more
careful scraper. Anything short of that changes the risk's size, not its kind.

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

**Synthesizing a `RemoteProviderConfig.exec` that composes into the right attach
command.** Setting `exec` to the resolved `claude` path and `args` to `["--cloud"]`
would make `argv + ["attach", sessionID]` almost work, which is the problem — it
would spell `claude --cloud attach <id>`, and any arrangement that did compose
correctly would do so by coincidence, breaking silently the next time either side
changed a flag. An explicit `attachArgv` says what is being spawned instead of
encoding it in the interaction of two fields that mean something else.
