# Worktree PR Status Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a colored PR-state icon on each worktree sidebar row, polled every 30s and refreshed immediately on selection, using a single `gh api graphql` call to GitHub.

**Architecture:** A new `PRStatusManager` actor in the daemon fetches the authenticated user's 100 most recent PRs via `gh api graphql viewer.pullRequests`, matches them to worktrees by branch name, and caches results in memory. Two new RPC methods (`pr.list`, `pr.refresh`) expose the cache to the app. The app polls `pr.list` every 30s and calls `pr.refresh` immediately when a worktree is selected.

**Tech Stack:** Swift 6, Swift Testing framework, GRDB (existing), `gh` CLI (external dependency), SwiftUI SF Symbols

---

## File Map

**Create:**
- `Sources/TBDDaemon/PR/PRStatusManager.swift` — actor: `gh` invocation, JSON parsing, branch→worktree matching, in-memory cache

**Modify:**
- `Sources/TBDShared/Models.swift` — add `PRMergeableState` enum and `PRStatus` struct
- `Sources/TBDShared/RPCProtocol.swift` — add `pr.list` / `pr.refresh` method constants and param/result structs
- `Sources/TBDDaemon/Server/RPCRouter.swift` — inject `PRStatusManager`, add `pr.list` and `pr.refresh` cases and handlers
- `Sources/TBDDaemon/Daemon.swift` — instantiate `PRStatusManager`, pass to `RPCRouter`
- `Sources/TBDApp/DaemonClient.swift` — add `listPRStatuses()` and `refreshPRStatus(worktreeID:)`
- `Sources/TBDApp/AppState.swift` — add `prStatuses` published property, `refreshPRStatuses()`, `refreshPRStatus(worktreeID:)`, polling hook, on-select hook
- `Sources/TBDApp/Sidebar/WorktreeRowView.swift` — add PR icon computed properties and render in HStack
- `Sources/TBDApp/ContentView.swift` — trigger `refreshPRStatus` on worktree selection

**Test:**
- `Tests/TBDDaemonTests/PRStatusManagerTests.swift` — new test file
- `Tests/TBDDaemonTests/RPCRouterTests.swift` — add `pr.list` and `pr.refresh` test cases

---

### Task 1: Data model — `PRMergeableState` and `PRStatus`

**Files:**
- Modify: `Sources/TBDShared/Models.swift`

- [ ] **Step 1: Add the types at the end of `Models.swift`**

```swift
public enum PRMergeableState: String, Codable, Sendable {
    case open        // PR exists but not ready to merge
    case mergeable   // GitHub considers it clean (checks + reviews satisfied)
    case merged      // PR was merged
    case closed      // PR was closed without merging
}

public struct PRStatus: Codable, Sendable, Equatable {
    public let number: Int
    public let url: String
    public let state: PRMergeableState

    public init(number: Int, url: String, state: PRMergeableState) {
        self.number = number
        self.url = url
        self.state = state
    }
}
```

- [ ] **Step 2: Build to verify no errors**

```bash
swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDShared/Models.swift
git commit -m "feat: add PRMergeableState and PRStatus models"
```

---

### Task 2: RPC protocol — method constants and param/result structs

**Files:**
- Modify: `Sources/TBDShared/RPCProtocol.swift`

- [ ] **Step 1: Add method constants to `RPCMethod` enum (after `notificationsMarkRead`)**

```swift
public static let prList    = "pr.list"
public static let prRefresh = "pr.refresh"
```

- [ ] **Step 2: Add param/result structs (after `NotificationsMarkReadParams`)**

```swift
public struct PRListResult: Codable, Sendable {
    public let statuses: [UUID: PRStatus]
    public init(statuses: [UUID: PRStatus]) { self.statuses = statuses }
}

public struct PRRefreshParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

// PRRefreshResult wraps an optional PRStatus.
// nil means no PR found for this worktree's branch.
public struct PRRefreshResult: Codable, Sendable {
    public let status: PRStatus?
    public init(status: PRStatus?) { self.status = status }
}
```

- [ ] **Step 3: Build to verify**

```bash
swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDShared/RPCProtocol.swift
git commit -m "feat: add pr.list and pr.refresh RPC protocol types"
```

---

### Task 3: `PRStatusManager` actor

**Files:**
- Create: `Sources/TBDDaemon/PR/PRStatusManager.swift`

This is the core: it shells out to `gh`, parses the GraphQL JSON, maps GitHub states to `PRMergeableState`, and maintains the cache.

- [ ] **Step 1: Write failing tests first**

Create `Tests/TBDDaemonTests/PRStatusManagerTests.swift`:

```swift
import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("PRStatusManager Tests")
struct PRStatusManagerTests {

    // MARK: - State mapping

    @Test("maps OPEN + CLEAN to .mergeable")
    func mapsMergeableState() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeStateStatus: "CLEAN")
        #expect(status == .mergeable)
    }

    @Test("maps OPEN + BLOCKED to .open")
    func mapsOpenBlocked() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeStateStatus: "BLOCKED")
        #expect(status == .open)
    }

    @Test("maps OPEN + DIRTY to .open")
    func mapsOpenDirty() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeStateStatus: "DIRTY")
        #expect(status == .open)
    }

    @Test("maps MERGED to .merged")
    func mapsMerged() {
        let status = PRStatusManager.mapState(ghState: "MERGED", mergeStateStatus: "UNKNOWN")
        #expect(status == .merged)
    }

    @Test("maps CLOSED to .closed")
    func mapsClosed() {
        let status = PRStatusManager.mapState(ghState: "CLOSED", mergeStateStatus: "BLOCKED")
        #expect(status == .closed)
    }

    // MARK: - JSON parsing

    @Test("parseGraphQLResponse extracts matching branches")
    func parsesResponse() throws {
        let json = """
        {
          "data": {
            "viewer": {
              "pullRequests": {
                "nodes": [
                  {
                    "number": 42,
                    "url": "https://github.com/owner/repo/pull/42",
                    "state": "OPEN",
                    "mergeStateStatus": "CLEAN",
                    "headRefName": "tbd/cool-feature",
                    "repository": { "nameWithOwner": "owner/repo" }
                  },
                  {
                    "number": 7,
                    "url": "https://github.com/owner/repo/pull/7",
                    "state": "MERGED",
                    "mergeStateStatus": "UNKNOWN",
                    "headRefName": "tbd/old-feature",
                    "repository": { "nameWithOwner": "owner/repo" }
                  },
                  {
                    "number": 99,
                    "url": "https://github.com/owner/repo/pull/99",
                    "state": "OPEN",
                    "mergeStateStatus": "CLEAN",
                    "headRefName": "feature/not-tbd",
                    "repository": { "nameWithOwner": "owner/repo" }
                  }
                ]
              }
            }
          }
        }
        """.data(using: .utf8)!

        let nodes = try PRStatusManager.parsePRNodes(from: json)
        // Only tbd/ branches
        #expect(nodes.count == 2)
        #expect(nodes[0].headRefName == "tbd/cool-feature")
        #expect(nodes[0].state == "OPEN")
        #expect(nodes[0].mergeStateStatus == "CLEAN")
        #expect(nodes[1].headRefName == "tbd/old-feature")
    }

    @Test("allStatuses reflects cache after manual seed")
    func cacheRoundTrip() async {
        let manager = PRStatusManager()
        let id = UUID()
        let status = PRStatus(number: 1, url: "https://github.com/o/r/pull/1", state: .mergeable)
        await manager.seedForTesting(worktreeID: id, status: status)
        let all = await manager.allStatuses()
        #expect(all[id] == status)
    }

    @Test("invalidate removes entry from cache")
    func invalidate() async {
        let manager = PRStatusManager()
        let id = UUID()
        let status = PRStatus(number: 2, url: "https://github.com/o/r/pull/2", state: .open)
        await manager.seedForTesting(worktreeID: id, status: status)
        await manager.invalidate(worktreeID: id)
        let all = await manager.allStatuses()
        #expect(all[id] == nil)
    }
}
```

- [ ] **Step 2: Run tests — expect compile failure (type not defined yet)**

```bash
swift test --filter PRStatusManagerTests 2>&1 | tail -20
```
Expected: compiler error about missing `PRStatusManager`

- [ ] **Step 3: Create `Sources/TBDDaemon/PR/PRStatusManager.swift`**

```swift
import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "PRStatusManager")

/// In-memory cache of GitHub PR status per worktree.
/// Fetches via `gh api graphql` — one call per `fetchAll`, one `gh pr view` per `refresh`.
public actor PRStatusManager {

    private var cache: [UUID: PRStatus] = [:]

    public init() {}

    // MARK: - Public interface

    public func allStatuses() -> [UUID: PRStatus] { cache }

    public func invalidate(worktreeID: UUID) { cache.removeValue(forKey: worktreeID) }

    /// Fetch all viewer PRs in one GraphQL call and update cache for all known worktrees.
    /// worktrees: list of (id, branch, repoPath) for active non-main worktrees.
    public func fetchAll(worktrees: [(id: UUID, branch: String, repoPath: String)]) async {
        guard !worktrees.isEmpty else { return }
        let repoPath = worktrees[0].repoPath

        guard let jsonData = await runGHGraphQL(repoPath: repoPath) else { return }

        guard let nodes = try? Self.parsePRNodes(from: jsonData) else {
            logger.warning("Failed to parse GraphQL response")
            return
        }

        // Build branch → PRNode lookup
        var byBranch: [String: PRNode] = [:]
        for node in nodes {
            byBranch[node.headRefName] = node
        }

        // Update cache — clear entries for worktrees with no matching PR
        for wt in worktrees {
            if let node = byBranch[wt.branch] {
                cache[wt.id] = PRStatus(
                    number: node.number,
                    url: node.url,
                    state: Self.mapState(ghState: node.state, mergeStateStatus: node.mergeStateStatus)
                )
            } else {
                cache.removeValue(forKey: wt.id)
            }
        }
    }

    /// Refresh a single worktree using `gh pr view`. Used for on-select refresh.
    public func refresh(worktreeID: UUID, branch: String, repoPath: String) async -> PRStatus? {
        let args = ["pr", "view", branch,
                    "--json", "number,url,state,mergeStateStatus",
                    "-R", "."]
        guard let output = await runGH(args: args, repoPath: repoPath),
              let data = output.data(using: .utf8),
              let obj = try? JSONDecoder().decode(GHPRViewResult.self, from: data) else {
            // gh exited non-zero or parse failed — leave cache unchanged
            return cache[worktreeID]
        }

        let status = PRStatus(
            number: obj.number,
            url: obj.url,
            state: Self.mapState(ghState: obj.state, mergeStateStatus: obj.mergeStateStatus)
        )
        cache[worktreeID] = status
        return status
    }

    /// For tests only: seed a cache entry directly.
    public func seedForTesting(worktreeID: UUID, status: PRStatus) {
        cache[worktreeID] = status
    }

    // MARK: - State mapping (internal but static for testability)

    public static func mapState(ghState: String, mergeStateStatus: String) -> PRMergeableState {
        switch ghState {
        case "MERGED": return .merged
        case "CLOSED": return .closed
        default:       return mergeStateStatus == "CLEAN" ? .mergeable : .open
        }
    }

    // MARK: - JSON parsing (internal but static for testability)

    public struct PRNode: Sendable {
        public let number: Int
        public let url: String
        public let state: String
        public let mergeStateStatus: String
        public let headRefName: String
    }

    public static func parsePRNodes(from data: Data) throws -> [PRNode] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let viewer = dataObj["viewer"] as? [String: Any],
              let prs = viewer["pullRequests"] as? [String: Any],
              let nodes = prs["nodes"] as? [[String: Any]] else {
            throw PRStatusError.invalidJSON
        }

        return nodes.compactMap { node -> PRNode? in
            guard let number = node["number"] as? Int,
                  let url = node["url"] as? String,
                  let state = node["state"] as? String,
                  let mergeStateStatus = node["mergeStateStatus"] as? String,
                  let headRefName = node["headRefName"] as? String,
                  headRefName.hasPrefix("tbd/") else { return nil }
            return PRNode(number: number, url: url, state: state,
                          mergeStateStatus: mergeStateStatus, headRefName: headRefName)
        }
    }

    // MARK: - Shell helpers

    private func runGHGraphQL(repoPath: String) async -> Data? {
        let query = """
        {
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
        """
        let args = ["api", "graphql", "-f", "query=\(query)"]
        guard let output = await runGH(args: args, repoPath: repoPath) else { return nil }
        return output.data(using: .utf8)
    }

    private func runGH(args: [String], repoPath: String) async -> String? {
        guard let ghPath = findGH() else {
            logger.debug("gh CLI not found in PATH")
            return nil
        }

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ghPath)
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: repoPath)

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { p in
                if p.terminationStatus != 0 {
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let errStr = String(data: errData, encoding: .utf8) ?? ""
                    logger.debug("gh exited \(p.terminationStatus): \(errStr)")
                    continuation.resume(returning: nil)
                    return
                }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }

            do {
                try process.run()
            } catch {
                logger.debug("Failed to launch gh: \(error)")
                continuation.resume(returning: nil)
            }
        }
    }

    private func findGH() -> String? {
        let candidates = ["/usr/local/bin/gh", "/opt/homebrew/bin/gh", "/usr/bin/gh"]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        // Fall back to PATH search
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let full = "\(dir)/gh"
                if FileManager.default.isExecutableFile(atPath: full) { return full }
            }
        }
        return nil
    }
}

// MARK: - Supporting types

private struct GHPRViewResult: Codable {
    let number: Int
    let url: String
    let state: String
    let mergeStateStatus: String
}

enum PRStatusError: Error {
    case invalidJSON
}
```

- [ ] **Step 4: Run the tests — expect them to pass**

```bash
swift test --filter PRStatusManagerTests 2>&1 | tail -20
```
Expected: all 7 tests pass

- [ ] **Step 5: Build full project**

```bash
swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDDaemon/PR/PRStatusManager.swift Tests/TBDDaemonTests/PRStatusManagerTests.swift
git commit -m "feat: add PRStatusManager actor with gh graphql fetching"
```

---

### Task 4: Wire `PRStatusManager` into `RPCRouter` and `Daemon`

**Files:**
- Modify: `Sources/TBDDaemon/Server/RPCRouter.swift`
- Modify: `Sources/TBDDaemon/Daemon.swift`

- [ ] **Step 1: Write failing RPC tests**

Add to `Tests/TBDDaemonTests/RPCRouterTests.swift`, after the existing notification tests:

```swift
// MARK: - PR Status Tests

@Test("pr.list returns empty result when no PRs cached")
func prListEmpty() async throws {
    let request = RPCRequest(method: RPCMethod.prList)
    let response = await router.handle(request)

    #expect(response.success)
    let result = try response.decodeResult(PRListResult.self)
    #expect(result.statuses.isEmpty)
}

@Test("pr.refresh returns nil for unknown worktree (no gh available in test)")
func prRefreshUnknown() async throws {
    let request = try RPCRequest(
        method: RPCMethod.prRefresh,
        params: PRRefreshParams(worktreeID: UUID())
    )
    let response = await router.handle(request)
    // Should succeed (gracefully returns nil status)
    #expect(response.success)
    let result = try response.decodeResult(PRRefreshResult.self)
    #expect(result.status == nil)
}
```

- [ ] **Step 2: Run — expect failure (method not handled)**

```bash
swift test --filter "RPCRouterTests/prList" 2>&1 | tail -10
```
Expected: `error: Unknown method: pr.list`

- [ ] **Step 3: Add `prManager` property to `RPCRouter`**

In `Sources/TBDDaemon/Server/RPCRouter.swift`, add to the stored properties and `init`:

```swift
// Add property alongside existing ones:
public let prManager: PRStatusManager

// Update init signature (add after subscriptions parameter):
prManager: PRStatusManager = PRStatusManager()

// Add to init body:
self.prManager = prManager
```

- [ ] **Step 4: Add cases to the `handle` switch**

In the `handle(_ request:)` switch, add after `notificationsMarkRead`:

```swift
case RPCMethod.prList:
    return try await handlePRList()
case RPCMethod.prRefresh:
    return try await handlePRRefresh(request.paramsData)
```

- [ ] **Step 5: Add handler methods**

Add a new `// MARK: - PR Status` section at the bottom of `RPCRouter.swift`, before the closing brace:

```swift
// MARK: - PR Status

private func handlePRList() async throws -> RPCResponse {
    let statuses = await prManager.allStatuses()
    return try RPCResponse(result: PRListResult(statuses: statuses))
}

private func handlePRRefresh(_ paramsData: Data) async throws -> RPCResponse {
    let params = try decoder.decode(PRRefreshParams.self, from: paramsData)

    // Look up worktree and repo to get branch and repoPath
    guard let wt = try await db.worktrees.get(id: params.worktreeID),
          let repo = try await db.repos.get(id: wt.repoID) else {
        return try RPCResponse(result: PRRefreshResult(status: nil))
    }

    let status = await prManager.refresh(
        worktreeID: wt.id,
        branch: wt.branch,
        repoPath: repo.path
    )
    return try RPCResponse(result: PRRefreshResult(status: status))
}
```

- [ ] **Step 6: Run the new tests**

```bash
swift test --filter "RPCRouterTests/prList" 2>&1 | tail -10
swift test --filter "RPCRouterTests/prRefreshUnknown" 2>&1 | tail -10
```
Expected: both pass

- [ ] **Step 7: Wire `PRStatusManager` into `Daemon.swift`**

In `Daemon.swift`, after `let lifecycle = ...`, add:

```swift
let prManager = PRStatusManager()
```

Update the `RPCRouter` init to pass `prManager`:

```swift
let rpcRouter = RPCRouter(
    db: database,
    lifecycle: lifecycle,
    tmux: tmux,
    git: git,
    startTime: startTime,
    subscriptions: subs,
    prManager: prManager
)
```

- [ ] **Step 8: Build full project**

```bash
swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 9: Run all daemon tests**

```bash
swift test 2>&1 | tail -20
```
Expected: all existing tests pass, new PR tests pass (git signing failures are pre-existing and expected)

- [ ] **Step 10: Commit**

```bash
git add Sources/TBDDaemon/Server/RPCRouter.swift Sources/TBDDaemon/Daemon.swift Tests/TBDDaemonTests/RPCRouterTests.swift
git commit -m "feat: wire PRStatusManager into RPCRouter with pr.list and pr.refresh handlers"
```

---

### Task 5: App — `DaemonClient` methods

**Files:**
- Modify: `Sources/TBDApp/DaemonClient.swift`

- [ ] **Step 1: Add two methods after `markNotificationsRead`**

```swift
/// Fetch all cached PR statuses from the daemon.
func listPRStatuses() throws -> [UUID: PRStatus] {
    let result = try callNoParams(method: RPCMethod.prList, resultType: PRListResult.self)
    return result.statuses
}

/// Trigger an immediate PR status refresh for one worktree.
/// Returns nil if no PR exists for the worktree's branch.
func refreshPRStatus(worktreeID: UUID) throws -> PRStatus? {
    let result = try call(
        method: RPCMethod.prRefresh,
        params: PRRefreshParams(worktreeID: worktreeID),
        resultType: PRRefreshResult.self
    )
    return result.status
}
```

- [ ] **Step 2: Build to verify**

```bash
swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/DaemonClient.swift
git commit -m "feat: add listPRStatuses and refreshPRStatus to DaemonClient"
```

---

### Task 6: App — `AppState` polling and on-select refresh

**Files:**
- Modify: `Sources/TBDApp/AppState.swift`
- Modify: `Sources/TBDApp/ContentView.swift`

- [ ] **Step 1: Add `prStatuses` published property and `pollCycle` counter to `AppState`**

After the `@Published var pendingWorktreeIDs` line, add:

```swift
@Published var prStatuses: [UUID: PRStatus] = [:]
```

After the `private var pollTimer: Timer?` line, add:

```swift
private var pollCycle = 0
```

- [ ] **Step 2: Add `refreshPRStatuses()` and `refreshPRStatus(worktreeID:)` methods**

Add after `refreshNotifications()`:

```swift
/// Poll all cached PR statuses from the daemon (background, every ~30s).
func refreshPRStatuses() async {
    do {
        let fetched = try await daemonClient.listPRStatuses()
        // Only update if changed to avoid unnecessary SwiftUI redraws
        if fetched != prStatuses {
            prStatuses = fetched
        }
    } catch {
        logger.error("Failed to list PR statuses: \(error)")
        handleConnectionError(error)
    }
}

/// Trigger an immediate PR refresh for one worktree (on-select).
func refreshPRStatus(worktreeID: UUID) async {
    do {
        let status = try await daemonClient.refreshPRStatus(worktreeID: worktreeID)
        if status != prStatuses[worktreeID] {
            prStatuses[worktreeID] = status
        }
    } catch {
        logger.error("Failed to refresh PR status for \(worktreeID): \(error)")
        handleConnectionError(error)
    }
}
```

- [ ] **Step 3: Add PR polling to the poll timer**

In `startPolling()`, the timer body currently calls only `await self.refreshAll()`. Replace it so it also increments `pollCycle` and polls PR statuses every 15 ticks (~30s):

```swift
// Replace the single refreshAll() call inside the timer closure with:
await self.refreshAll()
self.pollCycle += 1
if self.pollCycle % 15 == 0 {
    await self.refreshPRStatuses()
}
```

The full timer closure after this change (for reference — only the lines after `if !self.isConnected { return }` change):

```swift
await self.refreshAll()
self.pollCycle += 1
if self.pollCycle % 15 == 0 {
    await self.refreshPRStatuses()
}
```

- [ ] **Step 4: Add on-select refresh in `ContentView.swift`**

The existing `onChange(of: appState.selectedWorktreeIDs)` handler only calls `markSelectedWorktreesAsRead`. Extend it to also refresh PR status for newly selected worktrees:

```swift
.onChange(of: appState.selectedWorktreeIDs) { oldSelection, newSelection in
    markSelectedWorktreesAsRead(newSelection)
    let newlySelected = newSelection.subtracting(oldSelection)
    for worktreeID in newlySelected {
        Task { await appState.refreshPRStatus(worktreeID: worktreeID) }
    }
}
```

Note: the existing handler signature is `{ _, newSelection in` — update it to `{ oldSelection, newSelection in` to capture the old value.

- [ ] **Step 5: Build to verify**

```bash
swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDApp/AppState.swift Sources/TBDApp/ContentView.swift
git commit -m "feat: poll PR statuses in AppState, refresh on worktree selection"
```

---

### Task 7: UI — PR icon in `WorktreeRowView`

**Files:**
- Modify: `Sources/TBDApp/Sidebar/WorktreeRowView.swift`

- [ ] **Step 1: Add PR icon computed properties**

After the `gitStatusColor` computed property, add:

```swift
private var prIcon: String? {
    guard !isMain, let status = appState.prStatuses[worktree.id] else { return nil }
    switch status.state {
    case .open:      return "arrow.triangle.pull"
    case .mergeable: return "arrow.triangle.pull"
    case .merged:    return "checkmark.circle.fill"
    case .closed:    return "xmark.circle.fill"
    }
}

private var prIconColor: Color {
    guard let status = appState.prStatuses[worktree.id] else { return .secondary }
    switch status.state {
    case .open:      return .secondary
    case .mergeable: return .green
    case .merged:    return .purple
    case .closed:    return .red
    }
}
```

- [ ] **Step 2: Render the icon in the `HStack`**

After the `gitStatusIcon` block (lines 75–79 in the current file), add:

```swift
if let icon = prIcon {
    Image(systemName: icon)
        .font(.caption2)
        .foregroundStyle(prIconColor)
}
```

- [ ] **Step 3: Build to verify**

```bash
swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 4: Run full test suite**

```bash
swift test 2>&1 | tail -20
```
Expected: all non-git-signing tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDApp/Sidebar/WorktreeRowView.swift
git commit -m "feat: show PR status icon in worktree sidebar row"
```

---

### Task 8: Manual smoke test

- [ ] **Step 1: Restart daemon and app**

```bash
scripts/restart.sh
```

- [ ] **Step 2: Verify icons appear**

Open the app. Within 30s of launch, worktrees with open PRs should show a gray/green `arrow.triangle.pull` icon. Merged worktrees should show a purple `checkmark.circle.fill`.

- [ ] **Step 3: Verify on-select refresh**

Click a worktree that has a PR — the icon should update immediately (the `pr.refresh` call returns faster than waiting 30s).

- [ ] **Step 4: Verify `gh` not installed gracefully**

Find where `gh` lives first, then temporarily rename it:

```bash
GH=$(which gh)
sudo mv "$GH" "${GH}.bak"
```

Restart daemon. Icons should disappear (cache cleared on restart, no new data fetched). No errors surfaced in the UI. Restore:

```bash
sudo mv "${GH}.bak" "$GH"
```

- [ ] **Step 5: Check debug log for any unexpected errors**

```bash
tail -50 /tmp/tbdd.log
```

Expected: no errors, only normal startup messages.
