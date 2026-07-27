# Revive Conversation on a Fresh Branch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an archived-session action that creates a new worktree from the latest default branch, forks exactly the selected Claude conversation into it, and leaves the archived worktree unchanged.

**Architecture:** Add a typed RPC whose daemon handler delegates to a new lifecycle extension. The extension validates the archived source and transcript before creating anything, performs an uncached fetch, captures base provenance, and threads a `ConversationCarryover` through both ordinary-create terminal-spawn branches. The app calls the RPC through an injectable seam and renders a second archived-only transcript action while preserving the existing active and plain-revive behavior.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, GRDB, SwiftUI, tmux, git, Claude Code transcript JSONL.

## Global Constraints

- Use the approved design in `docs/specs/2026-07-27-revive-conversation-fresh-branch-design.md`; do not re-run brainstorming.
- Add no feature flag and no database migration.
- The archived worktree row must remain unchanged: status, branch, `archivedHeadSHA`, and `archivedClaudeSessions`.
- Validate that the selected transcript exists before inserting a worktree row or creating a worktree directory.
- Fetch the repository default branch directly with a 15-second timeout; on failure continue creation and return a visible non-error warning.
- Create through `beginCreateWorktree` and `completeCreateWorktree`, with no folder or branch override.
- Force the carried primary terminal to Claude and build it with `resumeID: sourceSessionID`, `forkSession: true`, the context prompt as `initialPrompt`, and `appendSystemPrompt: nil`.
- Thread the carryover through both the inline spawn branch and the `preSession` phase-3 branch, with a test for each.
- Seed the initial Notes tab through the create path; do not write it after `completeCreateWorktree` returns.
- Reuse the existing fork-session ID recapture behavior; any extracted delay takes `clock: any Clock<Duration> = ContinuousClock()` as its last initializer parameter.
- Add no `print()` under `Sources/`; use `os.Logger` with subsystem `com.tbd.daemon`, category `archive`, and explicit privacy on dynamic values.
- Add no terminal-screen scraping.
- Tests must not touch `~/tbd`; any test using `setenv("TBD_HOME", ...)` stays inside `TBDHomeSerialized`.
- The app warning is a non-error alert, and the fresh action must not mutate `revivingArchived`.
- Never use the banned repository terminology documented in `AGENTS.md`.

---

### Task 1: Shared RPC Contract and Git Provenance Primitive

**Files:**
- Modify: `Sources/TBDShared/RPCProtocol.swift`
- Modify: `Sources/TBDDaemon/Git/GitManager.swift`
- Create: `Tests/TBDSharedTests/WorktreeReviveConversationFreshCodingTests.swift`
- Create: `Tests/TBDDaemonTests/GitManagerCommitDateTests.swift`

**Interfaces:**
- Produces: `RPCMethod.worktreeReviveConversationFresh`
- Produces: `WorktreeReviveConversationFreshParams`
- Produces: `WorktreeReviveConversationFreshResult`
- Produces: `GitManager.commitDate(repoPath:ref:) async throws -> Date`

- [ ] **Step 1: Add failing round-trip tests for the RPC parameter and result types**

Create `Tests/TBDSharedTests/WorktreeReviveConversationFreshCodingTests.swift` with a fixed worktree UUID, session ID, terminal dimensions, and warning. Encode and decode both new values and assert every field, including a `nil` warning case:

```swift
import Foundation
import Testing
@testable import TBDShared

@Suite("Revive conversation fresh RPC coding")
struct WorktreeReviveConversationFreshCodingTests {
    @Test func paramsRoundTrip() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let value = WorktreeReviveConversationFreshParams(
            archivedWorktreeID: id,
            sessionID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            cols: 132,
            rows: 43
        )
        let decoded = try JSONDecoder().decode(
            WorktreeReviveConversationFreshParams.self,
            from: JSONEncoder().encode(value)
        )
        #expect(decoded.archivedWorktreeID == id)
        #expect(decoded.sessionID == value.sessionID)
        #expect(decoded.cols == 132)
        #expect(decoded.rows == 43)
    }

    @Test func resultRoundTripPreservesWarning() throws {
        let worktree = Worktree(
            repoID: UUID(), name: "brisk-elk", displayName: "stale-owl (revived)",
            branch: "tbd/brisk-elk", path: "/tmp/brisk-elk", tmuxServer: "tbd-test"
        )
        let value = WorktreeReviveConversationFreshResult(
            worktree: worktree,
            warning: "Fetch failed; using origin/main at def5678."
        )
        let decoded = try JSONDecoder().decode(
            WorktreeReviveConversationFreshResult.self,
            from: JSONEncoder().encode(value)
        )
        #expect(decoded.worktree == worktree)
        #expect(decoded.warning == value.warning)
    }
}
```

- [ ] **Step 2: Run the shared tests and verify they fail to compile**

Run:

```bash
swift test --filter WorktreeReviveConversationFreshCodingTests
```

Expected: compilation fails because the new RPC types do not exist.

- [ ] **Step 3: Add the RPC method and public Codable types**

In `Sources/TBDShared/RPCProtocol.swift`, add:

```swift
public static let worktreeReviveConversationFresh =
    "worktree.reviveConversationFresh"
```

Add the types beside `WorktreeReviveParams`:

```swift
public struct WorktreeReviveConversationFreshParams: Codable, Sendable {
    public let archivedWorktreeID: UUID
    public let sessionID: String
    public let cols: Int?
    public let rows: Int?

    public init(
        archivedWorktreeID: UUID,
        sessionID: String,
        cols: Int? = nil,
        rows: Int? = nil
    ) {
        self.archivedWorktreeID = archivedWorktreeID
        self.sessionID = sessionID
        self.cols = cols
        self.rows = rows
    }
}

public struct WorktreeReviveConversationFreshResult: Codable, Sendable {
    public let worktree: Worktree
    public let warning: String?

    public init(worktree: Worktree, warning: String?) {
        self.worktree = worktree
        self.warning = warning
    }
}
```

- [ ] **Step 4: Add a failing commit-date test**

Create `Tests/TBDDaemonTests/GitManagerCommitDateTests.swift`. Initialize a temporary git repo, configure its author, commit with `GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE` set to `2026-07-20T12:34:56Z`, then assert:

```swift
let date = try await GitManager().commitDate(repoPath: repo.path, ref: "HEAD")
#expect(date == ISO8601DateFormatter().date(from: "2026-07-20T12:34:56Z"))
```

- [ ] **Step 5: Run the commit-date test and verify it fails to compile**

Run:

```bash
swift test --filter GitManagerCommitDateTests
```

Expected: compilation fails because `commitDate(repoPath:ref:)` does not exist.

- [ ] **Step 6: Implement strict ISO-8601 commit-date parsing**

In `GitManager`, run `git show -s --format=%cI <ref>` through the existing process runner. Trim the output, parse it with an `ISO8601DateFormatter`, and throw `GitError` when the command returns an empty or unparsable value:

```swift
public func commitDate(repoPath: String, ref: String = "HEAD") async throws -> Date {
    let output = try await run(
        arguments: ["show", "-s", "--format=%cI", ref],
        at: repoPath
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let date = ISO8601DateFormatter().date(from: output) else {
        throw GitError(
            command: "git show -s --format=%cI \(ref)",
            exitCode: 0,
            stderr: "git returned an invalid commit date: \(output)"
        )
    }
    return date
}
```

- [ ] **Step 7: Run focused tests**

Run:

```bash
swift test --filter WorktreeReviveConversationFreshCodingTests
swift test --filter GitManagerCommitDateTests
```

Expected: both suites pass.

- [ ] **Step 8: Commit Task 1**

```bash
git add Sources/TBDShared/RPCProtocol.swift Sources/TBDDaemon/Git/GitManager.swift \
  Tests/TBDSharedTests/WorktreeReviveConversationFreshCodingTests.swift \
  Tests/TBDDaemonTests/GitManagerCommitDateTests.swift
git commit -m "feat: add fresh conversation revive contract"
```

---

### Task 2: Carry a Forked Conversation Through Both Create Branches

**Files:**
- Modify: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift`
- Modify: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+PreSession.swift`
- Create: `Sources/TBDDaemon/Claude/SessionRecaptureScheduler.swift`
- Modify: `Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift`
- Create: `Tests/TBDDaemonTests/WorktreeConversationCarryoverTests.swift`
- Create: `Tests/TBDDaemonTests/SessionRecaptureSchedulerTests.swift`

**Interfaces:**
- Produces: `ConversationCarryover(sourceSessionID:contextPrompt:notesSeed:)`
- Produces: optional `carryover: ConversationCarryover? = nil` on `completeCreateWorktree`, `runPreSessionPhase3`, and `spawnPrimaryTerminals`
- Produces: `SessionRecaptureScheduler.schedule(terminalID:paneID:server:)`
- Preserves: all ordinary-create call sites through defaulted parameters

- [ ] **Step 1: Write failing inline and preSession carryover tests**

Create the suite under `extension TBDHomeSerialized` so `isolateTBDHome()` is legal. Reuse `createTestRepo`, `makeTestRepo`, `makeLifecycle`, `installPreSessionHook`, `writeMarker`, and the dry-run tmux command recorder from `PreSessionTestSupport.swift`.

For both inline and preSession branches:

```swift
let carryover = ConversationCarryover(
    sourceSessionID: sourceSessionID,
    contextPrompt: "You have been moved to a fresh worktree. Re-read files before editing.",
    notesSeed: "# Revived conversation\n\nSource session: `\(sourceSessionID)`\n"
)
```

Assert after completion:

- exactly one primary Claude terminal exists;
- its command contains `--resume`, the source ID, and `--fork-session`;
- its command contains the context prompt;
- its provisional `claudeSessionID` equals the source ID;
- the source JSONL exists under the new path’s `TranscriptProjectDirSync.derivedProjectDir`;
- the Notes row content equals `notesSeed`;
- ordinary create with `carryover: nil` still follows the configured primary-agent preference and creates an empty Notes tab.

The preSession test must write the completion marker and await `phase3.value` before assertions.

- [ ] **Step 2: Run the carryover tests and verify they fail to compile**

Run:

```bash
swift test --filter WorktreeConversationCarryoverTests
```

Expected: compilation fails because `ConversationCarryover` and `carryover` parameters do not exist.

- [ ] **Step 3: Define and thread the carryover**

Add beside `WorktreeCreateCompletion`:

```swift
struct ConversationCarryover: Sendable {
    let sourceSessionID: String
    let contextPrompt: String
    let notesSeed: String
}
```

Add `carryover: ConversationCarryover? = nil` to the end of:

- `completeCreateWorktree`;
- `runPreSessionPhase3`;
- `spawnPrimaryTerminals`.

Pass it at the inline spawn call and into the detached preSession phase-3 call, then from phase 3 into `spawnPrimaryTerminals`.

- [ ] **Step 4: Force and build the carried Claude primary**

In `spawnPrimaryTerminals`:

```swift
let primaryTerminalKind: TerminalKind = carryover == nil
    ? resolvePrimaryTerminalKind(
        skipClaude: skipClaude,
        archivedClaudeSessions: archivedClaudeSessions,
        configuredPreference: config.primaryAgentPreference
    )
    : .claude
```

In the Claude branch, when carryover is present:

```swift
await TranscriptProjectDirSync.ensureSessionResumableDetached(
    sessionID: carryover.sourceSessionID,
    worktreePath: worktreePath,
    projectsRoot: claudeProjectsRoot(profileConfigDirPath: profileConfigDir.path),
    storedTranscriptPath: nil
)
primaryCommand = ClaudeSpawnCommandBuilder.build(
    resumeID: carryover.sourceSessionID,
    forkSession: true,
    appendSystemPrompt: nil,
    initialPrompt: carryover.contextPrompt,
    profileConfigDir: profileConfigDir.path,
    model: modelOverride
)
primarySessionID = carryover.sourceSessionID
```

Keep the existing ordinary-create and archived-session resume branches unchanged.

- [ ] **Step 5: Seed Notes in both create branches**

Change:

```swift
func createInitialNoteTab(worktreeID: UUID, seed: String? = nil) async
```

Create the Notes row, then call the existing file-backed `db.notes.update(id:title:content:)` only when `seed` is non-nil. Pass `carryover?.notesSeed` from both the inline call and the detached preSession call.

- [ ] **Step 6: Write failing scheduler tests with an injected clock**

Create `SessionRecaptureSchedulerTests.swift` using the repository clock test support. Insert a terminal with the source session ID, call `schedule`, advance the test clock by five seconds, and assert the detector result is persisted. Add the complementary branch where capture returns nil and the source ID stays unchanged.

- [ ] **Step 7: Extract the existing recapture timer**

Create `SessionRecaptureScheduler` with its clock last:

```swift
struct SessionRecaptureScheduler: Sendable {
    let db: TBDDatabase
    let tmux: TmuxManager
    let clock: any Clock<Duration>

    init(
        db: TBDDatabase,
        tmux: TmuxManager,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.db = db
        self.tmux = tmux
        self.clock = clock
    }

    func schedule(terminalID: UUID, paneID: String, server: String) {
        Task {
            guard (try? await clock.sleep(for: .seconds(5))) != nil else { return }
            let detector = ClaudeStateDetector(tmux: tmux)
            if let sessionID = await detector.captureSessionID(server: server, paneID: paneID) {
                try? await db.terminals.updateSessionID(id: terminalID, sessionID: sessionID)
            }
        }
    }
}
```

Replace the private router timer body with this helper. Invoke the same helper after a carried primary terminal is persisted. Do not add a second sleep implementation.

- [ ] **Step 8: Run focused daemon tests**

Run:

```bash
swift test --filter WorktreeConversationCarryoverTests
swift test --filter SessionRecaptureSchedulerTests
swift test --filter ClaudeSpawnCommandBuilderTests
swift test --filter NoteTabOnCreateTests
swift test --filter PreSessionHookTests
```

Expected: all pass.

- [ ] **Step 9: Commit Task 2**

```bash
git add Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift \
  Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+PreSession.swift \
  Sources/TBDDaemon/Claude/SessionRecaptureScheduler.swift \
  Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift \
  Tests/TBDDaemonTests/WorktreeConversationCarryoverTests.swift \
  Tests/TBDDaemonTests/SessionRecaptureSchedulerTests.swift
git commit -m "feat: carry conversations through worktree creation"
```

---

### Task 3: Implement the Fresh-Branch Lifecycle and RPC Handler

**Files:**
- Create: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+ReviveFresh.swift`
- Modify: `Sources/TBDDaemon/Server/RPCRouter.swift`
- Modify: `Sources/TBDDaemon/Server/RPCRouter+WorktreeHandlers.swift`
- Modify: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Recovery.swift`
- Create: `Tests/TBDDaemonTests/WorktreeReviveFreshTests.swift`

**Interfaces:**
- Consumes: `WorktreeReviveConversationFreshParams`, `WorktreeReviveConversationFreshResult`
- Consumes: `ConversationCarryover`
- Consumes: `GitManager.commitDate(repoPath:ref:)`
- Produces: `WorktreeLifecycle.reviveConversationOnFreshBranch(archivedWorktreeID:sessionID:cols:rows:date:)`
- Produces: `RPCRouter.handleWorktreeReviveConversationFresh(_:)`

- [ ] **Step 1: Write lifecycle rejection tests**

Under `TBDHomeSerialized`, add tests proving:

- an unknown or active worktree returns the existing explicit lifecycle error;
- a scratch archived row returns an explicit “fresh branch requires a repository” error;
- a missing transcript returns an explicit error;
- for missing transcript, the before/after worktree-row sets match and no new directory appears.

Call the lifecycle method with a fixed `date:` value so prompt and Notes dates are deterministic.

- [ ] **Step 2: Run rejection tests and verify they fail to compile**

Run:

```bash
swift test --filter WorktreeReviveFreshTests
```

Expected: compilation fails because the lifecycle method does not exist.

- [ ] **Step 3: Implement validation before creation**

In the new lifecycle extension:

```swift
guard let archived = try await db.worktrees.get(id: archivedWorktreeID) else {
    throw WorktreeLifecycleError.worktreeNotFound(archivedWorktreeID)
}
guard archived.status == .archived else {
    throw WorktreeLifecycleError.worktreeNotArchived(archivedWorktreeID)
}
guard let repoID = archived.repoID,
      let repo = try await db.repos.get(id: repoID) else {
    throw WorktreeLifecycleError.invalidOperation(
        "Cannot revive a conversation on a fresh branch without a repository."
    )
}
let projectsRoot = claudeProjectsRoot(profileConfigDirPath: nil)
guard TranscriptProjectDirSync.locateSessionTranscript(
    sessionID: sessionID,
    projectsRoot: projectsRoot
) != nil else {
    throw WorktreeLifecycleError.invalidOperation(
        "Cannot revive conversation: no transcript found for session \(sessionID)."
    )
}
```

No call to `beginCreateWorktree` may appear before these guards.

- [ ] **Step 4: Write success, fetch-warning, and provenance tests**

Use a real temporary repo and transcript fixture. Assert:

- successful fetch uses `origin/<default>` when it resolves;
- broken/missing origin still creates the worktree and returns a non-nil warning;
- warning names the selected base ref, abbreviated SHA, and commit date/age;
- new display name is `"<archived display name> (revived)"`;
- new branch is `tbd/<generated name>`;
- the context prompt names old branch/archive date, new branch, base ref/SHA, and tells the agent to re-read files;
- Notes exactly contain the approved provenance table;
- archived row equality before/after includes status, branch, `archivedHeadSHA`, and `archivedClaudeSessions`;
- only the selected session is carried;
- both ready and preSession-pending completions return the new row.

- [ ] **Step 5: Implement fetch, base resolution, and creation**

Use an injected data timestamp:

```swift
func reviveConversationOnFreshBranch(
    archivedWorktreeID: UUID,
    sessionID: String,
    cols: Int? = nil,
    rows: Int? = nil,
    date: Date = Date()
) async throws -> (completion: WorktreeCreateCompletion,
                   result: WorktreeReviveConversationFreshResult)
```

Perform:

```swift
var fetchWarning: Error?
do {
    try await git.fetch(
        repoPath: repo.path,
        branch: repo.defaultBranch,
        timeout: .seconds(15)
    )
} catch {
    fetchWarning = error
}

let remote = "origin/\(repo.defaultBranch)"
let baseRef = await git.refExists(repoPath: repo.path, ref: remote)
    ? remote
    : repo.defaultBranch
let baseSHA = try await git.headSHA(repoPath: repo.path, ref: baseRef)
let baseDate = try await git.commitDate(repoPath: repo.path, ref: baseRef)
```

Build the context prompt and Notes seed with one stable UTC date formatter. Call:

```swift
let pending = try await beginCreateWorktree(
    repoID: repo.id,
    displayName: "\(archived.displayName) (revived)"
)
let completion = try await completeCreateWorktree(
    worktreeID: pending.id,
    cols: cols,
    rows: rows,
    carryover: carryover
)
```

Reload the created row and return it with a warning only when fetch failed. The warning must state that creation succeeded but the selected base may be stale.

- [ ] **Step 6: Route, broadcast, and return the typed result**

Add the router switch case and handler. Serialize through `repoSerializer` using the source repository ID, as ordinary create does. For `.ready`, broadcast exactly one `.worktreeCreated`. For `.preSessionPending`, do not duplicate the lifecycle’s early create broadcast. Return `WorktreeReviveConversationFreshResult`.

- [ ] **Step 7: Add the accepted recovery warning**

In the ordinary `.creating` recovery path, log with category `archive` that an ephemeral conversation carryover cannot survive a daemon restart and the user can run the action again. Do not persist carryover data and do not reuse `archivedClaudeSessions`.

- [ ] **Step 8: Run focused daemon tests**

Run:

```bash
swift test --filter WorktreeReviveFreshTests
swift test --filter RPCRouterWorktreeCreateBroadcastTests
swift test --filter ArchivedReviveBranchRenameTests
swift test --filter TranscriptProjectDirSyncTests
```

Expected: all pass, including both create branches and exactly-once broadcast assertions.

- [ ] **Step 9: Commit Task 3**

```bash
git add Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+ReviveFresh.swift \
  Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Recovery.swift \
  Sources/TBDDaemon/Server/RPCRouter.swift \
  Sources/TBDDaemon/Server/RPCRouter+WorktreeHandlers.swift \
  Tests/TBDDaemonTests/WorktreeReviveFreshTests.swift
git commit -m "feat: revive conversations on fresh branches"
```

---

### Task 4: Add the App Client and State Action

**Files:**
- Modify: `Sources/TBDApp/DaemonClient.swift`
- Modify: `Sources/TBDApp/AppState.swift`
- Modify: `Sources/TBDApp/AppState+History.swift`
- Create: `Tests/TBDAppTests/ReviveConversationFreshAppStateTests.swift`

**Interfaces:**
- Produces: `DaemonClient.reviveConversationOnFreshBranch(worktreeID:sessionID:cols:rows:)`
- Produces: injectable `AppState.freshConversationReviver`
- Produces: `AppState.reviveConversationOnFreshBranch(worktreeID:sessionId:)`

- [ ] **Step 1: Add failing AppState tests through an injected closure**

Create an isolated `UserDefaults(suiteName:)` per test and remove its persistent domain at teardown. Seed an archived snapshot and a sentinel `revivingArchived` value. Inject a closure returning:

```swift
WorktreeReviveConversationFreshResult(
    worktree: freshWorktree,
    warning: "Created from cached origin/main at def5678."
)
```

After invoking the AppState action, assert:

- `revivingArchived` is byte-for-byte unchanged;
- the new worktree, not the archived source, is selected;
- `alertMessage` equals the warning;
- `alertIsError == false`;
- dimensions from `mainAreaTerminalSize()` and the selected session ID reached the closure.

Add a no-warning success test and an error test that shows an error alert without changing `revivingArchived`.

- [ ] **Step 2: Run the AppState tests and verify they fail to compile**

Run:

```bash
swift test --filter ReviveConversationFreshAppStateTests
```

Expected: compilation fails because the seam and action do not exist.

- [ ] **Step 3: Add the typed DaemonClient method**

Implement:

```swift
func reviveConversationOnFreshBranch(
    worktreeID: UUID,
    sessionID: String,
    cols: Int? = nil,
    rows: Int? = nil
) async throws -> WorktreeReviveConversationFreshResult {
    try await callAsync(
        method: RPCMethod.worktreeReviveConversationFresh,
        params: WorktreeReviveConversationFreshParams(
            archivedWorktreeID: worktreeID,
            sessionID: sessionID,
            cols: cols,
            rows: rows
        ),
        resultType: WorktreeReviveConversationFreshResult.self
    )
}
```

- [ ] **Step 4: Add the injectable AppState seam**

Beside existing daemon-client closures:

```swift
lazy var freshConversationReviver:
    @MainActor (UUID, String, Int?, Int?) async throws
        -> WorktreeReviveConversationFreshResult = {
            [daemonClient] worktreeID, sessionID, cols, rows in
            try await daemonClient.reviveConversationOnFreshBranch(
                worktreeID: worktreeID,
                sessionID: sessionID,
                cols: cols,
                rows: rows
            )
        }
```

- [ ] **Step 5: Implement the AppState action**

The method must not read or write `revivingArchived`. It obtains terminal size, calls the seam, refreshes the active list if necessary, navigates to the returned worktree with the existing `navigateToActiveWorktree`, and shows `result.warning` with `isError: false`. On failure, show `"Couldn't revive conversation on a fresh branch: …"` as an error and call `handleConnectionError`.

- [ ] **Step 6: Run focused app tests**

Run:

```bash
swift test --filter ReviveConversationFreshAppStateTests
swift test --filter ReviveStateGatingTests
```

Expected: all pass.

- [ ] **Step 7: Commit Task 4**

```bash
git add Sources/TBDApp/DaemonClient.swift Sources/TBDApp/AppState.swift \
  Sources/TBDApp/AppState+History.swift \
  Tests/TBDAppTests/ReviveConversationFreshAppStateTests.swift
git commit -m "feat: add fresh conversation revive action"
```

---

### Task 5: Render the Archived-Only Fresh-Branch Button

**Files:**
- Modify: `Sources/TBDApp/Panes/HistoryPaneView.swift`
- Create: `Tests/TBDAppTests/HistoryPaneActionTests.swift`

**Interfaces:**
- Consumes: `AppState.reviveConversationOnFreshBranch(worktreeID:sessionId:)`
- Produces: a pure transcript-header action presentation that is testable without ViewInspector

- [ ] **Step 1: Add failing pure presentation tests**

Extract a small presentation type in `HistoryPaneView.swift`, for example:

```swift
enum TranscriptHeaderActionKind: Equatable {
    case resume
    case reviveOriginal
    case reviveFresh
}

struct TranscriptHeaderActionDescriptor: Equatable {
    let kind: TranscriptHeaderActionKind
    let title: String
    let prominent: Bool
}
```

Tests assert:

```swift
#expect(TranscriptHeaderActions.descriptors(
    for: .resume, defaultBranch: "main"
) == [
    .init(kind: .resume, title: "Resume", prominent: true)
])

#expect(TranscriptHeaderActions.descriptors(
    for: .reviveWithSession, defaultBranch: "master"
) == [
    .init(kind: .reviveOriginal, title: "in original branch", prominent: true),
    .init(kind: .reviveFresh, title: "on fresh master", prominent: false),
])
```

- [ ] **Step 2: Run the presentation tests and verify they fail to compile**

Run:

```bash
swift test --filter HistoryPaneActionTests
```

Expected: compilation fails because the presentation types do not exist.

- [ ] **Step 3: Implement the pure presentation**

For `.resume`, return one prominent Resume descriptor. For `.reviveWithSession`, return the two descriptors above and expose the prefix copy `"Revive this session:"`. Use `"main"` only as the fallback when the source worktree’s repo cannot be found; otherwise use `repo.defaultBranch`.

- [ ] **Step 4: Render descriptors and local in-flight state**

In `SessionTranscriptView`, add:

```swift
@State private var isFreshBranchReviveInFlight = false
```

Render:

- active: the existing single prominent Resume button;
- archived: the prefix, prominent `in original branch`, and bordered `on fresh <default>`;
- disable only the fresh button while its task is in flight;
- call the existing `reviveWithSession` for the original branch;
- set/reset local in-flight state with `defer` around `reviveConversationOnFreshBranch`.

Do not place fresh-action state in `revivingArchived`.

- [ ] **Step 5: Run focused UI and app tests**

Run:

```bash
swift test --filter HistoryPaneActionTests
swift test --filter ReviveConversationFreshAppStateTests
```

Expected: active has one action, archived has two actions, default-branch copy is dynamic, and both suites pass.

- [ ] **Step 6: Run required project verification**

Run:

```bash
swift build
swift test
swiftlint --strict
```

Expected: build, all tests, and lint pass. If SwiftLint is unavailable, record that exact environment limitation in the task report; do not claim lint passed.

- [ ] **Step 7: Commit Task 5**

```bash
git add Sources/TBDApp/Panes/HistoryPaneView.swift \
  Tests/TBDAppTests/HistoryPaneActionTests.swift
git commit -m "feat: add fresh branch revive button"
```

---

## Self-Review Checklist

- Spec coverage: Tasks 1–5 cover the RPC, uncached fetch and fallback warning, base metadata, fresh create path, both spawn branches, fork semantics, transcript relocation, provisional/final session ID, Notes provenance, archived-row immutability, app state, warning alert, and archived-only UI.
- Placeholder scan: no implementation step delegates unspecified error handling, tests, validation, or edge cases.
- Type consistency: `WorktreeReviveConversationFreshParams`, `WorktreeReviveConversationFreshResult`, `ConversationCarryover`, and `reviveConversationOnFreshBranch` use the same field names and types across shared, daemon, client, app, and tests.
- Scope: no flag, migration, plain-revive behavior change, archived-row mutation, multi-session carryover, screen scraping, or new unseamed timer is included.
