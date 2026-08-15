# Claude cloud sessions in TBD — contract v2, a built-in provider, landing, and repo-declared remotes

**Date:** 2026-08-07
**Status:** Design, not yet implemented.
**Scope:** Four changes shipping together — an additive revision of the remote provider contract, a provider implementation compiled into the daemon, a path from a remote session to a local worktree, and a per-repo declaration of which remotes a repository runs on.

## Summary

TBD gains the ability to create, watch, steer, archive, and land **Claude cloud sessions** — Claude Code sessions running on Anthropic's hosted infrastructure, reachable today only from claude.ai, the mobile and Desktop apps, and `claude --cloud` in a terminal.

The integration rides the existing remote agent backend contract
([`2026-07-24-remote-agent-backends-design.md`](2026-07-24-remote-agent-backends-design.md),
[`../remote-provider-contract.md`](../remote-provider-contract.md),
[`2026-08-10-remote-sessions-in-worktree-tree-design.md`](2026-08-10-remote-sessions-in-worktree-tree-design.md))
rather than introducing a parallel concept. Cloud sessions become remote
sessions like any other: same mirror table, adopted as worktree rows in the same
tree, same health and auth machinery. What is new is that this is TBD's
**second** provider, and a second implementation exposes places where a contract
written against one implementation is unsound.

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

**The negotiation machinery has to be built first, and it spans two processes.**
`describeProvider` hard-requires that `describe.contractVersions` contains `1`,
and **three** call sites hardcode `TBD_CONTRACT_VERSION=1`:

- `ProviderRunner.run` — the daemon's ordinary verb path.
- `ProviderEventsSupervisor` — the daemon's long-lived `events` stream, spawned
  outside the runner.
- `RemoteAttachTerminalView.attachEnvironment` — **in `TBDApp`, not the daemon.**

The third is the one that makes this more than a parameter change. The app
spawns `attach` itself, directly on the pane's PTY, and never passes through
`RemoteProviderInvoking`. Negotiated state held in `RemoteProviderManager` is
therefore invisible to it: built as a daemon-side concern alone, `attach` would
go on announcing major 1 forever while every other verb for the same provider
had negotiated 2. The comment above that call site already warns that the
variable must not diverge across invocations, which is exactly the failure this
would cause.

So the negotiated major is resolved at `describe` time, stored per provider, and
made to reach all three: a parameter on `RemoteProviderInvoking` for the runner,
the same value threaded to the events supervisor when it spawns, and a field on
`RemoteProviderStatus` for the app — which already carries `config`, `describe`
and `health` over `remote.providers`, and is already in hand where the attach
environment is built. One resolved value, three consumers, no second source of
truth. This is small but it is a protocol and wire change, not a free ride on
existing code.

### Snapshots declare whether they are complete

The v1 drift rule marks a session `gone` after it is absent from two consecutive successful snapshots. `RemoteSessionStore.applySnapshot` increments `missingCount` for every row it did not see, with no notion of whether the provider could see everything. That is correct only when the provider enumerates its own inventory, and wrong for one that can enumerate only part of it.

The `list` envelope and the `events` stream's `snapshot` event gain a boolean:

```json
{"complete": true, "sessions": [...]}
```

- `complete: true` — the provider's full inventory. TBD applies the `gone` rule exactly as in v1.
- `complete: false` — a partial view. TBD may add, update, and adopt rows, and **must not** increment `missingCount` or retire anything.
- Absent — treated as `true`, so v1 providers are unaffected.

`complete: false` also does **not** advance freshness — but it does clear degraded health, and it does still adopt. The three have to be separated to avoid a trap. `RemoteProviderManager.apply` runs all three on any accepted snapshot: it adopts the sighted sessions (`broadcastAdoptions(await adopter.adopt(sessions:provider:))`), stamps `lastSuccessfulSnapshotAt`, and calls `markHealthy`. The last two drive the staleness indicator and the mutation gate from [`2026-08-01-remote-stale-snapshot-design.md`](2026-08-01-remote-stale-snapshot-design.md).

They answer different questions. **Adoption asks whether a session was observed**, and a session that appears in a partial view has been positively observed, so it gets its worktree row exactly as it would from a complete snapshot — which is the contract's standing "It MAY adopt sessions it has not seen before" rule, and it holds at either completeness. Adoption is therefore **not** gated on the freshness stamp, and must not be made to look as though it were: it runs before the stamp for a reason of its own, reading the repo association `applySnapshot` has just pinned. **Health asks whether the provider is reachable**, and an incomplete snapshot is a successful invocation — the provider answered — so it clears a degraded health state exactly as a complete one does. **Freshness asks when TBD last held a full inventory**, which a partial view by definition does not establish, so `lastSuccessfulSnapshotAt` advances only on a complete snapshot.

Conflating them either way is a bug. If a partial snapshot stamped freshness, a half-blind inventory would present as current and mutations would re-open against it. If a partial snapshot left health degraded, a provider whose steady state is `complete: false` could never recover from a single transport hiccup: health would stay degraded, `lastSuccessfulSnapshotAt` would remain non-nil from before, `hasStaleSnapshot` would stay true, and Create and Send would be blocked permanently — the opposite of the degradation this design claims. Splitting the two keeps mutations available against a reachable provider while never retiring a session on partial evidence.

**Freshness has two stores, and an incomplete snapshot suppresses both.** `RemoteSessionStore.applySnapshot` writes a persisted per-provider freshness key into `tbd_meta` in the same transaction that updates the mirror, and `RemoteProviderManager` recovers that key into `lastSuccessfulSnapshotAt` whenever the in-memory value is absent — after a daemon restart, most of all. Suppressing only the in-memory stamp would leave a partial snapshot presenting as a full inventory the moment the daemon came back, re-opening precisely the mutation gate the in-memory rule closes. So an incomplete snapshot writes neither, and the persisted key keeps meaning what its in-memory twin means: the last time TBD held everything.

**`complete` means complete with respect to the set TBD mirrors** — including archived sessions, per the next section. A provider that can enumerate active sessions but not archived ones reports `complete: false`.

### Archived is a third axis

The Session object gains `archived: bool`, defaulting false. It is orthogonal to `state` (process liveness) and `agent_state` (attention): a session can be archived while its machine is still winding down, and an active session is never implicitly archived.

Archived sessions are **returned by `list`, not filtered out of it.** TBD decides what to show — active by default, archived behind a filter, mirroring the local History pane. Filtering server-side would make archived sessions look absent and trip the drift rule, and would deny TBD the archived inventory it needs for the browse-and-revive flow.

**Carrying `archived` through to the adopted row's status is part of this work, not a consequence of it.** A session that resolves to a registered repo is a worktree row ([`2026-08-10-remote-sessions-in-worktree-tree-design.md`](2026-08-10-remote-sessions-in-worktree-tree-design.md)), and today nothing joins a payload's `archived` to that row: `worktree.archive` refuses a remote row outright, the auto-archive-on-merge rail skips one, and no other path writes `status` from a snapshot. So a session archived from claude.ai or another device would keep its lane in the active tree indefinitely. This design closes that: `archived: true` on a sighted session flips its row to `archived`, `archived: false` returns it to `active`, and archiving from TBD writes both sides through the composition below. Both directions are prerequisites for browsing and reviving rather than niceties — the flow browses archived lanes, and a lane that never becomes archived is never in the list being browsed.

Display follows the same axis on both surfaces. `AppState.visibleWorktrees` drops archived rows from the tree, so an archived lane leaves it for the archived list exactly as a local worktree does; and the session-row list shows active sessions by default, so the archived session does not re-emerge there as a bare row once its lane's worktree row is gone from the active tree. One lane, one surface, whatever its filing state.

Two new capabilities: `archive <id>` and `unarchive <id>`, both idempotent, both returning the session object. They compose with the row's own archived state rather than duplicating it, and what TBD does depends on what the provider declares:

- **`archive` declared** — TBD calls it and marks the row archived. The retirement is a fact on the backend, so other clients of it see the same thing.
- **`stop` declared but not `archive`** — TBD stops the session and marks the row archived. Ending the compute is as close to retiring as such a backend comes.
- **Neither declared** — TBD marks the row archived and touches nothing on the provider. The session keeps running and the lane says so.

`unarchive` runs the first case backwards, and the row follows it. A lane archived with no provider call at all is revived by the row flipping back, since nothing was retired anywhere else. Where a provider declares `archive` and no `unarchive`, the retirement stands on the backend and TBD offers no unarchive action rather than one that would fail. The row-level rule for all of this is the 08-10 design's Archive and Revive sections; this is the same rule read from the contract side.

### `stop` becomes a capability, distinct from archiving

v1 makes `stop` required and folds two operations into it — terminating the compute, and retiring the session from the inventory. One provider could do both in one call, so nothing forced them apart. A provider whose sessions are reclaimed by the platform on inactivity, with no termination call exposed to clients, can retire a session but cannot terminate one; a backend that kills processes and keeps no durable inventory is the same asymmetry the other way round.

So `stop` joins the declared capabilities and means only *terminate a running session*. Retiring is `archive`. `describe`, `create`, and `list` remain required. A provider declaring one, the other, both, or neither is conformant, and the caller composes over what it finds rather than assuming one verb covers both acts.

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

- **Two consecutive complete snapshots retire a resolved ledger row.** A row absent from that many enumerations is a session that no longer exists, and the ledger drops it rather than re-asserting it. Without retirement, "TBD launched it once" silently becomes "it exists permanently," and a session deleted from claude.ai could never tombstone. The count matches the mirror's `gone` rule deliberately, and for the same stated reason: a single absence is not enough, because transports flake and a snapshot can call itself complete while having transiently missed something. Retiring on one absence would also be worse here than in the mirror — the ledger is what keeps TBD-launched sessions visible when discovery is unavailable, so a row dropped on a flake takes that fallback with it. **`pending` rows are exempt**; they carry no session id to match against a snapshot and are governed solely by the ten-minute window below.
- **A ledger-only row carries `state: "unknown"`,** never a fabricated `running`. The contract forbids conflating unreachability with liveness, and with discovery down the ledger knows only that a session was created, not whether it lives. `agent_state` is likewise `unknown`.
- **Ledger rows never suppress a discovered row.** Where both exist the discovered payload wins; the ledger contributes only rows discovery did not return.

### Verb implementations

- **`describe`** — static and offline. Declares `send`, `attach`, `transcript`, `land`, `archive`, and `unarchive`; declares neither `stop` nor `log`. It reports **`contract_versions: [2]`, not `[1, 2]`** — nothing exposed terminates a running cloud session, so it cannot implement `stop`, and major 1 requires it. This is the one place in these documents where the `[1, 2]` idiom every other example shows would be wrong, and declaring a major means conforming to it. `create_params` are `repo`, `branch`, `prompt`, and `environment`.

  **`environment`** names a cloud environment configured on the account — the saved bundle of network policy, environment variables, and setup script a session runs under. It is typed `string`, not `enum`, because `describe` must answer offline and the set of environments is only knowable from the account. An empty or absent value means the account's default environment; an unrecognized name is the provider's error to report at create time, not TBD's to pre-validate. It is the param a repository is most likely to want to declare, since which environment a repository's sessions need is a property of the repository — and, being a name rather than a script or a command, a declared value can select among configurations the account already has but cannot author a new one. That does not exempt it from the trust gate, which shows every declared param whatever its name.
- **`create`** — `claude --cloud "<prompt>"` from the repository checkout.
- **`list`** — ledger union discovery, per above.
- **`send`** — `claude -p "<msg>" --cloud <id> --output-format json`, returning `{ok, session_id, url}`. A structured enqueue with an acknowledgement, not keystrokes into a terminal, so it carries none of the delivery-confirmation problems a keystroke transport has.

  The contract's `send` takes stdin bytes destined for a terminal, and requires the caller to append `\r` when it means Enter. That interface does not change here: TBD sends the same bytes it would send any provider. The provider decodes them as UTF-8 and **strips a single trailing `\r` or `\n`**, treating it as the submit gesture it is, then passes the remainder as one message. A byte stream carrying interior newlines becomes one multi-line message rather than several. What the contract fixes is the caller's side of the wire; how a provider delivers those bytes to its session has always been the provider's business, and for a session with no terminal, delivering them means enqueuing a message. Exit 0 keeps its contract meaning — handed to the transport, not acted upon.
- **`attach`** — `claude --cloud <id>` on the pane's PTY, spawned directly (below).
- **`transcript`** — reads the server-stored transcript for the session, cursor-tailed.
- **`land`** — the session's repository and branch, with `resume_command` of `claude --teleport <id>` and `forks: true`.
- **`archive` / `unarchive`** — the account's archive operation over the undocumented surface. An archived session rejects new messages, which is why archiving is a real state change and not a display preference. It is not a termination: nothing here ends a running VM, which is also why no `stop` is declared. So archiving a cloud lane takes the archive-verb path with the 08-10 design's termination guards inapplicable, and `unarchive` puts the lane back.

### Create idempotency, against the as-built handler

`handleRemoteCreate` mints a **fresh** idempotency key on every RPC call, retries **once with the same key** when the provider times out, and deliberately does not persist it. That shape means the key defends exactly one thing — a transport timeout on a create that may have started — and defends nothing against a user clicking Create twice, which produces two keys and two sessions.

The ledger changes what is possible without changing that handler's retry:

- The key and its state are written to the ledger **before** the invocation. The daemon's single same-key retry proceeds normally; a pending row is expected during it, not a reason to refuse.
- If both attempts fail, the row stays `pending` and is surfaced as an unresolved create the user can act on — never silently dropped, because the session may well have started.
- A pending row is resolved by the next complete discovery: a session matching its repository, branch and creation window adopts the row. A complete snapshot containing no such session **ten minutes** after the create transitions the row to `failed` and stops surfacing it to the user. The row itself is **retained for 24 hours**, then deleted — it stops being a prompt for attention long before it stops existing, which is what lets a late-arriving session still be matched against it. Twenty-four hours is sized to the gap it has to span: the time between a create and that session first appearing in a complete snapshot. Provisioning is not what makes that gap long — it runs in minutes even with a heavy setup script, which is why ten minutes suffices for the failure judgement itself. What makes it long is **discovery being unavailable**, which is the condition the ledger exists for in the first place. A day covers an outage lasting a full working day and then some, and past that horizon there is usually nothing left to adopt anyway: a cloud session idle that long has had its environment reclaimed.

The consequence of being wrong is small in the direction that matters, which is why a generous round number is adequate rather than a number worth deriving precisely. If a session does surface after the row is deleted, it is not lost — discovery returns it and TBD adopts it as a session it did not create, which the contract already requires. What is lost is only the provenance link back to the create that started it.

Both directions of getting that number wrong are user-visible. Too short and a slow-provisioning session — capacity is allocated on demand, and a setup script runs before the session is usable — is declared failed while it is still coming up, stranding a real session outside TBD's inventory. Too long and a create that genuinely failed sits as `pending` in front of the user with nothing to act on.

A compiled duration is exactly the shape [`../theory-placement.md`](../theory-placement.md)'s tunable-number test flags, so it is worth saying why this one stays compiled while the supervision thresholds it resembles did not. The two-reasonable-projects test is what separates them: "when is an agent stuck" is contested because one repository's forty idle minutes is another's normal test run, whereas how long a vendor takes to provision a machine is a property of that vendor's infrastructure, not of anyone's working style. The named-consumer test agrees — no repository wants a different provisioning-latency assumption, and if the real latency changed, the correct response would be to change the value for everyone rather than to hand out a knob. It stays compiled, and it is a fact TBD is asserting about a vendor, not a judgement about the user's work.

That argument has one soft edge worth naming rather than glossing, because the paragraph above names it: a repository's setup script runs before a session is usable, and setup scripts are repository-authored. A setup-script-heavy repository is therefore a real, nameable consumer of a longer window — structurally the same shape as the idle-time case this argument distinguishes itself from.

What answers it is not a knob but the floor, which the constant ships with regardless: **a session that appears in a later complete snapshot and matches a pending row already cleared as failed is adopted, not ignored.** The repository whose provisioning runs past ten minutes does not get a wrong answer; it gets a row that arrives late and is then correct. That is why the named consumer does not force the theory out to user-land here, where an unrecoverable misjudgement would have: the cost of the constant being wrong for them is bounded to latency, not correctness.

A window set too short therefore costs a delayed sidebar row rather than a lost session, and the adoption is logged — which is also the evidence that would justify changing the number. The threshold is revisable; being wrong about it is recoverable and visible rather than silent.
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

Storage needs a decision, because the transcript renderer cannot simply be pointed at provider bytes. `TranscriptParser` is file-path-based and is reached from several places that are **not** guarded alike. `handleSessionMessages` constrains its path to the Claude projects store, resolved through the same single point as `ClaudeProjectDirectory.resolve` so guard and resolver cannot disagree. The terminal handlers do not: where a terminal row carries a `transcriptPath` they read it verbatim, through `parse`, `parseTail`, and `lookupDetail` alike, and the only validation that field ever receives is an absoluteness check at write time in the sessionEvent handler. The comment on the guarded call site asserts it shares a trust boundary with the unguarded ones, which is how the asymmetry stays invisible.

Spooling vendor JSONL into the Claude store would also make `ClaudeSessionScanner` list a cloud conversation as a local session of the worktree.

So remote transcripts live in a TBD-owned root, `~/tbd/remote-transcripts/<provider>/<sessionID>/`, with a path helper in `TBDConstants` honoring `TBD_HOME`. Keeping them out of the Claude store is what stops session scanning from finding them at all, which is the property that matters — the scanner looks under a projects root resolved from a worktree path, and a root TBD owns is not one it searches.

**The two-root boundary is enforced at a single choke point, not per call site.** Every read goes through one resolver that takes an untrusted path and returns either a validated path under one of the two permitted roots or a refusal, and `TranscriptParser`'s entry points are reachable only through it. Enumerating handlers is what produced the current state: the guard was written for one call site, a second was added without it, and a third — `lookupDetail`, serving item-full-body requests — reads the same field independently. A list of call sites is a list that grows, and every future entry point starts unguarded by default. A choke point fails the other way round.

Closing that asymmetry is a prerequisite of this work rather than a side effect: a second permitted root is only safe where a boundary is actually checked, so the resolver has to exist before the TBD-owned root is admitted to it.

Cursor-tailed responses append to the TBD-owned root, which is also what gives a remote transcript continuity across daemon restarts.

**One open empirical question, worth answering before implementation.** Interactive Claude Code sessions always persist to disk — `--no-session-persistence` is documented as working only with `--print` — so `claude --cloud <id>` may already write an ordinary transcript JSONL locally. If it does, attaching once populates a remote session's transcript for free, and the `transcript` verb becomes the path for never-attached sessions rather than the only path. It also means the attach process must be pointed at the TBD-owned root rather than the default store, or a cloud conversation will surface as a local session of whatever worktree the pane ran in. The test is one command on a Mac: attach to a cloud session, then look for a new JSONL under the Claude projects store. The design above works either way; the answer only decides how much the `transcript` verb has to carry.

Minor and worth handling in the same pass: the transcript renderer turns file paths in tool calls into clickable local links. A remote transcript's paths refer to a different machine, so linking is suppressed for remote rows rather than dead-ending or opening an unrelated local file.

### Agent state and credentials

Agent state comes from the discovery response's session status, mapped onto `working` / `waiting_input` / `idle` / `exited`. Any value that does not map cleanly becomes `unknown` rather than a guess, and with discovery unavailable every row is `unknown` and TBD shows liveness only. No agent state is ever derived from rendered terminal output, including the attach pane's.

The undocumented half authenticates with the claude.ai credential `claude auth login` already stores; nothing new is minted or synced, and the documented half shells out to `claude`, which handles its own auth. Credential reads go through an injected seam so tests never touch a real credential store.

## Part 3 — Landing and reviving

### The land bridge

A session that resolves to a registered repo already **is** a worktree row: adoption mints one on first sighting, and the sidebar renders that row instead of a separate session row ([`2026-08-10-remote-sessions-in-worktree-tree-design.md`](2026-08-10-remote-sessions-in-worktree-tree-design.md)). So **Land is an action on that worktree row**, enabled when the row's provider declares `land`.

**Landing converts the row in place.** `remote.land` calls the verb, validates the returned fields per Part 1, materializes the git worktree through the existing lifecycle path, checks out the branch, spawns the first pane running `resume_command` when one is given, and flips the row's `WorktreeLocation` from `.remote(provider:sessionID:)` to `.local`. One row throughout: same id, same lane, keeping its display name, PR badge, position in the tree, and children. Landing is where a lane's files arrive on this machine, not where a second lane begins.

Preconditions are checked before anything is created, so a failure never leaves a half-built worktree or a half-converted row — the row stays `.remote` and the lane is exactly as it was. The local repository's configured remote must match `remote_url`, the branch must exist on the remote, the target worktree path must be free, and the branch must not already be checked out in another worktree, since `git worktree add <path> <branch>` refuses to check one branch out twice. Landing is always a user gesture, never triggered by session state.

**A session that was never adopted has nothing to land into.** Adoption's existence rule is that a row exists exactly when the session resolves to a registered repo, so an unadopted session is one TBD cannot match to a repository — and landing needs that repository, because `remote_url` is validated by comparison against its configured remote. Such a session appears only in the Provider Desk and is offered no Land action. Registering its repository adopts it on the next convergence, and the action arrives with the row.

**A fork is shown as a fork.** With `forks: true`, the landed checkout and the provider-side session diverge from the moment of landing, and TBD never implies that typing in one reaches the other. There is no second row to carry that fact, because the converted row *is* the local side of the fork — what it has to keep is where it came from.

**Origin lives in the columns that already bound the row to its session.** `providerName` and `providerSessionID` are on `worktree` from migration `v70`, and landing clears neither. They stop being a live binding and become provenance: `location` is what says which, so a `.remote` row with the pair set is a lane running on the provider, and a `.local` row with the pair set is a lane that was landed from one. The row renders that origin — the cloud session it was reconstructed from — instead of the remote indicator it carried before. Two readers key on those columns and must read them the same way. `WorktreeStore.findRemote(provider:sessionID:)` filters on the pair alone, which is what stops adoption from minting a second row for a session whose lane has already landed. The sidebar's session-row filter keys on `location` today and moves to the same pair, so a still-listed session does not reappear as a bare session row beside its own landed lane.

Holding provenance there is what makes the columns' rule "set whenever a row has a provider session behind it, past or present" rather than "set only alongside `location = 'remote'`": `WorktreeRecord` writes the pair for a landed local row too, and reads a row as `.remote` only when `location` says so, which it already does. That is a change of invariant, not of schema, and it is the whole of what in-place conversion asks of the table.

**The provider-side session survives the landing; TBD retires it where it can, and never kills it.** `land` itself changes nothing on the provider — the contract makes it a question, not an act — so what happens next is TBD's choice, and it uses archive's vocabulary from the 08-10 design. With `forks: true`, the work has moved to this machine and a session nobody will return to should not sit in the working set: TBD archives it where the provider declares `archive`, and where it does not, leaves the session running and says so on the row rather than claiming a retirement it did not perform. It never stops the session, whatever `stop` the provider declares: landing is a "bring this home" gesture, not a teardown, and the remote box may still hold work that was never pushed. With `forks: false` the session is left in the working set untouched — the landed copy and the session are one conversation, and retiring it would retire work the user is still doing.

That archive does not travel back to the row. Mirroring a provider's `archived` onto a row's status applies while the row is remote, so retiring the session TBD just landed from cannot archive the lane the user is about to work in. The lane is local now, and its filing state is TBD's own from that point.

A landed session is therefore landed once. The action lives on the row, the row becomes local, and `findRemote` keeps the session from being adopted into a fresh one — so the second-landing case the contract permits for `forks: true` providers is simply not offered here. Two independent local lines of work off the same session remain available the way they are for any other worktree: branch from the landed lane.

### Lifecycle parity with worktrees

Local worktrees already carry the model this needs: `WorktreeStatus` includes `archived`, rows keep `archivedAt`, `archivedHeadSHA` and `archivedClaudeSessions`, and both revive modes exist — plain Revive restores the archived branch and session, while Revive-fresh creates a new worktree off `origin/<default>` seeded with a forked conversation, leaving the archived row untouched ([`2026-07-27-revive-conversation-fresh-branch-design.md`](2026-07-27-revive-conversation-fresh-branch-design.md)).

Remote sessions get the same vocabulary and the same two revive modes. Both are about reconstructing the work *here*; returning an archived lane to the provider's own working set is `unarchive`, and leaves the lane remote.

- **Revive on the session's own branch** is `land` as described above.
- **Revive on a fresh branch off `origin/<default>`** composes: land, then run TBD's existing revive-fresh on the landed worktree.

Composition rather than a new verb is deliberate. Teleport is branch-coupled — it fetches and checks out the session's own branch and requires that branch to have been pushed — so a one-gesture fresh-branch landing would mean separating teleport's conversation fetch from its branch checkout, which nothing documented supports. The cost of composing is an intermediate worktree the user did not ask for. If that proves annoying in practice, the graduation is a branch mode on `land`, and the field evidence for it is the annoyance itself.

**The vocabulary is shared because the model is.** A remote session *is* a worktree row: it carries `location: .remote(provider:sessionID:)` from `WorktreeLocation`, nests in the tree under the lane that spawned it, and archives like any other row ([`2026-08-10-remote-sessions-in-worktree-tree-design.md`](2026-08-10-remote-sessions-in-worktree-tree-design.md)). `LocalWorktree` is what keeps the local-only subsystems — terminal spawn, hibernation, reconcile, the file viewer — structurally unable to reach one. This design composes with that model rather than standing beside it: the `remote_session` mirror stays what it is, provider-owned liveness that adoption reads, and the `remote.*` RPC family stays the path to the provider's verbs, but nothing here introduces a second kind of row. Landing does not add a row either — it changes one row's location, which is exactly the boundary `WorktreeLocation` was introduced to make crossable. Everything the fence held back from that lane becomes reachable at the moment its files exist, and nothing else about the lane moves.

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
- Approval is stored as the SHA-256 **of the file's exact bytes**, keyed by repository. Not of a parsed or normalized form: any canonicalization that reordered or reserialized the `remotes` array would let a committer change which remote is offered first — which is to say, change the default — without moving the hash and without re-prompting, defeating the gate at precisely the decision it exists to guard. Hashing raw bytes costs a re-approval after a whitespace-only edit, which is the correct direction to err. **Any change to the file re-prompts**, so approving once never blanket-approves whatever lands on the branch next week.
- Until approved, resolution skips the declaration and falls through to the next tier, with a visible flag in the repository's settings. Unapproved is a degraded state, not a blocked one.
- TBD reads only `provider`, `label`, and `params`. `provider` must name a locally registered provider or the reserved built-in name; it is a reference, never a definition. `label` is length-capped plain text. `params` values must be strings and are dropped if their name is absent from `create_params`. Unknown top-level keys are ignored per forward-compatibility, and ignored means *not interpreted* — TBD never grows a key that turns repository content into something it runs.

The declaration also carries no statement of what a remote *can do*. A grammar for capabilities is a policy language TBD would have to interpret and version permanently; the label is prose a human reads, and the human picks.

### Resolution

Location for a new session resolves most-specific-first:

1. **Explicit per-creation choice** in the create sheet. Always available, always wins.
2. **The repository's approved declaration.** Several declared remotes are offered in order with their labels.
3. **Global default location**, when configured.
4. **Local.**

A declaration naming an unregistered provider is configuration drift: resolution degrades to the next tier and the app flags it, rather than blocking creation. **A declaration naming a built-in provider whose flag is off degrades identically** — `claude-cloud` is compiled in rather than registry-loaded, so it does not fall under "unregistered" and needs saying separately. It is skipped at resolution and, importantly, **its trust prompt is never shown**: asking a user to approve a declaration for a disabled feature would display a prompt value for something that cannot run, and would leave an approval recorded for a decision they never got to act on. A disabled feature stays invisible rather than surfacing as a create that fails at the RPC gate with an error explaining nothing.

Repo-less scratch spaces always resolve to local.

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

**When `remote_backends_enabled` is deleted**, its gate is removed and `claude_cloud_enabled` becomes the sole gate for the cloud provider, with the external-provider path ungated as v1's rollout intends. That ordering matters: deleting the outer flag while the inner one is still soaking must not turn cloud on for anyone, so the deletion migration leaves `claude_cloud_enabled` untouched.

### Unset is a third state

The column is added with **no** SQL default — `addColumnIfMissing(table:column:type:)` with `defaults:` omitted — so it stays genuinely NULL until somebody touches the toggle:

- **NULL** — nobody has chosen. Resolves to the shipped default.
- **0 / 1** — an explicit gesture, honored forever.

Passing `defaults:` would make `ADD COLUMN ... DEFAULT` backfill every existing row, and the singleton `config` row is seeded naming only two columns, so a fresh install and an old one would both read `0` — indistinguishable from a deliberate opt-out. That distinction is destroyed on write and cannot be recovered later, which is why this is a decision at migration time rather than something to fix on graduation.

The shipped default therefore lives in exactly one place: `ConfigRecord.toModel()` resolving `claude_cloud_enabled ?? Config.claudeCloudEnabledDefault`. **Graduation is a one-line edit to that constant.** It reaches everyone who never touched the toggle and preserves every explicit opt-out — which matters more here than for most flags, because this feature calls a network service on a schedule and somebody who turned it off did so deliberately.

Three states, three assertions: a pre-migration row reads NULL rather than `0`; an explicit `false` survives a change to the default constant; a NULL row follows it.

Graduation for this flag is that default flip after soak, then deletion, once discovery has held up across a few endpoint revisions.

## Migrations and models

Each following the shared-model rule — migration, GRDB record, and the `TBDShared` Codable model in one commit, new fields optional or defaulted:

- `claude_cloud_session` — the ledger table, including idempotency key state.
- `config.claude_cloud_enabled` — the flag. Added with **no** SQL default so unset stays NULL; the shipped OFF default resolves in `ConfigRecord.toModel()` (see "Unset is a third state" above).
- `repo.remotes_declaration_trusted_sha` — the approved declaration hash, nullable.

**No table gains a column for landing or for archiving, and `remote_session` gains none at all.** `archived` rides in the payload the mirror already stores. Landing is a change of state on one existing row: `location` flips to `local` and a real path replaces the synthetic `remote://` URI, both columns present since `v70`, and `providerName`/`providerSessionID` — also `v70` — carry the origin afterwards. What changes is the rule those two columns obey (see the land bridge above): they are written for a landed local row rather than only for a remote one. That is a write-path and invariant change in `WorktreeRecord`, with no schema edit and nothing to migrate, since every existing row already satisfies the wider rule.

New poll intervals and timeouts take an injected `clock` parameter; persisted timestamps use the date seam.

## Testing

No test reaches the network or a real credential store: the undocumented transport sits behind an injected client protocol, credential reads behind an injected seam.

- **Contract v2** — `complete: false` adds, updates and **adopts** rows but never increments `missingCount` and never advances freshness in either store — neither the in-memory `lastSuccessfulSnapshotAt` nor the persisted `tbd_meta` key, asserted by restarting the manager after an incomplete snapshot and finding it still stale — while still clearing a degraded health state, so a provider whose snapshots are always incomplete recovers from a transport failure and keeps Create and Send available; absent `complete` behaves as `true`; a v1 provider negotiates v1 and is unaffected; `archived` rows are returned by `list` and filtered only for display; a provider that omits `stop` gets no stop action.
- **Version negotiation** — a provider declaring `[1, 2]` negotiates 2, one declaring `[1]` negotiates 1, one declaring `[3]` alone is refused with a clear error; `describe` itself carries the caller's highest supported major, and a provider's `describe` response is identical whatever that value is. All three emitters agree for a given provider: the runner, the events supervisor, and the app-side attach environment. The last of those is the regression test that matters — assert the negotiated major reaches `RemoteProviderStatus` and is what the attach environment emits, since that path crosses a process boundary and is the one that would silently keep announcing 1.
- **Transcript boundary** — every read reaches `TranscriptParser` through the one resolver; a path under the Claude store and a path under the TBD-owned root are both accepted; anything else is refused, including a traversal that escapes either root after normalization; the refusal holds for `parse`, `parseTail` and `lookupDetail` alike, so an entry point added later cannot be reached unguarded.
- **Ledger union** — **two consecutive** complete snapshots omitting a resolved ledger row retire it, and a single omission does not, so a row that reappears in the second snapshot survives; an incomplete snapshot never counts as an absence at all; a `pending` row is never retired by this rule whatever the snapshots say; a ledger-only row reports `state: unknown`; a discovered row wins over a ledger row for the same id.
- **Idempotency** — the daemon's single same-key retry succeeds against a pending row rather than being refused; a doubly-failed create leaves a surfaced pending row; discovery adopts a pending row, and ten minutes of complete snapshots with no match marks it failed, evaluated through the date seam rather than a `Clock<Duration>`, since it compares a persisted creation timestamp against now — `Duration` is behavior, `Date` is data; a matching session arriving after that is still adopted rather than ignored, which requires the failed row to still exist — so retention is asserted directly: a failed row survives to the 24-hour horizon and is gone after it; Create is disabled while a create for the same repository and parameters is in flight; a `send` byte stream ending in `\r` reaches the provider as a message with the terminator stripped and interior newlines preserved.
- **Attach** — `permanent` does not arm automatic reconnect while `unexpected` does; a failed eligibility preflight still offers attach; nothing reads attach output.
- **Land** — landing converts one row in place: the same row id comes back `.local` at a real path, keeping its display name, parent edge, children, and PR badge, and no second row appears for the session. Each precondition failure — remote mismatch, missing branch, occupied path, branch already checked out elsewhere — is reported without creating a worktree and leaves the row `.remote`, unchanged. `providerName`/`providerSessionID` survive the conversion, so the landed row reports its origin, the next snapshot does not re-adopt the session into a fresh row, and the session does not render as a bare session row beside the landed lane. With `forks: true` the provider session is archived where `archive` is declared and left running where it is not, and is never stopped whatever `stop` the provider declares; with `forks: false` it is left in the working set untouched. The landed row stays `active` through all of it — a later snapshot reporting that session `archived: true` does not archive the lane, because mirroring reaches remote rows only. A session that resolves to no registered repo has no row and is offered no Land action. A `branch` beginning with `-` and an `ext::`-style `remote_url` are both rejected before reaching git.
- **Archive composition** — a provider declaring `archive` is archived through the verb, one declaring only `stop` is stopped, one declaring neither has its row flipped alone with no provider call; each ends with the row `archived` and out of the active tree. A session sighted as `archived: true` flips its row without touching `state`, and `archived: false` returns it to `active`. An archived lane appears in the archived list and not as a session row. `unarchive` is offered only where declared.
- **Repo declarations** — an unapproved declaration does not resolve; editing an approved file re-prompts, including an edit that only reorders the `remotes` array, since the hash is over raw bytes and reordering changes which remote is offered first; `prompt` is displayed in full at the approval gate; a params key absent from `create_params` is dropped; command-shaped top-level keys are ignored; the root checkout's copy wins over a worktree's; a declaration naming a built-in provider whose flag is off degrades to the next tier **and shows no approval prompt**.
- **Flag branches** — all four combinations of the two flags; and the three states of `claude_cloud_enabled` are distinguishable: a pre-migration row reads NULL rather than `0`, a NULL row follows a change to `Config.claudeCloudEnabledDefault`, and an explicit `false` survives one.
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

No `stop` for cloud sessions, since nothing exposed terminates a running VM — archiving retires it instead. No `log` for cloud sessions, since there is no terminal to scroll. No diff or file viewer for remote workspaces. No landing or archiving driven by liveness or agent state — TBD never lands or retires a lane because a session went idle, exited, or aged out; the archive that follows a landing follows the user's gesture, and mirroring a provider-reported `archived` follows a filing decision a human already made elsewhere. No handling of concurrent drivers on one session, per the single-account assumption. No publishing of TBD's local sessions back for viewing elsewhere — the inverse direction is a separate idea, and TBD's own sessions can already enable it themselves.
