# Continue in Codex

**Status:** designed, not implemented
**Date:** 2026-07-31

## Problem

You are working in a Claude session and want the same work to continue in Codex — because Claude
hit a usage limit, because the next stretch suits Codex better, or because you want a second
opinion running beside the first. Today you open a Codex tab and retype the context, or paste a
summary you wrote by hand.

The obvious implementation is to generate a handoff document from the Claude transcript. That
approach forces TBD to own a summarizer: which turns matter, how much fits, what to do when a
session is long. Every answer is a heuristic, and a heuristic in the app is a decision nobody
revisits.

## Solution

Codex already ingests Claude transcripts. `externalAgentConfig/import` on the Codex app-server
takes a path to a Claude session JSONL plus a working directory, performs the conversion itself,
and reports the id of the thread it created. TBD reads that id and opens a Codex terminal resumed
on it.

TBD therefore never parses a transcript. It contributes the one thing only it knows: which session
you meant.

```
worktree  flow-fix
   ├─ ✳ Claude   session 9392D590…        ← keeps running, untouched
   │     │  "Continue in Codex"
   │     ▼
   │  externalAgentConfig/import { path, cwd }  ──▶  codex app-server
   │                                    target ◀──
   └─ ❯ Codex    codex resume 019fb9d4…   ← full history, empty composer
```

Protocol contracts, the executed verification, and the measured conversion fidelity are recorded in
[`docs/research/2026-07-31-codex-session-import/findings.md`](../research/2026-07-31-codex-session-import/findings.md).
This spec does not restate them.

## Decisions

- **Import, do not summarize.** Codex owns the conversion, so TBD owns no excerpting policy and no
  handoff artifact. A generated summary can only ever carry a fraction of a long session; the
  import carries the conversation in order.

- **Skip `detect`.** The discovery call returns every recent Claude session with no way to know
  which one is meant. TBD already stores `transcriptPath` on the terminal row and knows the
  worktree path, so it constructs the `SessionMigration` directly.

- **Fork, not link.** Each invocation imports and opens a new thread. TBD stores no source→target
  mapping and does not deduplicate. The source transcript keeps growing after an import, so
  "reuse the existing thread" would hand back a thread frozen at first-import time — helpful-looking
  and quietly stale. Two visible tabs are more legible than one silently out of date, and wanting
  two is a real case when comparing approaches. The cost is a spare session to close after a
  mis-click.

- **No initial prompt.** The imported thread already contains the conversation, so there is nothing
  to point the agent at. The Codex tab opens with history and an empty composer, spending no turn.
  Your first message sets direction.

- **The source Claude session keeps running.** Working both agents in parallel is a supported use.

- **Concurrent agents in one worktree are not policed.** Both sessions share a working tree and can
  edit the same files. TBD has never policed concurrent tabs and does not start here; either
  session can be told about the other. Sending no initial prompt matters to this: nothing instructs
  the Codex session to resume the plan, so it does not act until asked.

- **No feature flag.** The action is an explicit user gesture that is additive and non-destructive,
  acts on no timer, sends input to no session, and replaces no load-bearing path — it trips none of
  the triggers in "Large or risky new behavior ships behind a default-off flag", and that rule ends
  with "don't sprawl flags". The two temptations are worth naming so they are not re-litigated: a
  malformed `migrationItems` array would damage the user's Codex configuration, but that is a bug
  risk that correct construction and a test address, not something a switch protects; and the
  app-server being experimental argues for tolerating failure, not for a toggle, since a protocol
  change surfaces as a failed action rather than as damage. No flag means no `config` column and no
  migration.

## Daemon flow

A new `CodexSessionImporter` in `Sources/TBDDaemon/Codex/` owns the app-server conversation. It is
the only new type.

1. Resolve the Codex executable before any mutation, reusing the existing resolution order
   (`TBD_CODEX_EXECUTABLE`, then an absolute PATH entry, then the ChatGPT app-bundle binary).
2. Spawn `codex app-server` and speak newline-delimited JSON-RPC on stdio.
3. `initialize` with `clientInfo.name = "tbd"`. Codex records this as `session_meta.originator`, so
   imported threads are attributable to TBD.
4. Send `externalAgentConfig/import` with **exactly one** migration item (see Safety below).
5. Read `target` from the first `externalAgentConfig/import/completed` notification whose
   `itemTypeResults` contains a `SESSIONS` success. Treat a `failures` entry as an error.
6. Terminate the app-server process.

The importer returns the thread id, or throws. It persists nothing.

Waiting for the completed notification needs a deadline, so the importer takes
`clock: any Clock<Duration> = ContinuousClock()` as its last initializer parameter, per the injected
clock rule. The observed round trip is roughly 60 ms; the deadline exists for a wedged server, not
for normal latency.

### Safety: exactly one `SESSIONS` item

`externalAgentConfig/import` is a setup-migration call. Its item-type enum includes `AGENTS_MD`,
`HOOKS`, `SKILLS`, `PLUGINS`, `MCP_SERVER_CONFIG` and `COMMANDS`, and a request carrying those
rewrites the user's `~/.codex/AGENTS.md`, `hooks.json`, `config.toml` and installed skills.

TBD constructs the array itself and never forwards a `detect` result. The importer's signature
accepts a single session, not a list of migration items, so no caller can widen it:

```swift
func importSession(transcriptPath: String, cwd: String, title: String?) async throws -> String
```

A test must assert the emitted request contains one item, of type `SESSIONS`, with one session.

## Terminal creation

The resulting terminal is an ordinary Codex terminal with a resume argument.
`CodexSpawnCommandBuilder` gains a `resumeThreadID: String?` parameter defaulting to nil, which
appends `resume <id>` to the command. Everything else — `CODEX_HOME` from
`CodexHomeManager().ensureProfilePlugin()`, `DISABLE_AUTO_UPDATE`, env overrides — is unchanged from
the existing `.codex` spawn path.

The new terminal belongs to the same worktree as the source.

## RPC and CLI

`RPCMethod.terminalContinueInCodex = "terminal.continueInCodex"`, with the params and result added
to `Sources/TBDShared/RPCProtocol.swift`:

```swift
public struct TerminalContinueInCodexParams: Codable, Sendable {
    public let terminalID: UUID
}

public struct TerminalContinueInCodexResult: Codable, Sendable {
    public let terminalID: UUID     // the new Codex terminal
    public let threadID: String     // the imported Codex session id
}
```

The handler reads `transcriptPath` and the worktree path from the source terminal's row, calls the
importer, then creates the terminal. It fails before creating anything if the source terminal is
not a Claude terminal or has no `transcriptPath`.

`tbd terminal continue-in-codex <terminal-id>` exposes the same call and prints the new terminal id
and thread id.

## App

A `Continue in Codex` item in the Claude-tab context menu in `Sources/TBDApp/TabBar.swift`, placed
as a sibling of `Fork Session` rather than inside it — the `Swap profile` and `Fork Session`
submenus list profiles, and this is not a profile.

The item is hidden when the terminal is not a Claude terminal or has no `transcriptPath`, matching
how the menu already gates its Claude-only items.

Success selects the new tab. Failure surfaces the daemon's error message.

## Errors

Every failure happens before any terminal or database row is created, so there is no partial state
to unwind:

- Codex executable not found — report it; do not spawn.
- app-server fails to start, or `initialize` fails — report it.
- The import returns a `SESSIONS` failure, or no success entry arrives before the deadline — report
  it. Codex may have created a thread; TBD does not attempt to find or remove it.
- Source terminal has no `transcriptPath` — the menu item is hidden, and the RPC rejects it.

## Testing

- The importer emits a request with exactly one item, typed `SESSIONS`, carrying one session with
  the expected `path` and `cwd`. This is the safety-critical assertion.
- `target` is extracted from a `completed` notification containing a `SESSIONS` success.
- A `failures` entry becomes a thrown error.
- The deadline fires against a stub that never notifies, using a test clock.
- `CodexSpawnCommandBuilder` appends `resume <id>` when given a thread id, and is unchanged when
  not.
- The RPC rejects a non-Claude terminal and a terminal with no `transcriptPath`, and creates no
  terminal in either case.
- The menu item is absent for Codex and shell tabs.

Tests must not reach a real app-server; the importer takes its transport as an injected seam.

## Known limitations

**Conversion drops tool-result bulk.** Tool calls survive with their arguments, and results are
capped at roughly 4 KB each with largely silent truncation. The receiving agent learns what was
attempted and in what order, but not the full output. Since it is working in the same worktree, a
truncated read can be re-run. Measurements are in the findings doc.

**Re-importing a grown transcript is unverified.** Fork semantics mean TBD does not care, but the
behavior of Codex's own import ledger under a changed source file has not been observed.

**The app-server protocol is experimental.** A breaking change surfaces as a failed menu action.

## Not built

No handoff generator, no handoff file or store, no source→target mapping table, no dedup keying, no
initial prompt, no feature flag, no migration, and no `detect` call.
