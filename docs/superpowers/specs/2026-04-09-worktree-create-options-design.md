# Worktree Create Options: `--folder`, `--branch`, `--name`, `--prompt-file`

## Summary

Add three optional flags to `tbd worktree create` so users can control the directory name, git branch, and display label independently. Add `--prompt-file` as an escape-safe alternative to `--prompt` for long, multi-line briefings. All flags default to auto-generated values when omitted, preserving current behavior.

## CLI Surface

```
tbd worktree create [--repo <path-or-id>] [--folder <dir>] [--branch <full-branch>] [--name "<display>"] [--prompt "<text>" | --prompt-file <path-or-dash>] [--no-wait] [--json]
```

| Flag | Purpose | Example | Default when omitted |
|------|---------|---------|---------------------|
| `--folder` | Directory name under the worktree base path | `add-auth` | Auto-generated slug (`YYYYMMDD-adj-animal`) |
| `--branch` | Full git branch name | `tbd/add-auth` | `tbd/<folder>` |
| `--name` | Display label shown in TBD UI sidebar | `"🔐 Add Auth"` | Same as `--folder` value (must be explicitly passed to set a custom label) |
| `--prompt-file` | Read initial prompt from a file path or `-` for stdin | `/tmp/brief.md` or `-` | — |

`--prompt` and `--prompt-file` are mutually exclusive (error if both provided). `--prompt` remains for short inline text; `--prompt-file` is the preferred path for multi-line briefings since it avoids shell escaping issues entirely.

### Flag Combination Behavior

| `--folder` | `--branch` | `--name` | Folder | Branch | Display Name |
|------------|------------|----------|--------|--------|-------------|
| omitted | omitted | omitted | auto-generated | `tbd/<auto>` | `<auto>` |
| `my-feat` | omitted | omitted | `my-feat` | `tbd/my-feat` | `my-feat` |
| omitted | `feat/xyz` | omitted | auto-generated | `feat/xyz` | `<auto>` |
| omitted | omitted | `"🔐 Auth"` | auto-generated | `tbd/<auto>` | `🔐 Auth` |
| `my-feat` | `feat/xyz` | omitted | `my-feat` | `feat/xyz` | `my-feat` |
| `my-feat` | `feat/xyz` | `"🔐 Auth"` | `my-feat` | `feat/xyz` | `🔐 Auth` |

### Validation

`--folder` is validated at the CLI layer before the RPC call:
- Must not be empty
- Must not contain `/`, spaces, or emoji
- Must be a valid directory name (no `.`, `..`, or path traversal)

`--branch` has no special validation — git itself will reject invalid branch names.

`--name` has no validation — it is a free-form display label (emoji, spaces, Unicode all allowed).

### `--prompt-file` Implementation

In `WorktreeCreate.run()`, resolve the prompt before the RPC call:

Both `WorktreeCreate` and `TerminalCreate` use the shared `resolvePrompt()` helper (see below). The resolved prompt is passed to `WorktreeCreateParams`/`TerminalCreateParams` as before — the protocol and daemon are unaware of how the prompt was read.

### `tbd terminal create` — same treatment

`TerminalCreate` in `TerminalCommands.swift` also accepts `--prompt` for Claude tabs. Add `--prompt-file` with the same semantics (file path or `-` for stdin, mutually exclusive with `--prompt`). The resolution logic is identical — extract into a shared helper:

```swift
/// Resolve prompt from --prompt and --prompt-file, ensuring mutual exclusion.
func resolvePrompt(inline: String?, file: String?) throws -> String? {
    guard inline == nil || file == nil else {
        throw CLIError.invalidArgument("Cannot use both --prompt and --prompt-file")
    }
    if let file {
        if file == "-" {
            guard isatty(STDIN_FILENO) == 0 else {
                throw CLIError.invalidArgument("--prompt-file - requires piped input (e.g., <<'EOF' ... EOF)")
            }
            return String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
        }
        return try String(contentsOfFile: file, encoding: .utf8)
    }
    return inline
}
```

## System Prompt Update

### `SystemPromptBuilder.builtInTBDContext`

Update the spawn guidance in the built-in context to steer agents toward `--prompt-file -` for thorough briefings:

**Replace:**
```
Spawning a new Claude tab in the current worktree:
  tbd terminal create "$TBD_WORKTREE_ID" --type claude --prompt "your task here"

Creating a new worktree with an initial task for its default Claude tab:
  tbd worktree create --prompt "your task here"
```

**With:**
```
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
```

## Protocol Changes

### `WorktreeCreateParams` (TBDShared/RPCProtocol.swift)

Replace the existing `name: String?` field with three independent fields:

```swift
public struct WorktreeCreateParams: Codable, Sendable {
    public let repoID: UUID
    public let folder: String?
    public let branch: String?
    public let displayName: String?
    public let prompt: String?

    public init(
        repoID: UUID,
        folder: String? = nil,
        branch: String? = nil,
        displayName: String? = nil,
        prompt: String? = nil
    ) { ... }
}
```

The old `name` field was only ever sent as `nil` from the CLI, so removing it is non-breaking in practice. No migration needed.

## Lifecycle Changes

### `beginCreateWorktree()` (WorktreeLifecycle+Create.swift)

Signature changes from:
```swift
func beginCreateWorktree(repoID: UUID, name: String? = nil, skipClaude: Bool = false)
```
to:
```swift
func beginCreateWorktree(repoID: UUID, folder: String? = nil, branch: String? = nil, displayName: String? = nil, skipClaude: Bool = false)
```

Auto-generation logic:
1. `folder`: if nil, call `NameGenerator.generate()` (current behavior)
2. `branch`: if nil, default to `tbd/<folder>`
3. `displayName`: if nil, default to `folder`

The `createWorktree()` convenience wrapper gets the same parameter additions.

### `attemptWorktreeAdd()` (WorktreeLifecycle+Create.swift)

Collision retry behavior depends on which values are user-specified vs auto-generated:

| Collision type | `--folder` | `--branch` | Behavior |
|---------------|------------|------------|----------|
| Branch exists | auto | auto | Retry with new auto-generated folder + branch (current behavior) |
| Branch exists | user | auto | Fail — user chose the folder, can't silently change it |
| Branch exists | auto | user | Fail — user's branch already exists in git |
| Branch exists | user | user | Fail — both are user-specified |
| Folder exists | auto | auto | Retry with new auto-generated folder + branch |
| Folder exists | user | any | Fail — user chose the folder |
| Folder exists | auto | user | Retry with new auto-generated folder, keep user's branch |

## DB Layer Changes

### `WorktreeStore.create()` (WorktreeStore.swift)

Add `displayName: String? = nil` parameter. Falls back to `name` when nil (preserving current `displayName: name` behavior).

## RPC Router Changes

### `handleWorktreeCreate()` (RPCRouter+WorktreeHandlers.swift)

Pass the new fields through from params to lifecycle:
```swift
let pending = try await lifecycle.beginCreateWorktree(
    repoID: params.repoID,
    folder: params.folder,
    branch: params.branch,
    displayName: params.displayName
)
```

## App-Side Changes

### `DaemonClient.swift`

`createWorktree(repoID:name:)` becomes `createWorktree(repoID:folder:branch:displayName:)` with all three optional. This method is only called from `AppState+Worktrees.swift` which currently always passes `nil` for `name`, so the app-side UI button continues to auto-generate.

### Existing Tests

`Tests/TBDSharedTests/ModelsTests.swift` creates a `WorktreeCreateParams(repoID:)` which will need updating for the renamed field. The existing `WorktreeLifecycleTests` all use `createWorktree(repoID:skipClaude:)` without a `name:` — these continue to work unchanged since the new parameters default to `nil`.

## Scope

- CLI flags on `worktree create`: `--folder`, `--branch`, `--name`, `--prompt-file`
- CLI flag on `terminal create`: `--prompt-file`
- Shared `resolvePrompt()` helper for `--prompt`/`--prompt-file` mutual exclusion
- CLI validation for `--folder`
- `WorktreeCreateParams` protocol update
- `beginCreateWorktree()` / `createWorktree()` parameter changes
- `WorktreeStore.create()` displayName parameter
- RPC router passthrough
- Collision retry behavior change (fail instead of retry when user-specified)
- `SystemPromptBuilder.builtInTBDContext` update with spawn guidance and `--prompt-file -` example

## Out of Scope

- Renaming existing worktrees' folder/branch after creation
- Changing the `Worktree` model or DB schema (existing `name`, `displayName`, `branch` columns already support this)
- Slugification/sanitization of `--folder` input (validate and reject, don't silently transform)
