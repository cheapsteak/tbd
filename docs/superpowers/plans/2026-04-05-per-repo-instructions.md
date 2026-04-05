# Per-Repo Instructions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-repo configurable instructions (rename prompt + general instructions) that TBD injects into spawned Claude Code sessions via `--append-system-prompt`.

**Architecture:** New DB columns on `repo` table for `renamePrompt` and `customInstructions`. A `SystemPromptBuilder` composes three layers (rename prompt, built-in TBD context, user instructions) into a single `--append-system-prompt` flag appended to the `claude` command at spawn time. New `RepoDetailView` with segmented control replaces `ArchivedWorktreesView` in the detail area. New `RepoInstructionsView` provides two text editors with debounced auto-save.

**Tech Stack:** Swift, SwiftUI, GRDB, TBDShared models, TBDDaemon RPC

**Spec:** `docs/superpowers/specs/2026-04-05-per-repo-instructions-design.md`

---

### Task 1: Data Model — Migration, Shared Model, RepoRecord, RPC Types

**Files:**
- Modify: `Sources/TBDDaemon/Database/Database.swift:183` (add migration v11 before `try migrator.migrate`)
- Modify: `Sources/TBDShared/Models.swift:1-20` (add fields to Repo)
- Modify: `Sources/TBDDaemon/Database/RepoStore.swift:6-35` (add fields to RepoRecord + update method)
- Modify: `Sources/TBDShared/RPCProtocol.swift:78-122` (add RPC method + params struct)

- [ ] **Step 1: Add migration v11 to Database.swift**

In `Sources/TBDDaemon/Database/Database.swift`, add before `try migrator.migrate(writer)` (line 184):

```swift
migrator.registerMigration("v11") { db in
    try db.alter(table: "repo") { t in
        t.add(column: "renamePrompt", .text)
        t.add(column: "customInstructions", .text)
    }
}
```

- [ ] **Step 2: Add fields to Repo model in Models.swift**

In `Sources/TBDShared/Models.swift`, add to the `Repo` struct after `createdAt`:

```swift
public var renamePrompt: String?
public var customInstructions: String?
```

Update the `init` to include them with defaults:

```swift
public init(id: UUID = UUID(), path: String, remoteURL: String? = nil,
            displayName: String, defaultBranch: String = "main", createdAt: Date = Date(),
            renamePrompt: String? = nil, customInstructions: String? = nil) {
    self.id = id
    self.path = path
    self.remoteURL = remoteURL
    self.displayName = displayName
    self.defaultBranch = defaultBranch
    self.createdAt = createdAt
    self.renamePrompt = renamePrompt
    self.customInstructions = customInstructions
}
```

Note: `Repo` uses the synthesized `Codable` conformance (no manual `init(from:)`), so optional properties decode as `nil` automatically from existing data.

- [ ] **Step 3: Add fields to RepoRecord in RepoStore.swift**

In `Sources/TBDDaemon/Database/RepoStore.swift`, add to `RepoRecord`:

```swift
var renamePrompt: String?
var customInstructions: String?
```

Update `init(from repo:)`:

```swift
init(from repo: Repo) {
    self.id = repo.id.uuidString
    self.path = repo.path
    self.remoteURL = repo.remoteURL
    self.displayName = repo.displayName
    self.defaultBranch = repo.defaultBranch
    self.createdAt = repo.createdAt
    self.renamePrompt = repo.renamePrompt
    self.customInstructions = repo.customInstructions
}
```

Update `toModel()`:

```swift
func toModel() -> Repo {
    Repo(
        id: UUID(uuidString: id)!,
        path: path,
        remoteURL: remoteURL,
        displayName: displayName,
        defaultBranch: defaultBranch,
        createdAt: createdAt,
        renamePrompt: renamePrompt,
        customInstructions: customInstructions
    )
}
```

Add the update method to `RepoStore`:

```swift
/// Update per-repo instruction fields.
public func updateInstructions(id: UUID, renamePrompt: String?, customInstructions: String?) async throws {
    try await writer.write { db in
        try db.execute(
            sql: "UPDATE repo SET renamePrompt = ?, customInstructions = ? WHERE id = ?",
            arguments: [renamePrompt, customInstructions, id.uuidString]
        )
    }
}
```

- [ ] **Step 4: Add RPC method and params to RPCProtocol.swift**

In `Sources/TBDShared/RPCProtocol.swift`, add to `RPCMethod` enum (after `terminalConversation`):

```swift
public static let repoUpdateInstructions = "repo.updateInstructions"
```

Add the params struct after the existing param structs (e.g., after `RepoRemoveParams`):

```swift
public struct RepoUpdateInstructionsParams: Codable, Sendable {
    public let repoID: UUID
    public let renamePrompt: String?
    public let customInstructions: String?
    public init(repoID: UUID, renamePrompt: String?, customInstructions: String?) {
        self.repoID = repoID
        self.renamePrompt = renamePrompt
        self.customInstructions = customInstructions
    }
}
```

- [ ] **Step 5: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDDaemon/Database/Database.swift Sources/TBDShared/Models.swift Sources/TBDDaemon/Database/RepoStore.swift Sources/TBDShared/RPCProtocol.swift
git commit -m "feat: add renamePrompt and customInstructions to repo model (migration v11)"
```

---

### Task 2: RPC Handler + DaemonClient Method

**Files:**
- Modify: `Sources/TBDDaemon/Server/RPCRouter.swift:53-148` (add case for new method)
- Modify: `Sources/TBDDaemon/Server/RPCRouter+RepoHandlers.swift:109-113` (add handler method)
- Modify: `Sources/TBDApp/DaemonClient.swift:286-295` (add client method)

- [ ] **Step 1: Add handler method to RPCRouter+RepoHandlers.swift**

In `Sources/TBDDaemon/Server/RPCRouter+RepoHandlers.swift`, add after `handleRepoList()`:

```swift
func handleRepoUpdateInstructions(_ paramsData: Data) async throws -> RPCResponse {
    let params = try decoder.decode(RepoUpdateInstructionsParams.self, from: paramsData)

    guard try await db.repos.get(id: params.repoID) != nil else {
        return RPCResponse(error: "Repository not found: \(params.repoID)")
    }

    try await db.repos.updateInstructions(
        id: params.repoID,
        renamePrompt: params.renamePrompt,
        customInstructions: params.customInstructions
    )

    guard let updated = try await db.repos.get(id: params.repoID) else {
        return RPCResponse(error: "Repository not found after update: \(params.repoID)")
    }

    return try RPCResponse(result: updated)
}
```

- [ ] **Step 2: Add dispatch case to RPCRouter.swift**

In `Sources/TBDDaemon/Server/RPCRouter.swift`, add a new case in the `switch request.method` block (after the `repoList` case around line 61):

```swift
case RPCMethod.repoUpdateInstructions:
    return try await handleRepoUpdateInstructions(request.paramsData)
```

- [ ] **Step 3: Add DaemonClient method**

In `Sources/TBDApp/DaemonClient.swift`, add after the `addRepo` method (around line 295):

```swift
/// Update per-repo instruction fields.
func repoUpdateInstructions(repoID: UUID, renamePrompt: String?, customInstructions: String?) throws -> Repo {
    return try call(
        method: RPCMethod.repoUpdateInstructions,
        params: RepoUpdateInstructionsParams(repoID: repoID, renamePrompt: renamePrompt, customInstructions: customInstructions),
        resultType: Repo.self
    )
}
```

- [ ] **Step 4: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Server/RPCRouter.swift Sources/TBDDaemon/Server/RPCRouter+RepoHandlers.swift Sources/TBDApp/DaemonClient.swift
git commit -m "feat: add repo.updateInstructions RPC handler and client method"
```

---

### Task 3: Tests — Migration, RPC, Shell Escaping

**Files:**
- Modify: `Tests/TBDDaemonTests/RPCRouterTests.swift` (add tests)
- Create: `Sources/TBDDaemon/Lifecycle/SystemPromptBuilder.swift` (shell escape function — tested here, used in Task 4)

- [ ] **Step 1: Write the failing tests**

Add to `Tests/TBDDaemonTests/RPCRouterTests.swift`, at the end of the struct before the closing `}`:

```swift
// MARK: - Repo Instructions Tests

@Test("repo.updateInstructions stores and retrieves instructions")
func repoUpdateInstructions() async throws {
    let repo = try await db.repos.create(
        path: "/tmp/test-repo-\(UUID().uuidString)",
        displayName: "test-repo",
        defaultBranch: "main"
    )

    let request = try RPCRequest(
        method: RPCMethod.repoUpdateInstructions,
        params: RepoUpdateInstructionsParams(
            repoID: repo.id,
            renamePrompt: "Use cw/4/feat- prefix",
            customInstructions: "Always use pytest"
        )
    )
    let response = await router.handle(request)

    #expect(response.success)
    let updated = try response.decodeResult(Repo.self)
    #expect(updated.renamePrompt == "Use cw/4/feat- prefix")
    #expect(updated.customInstructions == "Always use pytest")

    // Verify via repo.list
    let listResp = await router.handle(RPCRequest(method: RPCMethod.repoList))
    let repos = try listResp.decodeResult([Repo].self)
    let found = repos.first { $0.id == repo.id }
    #expect(found?.renamePrompt == "Use cw/4/feat- prefix")
    #expect(found?.customInstructions == "Always use pytest")
}

@Test("repo.updateInstructions with nil clears instructions")
func repoUpdateInstructionsClear() async throws {
    let repo = try await db.repos.create(
        path: "/tmp/test-repo-\(UUID().uuidString)",
        displayName: "test-repo",
        defaultBranch: "main"
    )

    // Set instructions
    let setReq = try RPCRequest(
        method: RPCMethod.repoUpdateInstructions,
        params: RepoUpdateInstructionsParams(repoID: repo.id, renamePrompt: "test", customInstructions: "test")
    )
    _ = await router.handle(setReq)

    // Clear them
    let clearReq = try RPCRequest(
        method: RPCMethod.repoUpdateInstructions,
        params: RepoUpdateInstructionsParams(repoID: repo.id, renamePrompt: nil, customInstructions: nil)
    )
    let response = await router.handle(clearReq)

    #expect(response.success)
    let updated = try response.decodeResult(Repo.self)
    #expect(updated.renamePrompt == nil)
    #expect(updated.customInstructions == nil)
}

@Test("repo.updateInstructions returns error for unknown repo")
func repoUpdateInstructionsUnknownRepo() async throws {
    let request = try RPCRequest(
        method: RPCMethod.repoUpdateInstructions,
        params: RepoUpdateInstructionsParams(repoID: UUID(), renamePrompt: nil, customInstructions: nil)
    )
    let response = await router.handle(request)

    #expect(!response.success)
    #expect(response.error?.contains("Repository not found") == true)
}

@Test("existing repos have nil instructions after migration")
func existingReposNilInstructions() async throws {
    let repo = try await db.repos.create(
        path: "/tmp/test-repo-\(UUID().uuidString)",
        displayName: "test-repo",
        defaultBranch: "main"
    )

    let fetched = try await db.repos.get(id: repo.id)
    #expect(fetched?.renamePrompt == nil)
    #expect(fetched?.customInstructions == nil)
}
```

- [ ] **Step 2: Create SystemPromptBuilder with shellEscape function**

Create `Sources/TBDDaemon/Lifecycle/SystemPromptBuilder.swift`:

```swift
import Foundation
import TBDShared

/// Builds the `--append-system-prompt` value for Claude sessions in TBD worktrees.
enum SystemPromptBuilder {

    /// Shell-escape a string for embedding in a single-quoted shell argument.
    static func shellEscape(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let defaultRenamePrompt = """
        To do immediately, before any other work:

        1. Rename the git branch to reflect the task:
           git branch -m <new-branch-name>

        2. Rename the TBD worktree display name:
           tbd worktree rename "$(basename "$(git rev-parse --show-toplevel)")" "<emoji> <display name>"

        Branch naming: use kebab-case, be concise (<30 chars), be specific.
        Display name: pick a relevant emoji, convert branch name to title case with spaces.

        Examples:
          Branch: fix-login-timeout → Display: ⏱ Fix Login Timeout
          Branch: add-export-csv   → Display: 📊 Add Export CSV

        Do this before reading files, using skills, or any other tools.
        """

    static let builtInTBDContext = """
        You are running inside a TBD-managed worktree. TBD is a macOS worktree + terminal manager.

        Available CLI commands:
        - tbd worktree rename "<worktree-name>" "<display-name>" — rename the worktree display name
        - tbd worktree list [--repo <id>] — list worktrees
        - tbd terminal create <worktree> [--cmd <command>] — create a new terminal
        - tbd terminal output <terminal-id> [--lines N] — read terminal output
        - tbd notify --type <type> [--message <msg>] — send notifications to TBD UI
          Types: response_complete, error, task_complete, attention_needed

        Environment variables:
        - TBD_WORKTREE_ID — UUID of the current worktree (auto-set in all TBD terminals)
        """

    /// Build the combined system prompt for a Claude session.
    /// Returns nil if there's nothing to append.
    static func build(repo: Repo, worktree: Worktree, isResume: Bool) -> String? {
        if isResume { return nil }

        var parts: [String] = []

        // Layer 1: Rename prompt (conditional on worktree not yet renamed)
        if worktree.displayName == worktree.name {
            let renamePrompt = repo.renamePrompt ?? defaultRenamePrompt
            if !renamePrompt.isEmpty {
                parts.append(renamePrompt)
            }
        }

        // Layer 2: Built-in TBD context (always)
        parts.append(builtInTBDContext)

        // Layer 3: User general instructions (if set)
        if let instructions = repo.customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instructions.isEmpty {
            parts.append(instructions)
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n\n---\n\n")
    }
}
```

- [ ] **Step 3: Add SystemPromptBuilder tests**

Create `Tests/TBDDaemonTests/SystemPromptBuilderTests.swift`:

```swift
import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("SystemPromptBuilder Tests")
struct SystemPromptBuilderTests {

    // MARK: - Shell Escaping

    @Test("shellEscape wraps text in single quotes")
    func shellEscapeSimple() {
        let result = SystemPromptBuilder.shellEscape("hello world")
        #expect(result == "'hello world'")
    }

    @Test("shellEscape handles single quotes")
    func shellEscapeSingleQuotes() {
        let result = SystemPromptBuilder.shellEscape("don't mock")
        #expect(result == "'don'\\''t mock'")
    }

    @Test("shellEscape handles double quotes")
    func shellEscapeDoubleQuotes() {
        let result = SystemPromptBuilder.shellEscape("use \"pytest\"")
        #expect(result == "'use \"pytest\"'")
    }

    @Test("shellEscape handles newlines")
    func shellEscapeNewlines() {
        let result = SystemPromptBuilder.shellEscape("line1\nline2")
        #expect(result == "'line1\nline2'")
    }

    @Test("shellEscape handles special shell characters")
    func shellEscapeSpecialChars() {
        let result = SystemPromptBuilder.shellEscape("$HOME `cmd` $(eval)")
        #expect(result == "'$HOME `cmd` $(eval)'")
    }

    // MARK: - Build Prompt

    @Test("build returns nil for resumed sessions")
    func buildReturnsNilForResume() {
        let repo = Repo(path: "/test", displayName: "test", defaultBranch: "main")
        let wt = Worktree(repoID: repo.id, name: "test-wt", displayName: "test-wt",
                          branch: "tbd/test-wt", path: "/test/.tbd/worktrees/test-wt",
                          tmuxServer: "tbd-test")

        let result = SystemPromptBuilder.build(repo: repo, worktree: wt, isResume: true)
        #expect(result == nil)
    }

    @Test("build includes rename prompt when worktree not renamed")
    func buildIncludesRenameWhenNotRenamed() {
        let repo = Repo(path: "/test", displayName: "test", defaultBranch: "main")
        let wt = Worktree(repoID: repo.id, name: "gorgeous-panda", displayName: "gorgeous-panda",
                          branch: "tbd/gorgeous-panda", path: "/test/.tbd/worktrees/gorgeous-panda",
                          tmuxServer: "tbd-test")

        let result = SystemPromptBuilder.build(repo: repo, worktree: wt, isResume: false)
        #expect(result != nil)
        #expect(result!.contains("To do immediately"))
        #expect(result!.contains("git branch -m"))
        #expect(result!.contains("tbd worktree rename"))
    }

    @Test("build excludes rename prompt when worktree already renamed")
    func buildExcludesRenameWhenRenamed() {
        let repo = Repo(path: "/test", displayName: "test", defaultBranch: "main")
        let wt = Worktree(repoID: repo.id, name: "gorgeous-panda", displayName: "🔐 Auth Fix",
                          branch: "tbd/gorgeous-panda", path: "/test/.tbd/worktrees/gorgeous-panda",
                          tmuxServer: "tbd-test")

        let result = SystemPromptBuilder.build(repo: repo, worktree: wt, isResume: false)
        #expect(result != nil)
        #expect(!result!.contains("To do immediately"))
        // Should still have TBD context
        #expect(result!.contains("TBD-managed worktree"))
    }

    @Test("build excludes rename prompt when explicitly disabled (empty string)")
    func buildExcludesRenameWhenDisabled() {
        let repo = Repo(path: "/test", displayName: "test", defaultBranch: "main",
                        renamePrompt: "")
        let wt = Worktree(repoID: repo.id, name: "gorgeous-panda", displayName: "gorgeous-panda",
                          branch: "tbd/gorgeous-panda", path: "/test/.tbd/worktrees/gorgeous-panda",
                          tmuxServer: "tbd-test")

        let result = SystemPromptBuilder.build(repo: repo, worktree: wt, isResume: false)
        #expect(result != nil)
        #expect(!result!.contains("To do immediately"))
        #expect(result!.contains("TBD-managed worktree"))
    }

    @Test("build uses custom rename prompt when set")
    func buildUsesCustomRenamePrompt() {
        let repo = Repo(path: "/test", displayName: "test", defaultBranch: "main",
                        renamePrompt: "Use cw/4/feat- prefix")
        let wt = Worktree(repoID: repo.id, name: "gorgeous-panda", displayName: "gorgeous-panda",
                          branch: "tbd/gorgeous-panda", path: "/test/.tbd/worktrees/gorgeous-panda",
                          tmuxServer: "tbd-test")

        let result = SystemPromptBuilder.build(repo: repo, worktree: wt, isResume: false)
        #expect(result != nil)
        #expect(result!.contains("cw/4/feat-"))
        #expect(!result!.contains("To do immediately"))
    }

    @Test("build always includes TBD context for fresh sessions")
    func buildAlwaysIncludesTBDContext() {
        let repo = Repo(path: "/test", displayName: "test", defaultBranch: "main")
        let wt = Worktree(repoID: repo.id, name: "test-wt", displayName: "🔐 Renamed",
                          branch: "tbd/test-wt", path: "/test/.tbd/worktrees/test-wt",
                          tmuxServer: "tbd-test")

        let result = SystemPromptBuilder.build(repo: repo, worktree: wt, isResume: false)
        #expect(result != nil)
        #expect(result!.contains("TBD-managed worktree"))
        #expect(result!.contains("tbd notify"))
    }

    @Test("build includes general instructions when set")
    func buildIncludesGeneralInstructions() {
        let repo = Repo(path: "/test", displayName: "test", defaultBranch: "main",
                        customInstructions: "Always use pytest. Never mock the DB.")
        let wt = Worktree(repoID: repo.id, name: "test-wt", displayName: "🔐 Renamed",
                          branch: "tbd/test-wt", path: "/test/.tbd/worktrees/test-wt",
                          tmuxServer: "tbd-test")

        let result = SystemPromptBuilder.build(repo: repo, worktree: wt, isResume: false)
        #expect(result != nil)
        #expect(result!.contains("Always use pytest"))
    }

    @Test("build excludes general instructions when empty/whitespace")
    func buildExcludesEmptyInstructions() {
        let repo = Repo(path: "/test", displayName: "test", defaultBranch: "main",
                        customInstructions: "   \n  ")
        let wt = Worktree(repoID: repo.id, name: "test-wt", displayName: "🔐 Renamed",
                          branch: "tbd/test-wt", path: "/test/.tbd/worktrees/test-wt",
                          tmuxServer: "tbd-test")

        let result = SystemPromptBuilder.build(repo: repo, worktree: wt, isResume: false)
        #expect(result != nil)
        #expect(!result!.contains("   \n  "))
        // Should still have TBD context
        #expect(result!.contains("TBD-managed worktree"))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Lifecycle/SystemPromptBuilder.swift Tests/TBDDaemonTests/RPCRouterTests.swift Tests/TBDDaemonTests/SystemPromptBuilderTests.swift
git commit -m "feat: add SystemPromptBuilder with tests for prompt composition and shell escaping"
```

---

### Task 4: Inject System Prompt at Spawn Time

**Files:**
- Modify: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift:176-257` (inject in `setupTerminals`)
- Modify: `Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift:8-68` (inject in `handleTerminalCreate`)
- Modify: `Sources/TBDDaemon/Conductor/ConductorManager.swift:108-157` (inject in conductor start)

- [ ] **Step 1: Inject in setupTerminals (worktree creation)**

In `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift`, the `setupTerminals` method needs access to the repo to build the system prompt. The method already receives `repoPath` but needs the repo object. Modify `setupTerminals` signature and callers.

First, update the method signature to accept a `Repo` parameter:

```swift
func setupTerminals(
    worktreeID: UUID, repo: Repo,
    tmuxServer: String, worktreePath: String, skipClaude: Bool,
    archivedClaudeSessions: [String]? = nil
) async throws {
```

Then, after building `claudeCommand` (around line 196), add system prompt injection before creating the window:

```swift
if skipClaude {
    claudeCommand = defaultShell
    claudeSessionID = nil
} else {
    let sessionUUID = archivedClaudeSessions?.first ?? UUID().uuidString
    claudeCommand = "claude --dangerously-skip-permissions --session-id \(sessionUUID)"
    claudeSessionID = sessionUUID

    // Inject per-repo system prompt
    if let worktree = try await db.worktrees.get(id: worktreeID),
       let prompt = SystemPromptBuilder.build(repo: repo, worktree: worktree, isResume: false) {
        claudeCommand += " --append-system-prompt \(SystemPromptBuilder.shellEscape(prompt))"
    }
}
```

Update the two call sites in `completeCreateWorktree` (line 91):

```swift
try await setupTerminals(
    worktreeID: worktreeID, repo: repo,
    tmuxServer: worktree.tmuxServer, worktreePath: result.path,
    skipClaude: skipClaude
)
```

And in `reviveWorktree` (search for the other `setupTerminals` call — it will be in `WorktreeLifecycle+Archive.swift` or similar):

Find all call sites with:
```bash
grep -rn "setupTerminals(" Sources/
```
Update each to pass `repo:`.

- [ ] **Step 2: Inject in handleTerminalCreate (new Claude terminal)**

In `Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift`, in `handleTerminalCreate`, after the `isClaudeType` block builds `shellCommand` (around line 36), add prompt injection for new Claude sessions (not resume):

After line 36 (`shellCommand = "claude --session-id \(sessionID) --dangerously-skip-permissions"`), add:

```swift
} else if isClaudeType {
    let sessionID = UUID().uuidString
    claudeSessionID = sessionID
    var cmd = "claude --session-id \(sessionID) --dangerously-skip-permissions"

    // Inject per-repo system prompt
    if let repo = try await db.repos.get(id: worktree.repoID),
       let prompt = SystemPromptBuilder.build(repo: repo, worktree: worktree, isResume: false) {
        cmd += " --append-system-prompt \(SystemPromptBuilder.shellEscape(prompt))"
    }

    shellCommand = cmd
    label = "claude"
```

Replace the existing `else if isClaudeType` block with this version.

- [ ] **Step 3: Inject in conductor start**

In `Sources/TBDDaemon/Conductor/ConductorManager.swift`, in the `start` method (line 132), the current command is:

```swift
let shellCommand = "claude --dangerously-skip-permissions"
```

Replace with:

```swift
var shellCommand = "claude --dangerously-skip-permissions"

// Inject TBD context + general instructions (no rename prompt for conductors)
// Only inject general instructions if conductor scopes to a single repo
if let conductor = try await db.conductors.get(name: name) {
    let repoIDs = conductor.repos
    if repoIDs.count == 1, let repoIDStr = repoIDs.first, repoIDStr != "*",
       let repoUUID = UUID(uuidString: repoIDStr),
       let repo = try await db.repos.get(id: repoUUID) {
        var parts = [SystemPromptBuilder.builtInTBDContext]
        if let instructions = repo.customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instructions.isEmpty {
            parts.append(instructions)
        }
        let combined = parts.joined(separator: "\n\n---\n\n")
        shellCommand += " --append-system-prompt \(SystemPromptBuilder.shellEscape(combined))"
    } else {
        // Multi-repo or wildcard — just inject TBD context
        shellCommand += " --append-system-prompt \(SystemPromptBuilder.shellEscape(SystemPromptBuilder.builtInTBDContext))"
    }
}
```

Note: We already have a `conductor` variable from the `guard let` on line 109, so we need to reuse that instead of re-fetching. Adjust the code to use the existing `conductor` variable — the key fields are `conductor.repos` which is `[String]`.

- [ ] **Step 4: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 5: Run tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift Sources/TBDDaemon/Conductor/ConductorManager.swift
git commit -m "feat: inject per-repo system prompt at Claude session spawn time"
```

---

### Task 5: UI — RepoDetailView with Segmented Control

**Files:**
- Create: `Sources/TBDApp/RepoDetailView.swift`
- Modify: `Sources/TBDApp/ContentView.swift:30` (swap ArchivedWorktreesView for RepoDetailView)

- [ ] **Step 1: Create RepoDetailView.swift**

Create `Sources/TBDApp/RepoDetailView.swift`:

```swift
import SwiftUI
import TBDShared

struct RepoDetailView: View {
    let repoID: UUID

    enum Tab: String, CaseIterable {
        case archived = "Archived"
        case instructions = "Instructions"
    }

    @State private var selectedTab: Tab = .archived

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .padding(.vertical, 12)

            Divider()

            switch selectedTab {
            case .archived:
                ArchivedWorktreesView(repoID: repoID)
            case .instructions:
                RepoInstructionsView(repoID: repoID)
            }
        }
    }
}
```

- [ ] **Step 2: Update ContentView to use RepoDetailView**

In `Sources/TBDApp/ContentView.swift`, replace line 30:

```swift
// Before:
ArchivedWorktreesView(repoID: repoID)

// After:
RepoDetailView(repoID: repoID)
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded (RepoInstructionsView doesn't exist yet — create a stub if needed, or do Task 6 immediately after)

Actually, since `RepoInstructionsView` is referenced but doesn't exist yet, create a minimal stub:

Create `Sources/TBDApp/RepoInstructionsView.swift`:

```swift
import SwiftUI
import TBDShared

struct RepoInstructionsView: View {
    let repoID: UUID

    var body: some View {
        Text("Instructions placeholder")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 4: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDApp/RepoDetailView.swift Sources/TBDApp/RepoInstructionsView.swift Sources/TBDApp/ContentView.swift
git commit -m "feat: add RepoDetailView with segmented control (Archived | Instructions)"
```

---

### Task 6: UI — RepoInstructionsView with Debounced Auto-Save

**Files:**
- Modify: `Sources/TBDApp/RepoInstructionsView.swift` (replace stub with full implementation)
- Modify: `Sources/TBDApp/AppState+Repos.swift` (add updateRepoInstructions method)

- [ ] **Step 1: Add updateRepoInstructions to AppState**

In `Sources/TBDApp/AppState+Repos.swift`, add after the existing repo methods:

```swift
/// Update per-repo instruction fields.
func updateRepoInstructions(repoID: UUID, renamePrompt: String?, customInstructions: String?) async {
    do {
        _ = try await daemonClient.repoUpdateInstructions(
            repoID: repoID, renamePrompt: renamePrompt, customInstructions: customInstructions
        )
        await refreshRepos()
    } catch {
        showError("Failed to update instructions: \(error)")
    }
}
```

- [ ] **Step 2: Implement full RepoInstructionsView**

Replace the contents of `Sources/TBDApp/RepoInstructionsView.swift`:

```swift
import SwiftUI
import TBDShared

struct RepoInstructionsView: View {
    let repoID: UUID
    @EnvironmentObject var appState: AppState

    @State private var renamePromptDraft: String = ""
    @State private var customInstructionsDraft: String = ""
    @State private var showSaved = false
    @State private var saveTask: Task<Void, Never>?
    @State private var initialized = false

    private var repo: Repo? {
        appState.repos.first { $0.id == repoID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // MARK: - Rename Prompt Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rename Prompt")
                        .font(.title3)
                        .fontWeight(.medium)
                    Text("Sent with the first message in worktrees that haven't been renamed yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $renamePromptDraft)
                        .font(.body.monospaced())
                        .frame(minHeight: 160)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

                    HStack {
                        Spacer()
                        Button("Reset to Default") {
                            renamePromptDraft = SystemPromptBuilder.defaultRenamePrompt
                            scheduleSave()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // MARK: - General Instructions Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("General Instructions")
                        .font(.title3)
                        .fontWeight(.medium)
                    Text("Added to all new Claude sessions in this repo.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $customInstructionsDraft)
                            .font(.body.monospaced())
                            .frame(minHeight: 120)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

                        if customInstructionsDraft.isEmpty {
                            Text("e.g. Always use pytest. Never mock the database.")
                                .font(.body.monospaced())
                                .foregroundStyle(.tertiary)
                                .padding(12)
                                .allowsHitTesting(false)
                        }
                    }
                }

                // MARK: - Save Indicator
                HStack {
                    Spacer()
                    if showSaved {
                        Text("Saved")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            if let repo {
                renamePromptDraft = repo.renamePrompt ?? SystemPromptBuilder.defaultRenamePrompt
                customInstructionsDraft = repo.customInstructions ?? ""
            }
        }
        .onChange(of: renamePromptDraft) { _, _ in
            guard initialized else { return }
            scheduleSave()
        }
        .onChange(of: customInstructionsDraft) { _, _ in
            guard initialized else { return }
            scheduleSave()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            // Determine what to persist:
            // renamePrompt: nil if matches default, "" if user cleared it, otherwise custom text
            let renameToSave: String?
            if renamePromptDraft == SystemPromptBuilder.defaultRenamePrompt {
                renameToSave = nil  // Use default
            } else {
                renameToSave = renamePromptDraft  // Custom or empty (disabled)
            }

            let instructionsToSave: String? = customInstructionsDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : customInstructionsDraft

            await appState.updateRepoInstructions(
                repoID: repoID,
                renamePrompt: renameToSave,
                customInstructions: instructionsToSave
            )

            withAnimation(.easeInOut(duration: 0.3)) { showSaved = true }
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeInOut(duration: 0.3)) { showSaved = false }
        }
    }
}
```

Note: This references `SystemPromptBuilder.defaultRenamePrompt` — the `SystemPromptBuilder` type is in `TBDDaemonLib`, not accessible from the app target. We need to either:
1. Move the default prompt string to `TBDShared` so both targets can use it, or
2. Duplicate the string in the view.

The cleanest approach is to add a static string to `TBDShared`. Add to `Sources/TBDShared/RepoConstants.swift`:

```swift
import Foundation

public enum RepoConstants {
    public static let defaultRenamePrompt = """
        To do immediately, before any other work:

        1. Rename the git branch to reflect the task:
           git branch -m <new-branch-name>

        2. Rename the TBD worktree display name:
           tbd worktree rename "$(basename "$(git rev-parse --show-toplevel)")" "<emoji> <display name>"

        Branch naming: use kebab-case, be concise (<30 chars), be specific.
        Display name: pick a relevant emoji, convert branch name to title case with spaces.

        Examples:
          Branch: fix-login-timeout → Display: ⏱ Fix Login Timeout
          Branch: add-export-csv   → Display: 📊 Add Export CSV

        Do this before reading files, using skills, or any other tools.
        """
}
```

Then update `SystemPromptBuilder.defaultRenamePrompt` to reference `RepoConstants.defaultRenamePrompt`, and update `RepoInstructionsView` to use `RepoConstants.defaultRenamePrompt` instead of `SystemPromptBuilder.defaultRenamePrompt`.

- [ ] **Step 3: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 4: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDShared/RepoConstants.swift Sources/TBDApp/RepoInstructionsView.swift Sources/TBDApp/AppState+Repos.swift Sources/TBDDaemon/Lifecycle/SystemPromptBuilder.swift
git commit -m "feat: add RepoInstructionsView with rename prompt and general instructions editors"
```

---

### Task 7: Final Verification

**Files:** None (verification only)

- [ ] **Step 1: Run full test suite**

Run: `swift test 2>&1 | tail -30`
Expected: All tests pass

- [ ] **Step 2: Verify build is clean with no warnings**

Run: `swift build 2>&1`
Expected: Build succeeded with no warnings related to our changes

- [ ] **Step 3: Restart daemon and app to verify end-to-end**

Run: `scripts/restart.sh`
Expected: Daemon restarts, app reconnects, no crashes
