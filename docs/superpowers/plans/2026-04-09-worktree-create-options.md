# Worktree Create Options Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `--folder`, `--branch`, `--name`, and `--prompt-file` flags to `tbd worktree create` (and `--prompt-file` to `tbd terminal create`) so users can control directory name, git branch, display label, and provide multi-line prompts without shell escaping issues.

**Architecture:** CLI-only flags resolve locally, then pass through existing RPC protocol to the daemon. `WorktreeCreateParams` gains `folder`/`branch`/`displayName` fields (replacing `name`). The daemon lifecycle layer uses them independently for path, branch, and display name generation. A shared `resolvePrompt()` CLI helper handles `--prompt`/`--prompt-file` mutual exclusion with TTY detection.

**Tech Stack:** Swift, ArgumentParser, GRDB, tmux

**Spec:** `docs/superpowers/specs/2026-04-09-worktree-create-options-design.md`

---

### Task 1: Shared `resolvePrompt()` helper in CLI

**Files:**
- Modify: `Sources/TBDCLI/Utilities.swift`

This is the foundation both `WorktreeCreate` and `TerminalCreate` depend on. Build it first.

- [ ] **Step 1: Add `resolvePrompt()` to Utilities.swift**

Append to the end of `Sources/TBDCLI/Utilities.swift`:

```swift
import Darwin

/// Resolve prompt text from `--prompt` (inline) and `--prompt-file` (file/stdin).
/// The two flags are mutually exclusive. Returns nil if neither is provided.
func resolvePrompt(inline: String?, file: String?) throws -> String? {
    guard inline == nil || file == nil else {
        throw CLIError.invalidArgument("Cannot use both --prompt and --prompt-file")
    }
    guard let file else { return inline }
    if file == "-" {
        guard isatty(STDIN_FILENO) == 0 else {
            throw CLIError.invalidArgument("--prompt-file - requires piped input (e.g., <<'EOF' ... EOF)")
        }
        return String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
    }
    let resolved = resolvePath(file)
    guard FileManager.default.fileExists(atPath: resolved) else {
        throw CLIError.invalidArgument("Prompt file not found: \(file)")
    }
    return try String(contentsOfFile: resolved, encoding: .utf8)
}
```

Note: `import Darwin` may already be transitively available — if it causes a duplicate import warning, remove it. The `resolvePath()` function already exists in `Utilities.swift` (line 25).

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDCLI/Utilities.swift
git commit -m "feat: add resolvePrompt() CLI helper for --prompt-file support"
```

---

### Task 2: Update `WorktreeCreateParams` in shared protocol

**Files:**
- Modify: `Sources/TBDShared/RPCProtocol.swift:296-304`
- Modify: `Tests/TBDSharedTests/ModelsTests.swift:120-129`

Replace the `name` field with `folder`, `branch`, and `displayName`.

- [ ] **Step 1: Update `WorktreeCreateParams`**

In `Sources/TBDShared/RPCProtocol.swift`, replace lines 296-304:

```swift
public struct WorktreeCreateParams: Codable, Sendable {
    public let repoID: UUID
    public let name: String?
    /// Optional initial prompt to pass to the auto-created default Claude session.
    public let prompt: String?
    public init(repoID: UUID, name: String? = nil, prompt: String? = nil) {
        self.repoID = repoID; self.name = name; self.prompt = prompt
    }
}
```

with:

```swift
public struct WorktreeCreateParams: Codable, Sendable {
    public let repoID: UUID
    public let folder: String?
    public let branch: String?
    public let displayName: String?
    public let prompt: String?
    public init(repoID: UUID, folder: String? = nil, branch: String? = nil, displayName: String? = nil, prompt: String? = nil) {
        self.repoID = repoID; self.folder = folder; self.branch = branch; self.displayName = displayName; self.prompt = prompt
    }
}
```

- [ ] **Step 2: Update the test**

In `Tests/TBDSharedTests/ModelsTests.swift`, the test at line 120 creates a `WorktreeCreateParams(repoID: UUID())`. This still works since all new fields default to nil. No change needed — verify by running:

Run: `swift test --filter testRPCRequestRoundTrip 2>&1 | tail -5`
Expected: `Test run started` ... `passed`

- [ ] **Step 3: Verify full build**

Run: `swift build 2>&1 | tail -5`

This will fail because callers still reference `params.name` — that's expected. We'll fix them in subsequent tasks. Just verify the shared module itself compiles:

Run: `swift build --target TBDShared 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDShared/RPCProtocol.swift
git commit -m "feat: replace WorktreeCreateParams.name with folder/branch/displayName"
```

---

### Task 3: Update CLI `WorktreeCreate` with new flags and `--prompt-file`

**Files:**
- Modify: `Sources/TBDCLI/Commands/WorktreeCommands.swift:21-121`

Replace the existing `@Argument name` with three `@Option` flags, add `--prompt-file`, update `validate()`, and update the RPC call.

- [ ] **Step 1: Rewrite the `WorktreeCreate` struct**

In `Sources/TBDCLI/Commands/WorktreeCommands.swift`, replace lines 21-121 (the entire `WorktreeCreate` struct) with:

```swift
struct WorktreeCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new worktree (waits for git setup to complete)"
    )

    @Option(name: .long, help: "Directory name for the worktree (default: auto-generated)")
    var folder: String?

    @Option(name: .long, help: "Full git branch name (default: tbd/<folder>)")
    var branch: String?

    @Option(name: .long, help: "Display name shown in TBD UI (default: same as folder)")
    var name: String?

    @Option(name: .long, help: "Repository path or ID")
    var repo: String?

    @Option(name: .long, help: "Initial prompt for the auto-created Claude session")
    var prompt: String?

    @Option(name: .long, help: "Read initial prompt from a file (use - for stdin)")
    var promptFile: String?

    @Flag(name: .long, help: "Return immediately without waiting for the worktree to become active")
    var noWait = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func validate() throws {
        if let folder = folder {
            if folder.isEmpty {
                throw ValidationError("Folder name must not be empty.")
            }
            if folder == "." || folder == ".." {
                throw ValidationError("Folder name cannot be '.' or '..'.")
            }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
            if folder.unicodeScalars.contains(where: { !allowed.contains($0) }) {
                throw ValidationError(
                    "Invalid folder name '\(folder)'. Use only letters, digits, hyphens, underscores, or dots."
                )
            }
        }
    }

    mutating func run() async throws {
        let client = SocketClient()
        let repoID: UUID

        if let repo = repo {
            if let id = UUID(uuidString: repo) {
                repoID = id
            } else {
                let resolver = PathResolver(client: client)
                repoID = try resolver.resolveRepoID(path: repo)
            }
        } else {
            let resolver = PathResolver(client: client)
            repoID = try resolver.resolveRepoID()
        }

        let resolvedPrompt = try resolvePrompt(inline: prompt, file: promptFile)

        let pending: Worktree = try client.call(
            method: RPCMethod.worktreeCreate,
            params: WorktreeCreateParams(repoID: repoID, folder: folder, branch: branch, displayName: name, prompt: resolvedPrompt),
            resultType: Worktree.self
        )

        let worktree: Worktree
        if noWait {
            worktree = pending
        } else {
            worktree = try waitForActive(pending: pending, client: client)
        }

        if json {
            printJSON(worktree)
        } else {
            print("Created worktree: \(worktree.displayName)")
            print("  ID:     \(worktree.id)")
            print("  Branch: \(worktree.branch)")
            print("  Path:   \(worktree.path)")
        }
    }

    private func waitForActive(pending: Worktree, client: SocketClient) throws -> Worktree {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let worktrees: [Worktree] = try client.call(
                method: RPCMethod.worktreeList,
                params: WorktreeListParams(repoID: pending.repoID),
                resultType: [Worktree].self
            )
            if let updated = worktrees.first(where: { $0.id == pending.id }) {
                if updated.status == .active || updated.status == .main {
                    return updated
                }
            } else {
                throw CLIError.invalidArgument("Worktree creation failed (see daemon logs)")
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw CLIError.invalidArgument("Timed out waiting for worktree to become active")
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --target TBDCLI 2>&1 | tail -5`
Expected: `Build complete!` (or errors only from daemon-side callers, which is OK at this stage)

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDCLI/Commands/WorktreeCommands.swift
git commit -m "feat: add --folder, --branch, --name, --prompt-file to worktree create"
```

---

### Task 4: Add `--prompt-file` to `TerminalCreate`

**Files:**
- Modify: `Sources/TBDCLI/Commands/TerminalCommands.swift:19-59`

- [ ] **Step 1: Add `--prompt-file` option and use `resolvePrompt()`**

In `Sources/TBDCLI/Commands/TerminalCommands.swift`, add the `promptFile` option after the existing `prompt` option (after line 35):

```swift
    @Option(name: .long, help: "Read initial prompt from a file (use - for stdin)")
    var promptFile: String?
```

Then in `run()`, replace line 46:

```swift
            params: TerminalCreateParams(worktreeID: worktreeID, cmd: cmd, type: type, prompt: prompt),
```

with:

```swift
            params: TerminalCreateParams(worktreeID: worktreeID, cmd: cmd, type: type, prompt: try resolvePrompt(inline: prompt, file: promptFile)),
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --target TBDCLI 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDCLI/Commands/TerminalCommands.swift
git commit -m "feat: add --prompt-file to terminal create"
```

---

### Task 5: Update daemon lifecycle — `beginCreateWorktree()` and `createWorktree()`

**Files:**
- Modify: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift:14-66`

- [ ] **Step 1: Update `createWorktree()` convenience wrapper (line 14)**

Replace:

```swift
    public func createWorktree(repoID: UUID, name: String? = nil, skipClaude: Bool = false, initialPrompt: String? = nil) async throws -> Worktree {
        let pending = try await beginCreateWorktree(repoID: repoID, name: name, skipClaude: skipClaude)
```

with:

```swift
    public func createWorktree(repoID: UUID, folder: String? = nil, branch: String? = nil, displayName: String? = nil, skipClaude: Bool = false, initialPrompt: String? = nil) async throws -> Worktree {
        let pending = try await beginCreateWorktree(repoID: repoID, folder: folder, branch: branch, displayName: displayName, skipClaude: skipClaude)
```

- [ ] **Step 2: Update `beginCreateWorktree()` (line 28)**

Replace the signature and the name/branch/path generation logic (lines 28-65):

```swift
    public func beginCreateWorktree(repoID: UUID, name: String? = nil, skipClaude: Bool = false) async throws -> Worktree {
        // 1. Fetch repo
        guard let repo = try await db.repos.get(id: repoID) else {
            throw WorktreeLifecycleError.repoNotFound(repoID)
        }

        // 2. Generate name and construct path
        let name = name ?? NameGenerator.generate()
        let branch = "tbd/\(name)"
```

with:

```swift
    public func beginCreateWorktree(repoID: UUID, folder: String? = nil, branch: String? = nil, displayName: String? = nil, skipClaude: Bool = false) async throws -> Worktree {
        // 1. Fetch repo
        guard let repo = try await db.repos.get(id: repoID) else {
            throw WorktreeLifecycleError.repoNotFound(repoID)
        }

        // 2. Resolve folder, branch, displayName — each independent, with defaults
        let name = folder ?? NameGenerator.generate()
        let branch = branch ?? "tbd/\(name)"
```

Note: the local variable `name` is reused (it maps to the DB `name` column which is the folder name). The rest of the method (lines 37-65) uses `name` for the folder path and `branch` for the git branch — this continues to work correctly because `name` now holds the resolved folder value and `branch` holds the resolved branch value.

- [ ] **Step 3: Update the `db.worktrees.create()` call (line 56)**

Replace:

```swift
        let worktree = try await db.worktrees.create(
            repoID: repo.id,
            name: name,
            branch: branch,
            path: worktreePath,
            tmuxServer: tmuxServer,
            status: .creating
        )
```

with:

```swift
        let worktree = try await db.worktrees.create(
            repoID: repo.id,
            name: name,
            displayName: displayName,
            branch: branch,
            path: worktreePath,
            tmuxServer: tmuxServer,
            status: .creating
        )
```

- [ ] **Step 4: Update collision retry in `attemptWorktreeAdd()` (lines 127-178)**

The current retry logic (lines 151-173) generates a fresh random name on collision. This should only happen when both folder and branch are auto-generated. Add a `folderIsUserSpecified` parameter to control this.

Update the `attemptWorktreeAdd` signature at line 127:

Replace:

```swift
    private func attemptWorktreeAdd(
        repo: Repo, name: String, branch: String,
        worktreePath: String
    ) async throws -> (name: String, branch: String, path: String) {
```

with:

```swift
    private func attemptWorktreeAdd(
        repo: Repo, name: String, branch: String,
        worktreePath: String,
        userSpecifiedFolder: Bool,
        userSpecifiedBranch: Bool
    ) async throws -> (name: String, branch: String, path: String) {
```

Then replace the retry block (lines 151-173):

```swift
        // Retry with a fresh name (branch collision case)
        let retryName = NameGenerator.generate()
        let retryBranch = "tbd/\(retryName)"
        let retryCanonicalBase = WorktreeLayout().basePath(for: repo)
        let retryPath = (retryCanonicalBase as NSString).appendingPathComponent(retryName)
        try FileManager.default.createDirectory(
            atPath: retryCanonicalBase,
            withIntermediateDirectories: true
        )

        for baseBranch in baseBranches {
            do {
                try await git.worktreeAdd(
                    repoPath: repoPath,
                    worktreePath: retryPath,
                    branch: retryBranch,
                    baseBranch: baseBranch
                )
                return (name: retryName, branch: retryBranch, path: retryPath)
            } catch {
                try? FileManager.default.removeItem(atPath: retryPath)
            }
        }
```

with:

```swift
        // Only retry with a fresh name if both folder and branch are auto-generated.
        // If either was user-specified, fail immediately — silent retry would be surprising.
        guard !userSpecifiedFolder && !userSpecifiedBranch else {
            throw WorktreeLifecycleError.createFailed(
                "git worktree add failed — the branch or folder may already exist"
            )
        }

        let retryName = NameGenerator.generate()
        let retryBranch = "tbd/\(retryName)"
        let retryCanonicalBase = WorktreeLayout().basePath(for: repo)
        let retryPath = (retryCanonicalBase as NSString).appendingPathComponent(retryName)
        try FileManager.default.createDirectory(
            atPath: retryCanonicalBase,
            withIntermediateDirectories: true
        )

        for baseBranch in baseBranches {
            do {
                try await git.worktreeAdd(
                    repoPath: repoPath,
                    worktreePath: retryPath,
                    branch: retryBranch,
                    baseBranch: baseBranch
                )
                return (name: retryName, branch: retryBranch, path: retryPath)
            } catch {
                try? FileManager.default.removeItem(atPath: retryPath)
            }
        }
```

- [ ] **Step 5: Update the call to `attemptWorktreeAdd` in `completeCreateWorktree()` (line 95)**

We need to thread the user-specified flags through. Add stored properties to track this. The simplest approach: store `userSpecifiedFolder` and `userSpecifiedBranch` on the worktree DB record would require a schema change. Instead, pass them through `completeCreateWorktree()`.

Update `completeCreateWorktree` signature at line 70:

Replace:

```swift
    public func completeCreateWorktree(worktreeID: UUID, skipClaude: Bool = false, initialPrompt: String? = nil) async throws {
```

with:

```swift
    public func completeCreateWorktree(worktreeID: UUID, skipClaude: Bool = false, initialPrompt: String? = nil, userSpecifiedFolder: Bool = false, userSpecifiedBranch: Bool = false) async throws {
```

Then update the call at line 95:

Replace:

```swift
            let result = try await attemptWorktreeAdd(
                repo: repo, name: worktree.name, branch: worktree.branch,
                worktreePath: worktree.path
            )
```

with:

```swift
            let result = try await attemptWorktreeAdd(
                repo: repo, name: worktree.name, branch: worktree.branch,
                worktreePath: worktree.path,
                userSpecifiedFolder: userSpecifiedFolder,
                userSpecifiedBranch: userSpecifiedBranch
            )
```

Also update the `createWorktree()` convenience wrapper call at line 16:

Replace:

```swift
        try await completeCreateWorktree(worktreeID: pending.id, skipClaude: skipClaude, initialPrompt: initialPrompt)
```

with:

```swift
        try await completeCreateWorktree(worktreeID: pending.id, skipClaude: skipClaude, initialPrompt: initialPrompt, userSpecifiedFolder: folder != nil, userSpecifiedBranch: branch != nil)
```

- [ ] **Step 6: Verify it compiles**

Run: `swift build --target TBDDaemon 2>&1 | tail -10`

This may still fail due to callers (RPCRouter, DaemonClient) — that's OK. Verify no errors originate from `WorktreeLifecycle+Create.swift` itself.

- [ ] **Step 7: Commit**

```bash
git add Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift
git commit -m "feat: accept folder/branch/displayName in worktree lifecycle"
```

---

### Task 6: Update `WorktreeStore.create()` to accept `displayName`

**Files:**
- Modify: `Sources/TBDDaemon/Database/WorktreeStore.swift:76-103`

- [ ] **Step 1: Add `displayName` parameter**

In `Sources/TBDDaemon/Database/WorktreeStore.swift`, replace lines 76-83:

```swift
    public func create(
        repoID: UUID,
        name: String,
        branch: String,
        path: String,
        tmuxServer: String,
        status: WorktreeStatus = .active
    ) async throws -> Worktree {
```

with:

```swift
    public func create(
        repoID: UUID,
        name: String,
        displayName: String? = nil,
        branch: String,
        path: String,
        tmuxServer: String,
        status: WorktreeStatus = .active
    ) async throws -> Worktree {
```

Then on line 93, replace:

```swift
                displayName: name,
```

with:

```swift
                displayName: displayName ?? name,
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --target TBDDaemon 2>&1 | tail -5`

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDDaemon/Database/WorktreeStore.swift
git commit -m "feat: accept optional displayName in WorktreeStore.create()"
```

---

### Task 7: Update RPC router and app-side callers

**Files:**
- Modify: `Sources/TBDDaemon/Server/RPCRouter+WorktreeHandlers.swift:8-37`
- Modify: `Sources/TBDApp/DaemonClient.swift:379-386`

- [ ] **Step 1: Update `handleWorktreeCreate()` in RPCRouter**

In `Sources/TBDDaemon/Server/RPCRouter+WorktreeHandlers.swift`, replace line 12:

```swift
        let pending = try await lifecycle.beginCreateWorktree(repoID: params.repoID, name: params.name)
```

with:

```swift
        let pending = try await lifecycle.beginCreateWorktree(repoID: params.repoID, folder: params.folder, branch: params.branch, displayName: params.displayName)
```

Also update the `completeCreateWorktree` call at line 20 to pass through user-specified flags:

```swift
                try await lifecycle.completeCreateWorktree(worktreeID: pending.id, initialPrompt: initialPrompt, userSpecifiedFolder: params.folder != nil, userSpecifiedBranch: params.branch != nil)
```

Add locals before the `Task.detached` block (after line 17):

```swift
        let userSpecifiedFolder = params.folder != nil
        let userSpecifiedBranch = params.branch != nil
```

And update the call inside the Task:

```swift
                try await lifecycle.completeCreateWorktree(worktreeID: pending.id, initialPrompt: initialPrompt, userSpecifiedFolder: userSpecifiedFolder, userSpecifiedBranch: userSpecifiedBranch)
```

- [ ] **Step 2: Update `DaemonClient.createWorktree()`**

In `Sources/TBDApp/DaemonClient.swift`, replace lines 379-386:

```swift
    /// Create a new worktree in a repo.
    func createWorktree(repoID: UUID, name: String? = nil) async throws -> Worktree {
        return try await callAsync(
            method: RPCMethod.worktreeCreate,
            params: WorktreeCreateParams(repoID: repoID, name: name),
            resultType: Worktree.self
        )
    }
```

with:

```swift
    /// Create a new worktree in a repo.
    func createWorktree(repoID: UUID, folder: String? = nil, branch: String? = nil, displayName: String? = nil) async throws -> Worktree {
        return try await callAsync(
            method: RPCMethod.worktreeCreate,
            params: WorktreeCreateParams(repoID: repoID, folder: folder, branch: branch, displayName: displayName),
            resultType: Worktree.self
        )
    }
```

- [ ] **Step 3: Verify full build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 4: Run tests**

Run: `swift test 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Server/RPCRouter+WorktreeHandlers.swift Sources/TBDApp/DaemonClient.swift
git commit -m "feat: wire folder/branch/displayName through RPC router and DaemonClient"
```

---

### Task 8: Update `SystemPromptBuilder.builtInTBDContext`

**Files:**
- Modify: `Sources/TBDDaemon/Lifecycle/SystemPromptBuilder.swift:14-41`

- [ ] **Step 1: Update the spawn guidance**

In `Sources/TBDDaemon/Lifecycle/SystemPromptBuilder.swift`, replace lines 17-41 (inside `builtInTBDContext`). Find this block:

```swift
        - tbd worktree create [--repo <path-or-id>] — create a new worktree (auto-named)
```

Replace with:

```swift
        - tbd worktree create [--repo <path-or-id>] [--folder <dir>] [--branch <name>] [--name "<display>"] — create a new worktree
```

Then find this block:

```swift
        Spawning a new Claude tab in the current worktree:
          tbd terminal create "$TBD_WORKTREE_ID" --type claude --prompt "your task here"

        Creating a new worktree with an initial task for its default Claude tab:
          tbd worktree create --prompt "your task here"

        Using --cmd for full control (env vars expand in the new shell):
          tbd terminal create "$TBD_WORKTREE_ID" --cmd 'claude --append-system-prompt "$TBD_PROMPT_CONTEXT"'
```

Replace with:

```swift
        Spawning a new Claude tab in the current worktree:
          tbd terminal create "$TBD_WORKTREE_ID" --type claude --prompt-file - <<'EOF'
          your task here
          EOF

        Creating a new worktree with an initial task for its default Claude tab:
          tbd worktree create --prompt-file - <<'EOF'
          your task here
          EOF

        When using --prompt or --prompt-file to spawn a new worktree or Claude tab, write a
        thorough briefing — the new session starts with zero context from your conversation.
        Include what you're trying to accomplish, what you've already learned or ruled out,
        relevant file paths and line numbers, and enough surrounding context that the new
        session can make judgment calls rather than follow narrow instructions. Use
        --prompt-file - with a heredoc for multi-line prompts to avoid shell escaping issues.

        Using --cmd for full control (env vars expand in the new shell):
          tbd terminal create "$TBD_WORKTREE_ID" --cmd 'claude --append-system-prompt "$TBD_PROMPT_CONTEXT"'
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Run `SystemPromptBuilderTests`**

Run: `swift test --filter SystemPromptBuilder 2>&1 | tail -10`

These tests may check exact string content. If any fail, update the test expectations to match the new text.

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDDaemon/Lifecycle/SystemPromptBuilder.swift
git commit -m "feat: update system prompt with --prompt-file guidance and thorough briefing instructions"
```

---

### Task 9: Full build + test verification

**Files:** None (verification only)

- [ ] **Step 1: Clean build**

Run: `swift build 2>&1 | tail -10`
Expected: `Build complete!`

- [ ] **Step 2: Run full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 3: If any tests fail, fix them**

Common issues:
- `SystemPromptBuilderTests` may assert exact string content — update expectations
- `ModelsTests.testRPCRequestRoundTrip` — should still work since `WorktreeCreateParams(repoID:)` still compiles with all-optional fields
- Any test referencing `createWorktree(repoID:name:)` on the lifecycle — needs `name:` renamed to `folder:`

- [ ] **Step 4: Final commit if any test fixes were needed**

```bash
git add -A
git commit -m "fix: update tests for new worktree create params"
```
