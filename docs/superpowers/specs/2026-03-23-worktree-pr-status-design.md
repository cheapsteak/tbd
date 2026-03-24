# Worktree PR Status Display

**Date:** 2026-03-23
**Branch:** `tbd/worktree-pr-status`
**Status:** Approved

## Problem

Worktree sidebar items have no indication of whether a PR exists for the branch, or what its status is. Users must switch to a browser or run `gh` manually to check.

## Goal

Show a small colored icon on each worktree row indicating the state of its associated GitHub PR, updated automatically in the background.

---

## Data Model

New types added to `Sources/TBDShared/Models.swift`:

```swift
public enum PRMergeableState: String, Codable, Sendable {
    case open        // PR exists but not ready to merge
    case mergeable   // GitHub considers it clean (checks + reviews satisfied)
    case merged      // PR was merged
    case closed      // PR was closed without merging
}

public struct PRStatus: Codable, Sendable {
    public let number: Int
    public let url: String
    public let state: PRMergeableState
}
```

`mergeable` maps to GitHub's `mergeStateStatus == "CLEAN"`. All other open states (`BLOCKED`, `DIRTY`, `BEHIND`, `UNSTABLE`, `UNKNOWN`, `DRAFT`) map to `open`. GitHub is the sole source of truth for mergeability — no local CI/review logic needed.

No new database table. PR status is ephemeral and cheap to re-fetch.

---

## Daemon: PRStatusManager

New actor: `Sources/TBDDaemon/PR/PRStatusManager.swift`

```swift
actor PRStatusManager {
    private var cache: [UUID: PRStatus] = [:]    // worktreeID → status

    func fetchAll(worktrees: [(id: UUID, branch: String, repoPath: String)]) async
    func refresh(worktreeID: UUID, branch: String, repoPath: String) async -> PRStatus?
    func invalidate(worktreeID: UUID)
    func allStatuses() -> [UUID: PRStatus]
}
```

### Fetching Strategy

A **single** `gh api graphql` call fetches the authenticated user's most recent 50 PRs across all repos:

```bash
gh api graphql -f query='
  query {
    viewer {
      pullRequests(first: 100, states: [OPEN, MERGED, CLOSED],
                   orderBy: {field: CREATED_AT, direction: DESC}) {
        nodes {
          number url state mergeStateStatus headRefName
          repository { nameWithOwner }
        }
      }
    }
  }
' --repo <any-repo-path>
```

The call is made from any known repo path (for `gh` to infer the host). The response is filtered client-side:

1. Keep only nodes where `headRefName` starts with `tbd/`
2. Match each node to a worktree by `headRefName` (exact match against `worktree.branch`)
3. Update cache for matched worktrees; remove cache entries for worktrees with no matching PR node

This approach requires no dynamic query building, no per-repo grouping, and no owner/slug parsing. One HTTP call covers all repos the user has worktrees in.

- If `gh` exits non-zero (not installed, not authenticated, network error): cache is left unchanged — stale is better than missing. Logged at debug level.
- `first: 100` is sufficient in practice: active TBD worktrees would appear in the user's most recent PRs. If a worktree's PR is not in the top 100, it is treated as having no PR.

**On-demand refresh** (`pr.refresh` for a single worktree): runs `gh pr view <branch> --json number,url,state,mergeStateStatus` from `repoPath` — a targeted single-PR lookup used when the user selects a worktree.

### State Mapping

| GitHub `state` | GitHub `mergeStateStatus` | `PRMergeableState` |
|---|---|---|
| `OPEN` | `CLEAN` | `.mergeable` |
| `OPEN` | anything else | `.open` |
| `MERGED` | — | `.merged` |
| `CLOSED` | — | `.closed` |

---

## RPC Protocol

Two new methods added to `Sources/TBDShared/RPCProtocol.swift`:

```swift
RPCMethod.prList    = "pr.list"     // no params → PRListResult
RPCMethod.prRefresh = "pr.refresh"  // PRRefreshParams → PRStatus?
```

```swift
public struct PRListResult: Codable, Sendable {
    public let statuses: [UUID: PRStatus]
}

public struct PRRefreshParams: Codable, Sendable {
    public let worktreeID: UUID
}
```

Handlers added to `RPCRouter`:
- `handlePRList()` — returns `PRStatusManager.allStatuses()`
- `handlePRRefresh(params)` — looks up the worktree and its repo from `db` to obtain `branch` and `repoPath`, then calls `PRStatusManager.refresh(worktreeID:branch:repoPath:)`, returns updated `PRStatus?`

`PRStatusManager` is injected into `RPCRouter` alongside existing dependencies.

---

## App: AppState

New published property:

```swift
@Published var prStatuses: [UUID: PRStatus] = [:]
```

**Background polling** — every 15th cycle (~30s at 2s interval):

```swift
if pollCycle % 15 == 0 {
    await refreshPRStatuses()
}
```

**On-select refresh** — in the `onChange(of: selectedWorktreeIDs)` handler (already exists in `ContentView`), trigger immediate refresh for newly selected worktree IDs:

```swift
for worktreeID in newlySelected {
    Task { await appState.refreshPRStatus(worktreeID: worktreeID) }
}
```

New methods:

```swift
func refreshPRStatuses() async          // polls pr.list
func refreshPRStatus(worktreeID: UUID)  // calls pr.refresh for one worktree
```

New DaemonClient methods:

```swift
func listPRStatuses() throws -> [UUID: PRStatus]
func refreshPRStatus(worktreeID: UUID) throws -> PRStatus?
```

---

## UI: WorktreeRowView

A small SF Symbols icon added to the leading `HStack`, between the notification dot and the display name. Only rendered when `appState.prStatuses[worktree.id] != nil`.

| State | SF Symbol | Color |
|---|---|---|
| `.open` | `arrow.triangle.pull` | `.secondary` |
| `.mergeable` | `arrow.triangle.pull` | `.green` |
| `.merged` | `checkmark.circle.fill` | `.purple` |
| `.closed` | `xmark.circle.fill` | `.red` |

Icon size: `.caption` to match the existing branch icon style.

No tooltip required for MVP — the color is sufficient for at-a-glance status.

---

## Error Handling

- `gh` not installed or not authenticated: `PRStatusManager` catches the non-zero exit, logs at debug level, leaves cache unchanged. No error surfaces to the user.
- GraphQL parse failure: log warning, leave cache unchanged.
- Daemon not running: standard `handleConnectionError` path in `AppState.refreshPRStatuses()`.

---

## Files to Create

- `Sources/TBDDaemon/PR/PRStatusManager.swift` — new actor

## Files to Modify

- `Sources/TBDShared/Models.swift` — add `PRMergeableState`, `PRStatus`
- `Sources/TBDShared/RPCProtocol.swift` — add `pr.list`, `pr.refresh` methods and structs
- `Sources/TBDDaemon/Server/RPCRouter.swift` — inject `PRStatusManager`, add handlers
- `Sources/TBDDaemon/Daemon.swift` — instantiate `PRStatusManager`, pass to router
- `Sources/TBDApp/DaemonClient.swift` — add `listPRStatuses()`, `refreshPRStatus()`
- `Sources/TBDApp/AppState.swift` — add `prStatuses`, polling, on-select refresh
- `Sources/TBDApp/Sidebar/WorktreeRowView.swift` — render PR icon
- `Sources/TBDApp/ContentView.swift` — trigger on-select refresh

## Out of Scope

- Tooltip with PR title or number
- Clicking the icon to open the PR in browser
- PR status for the main branch worktree
- Non-GitHub remotes (GitLab, Bitbucket)
- Persisting PR status across daemon restarts
