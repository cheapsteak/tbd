# Per-Repo Custom Instructions

Add configurable per-repo instructions that TBD injects into spawned Claude Code sessions via `--append-system-prompt`, without modifying CLAUDE.md files.

## Motivation

Users want project-specific conventions (testing frameworks, code style, forbidden patterns) applied to every Claude session in a repo. Today the only option is CLAUDE.md, which is committed to the repo and visible to all collaborators. Per-repo instructions in TBD are local, per-user, and managed through the app UI.

## Data Model & Storage

### DB Migration v11

Add a `customInstructions` TEXT column to the `repo` table, defaulting to NULL:

```swift
migrator.registerMigration("v11") { db in
    try db.alter(table: "repo") { t in
        t.add(column: "customInstructions", .text)
    }
}
```

### Shared Model (TBDShared/Models.swift)

Add to `Repo`:

```swift
public var customInstructions: String?
```

Must be optional so existing JSON/rows decode without error. Add to `init` with default `nil`. Add to the manual `init(from decoder:)` with `decodeIfPresent`.

### RepoRecord (TBDDaemon/Database/RepoStore.swift)

Add `customInstructions: String?` to `RepoRecord`. Update `init(from:)` and `toModel()` to map the field.

Add an update method:

```swift
public func update(id: UUID, customInstructions: String?) async throws {
    try await writer.write { db in
        try db.execute(
            sql: "UPDATE repo SET customInstructions = ? WHERE id = ?",
            arguments: [customInstructions, id.uuidString]
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
    public let customInstructions: String?
    public init(repoID: UUID, customInstructions: String?) {
        self.repoID = repoID
        self.customInstructions = customInstructions
    }
}
```

No separate read RPC needed — `repo.list` already returns `[Repo]` which will include `customInstructions` automatically.

## Instruction Injection

### Fresh Claude Sessions (WorktreeLifecycle+Create.swift)

In `setupTerminals()`, after building the base `claudeCommand` and before spawning:

1. Look up the repo's `customInstructions` from the database using the worktree's `repoID`.
2. If non-nil and non-empty after trimming, append `--append-system-prompt '<escaped>'` to the command string.

```swift
// Pseudocode
if let instructions = repo.customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
   !instructions.isEmpty {
    claudeCommand += " --append-system-prompt \(shellEscape(instructions))"
}
```

### Conductor Sessions (ConductorManager.swift)

Same logic at conductor start. The conductor's working directory is `~/.tbd/conductors/<name>/`, not a repo directory, so the injection must explicitly look up the repo. If the conductor's `repos` scope is a single repo ID, use that repo's instructions. If the scope is `["*"]` (all repos) or multiple repos, skip injection — there's no single set of instructions to apply.

### Resumed Sessions

`--resume` restores the full conversation including the original system prompt. Do NOT re-inject instructions on resume to avoid double-injection.

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
            // Segmented control at top
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            // Tab content
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
┌─────────────────────────────────────────┐
│  Custom Instructions                    │
│  Added to all new Claude sessions in    │
│  this repo via --append-system-prompt   │
├─────────────────────────────────────────┤
│                                         │
│  ┌─────────────────────────────────┐    │
│  │ TextEditor                      │    │
│  │                                 │    │
│  │ (placeholder when empty:        │    │
│  │  "e.g. Always use pytest...")   │    │
│  │                                 │    │
│  └─────────────────────────────────┘    │
│                                         │
│                          Saved ✓  (fade)│
└─────────────────────────────────────────┘
```

Behavior:
- `@State var draft: String` initialized from `repo.customInstructions ?? ""`
- Placeholder overlay that hides when draft is non-empty
- `.onChange(of: draft)` triggers a debounced save (~1 second)
- Calls `appState.updateRepoInstructions(repoID:instructions:)` on save
- Subtle "Saved" text with a fade-in/fade-out animation after each successful save
- Empty/whitespace-only text saves as `nil` (clears the instructions)

## State & RPC Wiring

### DaemonClient

Add method:

```swift
func repoUpdateInstructions(repoID: UUID, customInstructions: String?) async throws
```

Wraps the `repo.updateInstructions` RPC call.

### AppState

Add method:

```swift
func updateRepoInstructions(repoID: UUID, instructions: String?) async {
    try? await daemonClient.repoUpdateInstructions(repoID: repoID, customInstructions: instructions)
    await refreshRepos()
}
```

### RPCRouter (daemon side)

Handle `repo.updateInstructions`:

```swift
case RPCMethod.repoUpdateInstructions:
    let params = try decode(RepoUpdateInstructionsParams.self, from: request.params)
    try await db.repos.update(id: params.repoID, customInstructions: params.customInstructions)
    let repo = try await db.repos.get(id: params.repoID)
    return encode(repo)
```

No new state subscriptions needed. Instructions only matter at spawn time (daemon-side read) and at edit time (app-side write).

## Testing

### DB Migration

- Verify v11 migration adds `customInstructions` column
- Existing repos have NULL instructions after migration
- Can store and retrieve instructions text

### Instruction Injection (branching conditional — both branches tested)

- **With instructions**: when `customInstructions` is set, the spawned claude command includes `--append-system-prompt` with the instructions text
- **Without instructions**: when `customInstructions` is nil or empty, the command does NOT include `--append-system-prompt`

### Shell Escaping

- Text with single quotes: `don't mock` → `'don'\''t mock'`
- Text with double quotes: `use "pytest"` → correctly preserved
- Text with newlines: multi-line instructions are escaped properly
- Text with special shell characters: `$HOME`, backticks, etc.

### Not Tested (UI)

No existing SwiftUI test infrastructure. The segmented control, TextEditor, debounce, and save indicator are standard SwiftUI composition and are verified manually.
