# Claude cloud sessions in TBD — contract v2, a built-in provider, landing, and repo-declared remotes

**Date:** 2026-08-07
**Status:** Design, not yet implemented.
**Scope:** Four changes shipping together — an additive revision of the remote provider contract, a provider implementation compiled into the daemon, a path from a remote session to a local worktree, and a per-repo declaration of which remotes a repository runs on.

## Summary

TBD gains the ability to create, watch, steer, and land **Claude cloud sessions** — Claude Code sessions running on Anthropic's hosted infrastructure, reachable today only from claude.ai, the mobile and Desktop apps, and `claude --cloud` in a terminal.

The integration rides the existing remote agent backend contract
([`2026-07-24-remote-agent-backends-design.md`](2026-07-24-remote-agent-backends-design.md),
[`../remote-provider-contract.md`](../remote-provider-contract.md)) rather than
introducing a parallel concept. Cloud sessions become remote sessions like any
other: same mirror table, same sidebar rendering, same health and auth
machinery. What is new is that this is TBD's **second** provider, and a second
implementation exposes places where a contract written against one implementation
is unsound.

Three facts shape everything below.

- **The documented surface is partial.** `claude --cloud "<prompt>"` creates a session, `claude -p "msg" --cloud <id>` sends to one, and `claude --cloud <id>` attaches a terminal to one. There is no documented way to enumerate sessions, stop one, or read one's conversation.
- **The conversation lives on a server, not in a terminal.** Anthropic stores the transcript — messages, responses, and tool activity — and every client syncs against it. Reading a cloud session is not reading scrollback.
- **Landing work locally is a fork.** `claude --teleport <id>` fetches the session's branch and conversation history into a checkout, but subsequent local work does not flow back. It is a one-time move, not a view.

## Part 1 — Contract v2

Four additive changes. Contract major becomes `2`; `TBD_CONTRACT_VERSION=2` rides on invocations to providers that negotiate it. A v1 provider keeps working unchanged.

### Snapshots declare whether they are complete

The v1 drift rule marks a session `gone` after it is absent from two consecutive successful snapshots. That is correct only when the provider enumerates its own inventory. A provider that can enumerate only part of its inventory would tombstone live sessions.

The `list` envelope and the `events` stream's `snapshot` event gain a boolean:

```json
{"complete": true, "sessions": [...]}
```

- `complete: true` — this is the provider's full inventory. TBD applies the `gone` rule exactly as in v1.
- `complete: false` — a partial view. TBD may add and update rows from it, and **must not** increment `missingCount` or retire anything.
- Absent — treated as `true`, so v1 providers keep their existing behavior.

A provider whose snapshots are never complete still gets adoption, liveness, and agent state; it forgoes only automatic tombstoning, which is the correct trade when absence carries no information.

### `transcript` — the conversation as structured messages

New declared capability, distinct from `log` and not a replacement for it.

```
p transcript <id> [--since <cursor>]
```

stdout is Claude Code transcript JSONL. The response's final line carries `{"cursor": "<opaque>"}` so the next call tails rather than refetches; a provider with no incremental support omits it and TBD refetches. Cursors are opaque to TBD.

`log` remains what it is: raw ANSI scrollback bytes for a read-only terminal pane, for providers that genuinely host a terminal. Feeding structured messages into a scrollback view would lose every tool card; feeding ANSI into the transcript renderer would produce garbage. They are different data with different destinations, and a provider may implement either, both, or neither.

The verb is not vendor-specific. Any provider running Claude Code has transcript JSONL available — a provider hosting sessions on its own machine has the files on disk beside whatever it already reads for agent state — so declaring `transcript` upgrades it from ANSI scrollback to TBD's structured transcript pane with no new transport.

### `land` — reconstructing a remote session locally

New declared capability.

```
p land <id>
```

Returns what TBD needs to rebuild the session as a local worktree:

```json
{
  "remote_url": "git@github.com:acme/api.git",
  "branch": "claude/fix-flaky-ci",
  "resume_command": ["claude", "--teleport", "sess_01ABC"],
  "forks": true
}
```

- `remote_url`, `branch` — required. Where the work is.
- `resume_command` — optional argv TBD runs in the new worktree's first pane. Omitted when the provider has nothing to resume; TBD then opens an ordinary pane.
- `forks` — required. Whether local work continues to reach the remote session. `true` means the two diverge after landing, which TBD must show (Part 3).

`resume_command` comes from a provider the user registered, or from the daemon itself, so it is already trusted. It never originates in repository content — see Part 4.

### `stop` becomes a capability

v1 makes `stop` required. A provider whose sessions are reclaimed by the platform on inactivity, with no termination call exposed to clients, cannot implement it. A required verb that a legitimate provider structurally cannot supply is a contract defect, not a provider defect.

`stop` joins `log`, `send`, `attach`, `events`, `transcript`, and `land` as a declared capability. `describe`, `create`, and `list` remain required. TBD hides the stop action for providers that do not declare it, the same way it already hides attach.

## Part 2 — The built-in `claude-cloud` provider

### Why this one is compiled

The placement rule ([`../theory-placement.md`](../theory-placement.md)) asks whether two reasonable projects could want a behavior different. Nightwatch policies are forked per repository because "when is an agent stuck" is genuinely contested. How to talk to a specific vendor's session API is not: there is one API, and no project's convention changes its shape. That makes it a mechanism, and mechanisms compile.

Fragility is a separate axis from ownership, and it is the one that argued for keeping this editable — an undocumented endpoint moves and the fix waits on a release. Two things answer it. TBD is built from source, so a fix is a pull and a restart. And the design degrades rather than fails: when the undocumented half is unavailable, sessions TBD launched keep listing, creating, sending, and attaching, and only discovery of foreign sessions and the transcript pane go dark.

### Shape

`RemoteProviderInvoking` is already a one-method protocol injected into `RemoteProviderManager`. The built-in provider is a second conformance, selected by a dispatcher that routes on provider name: registered names fork a subprocess through `ProviderRunner`, the reserved name is served in-process.

It synthesizes the same `ProviderResult` envelope — exit code, stdout, stderr — that a subprocess produces. Fabricating an exit code is deliberate: it forces the built-in provider through `ProviderFailureClass.classify`, the retry and backoff rules, and the `needs_auth` banner path, exactly as an external provider. There is one code path for every remote session and no special-casing downstream.

`claude-cloud` is a reserved provider name. `RemoteProviderRegistry.load` rejects it the way it already rejects duplicates, so a registry entry cannot shadow the built-in.

### The ledger

A new `claude_cloud_session` table records what TBD launched: session id, idempotency key, creation time, repository path, branch, and the parameters the create used. It is distinct from the `remote_session` mirror, and the distinction is the point — the ledger is *what this machine started*, the mirror is *what the manager last observed*. Keeping them apart preserves the contract's direction of authority for every consumer downstream.

`list` returns the union of ledger rows and discovered sessions, keyed by session id, and sets `complete` according to whether discovery succeeded. Discovery down means ledger rows only, `complete: false`, nothing tombstoned.

### Verb implementations

- **`describe`** — static and offline, as the contract requires. Declares `send`, `attach`, `transcript`, and `land`; declares neither `stop` nor `log`. `create_params` are `repo`, `branch`, `prompt`, and `environment`.
- **`create`** — `claude --cloud "<prompt>"` from the repository checkout. The idempotency key is written to the ledger **before** the invocation, marked pending, and resolved to a session id on return. A replayed key whose row is still pending does not re-create: it surfaces the ambiguity to the user, because a duplicate cloud session costs more than a prompt.
- **`list`** — ledger union discovery, per above.
- **`send`** — `claude -p "<msg>" --cloud <id> --output-format json`, which returns `{ok, session_id, url}`. This is a structured enqueue with an acknowledgement, not keystrokes into a terminal, so it carries none of the delivery-confirmation problems that keystroke transports have.
- **`attach`** — `claude --cloud <id>`, reached through a shim (below).
- **`transcript`** — reads the server-stored transcript for the session, cursor-tailed.
- **`land`** — returns the session's repository and branch with `resume_command` of `claude --teleport <id>` and `forks: true`.

### Attach needs a shim, not an argv

Attach is the one verb the in-process implementation cannot serve, because it is not a request/response at all: the app spawns it on the pane's PTY and its exit code never passes through the daemon's runner. A provider compiled into the daemon has no executable for the app to spawn.

Handing the app a bare `["claude", "--cloud", "<id>"]` is the alternative the contract rejects — a provider printing an argv for TBD to exec. Two of the three reasons dissolve for a built-in provider: `claude` authenticates at launch and refreshes itself, so nothing is frozen at print time, and it is itself a live client that owns its own reconnect. The third, vendor argv in TBD's process table, is moot when the vendor is compiled in.

The reason that survives is exit codes. `RemoteAttachExitClass.classify` reads the attach process's exit through `ProviderFailureClass`, the contract's error table, and `claude` does not speak it. Interactive attach is gated per account, and an ineligible account exits with a code that would classify as `.unexpected` — which the reconnect policy treats as transient and eligible for automatic reconnect, so a permanent condition would retry forever.

So the attach argv is `tbd remote-attach claude-cloud <id>`, a new `TBDCLI` subcommand that execs the vendor CLI on the inherited PTY and translates its outcome into contract exit classes: ineligible account or archived session to 1, credential failure to 4, transport failure to 3, user detach to 0. `TBDCLI` is already installed as `~/.local/bin/tbd`, so this adds no install step, and routing through TBD's own binary keeps the contract's live-shim property rather than working around it.

Nothing parses the shim's output. Per the contract, attach's stdout is a PTY byte stream and the exit code is the whole signal — which is also what the no-TUI-scraping rule requires.

### Attach and transcript are one session, not two

Both surfaces read the same server-stored conversation: a message typed in the attach pane appears in the transcript pane, and one sent through `send` appears in both. This is the opposite of landing, where the local copy forks. No reconciliation is needed and none is designed; the two are windows, not replicas.

The attach pane is also the floor. When the undocumented half is unavailable and the transcript pane goes dark, attach still works, because it rides only documented surface.

### Agent state

Agent state comes from the discovery response's own session status, mapped onto the contract's `working` / `waiting_input` / `idle` / `exited` axis. The precise mapping is fixed at implementation time against the actual response shape; any value that does not map cleanly becomes `unknown` rather than a guess. When discovery is unavailable the axis is `unknown` for every row, and TBD shows liveness only — the contract's stated behavior for providers without instrumentation.

No agent state is ever derived from rendered terminal output, including the attach pane's, per the no-TUI-scraping rule.

### Credentials

The undocumented half authenticates with the claude.ai credential that `claude auth login` already stores. Nothing new is minted, stored, or synced, and the documented half shells out to `claude`, which handles its own auth. Credential reads go through an injected seam so tests never touch a real credential store.

## Part 3 — The land bridge

A remote session row gains a **Land** action, enabled when its provider declares `land`.

`remote.land` is a new RPC. The daemon calls the provider's `land` verb, creates a worktree through the existing lifecycle path, fetches and checks out the returned branch, and spawns the first pane running `resume_command` when one is given.

Preconditions are checked before anything is created, and a failure explains which one failed rather than leaving a half-built worktree: the local repository must match `remote_url`, the branch must exist on the remote, and the worktree path must be free. Landing is never automatic and never triggered by session state — it is always a user gesture.

**A fork is shown as a fork.** When `land` returns `forks: true`, the landed worktree and the remote session are two things from that moment on. The remote row records that it was landed and links to the worktree; the worktree records where it came from. Neither is retired, and TBD does not imply that typing in one reaches the other. Landing the same session twice is allowed and produces a second worktree, because that is what actually happens.

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

The path is a single root file rather than a directory entry because `<repo>/.tbd/` already means legacy worktree storage and is gitignored in this repository — the one place the feature most needs to work.

### The declaration is inert data

This file is authored by anyone who can push to the repository, so cloning a repository must never grant execution on the machine that clones it. TBD reads exactly three keys:

- **`provider`** — must match a provider already registered locally or the reserved built-in name. It is a reference, never a definition.
- **`label`** — a display string, length-capped and rendered as plain text.
- **`params`** — string values matched by name against that provider's `describe.create_params`. Unrecognized names are dropped.

Everything else is ignored: no `exec`, no `args`, no commands, no environment, no paths. Unknown keys are ignored rather than rejected, per the contract's forward-compatibility rule, but ignored means *not interpreted* — TBD never grows a key that turns repository content into something it runs.

The declaration also carries no statement of what a remote *can do*. A grammar for capabilities is a policy language TBD would have to interpret and version permanently; the label is prose a human reads, and the human picks. This keeps the fourth piece small and keeps TBD out of the business of executing a schema it does not own.

### Resolution

Location for a new session resolves most-specific-first:

1. **Explicit per-creation choice** in the create sheet. Always available, always wins.
2. **The repository's declaration.** A single declared remote becomes the default; several are offered in order with their labels.
3. **Global default location**, when configured.
4. **Local.**

A declaration naming a provider that is not registered is configuration drift, not a live fault: resolution degrades to the next tier and the app flags it in the repository's settings rather than blocking creation. Repo-less scratch spaces always resolve to local — there is no repository to carry a declaration.

### This repository's own declaration

TBD ships `.tbd-remotes.json` declaring `claude-cloud`, and the label says what is honestly true: cloud sessions can do specification, documentation, review-gate and shell-harness work here, but cannot build or test the project.

That is not a limitation of any cloud environment's setup script. TBD's `Package.swift` declares `platforms: [.macOS(.v15)]`, every target imports `os` — mandated by the no-`print()`-in-`Sources` rule and enforced by SwiftLint — and the app target is built on SwiftUI and AppKit. There is no Linux-clean target to build, whatever toolchain is installed. Meanwhile `scripts/test.test.sh` stubs the compiler out entirely and runs with no toolchain, as do the other shell harnesses, alongside the review-gate Python scripts and the committed-plans guard.

A declaration where every remote does everything demonstrates nothing. This one has to say something real, which makes it the worked example.

## Feature flag

`claude_cloud_enabled` — a new `config` column, default OFF. The behavior is autonomous background polling against a network service, which is squarely inside the default-off rule.

It is a separate flag from `remote_backends_enabled` rather than a reuse. That flag was written to be disposable on the reasoning that the feature is inert without a registered provider file; a provider compiled into the daemon is never inert, so folding this into it would silently convert a deletable flag into a permanent one. Both branches are tested: off means no polling, no discovery calls, and the built-in provider absent from `remote.providers`; on means the manager runs.

Graduation is a default flip after soak, then deletion, once discovery has held up across a few endpoint revisions.

## Migrations and models

Two migrations, each following the shared-model rule — migration, GRDB record, and the `TBDShared` Codable model in one commit, with new fields optional or defaulted:

- `claude_cloud_session` — the ledger table.
- `config.claude_cloud_enabled` — the flag, defaulting to off.

`remote_session` gains no columns. Landing state is recorded as a link between an existing remote row and an existing worktree row.

Every new poll interval and timeout takes an injected `clock` parameter per the clock rule; persisted timestamps use the date seam.

## Testing

No test reaches the network or a real credential store. The undocumented transport sits behind an injected client protocol, and credential reads behind an injected seam.

- **Contract v2** — `complete: false` adds and updates rows but never increments `missingCount`; absent `complete` behaves as `true`; a v1 provider negotiates v1 and is unaffected; `transcript` output routes to the transcript pane and `log` output to the scrollback pane; a provider that omits `stop` gets no stop action.
- **Built-in provider** — ledger union discovery; discovery failure yields ledger-only and `complete: false`; a pending idempotency key does not re-create; failure classification and the auth banner behave identically to a subprocess provider; the reserved name is rejected from the registry file.
- **Attach shim** — each vendor outcome maps to the intended contract exit class, driven by a stub standing in for the vendor CLI; an ineligible account classifies as permanent and does not arm automatic reconnect, while a dropped transport does; a user detach reads as clean.
- **Land bridge** — each precondition failure is reported without creating a worktree; `forks: true` records the link both ways; landing twice produces two worktrees.
- **Repo declarations** — `exec`, `args`, and command-shaped keys are ignored rather than honored; a params key absent from `create_params` is dropped; an unregistered provider degrades to the next tier with a visible flag; resolution order holds at each tier.
- **Flag branches** — off and on, per the branching-conditional rule.

All tests use the `TBD_HOME` isolation seams and run under `scripts/test.sh`.

## Rejected alternatives

- **Ship the adapter as a seeded, user-editable script.** The seeding pattern exists so projects can fork a contested policy; this is a mechanism with one correct implementation and no consumer who wants it different. Seeding would also have needed write-once semantics TBD does not have, since the existing plugin writer overwrites unconditionally — paying for a new mechanism to make something editable that nobody should edit.
- **Ship the adapter as a separate repository.** Consistent with the contract's stated boundary, but this repository's own declaration would then reference a provider a fresh clone does not have, breaking the worked example on first run. Vendor neutrality lives in the contract; one implementation in the box does not compromise it.
- **Endpoint shapes in a configuration file with the code compiled.** A middle path that looks like it buys fast fixes and instead makes TBD execute a schema it does not own, versioned forever. Either the transport is compiled or it is not.
- **A per-session streaming transcript follow.** The relay is streaming and could support it, but a per-session stream is a new supervision shape — one process per session rather than per provider — and v1 already cut `log --follow` for that reason. Cursor polling first; graduate on evidence that latency is the complaint.
- **Teleport as the read path.** Landing fetches a branch and forks the conversation. Using it to view a session would create a worktree per refresh and silently diverge from what it was showing.
- **Encoding capabilities in the repository declaration.** A machine-readable statement of what a remote can do for a repository is a policy grammar; a prose label a human reads is not, and is sufficient for choosing.

## Deliberate cuts

No stop for cloud sessions, since none is exposed. No `log` for cloud sessions, since there is no terminal to scroll. No diff or file viewer for remote workspaces. No automatic landing on any session state. No publishing of TBD's local sessions back to Anthropic's relay for viewing elsewhere — the inverse direction is a separate idea, and TBD's own sessions can already enable it themselves.
