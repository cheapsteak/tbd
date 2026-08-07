# Claude cloud sessions in TBD — contract v2, a built-in provider, landing, and repo-declared remotes

**Date:** 2026-08-07
**Status:** Design, not yet implemented.
**Scope:** Four changes shipping together — an additive revision of the remote provider contract, a provider implementation compiled into the daemon, a path from a remote session to a local worktree, and a per-repo declaration of which remotes a repository runs on.

## Summary

TBD gains the ability to create, watch, steer, archive, and land **Claude cloud sessions** — Claude Code sessions running on Anthropic's hosted infrastructure, reachable today only from claude.ai, the mobile and Desktop apps, and `claude --cloud` in a terminal.

The integration rides the existing remote agent backend contract
([`2026-07-24-remote-agent-backends-design.md`](2026-07-24-remote-agent-backends-design.md),
[`../remote-provider-contract.md`](../remote-provider-contract.md)) rather than
introducing a parallel concept. Cloud sessions become remote sessions like any
other: same mirror table, same sidebar rendering, same health and auth
machinery. What is new is that this is TBD's **second** provider, and a second
implementation exposes places where a contract written against one implementation
is unsound.

Three facts shape everything below.

- **The documented surface is partial.** `claude --cloud "<prompt>"` creates a session, `claude -p "msg" --cloud <id>` sends to one, and `claude --cloud <id>` attaches a terminal to one. There is no documented way to enumerate sessions, archive one, or read one's conversation. Those ride undocumented endpoints, and the design degrades to the documented floor when they are unavailable.
- **The conversation lives on a server, not in a terminal.** Anthropic stores the transcript — messages, responses, and tool activity — and every client syncs against it. Reading a cloud session is not reading scrollback.
- **Landing work locally is a fork.** `claude --teleport <id>` fetches the session's branch and conversation history into a checkout, but subsequent local work does not flow back.

**Single-account assumption.** Every cloud session TBD deals with belongs to the
signed-in user, and TBD assumes it is the only client driving a given session at
a given moment. Concurrent drivers are a real product possibility and explicitly
out of scope here; nothing in this design tries to detect, arbitrate, or warn
about them. Revisiting that is a separate piece of work.

## Part 1 — Contract v2

Contract major becomes `2`. A v1 provider keeps working unchanged.

**The negotiation machinery has to be built first.** `ProviderRunner.run`
hardcodes `TBD_CONTRACT_VERSION=1` and `describeProvider` hard-requires that
`describe.contractVersions` contains `1`. There is no per-provider negotiated
version anywhere, and `RemoteProviderInvoking.run(_:verb:stdin:timeout:)` has no
parameter to carry one. Negotiated version becomes provider state resolved at
`describe` time and a parameter on the invocation protocol. This is small but it
is a protocol change, not a free ride on existing code.

### Snapshots declare whether they are complete

The v1 drift rule marks a session `gone` after it is absent from two consecutive successful snapshots. `RemoteSessionStore.applySnapshot` increments `missingCount` for every row it did not see, with no notion of whether the provider could see everything. That is correct only when the provider enumerates its own inventory, and wrong for one that can enumerate only part of it.

The `list` envelope and the `events` stream's `snapshot` event gain a boolean:

```json
{"complete": true, "sessions": [...]}
```

- `complete: true` — the provider's full inventory. TBD applies the `gone` rule exactly as in v1.
- `complete: false` — a partial view. TBD may add and update rows and **must not** increment `missingCount` or retire anything.
- Absent — treated as `true`, so v1 providers are unaffected.

`complete: false` also does **not** refresh freshness. `RemoteProviderManager.apply` currently calls `markHealthy` and stamps `lastSuccessfulSnapshotAt` on any accepted snapshot, and those drive the staleness indicator and the mutation gate from [`2026-08-01-remote-stale-snapshot-design.md`](2026-08-01-remote-stale-snapshot-design.md). A partial snapshot that stamped freshness would present a half-blind inventory as current and re-open mutations against it. A partial snapshot leaves `lastSuccessfulSnapshotAt` untouched.

**`complete` means complete with respect to the set TBD mirrors** — including archived sessions, per the next section. A provider that can enumerate active sessions but not archived ones reports `complete: false`.

### Archived is a third axis

The Session object gains `archived: bool`, defaulting false. It is orthogonal to `state` (process liveness) and `agent_state` (attention): a session can be archived while its machine is still winding down, and an active session is never implicitly archived.

Archived sessions are **returned by `list`, not filtered out of it.** TBD decides what to show — active by default, archived behind a filter, mirroring the local History pane. Filtering server-side would make archived sessions look absent and trip the drift rule, and would deny TBD the archived inventory it needs for the browse-and-revive flow.

Two new capabilities: `archive <id>` and `unarchive <id>`, both idempotent, both returning the session object.

### `stop` becomes a capability, distinct from archiving

v1 makes `stop` required and folds two operations into it — terminating the compute, and retiring the session from the inventory. One provider could do both in one call, so nothing forced them apart. A provider whose sessions are reclaimed by the platform on inactivity, with no termination call exposed to clients, can retire a session but cannot terminate one.

So `stop` joins the declared capabilities and means only *terminate a running session*. Retiring is `archive`. `describe`, `create`, and `list` remain required.

TBD gains capability gating for the stop action. Attach is already gated this way (`RemoteSessionActionMenu`); stop is not, and this is new work rather than an existing behavior being reused.

### `transcript` — the conversation as structured messages

New declared capability, distinct from `log` and not a replacement for it.

```
p transcript <id> [--since <cursor>]
```

stdout is Claude Code transcript JSONL. The cursor for the next call is returned in an **envelope on stderr**, not as a trailing line of the data stream — mixing a control record into JSONL makes a truncated response indistinguishable from a provider with no incremental support. A provider without incremental support returns no cursor and TBD refetches. Cursors are opaque to TBD.

`log` remains raw ANSI scrollback bytes for a read-only terminal pane, for providers that host a terminal. Structured messages in a scrollback view would lose every tool card; ANSI in the transcript renderer would produce garbage. A provider may implement either, both, or neither.

The verb is not vendor-specific. Any provider running Claude Code has transcript JSONL available, so declaring `transcript` upgrades it from ANSI scrollback to TBD's structured transcript pane with no new transport.

### `land` — reconstructing a remote session locally

New declared capability.

```
p land <id>
```

```json
{
  "remote_url": "git@github.com:acme/api.git",
  "branch": "claude/fix-flaky-ci",
  "resume_command": ["claude", "--teleport", "sess_01ABC"],
  "forks": true
}
```

- `remote_url`, `branch` — required. Where the work is.
- `resume_command` — optional argv TBD runs in the new worktree's first pane. Omitted when there is nothing to resume.
- `forks` — required. Whether local work continues to reach the remote session.

**These fields are not trusted input.** For an external provider they come from an executable the user registered, but for the built-in provider they come from session metadata on a remote server, including sessions created from another device. Before any of them reaches git, TBD validates: `branch` must match a conservative ref-name pattern and must not begin with `-`; `remote_url` is only ever **compared** against the local repository's configured remote, never passed to git as a remote argument, which rules out the `ext::` transport family and its command execution. `resume_command` is accepted only from a registered executable or from the daemon's own built-in provider, never from repository content.

## Part 2 — The built-in `claude-cloud` provider

### Why this one is compiled

The placement rule ([`../theory-placement.md`](../theory-placement.md)) asks whether two reasonable projects could want a behavior different. Supervision policies are forked per repository because "when is an agent stuck" is genuinely contested. How to talk to a specific vendor's session API is not: there is one API, and no project's convention changes its shape. That makes it a mechanism, and mechanisms compile.

Fragility is a separate axis from ownership. TBD is built from source, so a fix to a moved endpoint is a pull and a restart, and the design degrades rather than fails: when the undocumented half is unavailable, sessions TBD launched keep listing, creating, sending, and attaching, and only discovery of foreign sessions and the transcript pane go dark.

Two things do ride along inside the compiled provider that are closer to theory than mechanism: the mapping from the vendor's session status onto the contract's `agent_state` axis, and the choice of `create_params`. Both are TBD's to own and revise, and both are stated here rather than left to implementation taste.

### Shape

`RemoteProviderInvoking` is a one-method protocol with one production conformance and one injection site. The built-in provider is a second conformance, selected by a dispatcher that routes on provider name: registered names fork a subprocess through `ProviderRunner`, the reserved name is served in-process.

It synthesizes the same `ProviderResult` envelope a subprocess produces. Fabricating an exit code is deliberate: it puts the built-in provider through `ProviderFailureClass.classify` and the same health, auth-banner, and staleness handling as an external provider, so nothing downstream special-cases it. (It does not inherit retry or backoff, because there is none for classified verb failures — `recordFailure` sets health and returns. The only backoff in the subsystem is the events supervisor's stream restart.)

`claude-cloud` is a reserved provider name. A registry entry claiming it is **skipped with a visible flag**, not rejected. `RemoteProviderRegistry.load` currently throws for the entire file on a duplicate name, and two of its three call sites swallow that with `try?`, so a single bad entry silently removes every provider. Skipping the offending entry and surfacing it matches how the rest of this design handles configuration drift, and avoids a total outage for anyone who registered an external adapter under that name against v1.

### The ledger, and what it may not do

A new `claude_cloud_session` table records what TBD launched: session id, idempotency key and its state, creation time, repository path, branch, and the parameters used. It is distinct from the `remote_session` mirror — the ledger is *what this machine started*, the mirror is *what the manager last observed*.

`list` returns the union of ledger rows and discovered sessions, keyed by session id. Three rules keep the union from inverting the contract's direction of authority:

- **A complete snapshot retires ledger rows it omits.** If discovery succeeded and enumerated everything, a ledger row absent from it is a session that no longer exists, and the ledger drops it rather than re-asserting it. Without this rule "TBD launched it once" silently becomes "it exists permanently," and a session deleted from claude.ai could never tombstone.
- **A ledger-only row carries `state: "unknown"`,** never a fabricated `running`. The contract forbids conflating unreachability with liveness, and with discovery down the ledger knows only that a session was created, not whether it lives. `agent_state` is likewise `unknown`.
- **Ledger rows never suppress a discovered row.** Where both exist the discovered payload wins; the ledger contributes only rows discovery did not return.

### Verb implementations

- **`describe`** — static and offline. Declares `send`, `attach`, `transcript`, `land`, `archive`, and `unarchive`; declares neither `stop` nor `log`. It reports **`contract_versions: [2]`, not `[1, 2]`** — nothing exposed terminates a running cloud session, so it cannot implement `stop`, and major 1 requires it. This is the one place in these documents where the `[1, 2]` idiom every other example shows would be wrong, and declaring a major means conforming to it. `create_params` are `repo`, `branch`, `prompt`, and `environment`.

  **`environment`** names a cloud environment configured on the account — the saved bundle of network policy, environment variables, and setup script a session runs under. It is typed `string`, not `enum`, because `describe` must answer offline and the set of environments is only knowable from the account. An empty or absent value means the account's default environment; an unrecognized name is the provider's error to report at create time, not TBD's to pre-validate. It is the param a repository is most likely to want to declare, since which environment a repository's sessions need is a property of the repository — and, being a name rather than a script or a command, a declared value can select among configurations the account already has but cannot author a new one. That does not exempt it from the trust gate, which shows every declared param whatever its name.
- **`create`** — `claude --cloud "<prompt>"` from the repository checkout.
- **`list`** — ledger union discovery, per above.
- **`send`** — `claude -p "<msg>" --cloud <id> --output-format json`, returning `{ok, session_id, url}`. A structured enqueue with an acknowledgement, not keystrokes into a terminal, so it carries none of the delivery-confirmation problems a keystroke transport has.
- **`attach`** — `claude --cloud <id>` on the pane's PTY, spawned directly (below).
- **`transcript`** — reads the server-stored transcript for the session, cursor-tailed.
- **`land`** — the session's repository and branch, with `resume_command` of `claude --teleport <id>` and `forks: true`.
- **`archive` / `unarchive`** — the account's archive operation over the undocumented surface. An archived session rejects new messages, which is why archiving is a real state change and not a display preference.

### Create idempotency, against the as-built handler

`handleRemoteCreate` mints a **fresh** idempotency key on every RPC call, retries **once with the same key** when the provider times out, and deliberately does not persist it. That shape means the key defends exactly one thing — a transport timeout on a create that may have started — and defends nothing against a user clicking Create twice, which produces two keys and two sessions.

The ledger changes what is possible without changing that handler's retry:

- The key and its state are written to the ledger **before** the invocation. The daemon's single same-key retry proceeds normally; a pending row is expected during it, not a reason to refuse.
- If both attempts fail, the row stays `pending` and is surfaced as an unresolved create the user can act on — never silently dropped, because the session may well have started.
- A pending row is resolved by the next complete discovery: a session matching its repository, branch and creation window adopts the row. A complete snapshot containing no such session **ten minutes** after the create transitions the row to `failed` and stops surfacing it to the user. The row itself is **retained for 24 hours**, then deleted — it stops being a prompt for attention long before it stops existing, which is what lets a late-arriving session still be matched against it.

Both directions of getting that number wrong are user-visible. Too short and a slow-provisioning session — capacity is allocated on demand, and a setup script runs before the session is usable — is declared failed while it is still coming up, stranding a real session outside TBD's inventory. Too long and a create that genuinely failed sits as `pending` in front of the user with nothing to act on.

A compiled duration is exactly the shape [`../theory-placement.md`](../theory-placement.md)'s tunable-number test flags, so it is worth saying why this one stays compiled while the supervision thresholds it resembles did not. The two-reasonable-projects test is what separates them: "when is an agent stuck" is contested because one repository's forty idle minutes is another's normal test run, whereas how long a vendor takes to provision a machine is a property of that vendor's infrastructure, not of anyone's working style. The named-consumer test agrees — no repository wants a different provisioning-latency assumption, and if the real latency changed, the correct response would be to change the value for everyone rather than to hand out a knob. It stays compiled, and it is a fact TBD is asserting about a vendor, not a judgement about the user's work.

What that argument does not buy is being right. So the constant ships with the floor its own failure mode requires: **a session that appears in a later complete snapshot and matches a pending row already cleared as failed is adopted, not ignored.** A window set too short then costs a delayed sidebar row rather than a lost session, and the adoption is logged — which is also the evidence that would justify changing the number. The threshold is revisable; being wrong about it is recoverable and visible rather than silent.
- Duplicate protection for a double-click is a UI concern, not a key concern: Create is disabled while a create for the same repository and parameters is in flight.

### Attach spawns the vendor CLI directly

No shim. The app spawns `claude --cloud <id>` on the pane's PTY, the same way it spawns an external provider's `attach`.

An intermediate translator was considered and rejected on its own terms. Its only job would be mapping the vendor CLI's exit codes onto the contract's error table, and it has no lawful input to do that with: the information distinguishing an ineligible account from a dropped transport is printed on the terminal, and parsing it is forbidden both by the no-TUI-scraping rule and by the contract's `attach` section. A translator would have had to either scrape or guess.

Instead, TBD does not try to learn *why* attach ended from its exit code alone. Two changes make that safe:

- **`RemoteAttachExitClass` gains a `permanent` case** distinct from `unexpected`. Today `.permanent`, `.contractBug` and `.transient` all collapse into `.unexpected`, which arms automatic reconnect — so a permanently ineligible account would retry forever at a 300s cap. A `permanent` class does not arm reconnect and says so on screen.
- **Eligibility is a preflight, not a postmortem.** Whether the account can attach interactively is checked once against the undocumented surface, cached, and reflected by disabling the attach affordance with an explanation. This is the one place attach touches the undocumented half, and it fails open: if the preflight cannot run, attach is offered, and a failure is treated as transient.

Nothing parses attach's output. The exit code remains the only signal read from the process itself.

### Attach, transcript, and where a remote conversation is stored

Both surfaces read the same server-stored conversation, so a message typed in the attach pane appears in the transcript pane and one sent through `send` appears in both. This is the opposite of landing, where the local copy forks. No reconciliation is needed and none is designed.

Storage needs a decision, because the transcript renderer cannot simply be pointed at provider bytes. `TranscriptParser.parse(filePath:)` is file-path-based, and the two RPCs reaching it are **not** guarded alike. `handleSessionMessages` constrains the path to the Claude projects store, resolved through the same single point as `ClaudeProjectDirectory.resolve` so guard and resolver cannot disagree. `handleTerminalTranscript` has no such check: when a terminal row carries a `transcriptPath` it reads that path verbatim, and the only validation `transcriptPath` ever receives is an absoluteness check at write time in the sessionEvent handler. The comment on the guarded call site asserts it shares a trust boundary with the unguarded one, which is how the asymmetry stays invisible.

Spooling vendor JSONL into the Claude store would also make `ClaudeSessionScanner` list a cloud conversation as a local session of the worktree.

So remote transcripts live in a TBD-owned root, `~/tbd/remote-transcripts/<provider>/<sessionID>/`, with a path helper in `TBDConstants` honoring `TBD_HOME`. `ClaudeSessionScanner` already accepts a `projectsBase` parameter. Both transcript RPCs then enforce the same two-root boundary — the Claude store and the TBD-owned root, never an unguarded path — which means `handleTerminalTranscript` **gains** a boundary check it does not have today rather than having an existing one widened. That closing of the asymmetry is a prerequisite of this work, not a side effect of it: a second permitted root is only safe where a boundary is actually checked.

Cursor-tailed responses append to the TBD-owned root, which is also what gives a remote transcript continuity across daemon restarts.

**One open empirical question, worth answering before implementation.** Interactive Claude Code sessions always persist to disk — `--no-session-persistence` is documented as working only with `--print` — so `claude --cloud <id>` may already write an ordinary transcript JSONL locally. If it does, attaching once populates a remote session's transcript for free, and the `transcript` verb becomes the path for never-attached sessions rather than the only path. It also means the attach process must be pointed at the TBD-owned root rather than the default store, or a cloud conversation will surface as a local session of whatever worktree the pane ran in. The test is one command on a Mac: attach to a cloud session, then look for a new JSONL under the Claude projects store. The design above works either way; the answer only decides how much the `transcript` verb has to carry.

Minor and worth handling in the same pass: the transcript renderer turns file paths in tool calls into clickable local links. A remote transcript's paths refer to a different machine, so linking is suppressed for remote rows rather than dead-ending or opening an unrelated local file.

### Agent state and credentials

Agent state comes from the discovery response's session status, mapped onto `working` / `waiting_input` / `idle` / `exited`. Any value that does not map cleanly becomes `unknown` rather than a guess, and with discovery unavailable every row is `unknown` and TBD shows liveness only. No agent state is ever derived from rendered terminal output, including the attach pane's.

The undocumented half authenticates with the claude.ai credential `claude auth login` already stores; nothing new is minted or synced, and the documented half shells out to `claude`, which handles its own auth. Credential reads go through an injected seam so tests never touch a real credential store.

## Part 3 — Landing and reviving

### The land bridge

A remote session row gains a **Land** action, enabled when its provider declares `land`. `remote.land` calls the verb, validates the returned fields per Part 1, creates a worktree through the existing lifecycle path, checks out the branch, and spawns the first pane running `resume_command` when one is given.

Preconditions are checked before anything is created, so a failure never leaves a half-built worktree: the local repository's remote must match `remote_url`, the branch must exist on the remote, and the worktree path must be free. Landing is always a user gesture, never triggered by session state.

**A fork is shown as a fork.** With `forks: true`, the landed worktree and the remote session diverge from that moment. The remote row records that it was landed and links to the worktree; the worktree records its origin. Neither is retired, and TBD never implies that typing in one reaches the other.

**A second landing needs its own branch.** `git worktree add <path> <branch>` refuses to check one branch out twice, so landing the same session again cannot reuse the branch. The second landing creates `<branch>-2` (then `-3`, and so on) from the same commit, and the provenance note records that it came from the same remote session. This is deliberate rather than an error: two landings of one session are two independent local lines of work, which is exactly what the fork rule already says.

### Lifecycle parity with worktrees

Local worktrees already carry the model this needs: `WorktreeStatus` includes `archived`, rows keep `archivedAt`, `archivedHeadSHA` and `archivedClaudeSessions`, and both revive modes exist — plain Revive restores the archived branch and session, while Revive-fresh creates a new worktree off `origin/<default>` seeded with a forked conversation, leaving the archived row untouched ([`2026-07-27-revive-conversation-fresh-branch-design.md`](2026-07-27-revive-conversation-fresh-branch-design.md)).

Remote sessions get the same vocabulary and the same two revive modes:

- **Revive on the session's own branch** is `land` as described above.
- **Revive on a fresh branch off `origin/<default>`** composes: land, then run TBD's existing revive-fresh on the landed worktree.

Composition rather than a new verb is deliberate. Teleport is branch-coupled — it fetches and checks out the session's own branch and requires that branch to have been pushed — so a one-gesture fresh-branch landing would mean separating teleport's conversation fetch from its branch checkout, which nothing documented supports. The cost of composing is an intermediate worktree the user did not ask for. If that proves annoying in practice, the graduation is a branch mode on `land`, and the field evidence for it is the annoyance itself.

**Sharing lifecycle vocabulary is not model unification.** Remote sessions keep their own table, RPC family, and rendering. v1 deliberately avoided the `Location {local|remote}` refactor and this does not reopen it.

## Part 4 — Repo-declared remotes

### The file

A repository declares which remotes it runs on in `.tbd-remotes.json` at its root, committed:

```json
{
  "version": 1,
  "remotes": [
    {
      "provider": "claude-cloud",
      "label": "Cloud — specs, docs, review-gate and script work",
      "params": {"environment": "default"}
    }
  ]
}
```

A single root file rather than a directory entry because `<repo>/.tbd/` already means legacy worktree storage and is gitignored in this repository — the one place the feature most needs to work.

**The authoritative copy is the one in the repository's registered root checkout**, not the selected worktree's. Every worktree carries its own copy, so a branch under review would otherwise get to redefine where sessions run merely by being selected.

### Trust on first use

The declaration is repository content, so it is authored by anyone who can push. It is **not** inert. `params` are matched against the provider's `create_params`, and for the built-in provider those include `prompt` — so an unreviewed declaration could set the opening instruction of an agent with repository write access, network egress, and the user's credential. The general case is worse, because the whitelist is provider-defined: a third-party provider is free to declare params named for scripts, images, or environments, and TBD would faithfully pass repository-authored strings into them.

So a declaration takes effect only after the user has seen it and approved it:

- On first encountering a declaration in a repository, TBD shows exactly what it would do — provider, label, and every parameter value verbatim, with `prompt` shown in full rather than truncated — and asks the user to approve it.
- Approval is stored as the SHA-256 of the canonicalized declaration, keyed by repository. **Any change to the file re-prompts**, so approving once never blanket-approves whatever lands on the branch next week.
- Until approved, resolution skips the declaration and falls through to the next tier, with a visible flag in the repository's settings. Unapproved is a degraded state, not a blocked one.
- TBD reads only `provider`, `label`, and `params`. `provider` must name a locally registered provider or the reserved built-in name; it is a reference, never a definition. `label` is length-capped plain text. `params` values must be strings and are dropped if their name is absent from `create_params`. Unknown top-level keys are ignored per forward-compatibility, and ignored means *not interpreted* — TBD never grows a key that turns repository content into something it runs.

The declaration also carries no statement of what a remote *can do*. A grammar for capabilities is a policy language TBD would have to interpret and version permanently; the label is prose a human reads, and the human picks.

### Resolution

Location for a new session resolves most-specific-first:

1. **Explicit per-creation choice** in the create sheet. Always available, always wins.
2. **The repository's approved declaration.** Several declared remotes are offered in order with their labels.
3. **Global default location**, when configured.
4. **Local.**

A declaration naming an unregistered provider is configuration drift: resolution degrades to the next tier and the app flags it, rather than blocking creation. Repo-less scratch spaces always resolve to local.

**Why a repository's declaration outranks the user's own global default.** This is the contestable step in that order — a file written by whoever can push to a repository, placed above a setting the user chose for themselves — so it gets the same treatment as the other decisions in this document that could reasonably go the other way.

The two-reasonable-projects test does not save it: teams could sanely disagree about whether repository configuration should be able to override a personal default, and plenty of tools answer that both ways. What settles it is the trust gate. A declaration only resolves after the user has read it and approved it, so tier 2 is not a stranger's file outranking the user's setting — it is a suggestion the user accepted, and accepting it is exactly the gesture that says "for this repository, use this instead of my default." The ordering and the gate are one mechanism, and the ordering would be indefensible without it.

The named-consumer test then supplies the rest: a global default is what applies when nothing more specific is known, and a repository that has declared its remotes has told you something more specific — that this repository cannot build where the default sends it, or needs a machine the default does not provide. Ordering a general fallback above particular knowledge would make the declaration pointless for the repositories that most need it.

Two properties keep the user in control regardless. The explicit per-creation choice is tier 1 and always wins, so no resolution is ever a trap. And declining a declaration is a durable state, not a dismissal: an unapproved declaration keeps falling through to the global default indefinitely.

### This repository's own declaration

TBD ships `.tbd-remotes.json` declaring `claude-cloud`, with a label saying what is honestly true: cloud sessions can do specification, documentation, review-gate and shell-harness work here, but cannot build or test the project.

That is not a limitation any setup script can lift. `TBDApp` is built on SwiftUI, AppKit and UserNotifications, and `TBDDaemon` reaches `Security` for Keychain access; every target imports `os`, whose `Logger` is Darwin-only and which the no-`print()`-in-`Sources` rule makes the only sanctioned logging path. There is no Linux-clean target to build, whatever toolchain is installed. (`Package.swift`'s `platforms:` declaration sets minimum deployment versions for Apple platforms; it is not what blocks a Linux build.) Meanwhile `scripts/test.test.sh` stubs the compiler out entirely and runs with no toolchain, as do the other shell harnesses, alongside the review-gate Python scripts and the committed-plans guard.

A declaration where every remote does everything demonstrates nothing. This one has to say something real, which is what makes it the worked example — and it is a worked example of a general mechanism, not a TBD-shaped feature.

## Feature flags

`claude_cloud_enabled` — a new `config` column, default OFF. The behavior is autonomous background polling against a network service, squarely inside the default-off rule.

**Composition is explicit: cloud requires both flags.** Every `remote.*` handler gates on `remoteBackendsEnabled` through `remoteGate()`, and the cloud provider is reached through those same verbs, so `claude_cloud_enabled` is a second gate inside the first, never a bypass. Tests assert all four combinations, not two.

The two stay separate rather than merging because `remote_backends_enabled` was written to be *deletable* after soak, on the reasoning that the feature is inert without a registered provider file. A provider compiled into the daemon is never inert, so folding this into it would silently convert a disposable flag into a permanent one.

**When `remote_backends_enabled` is deleted**, its gate is removed and `claude_cloud_enabled` becomes the sole gate for the cloud provider, with the external-provider path ungated as v1's rollout intends. That ordering matters: deleting the outer flag while the inner one is still soaking must not turn cloud on for anyone, so the deletion migration leaves `claude_cloud_enabled` untouched. Graduation for the inner flag is a default flip after soak, then deletion, once discovery has held up across a few endpoint revisions.

## Migrations and models

Each following the shared-model rule — migration, GRDB record, and the `TBDShared` Codable model in one commit, new fields optional or defaulted:

- `claude_cloud_session` — the ledger table, including idempotency key state.
- `config.claude_cloud_enabled` — the flag, defaulting to off.
- `repo.remotes_declaration_trusted_sha` — the approved declaration hash, nullable.

`remote_session` gains no columns; landing state is a link between an existing remote row and an existing worktree row, and `archived` rides in the payload.

New poll intervals and timeouts take an injected `clock` parameter; persisted timestamps use the date seam.

## Testing

No test reaches the network or a real credential store: the undocumented transport sits behind an injected client protocol, credential reads behind an injected seam.

- **Contract v2** — `complete: false` adds and updates rows but never increments `missingCount` and never stamps freshness or re-opens the mutation gate; absent `complete` behaves as `true`; a v1 provider negotiates v1 and is unaffected; `archived` rows are returned by `list` and filtered only for display; a provider that omits `stop` gets no stop action.
- **Ledger union** — a complete snapshot omitting a ledger row retires it; an incomplete one does not; a ledger-only row reports `state: unknown`; a discovered row wins over a ledger row for the same id.
- **Idempotency** — the daemon's single same-key retry succeeds against a pending row rather than being refused; a doubly-failed create leaves a surfaced pending row; discovery adopts a pending row, and ten minutes of complete snapshots with no match marks it failed, driven by an injected clock rather than elapsed wall time; a matching session arriving after that is still adopted rather than ignored.
- **Attach** — `permanent` does not arm automatic reconnect while `unexpected` does; a failed eligibility preflight still offers attach; nothing reads attach output.
- **Land** — each precondition failure is reported without creating a worktree; a second landing gets a suffixed branch; a `branch` beginning with `-` and an `ext::`-style `remote_url` are both rejected before reaching git.
- **Repo declarations** — an unapproved declaration does not resolve; editing an approved file re-prompts; `prompt` is displayed in full at the approval gate; a params key absent from `create_params` is dropped; command-shaped top-level keys are ignored; the root checkout's copy wins over a worktree's.
- **Flag branches** — all four combinations of the two flags.
- **Registry** — an entry claiming the reserved name is skipped and flagged while every other entry still loads.

All tests use the `TBD_HOME` isolation seams and run under `scripts/test.sh`.

## Rejected alternatives

- **An attach shim translating vendor exit codes.** Its only input would have been terminal output, which two separate rules forbid reading. Preflight plus a `permanent` exit class gets the same outcome without a translator that has to guess.
- **Ship the adapter as a seeded, user-editable script.** The seeding pattern exists so projects can fork a contested policy; this is a mechanism with one correct implementation and no consumer who wants it different.
- **Ship the adapter as a separate repository.** Consistent with the contract's stated boundary, but this repository's own declaration would then reference a provider a fresh clone does not have, breaking the worked example on first run. Vendor neutrality lives in the contract; one implementation in the box does not compromise it.
- **Endpoint shapes in a configuration file with the code compiled.** Looks like it buys fast fixes; actually makes TBD execute a schema it does not own, versioned forever.
- **A per-session streaming transcript follow.** A per-session stream is a new supervision shape — one process per session rather than per provider — and v1 already cut `log --follow` for that reason. Cursor polling first.
- **Teleport as the read path.** Landing forks the conversation; using it to view a session would create a worktree per refresh.
- **Filtering archived sessions out of `list`.** They would look absent and trip the drift rule, and TBD would lose the archived inventory the revive flow browses.
- **Encoding capabilities in the repository declaration.** A machine-readable statement of what a remote can do is a policy grammar; a prose label is not, and suffices for choosing.

## Deliberate cuts

No `stop` for cloud sessions, since nothing exposed terminates a running VM — archiving retires it instead. No `log` for cloud sessions, since there is no terminal to scroll. No diff or file viewer for remote workspaces. No automatic landing or archiving on any session state. No handling of concurrent drivers on one session, per the single-account assumption. No publishing of TBD's local sessions back for viewing elsewhere — the inverse direction is a separate idea, and TBD's own sessions can already enable it themselves.
