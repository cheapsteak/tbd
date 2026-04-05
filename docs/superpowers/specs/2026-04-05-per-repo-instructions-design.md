# Per-Repo Custom Instructions

Add configurable per-repo instructions that TBD injects into spawned Claude Code sessions via `--append-system-prompt`, without modifying CLAUDE.md files.

## Motivation

Users want project-specific conventions (testing frameworks, code style, forbidden patterns) applied to every Claude session in a repo. Today the only option is CLAUDE.md, which is committed to the repo and visible to all collaborators. Per-repo instructions in TBD are local, per-user, and managed through the app UI.

Additionally, TBD creates worktrees with auto-generated adjective-animal names and `tbd/<name>` branches. Users want Claude to rename these to meaningful names on session start, following their preferred conventions — similar to how Conductor (conductor.build) handles branch renames.

## Instruction Layers

There are three distinct instruction layers, injected via `--append-system-prompt`:

### 1. Rename Prompt (per-repo, user-editable, conditional)

A prompt telling Claude to rename the git branch and TBD worktree display name on session start. Pre-populated with a sensible default that the user can fully customize.

**When injected:** Only when the worktree hasn't been renamed yet — i.e., when `worktree.displayName == worktree.name` (the auto-generated adjective-animal name). Once anyone (Claude or the user) renames the worktree, this prompt stops firing for all sessions in that worktree.

**Default prompt:**

```
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
```

The user can edit this to add their own conventions (e.g., `cw/4/feat-{feature}` prefix, specific emoji rules, etc.).

### 2. Built-in TBD Context (not user-editable, always injected)

A system-level prompt that tells Claude it's running inside a TBD worktree and what CLI commands are available. Always injected on fresh sessions, not configurable by the user.

```
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
```

### 3. General Instructions (per-repo, user-editable, always injected)

Freeform text for project conventions. Injected as user preferences after the TBD context.

## Data Model & Storage

### DB Migration v11

Add two columns to the `repo` table:

```swift
migrator.registerMigration("v11") { db in
    try db.alter(table: "repo") { t in
        t.add(column: "renamePrompt", .text)
        t.add(column: "customInstructions", .text)
    }
}
```

Both default to NULL. NULL `renamePrompt` means "use the built-in default" (not "no rename prompt"). An explicitly empty string means "disabled."

### Shared Model (TBDShared/Models.swift)

Add to `Repo`:

```swift
public var renamePrompt: String?
public var customInstructions: String?
```

Both optional so existing JSON/rows decode without error. Add to `init` with default `nil`. Add to the manual `init(from decoder:)` with `decodeIfPresent`.

### RepoRecord (TBDDaemon/Database/RepoStore.swift)

Add both fields to `RepoRecord`. Update `init(from:)` and `toModel()` to map them.

Add an update method:

```swift
public func updateInstructions(id: UUID, renamePrompt: String?, customInstructions: String?) async throws {
    try await writer.write { db in
        try db.execute(
            sql: "UPDATE repo SET renamePrompt = ?, customInstructions = ? WHERE id = ?",
            arguments: [renamePrompt, customInstructions, id.uuidString]
        )
    }
}
```

### RPC

New method `repo.updateInstructions`:

```swift
// RPCProtocol.swift
public static let repoUpdateInstructions = "repo.updateInstructions"

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

No separate read RPC needed — `repo.list` already returns `[Repo]` which will include both fields automatically.

## Instruction Injection

### Composing the System Prompt

At spawn time, build the appended system prompt by concatenating applicable layers:

```swift
var parts: [String] = []

// Layer 1: Rename prompt (conditional)
if worktree.displayName == worktree.name {
    let renamePrompt = repo.renamePrompt ?? Self.defaultRenamePrompt
    if !renamePrompt.isEmpty {
        parts.append(renamePrompt)
    }
}

// Layer 2: Built-in TBD context (always)
parts.append(Self.builtInTBDContext)

// Layer 3: User general instructions (if set)
if let instructions = repo.customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
   !instructions.isEmpty {
    parts.append(instructions)
}

if !parts.isEmpty {
    let combined = parts.joined(separator: "\n\n---\n\n")
    claudeCommand += " --append-system-prompt \(shellEscape(combined))"
}
```

The default rename prompt and built-in TBD context are static strings defined on the lifecycle class.

### Where Injection Happens

**Fresh worktree Claude sessions** (`WorktreeLifecycle+Create.swift` `setupTerminals()`) — yes, with rename conditional check.

**New Claude terminals** (`RPCRouter+TerminalHandlers.swift` terminal creation) — yes, same logic. This covers the case where a user opens a second Claude terminal before the first one has renamed.

**Conductor sessions** (`ConductorManager.swift`) — inject layers 2 and 3 only (no rename prompt). If conductor's `repos` scope is a single repo ID, use that repo's instructions. If scope is `["*"]` or multiple repos, skip layer 3 (no single set of instructions to apply). Layer 2 (TBD context) is always injected.

**Resumed sessions** (`--resume`) — no injection. The original session already has the prompt.

### Shell Escaping

Instructions are embedded in a tmux shell command string. Escape using single-quote wrapping with interior single quotes replaced by `'\''`:

```swift
func shellEscape(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
```

## UI

### RepoDetailView (new file: TBDApp/RepoDetailView.swift)

Replaces the `ArchivedWorktreesView(repoID:)` call in `ContentView.swift` line 30.

```swift
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
            .padding(.horizontal, 20)
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

### ContentView Change

```swift
// Before:
ArchivedWorktreesView(repoID: repoID)

// After:
RepoDetailView(repoID: repoID)
```

### RepoInstructionsView (new file: TBDApp/RepoInstructionsView.swift)

```
┌──────────────────────────────────────────────────┐
│                                                  │
│  Rename Prompt                                   │
│  Sent with first message in worktrees that       │
│  haven't been renamed yet                        │
│                                                  │
│  ┌────────────────────────────────────────────┐  │
│  │ To do immediately, before any other work:  │  │
│  │                                            │  │
│  │ 1. Rename the git branch...               │  │
│  │ 2. Rename the TBD worktree...             │  │
│  │ ...                                       │  │
│  └────────────────────────────────────────────┘  │
│                                       [Reset]    │
│                                                  │
│  ──────────────────────────────────────────────  │
│                                                  │
│  General Instructions                            │
│  Added to all new Claude sessions in this repo   │
│                                                  │
│  ┌────────────────────────────────────────────┐  │
│  │ (placeholder: "e.g. Always use pytest...") │  │
│  │                                            │  │
│  │                                            │  │
│  └────────────────────────────────────────────┘  │
│                                                  │
│                                    Saved ✓ (fade)│
└──────────────────────────────────────────────────┘
```

Behavior:
- Two sections in a single scrollable view
- **Rename prompt**: `TextEditor` pre-populated with the default rename prompt (or the user's saved version). A "Reset" button restores the default. Saving an empty string disables the rename prompt entirely.
- **General instructions**: `TextEditor` with placeholder overlay, empty by default.
- Both fields share the same debounced auto-save (~1 second). A single `Saved` indicator covers both.
- Calls `appState.updateRepoInstructions(repoID:renamePrompt:customInstructions:)` on save.
- `renamePrompt` saves as `nil` when it matches the default (so the DB only stores customizations). Saves as `""` (empty string) when the user explicitly clears it (disabling rename).

## State & RPC Wiring

### DaemonClient

Add method:

```swift
func repoUpdateInstructions(repoID: UUID, renamePrompt: String?, customInstructions: String?) async throws
```

Wraps the `repo.updateInstructions` RPC call.

### AppState

Add method:

```swift
func updateRepoInstructions(repoID: UUID, renamePrompt: String?, customInstructions: String?) async {
    try? await daemonClient.repoUpdateInstructions(
        repoID: repoID, renamePrompt: renamePrompt, customInstructions: customInstructions
    )
    await refreshRepos()
}
```

### RPCRouter (daemon side)

Handle `repo.updateInstructions`:

```swift
case RPCMethod.repoUpdateInstructions:
    let params = try decode(RepoUpdateInstructionsParams.self, from: request.params)
    try await db.repos.updateInstructions(
        id: params.repoID,
        renamePrompt: params.renamePrompt,
        customInstructions: params.customInstructions
    )
    let repo = try await db.repos.get(id: params.repoID)
    return encode(repo)
```

No new state subscriptions needed. Instructions only matter at spawn time (daemon-side read) and at edit time (app-side write).

## Testing

### DB Migration

- Verify v11 migration adds both `renamePrompt` and `customInstructions` columns
- Existing repos have NULL for both after migration
- Can store and retrieve both fields

### Rename Prompt Conditional (branching — both branches tested)

- **Worktree not renamed** (`displayName == name`): rename prompt is included in the appended system prompt
- **Worktree already renamed** (`displayName != name`): rename prompt is NOT included
- **Rename prompt explicitly disabled** (empty string in DB): rename prompt is NOT included even if worktree hasn't been renamed

### General Instructions Injection (branching — both branches tested)

- **With instructions**: when `customInstructions` is set, the spawned command includes it in `--append-system-prompt`
- **Without instructions**: when `customInstructions` is nil or empty, it is omitted

### Built-in TBD Context

- Always present in the appended system prompt for fresh sessions
- Not present for resumed sessions

### Shell Escaping

- Text with single quotes: `don't mock` → `'don'\''t mock'`
- Text with double quotes: `use "pytest"` → correctly preserved
- Text with newlines: multi-line instructions are escaped properly
- Text with special shell characters: `$HOME`, backticks, etc.

### Not Tested (UI)

No existing SwiftUI test infrastructure. The segmented control, text editors, debounce, and save indicator are standard SwiftUI composition and are verified manually.
