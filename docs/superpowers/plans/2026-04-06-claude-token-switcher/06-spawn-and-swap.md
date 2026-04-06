# Phase 06: Spawn Env Prefix + Mid-Conversation Swap

> **Parent plan:** [../2026-04-06-claude-token-switcher.md](../2026-04-06-claude-token-switcher.md)
> **Depends on:** Phase 01, 02, 04
> **Unblocks:** Phase 07 (poll scheduler uses terminal.claudeTokenID), Phase 08 (DaemonClient)

**Scope:** Inject `CLAUDE_CODE_OAUTH_TOKEN` into the claude spawn path via `ClaudeTokenResolver`, and implement the `terminal.swapClaudeToken` RPC that kills + respawns the in-pane claude process with `--resume` and the new env var. Context preserved via Claude Code's JSONL transcript.

## Assumptions

- Phase 01 landed `Sources/TBDDaemon/Claude/ClaudeTokenResolver.swift` exposing something like
  `func resolve(repoID: UUID?) async throws -> ResolvedClaudeToken?` where `ResolvedClaudeToken`
  has `tokenID: UUID` and `secret: String` (Keychain-loaded). It also has a by-id path
  `func loadByID(_ id: UUID) async throws -> ResolvedClaudeToken?` (or we add it in task 02).
- Phase 02 added `terminals.setClaudeTokenID(id:tokenID:)` to `TerminalStore`.
- Phase 04 added `Terminal.claudeTokenID: UUID?` to `Sources/TBDShared/Models.swift` and the
  GRDB record + migration.
- `RPCRouter` already has stored properties `db`, `tmux`, `subscriptions`, and we will inject
  `claudeTokenResolver: ClaudeTokenResolver` the same way (constructor arg, wired in
  `TBDDaemon` startup).
- Claude OAuth tokens (`sk-ant-oat01-...`) and Anthropic API keys (`sk-ant-api03-...`) contain
  only `[A-Za-z0-9_-]` characters. We assert this at injection time so a bad value
  fails loudly instead of silently producing a broken shell line. We still single-quote.

## Tasks

### Task 1: Extract `buildClaudeSpawnCommand` pure helper

Create `Sources/TBDDaemon/Claude/ClaudeSpawnCommandBuilder.swift`:

```swift
import Foundation

enum ClaudeSpawnCommandBuilder {
    /// Build the shell command string for spawning a claude terminal.
    /// Pure function — no DB, no Keychain, no tmux. Easy to unit-test.
    ///
    /// Exactly one of `resumeID` or `freshSessionID` must be non-nil for a claude spawn.
    /// If both are nil, returns the fallback (`cmd` if set, else `$SHELL`).
    static func build(
        resumeID: String?,
        freshSessionID: String?,
        appendSystemPrompt: String?,
        initialPrompt: String?,
        tokenSecret: String?,
        cmd: String?,
        shellFallback: String
    ) -> String {
        let base: String
        if let resumeID {
            base = "claude --resume \(resumeID) --dangerously-skip-permissions"
        } else if let sessionID = freshSessionID {
            var b = "claude --session-id \(sessionID) --dangerously-skip-permissions"
            if let prompt = appendSystemPrompt {
                b += " --append-system-prompt \(SystemPromptBuilder.shellEscape(prompt))"
            }
            if let p = initialPrompt, !p.isEmpty {
                b += " \(SystemPromptBuilder.shellEscape(p))"
            }
            base = b
        } else if let cmd {
            return cmd
        } else {
            return shellFallback
        }

        guard let secret = tokenSecret else { return base }
        precondition(
            secret.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" },
            "Claude token contains unexpected characters; refusing to inject"
        )
        return "CLAUDE_CODE_OAUTH_TOKEN='\(secret)' \(base)"
    }
}
```

Note the env-prefix form `CLAUDE_CODE_OAUTH_TOKEN='...' claude ...` matches what zsh evaluates
when tmux runs the command, and avoids `ps` leakage of the token in the `claude` arg list.

### Task 2: Make `ClaudeTokenResolver` loadable by explicit ID

If Phase 01's resolver does not already expose a by-id load, add:

```swift
func loadByID(_ id: UUID) async throws -> ResolvedClaudeToken?
```

It bypasses the repo/global precedence chain, looks up the row by id, loads the secret from
`ClaudeTokenKeychain`, and returns nil if either step fails. Used by `swapClaudeToken` when
the caller has already chosen a specific token.

### Task 3: Wire `ClaudeTokenResolver` into `RPCRouter`

Add a stored property `let claudeTokenResolver: ClaudeTokenResolver` to `RPCRouter` and
pass it through the daemon startup site (search for `RPCRouter(` to find the construction
point in `TBDDaemon`). No behavior change yet — just plumbing.

### Task 4: Use the builder in `handleTerminalCreate`

Replace the inline `if let resumeID ... else if isClaudeType ... else if let cmd ... else`
chain in `Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift` (lines ~30–66) with:

1. Resolve `appendSystemPrompt` exactly as today (only for fresh sessions, only when the
   repo provides one).
2. Generate `freshSessionID` only when `isClaudeType && resumeID == nil`.
3. Resolve token: `let resolved = isClaudeType ? try? await claudeTokenResolver.resolve(repoID: worktree.repoID) : nil`.
4. Call `ClaudeSpawnCommandBuilder.build(...)` with the assembled inputs.
5. Compute `label` as today.
6. Pass `claudeTokenID: resolved?.tokenID` into `db.terminals.create(...)`.

`db.terminals.create` already accepts `claudeSessionID`; extend it (or use the Phase 02
setter immediately after) to persist `claudeTokenID`. Prefer extending `create` so the row
is consistent on insert.

### Task 5: Token-resolution failure must not break spawn

`claudeTokenResolver.resolve` may throw (Keychain locked, missing secret, DB issue). Wrap
the call in `try?` and treat nil as "no token". The user gets a working terminal that falls
back to claude's keychain login. Log a single warning to `os_log` so we can diagnose.

### Task 6: Add `RPCMethod.terminalSwapClaudeToken` constant

In whichever file holds the `RPCMethod` enum / string constants, add
`static let terminalSwapClaudeToken = "terminal.swapClaudeToken"`. Add params/result types in
`Sources/TBDShared/Models.swift`:

```swift
public struct TerminalSwapClaudeTokenParams: Codable, Sendable {
    public let terminalID: UUID
    public let newTokenID: UUID?
}
```

Result is the updated `Terminal` row.

### Task 7: Implement `handleTerminalSwapClaudeToken`

Add to `RPCRouter+TerminalHandlers.swift`:

```swift
func handleTerminalSwapClaudeToken(_ paramsData: Data) async throws -> RPCResponse {
    let params = try decoder.decode(TerminalSwapClaudeTokenParams.self, from: paramsData)

    guard let terminal = try await db.terminals.get(id: params.terminalID) else {
        return RPCResponse(error: "Terminal not found: \(params.terminalID)")
    }
    guard let sessionID = terminal.claudeSessionID else {
        return RPCResponse(error: "Terminal \(params.terminalID) is not a Claude terminal")
    }
    guard let worktree = try await db.worktrees.get(id: terminal.worktreeID) else {
        return RPCResponse(error: "Worktree not found for terminal: \(params.terminalID)")
    }

    // Resolve the new token (nil = clear override, fall back to keychain login).
    let resolved: ResolvedClaudeToken?
    if let newID = params.newTokenID {
        resolved = try await claudeTokenResolver.loadByID(newID)
        if resolved == nil {
            return RPCResponse(error: "Token not found or unreadable: \(newID)")
        }
    } else {
        resolved = nil
    }

    // 1. C-c the running claude process.
    try await tmux.sendKey(server: worktree.tmuxServer, paneID: terminal.tmuxPaneID, key: "C-c")
    try await Task.sleep(nanoseconds: 500_000_000)

    // 2. Build respawn command (resume the same session).
    let respawn = ClaudeSpawnCommandBuilder.build(
        resumeID: sessionID,
        freshSessionID: nil,
        appendSystemPrompt: nil,
        initialPrompt: nil,
        tokenSecret: resolved?.secret,
        cmd: nil,
        shellFallback: ""
    )

    // 3. Type the command into the existing pane and submit.
    try await tmux.sendKeys(server: worktree.tmuxServer, paneID: terminal.tmuxPaneID, text: respawn)
    try await tmux.sendKey(server: worktree.tmuxServer, paneID: terminal.tmuxPaneID, key: "Enter")

    // 4. Persist the new token id on the terminal.
    try await db.terminals.setClaudeTokenID(id: terminal.id, tokenID: resolved?.tokenID)

    // 5. Fire-and-forget usage refresh for the new token.
    if let newID = resolved?.tokenID {
        Task.detached { [usage = self.claudeUsageFetcher] in
            await usage?.fetch(tokenID: newID)
        }
    }

    // 6. Broadcast delta so UI updates immediately.
    guard let updated = try await db.terminals.get(id: terminal.id) else {
        return RPCResponse(error: "Terminal vanished after swap")
    }
    subscriptions.broadcast(delta: .terminalUpdated(TerminalDelta(
        terminalID: updated.id, worktreeID: updated.worktreeID, label: updated.label
    )))
    return try RPCResponse(result: updated)
}
```

Notes:
- `tmux.sendKey` / `tmux.sendKeys` already exist (see `handleTerminalSend` at line 301 and 308).
- If `tmux.respawnPane` exists in `TmuxManager`, prefer it over the type-then-Enter dance and
  call it with `shellCommand: respawn`. Verify by grepping `TmuxManager` during this task; if
  not present, the type-and-Enter approach is fine and matches what a user would do manually.
- The `claudeUsageFetcher` reference assumes Phase 03 wired a fetcher into the router. If
  Phase 03 isn't merged yet, gate the fire-and-forget behind `if let usage = claudeUsageFetcher`
  or skip the call and add a TODO referencing Phase 07.

### Task 8: Register the new method in `RPCRouter.handle`

Find `RPCRouter.handle()` (likely `Sources/TBDDaemon/Server/RPCRouter.swift`) and add a case:

```swift
case RPCMethod.terminalSwapClaudeToken:
    return try await handleTerminalSwapClaudeToken(paramsData)
```

### Task 9: Builder unit tests — fallback paths

Create `Tests/TBDDaemonTests/ClaudeSpawnCommandBuilderTests.swift`. Cover the non-token branches:
- `resumeID` only → `claude --resume X --dangerously-skip-permissions`
- `freshSessionID` only → `claude --session-id Y --dangerously-skip-permissions`
- fresh + appendSystemPrompt → contains `--append-system-prompt '...'`
- fresh + initialPrompt → trailing `'...'`
- `cmd` only → returns `cmd` verbatim
- all nils → returns `shellFallback`

### Task 10: Builder unit tests — token prefix branches

Same file:
- resume + token → starts with `CLAUDE_CODE_OAUTH_TOKEN='sk-ant-oat01-fake' `
- fresh + token → starts with the same prefix
- `cmd` + token → token is **ignored** (cmd path is for non-claude shells); assert no prefix
- shellFallback + token → no prefix
- token with bad char → `precondition` traps (XCTAssertThrowsError via a wrapper, or
  document as a non-test invariant if XCTest can't catch preconditions cleanly)

### Task 11: Spawn integration test — no tokens configured

Create `Tests/TBDDaemonTests/ClaudeTokenSpawnTests.swift`. Set up an in-memory DB with one
repo + one worktree, no `claude_tokens` rows, `config.default_claude_token_id = nil`. Stub
tmux with a recording double that captures the `shellCommand` arg to `createWindow`.
Call `handleTerminalCreate` with `type: .claude`. Assert:
- captured `shellCommand` matches the existing format (no env prefix)
- created terminal row has `claudeTokenID == nil`

### Task 12: Spawn integration test — global default set

Same fixture, but seed one token (Keychain set to `sk-ant-oat01-fake`) and set
`config.default_claude_token_id`. Call `handleTerminalCreate`. Assert:
- captured `shellCommand` begins with `CLAUDE_CODE_OAUTH_TOKEN='sk-ant-oat01-fake' `
- created terminal row's `claudeTokenID` equals the default token's id
- `last_used_at` on the token row is bumped (if Phase 01 implemented this — otherwise
  defer the assertion to that phase's tests)

### Task 13: Spawn integration tests — repo override + non-claude

Two more cases in the same file:
- **Repo override beats default.** Seed two tokens A and B, default = A,
  `repo.claude_token_override_id = B`. Spawn → command uses B's secret, terminal row's
  `claudeTokenID == B.id`.
- **Non-claude type ignores tokens.** Default = A. Call `handleTerminalCreate` with
  `type: .shell` (no `resumeSessionID`). Assert no `CLAUDE_CODE_OAUTH_TOKEN=` in the
  captured `shellCommand`, and `claudeTokenID == nil` on the row.

### Task 14: Swap RPC integration tests

Same test file. Use the same recording tmux double, plus a way to inspect the bytes sent
to `sendKeys` (capture into an array per pane).

- **Swap to a different token.** Spawn a claude terminal with token A. Call
  `handleTerminalSwapClaudeToken(terminalID: t, newTokenID: B.id)`. Assert:
  - a `C-c` key was sent
  - the typed text contains `CLAUDE_CODE_OAUTH_TOKEN='<B-secret>' claude --resume <sessionID> --dangerously-skip-permissions`
  - terminal row's `claudeTokenID == B.id`
- **Swap to nil.** Same setup, call with `newTokenID: nil`. Assert typed text has **no**
  `CLAUDE_CODE_OAUTH_TOKEN=` prefix and terminal row's `claudeTokenID == nil`.
- **Swap on a non-claude terminal.** Spawn with `type: .shell`. Swap call returns an
  RPC error and does not touch tmux.
- **Swap with unknown tokenID.** Returns an RPC error, no tmux interaction, terminal row
  unchanged.

## Verification

- `swift build` clean.
- `swift test --filter ClaudeSpawnCommandBuilderTests` green.
- `swift test --filter ClaudeTokenSpawnTests` green.
- Manual smoke (after Phase 07/08 land the UI): create a claude terminal with no default,
  confirm it works as before; set a default, create another terminal, confirm `ps` shows
  no token in the claude arg list; right-click → swap token, confirm the conversation
  resumes against the new account.

## Out of scope

- Touching `repo.claudeTokenOverrideID` or `config.defaultClaudeTokenID` from the swap path
  (one-shot, per spec).
- Retrying a failed `--resume` after swap. The pane is left dead per spec.
- UI surfaces for swap and default selection — Phase 08+.
