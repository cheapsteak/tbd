# Agent-Process Reaper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect and reap orphaned/wedged `claude`/`codex` agent processes that TBD spawned but whose tmux pane is gone, autonomously and safely.

**Architecture:** A new `ProcessSignaller` seam wraps OS process operations (`kill(2)`, `ps`) for testability. `AgentReaper` composes it with tmux queries to find *structural orphans* (a child of a TBD-owned tmux server that is no longer any live pane's `pane_pid`), gate them by a TBD spawn-argv fingerprint, and reap them via SIGTERM→grace→SIGKILL. The reaper is wired into every teardown point (archive, reconcile, pre-`kill-server`) as a confirm-and-escalate step after `kill-window`, and into the daemon as a startup + ~60s periodic sweep.

**Tech Stack:** Swift, Swift Testing (`import Testing`), GRDB (unaffected), tmux CLI, POSIX `kill`/`ps`.

**Spec:** `docs/specs/2026-06-15-agent-reaper-spec.md`

**Conventions (from CLAUDE.md):**
- No `print()` in `Sources/` — use `os.Logger` (`com.tbd.daemon` subsystem, feature category).
- After daemon/shared changes, verify with `swift build`; run `swift test`.
- Tests must not touch `~/tbd` — these tests inject fakes and never send real signals.
- A test for each branch of new gated behavior.
- Conventional commits.

---

## File Structure

New:
- `Sources/TBDDaemon/Process/ProcessSignaller.swift` — protocol + `ProductionProcessSignaller`.
- `Sources/TBDDaemon/Process/AgentReaper.swift` — detection + reaping logic, plus `TmuxProcessQuerying` protocol.
- `Tests/TBDDaemonTests/Process/FakeProcessSignaller.swift` — test double + a fake `TmuxProcessQuerying`.
- `Tests/TBDDaemonTests/Process/AgentReaperTests.swift` — unit tests.

Modified:
- `Sources/TBDDaemon/Tmux/TmuxManager.swift` — add `serverPID` + `livePanePIDs` (command builders + methods) and conform to `TmuxProcessQuerying`.
- `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle.swift` — inject `processSignaller` + reaper grace knobs; add computed `reaper` + `killWindowAndReap` helper.
- `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Archive.swift` — escalate after `kill-window`.
- `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Reconcile.swift` — escalate after `kill-window` (×2) + reap children before `kill-server`.
- `Sources/TBDDaemon/Daemon.swift` — startup sweep + periodic `reaperTask` + cancel in `stop()`.
- `Tests/TBDDaemonTests/TmuxManagerTests.swift` (or nearest existing tmux test file) — command-builder shape tests.

---

## Task 1: ProcessSignaller seam

**Files:**
- Create: `Sources/TBDDaemon/Process/ProcessSignaller.swift`
- Create: `Tests/TBDDaemonTests/Process/FakeProcessSignaller.swift`
- Test: `Tests/TBDDaemonTests/Process/AgentReaperTests.swift` (start the file here)

- [ ] **Step 1: Write the production seam**

```swift
// Sources/TBDDaemon/Process/ProcessSignaller.swift
import Foundation

/// Injectable seam over OS process operations so reaper logic is unit-testable
/// without sending real signals or shelling out to `ps`. Mirrors TmuxManager's
/// dryRun-injection pattern.
public protocol ProcessSignaller: Sendable {
    /// True if the pid exists. Uses `kill(pid, 0)`: 0 => alive; EPERM => alive
    /// but owned by another uid (still "alive"); ESRCH => dead.
    func isAlive(_ pid: Int32) -> Bool
    /// Send SIGTERM. Targets the process group when `pid` is a group leader
    /// (tmux panes are `setsid` leaders, so this reaps in-group children too);
    /// otherwise signals just the pid.
    func terminate(_ pid: Int32)
    /// Send SIGKILL with the same group-vs-single semantics as `terminate`.
    func forceKill(_ pid: Int32)
    /// Pids whose parent pid == `serverPID` (one generation; tmux panes are
    /// direct children of the server process).
    func children(ofServerPID serverPID: Int32) -> [Int32]
    /// Full command line of the pid (for the TBD ownership fingerprint), or nil.
    func commandLine(_ pid: Int32) -> String?
}

public struct ProductionProcessSignaller: ProcessSignaller {
    public init() {}

    public func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Foundation.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public func terminate(_ pid: Int32) { signal(pid, SIGTERM) }
    public func forceKill(_ pid: Int32) { signal(pid, SIGKILL) }

    private func signal(_ pid: Int32, _ sig: Int32) {
        guard pid > 1 else { return }  // never signal pid<=1
        // Group-kill only when pid is its own group leader, so we never signal
        // an unrelated process group by accident.
        if getpgid(pid) == pid {
            _ = Foundation.kill(-pid, sig)
        } else {
            _ = Foundation.kill(pid, sig)
        }
    }

    public func children(ofServerPID serverPID: Int32) -> [Int32] {
        guard let out = Self.runPS(["-axo", "pid=,ppid="]) else { return [] }
        var result: [Int32] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, let p = Int32(parts[0]), let pp = Int32(parts[1]) else { continue }
            if pp == serverPID { result.append(p) }
        }
        return result
    }

    public func commandLine(_ pid: Int32) -> String? {
        Self.runPS(["-o", "command=", "-p", String(pid)])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runPS(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
```

- [ ] **Step 2: Write the test double**

```swift
// Tests/TBDDaemonTests/Process/FakeProcessSignaller.swift
import Foundation
@testable import TBDDaemonLib

/// Records signal intent and answers liveness from a scriptable table.
final class FakeProcessSignaller: ProcessSignaller, @unchecked Sendable {
    struct Behavior {
        var aliveInitially = true
        var aliveAfterTerminate = true
        var aliveAfterKill = false
    }

    private let lock = NSLock()
    var childrenByServer: [Int32: [Int32]] = [:]
    var cmdlines: [Int32: String] = [:]
    var behaviors: [Int32: Behavior] = [:]
    private(set) var terminated: [Int32] = []
    private(set) var killed: [Int32] = []
    private var terminatedSet: Set<Int32> = []
    private var killedSet: Set<Int32> = []

    func isAlive(_ pid: Int32) -> Bool {
        lock.withLock {
            let b = behaviors[pid] ?? Behavior()
            if killedSet.contains(pid) { return b.aliveAfterKill }
            if terminatedSet.contains(pid) { return b.aliveAfterTerminate }
            return b.aliveInitially
        }
    }
    func terminate(_ pid: Int32) { lock.withLock { terminated.append(pid); terminatedSet.insert(pid) } }
    func forceKill(_ pid: Int32) { lock.withLock { killed.append(pid); killedSet.insert(pid) } }
    func children(ofServerPID serverPID: Int32) -> [Int32] { lock.withLock { childrenByServer[serverPID] ?? [] } }
    func commandLine(_ pid: Int32) -> String? { lock.withLock { cmdlines[pid] } }
}
```

- [ ] **Step 3: Write failing tests for the production seam**

```swift
// Tests/TBDDaemonTests/Process/AgentReaperTests.swift
import Testing
import Foundation
@testable import TBDDaemonLib

@Suite struct ProcessSignallerTests {
    @Test func isAliveTrueForSelf() {
        let s = ProductionProcessSignaller()
        #expect(s.isAlive(getpid()) == true)
    }

    @Test func isAliveFalseForUnusedPID() {
        let s = ProductionProcessSignaller()
        // PID 0 and negative are rejected; a very high pid is almost certainly free.
        #expect(s.isAlive(0) == false)
        #expect(s.isAlive(2_000_000_000) == false)
    }

    @Test func commandLineContainsPSForSelf() {
        let s = ProductionProcessSignaller()
        let cmd = s.commandLine(getpid())
        #expect(cmd != nil)
    }
}
```

- [ ] **Step 4: Run tests — expect FAIL (types not yet compiled / file new), then PASS once Step 1–2 compile**

Run: `swift test --filter ProcessSignallerTests`
Expected: PASS after Steps 1–2 compile. (If the first run fails to build because `AgentReaper` is referenced later, that's fine — this file has no such reference yet.)

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Process/ProcessSignaller.swift Tests/TBDDaemonTests/Process/FakeProcessSignaller.swift Tests/TBDDaemonTests/Process/AgentReaperTests.swift
git commit -m "feat(daemon): add ProcessSignaller OS seam + fake"
```

---

## Task 2: TmuxManager — server pid + live pane pids

**Files:**
- Modify: `Sources/TBDDaemon/Tmux/TmuxManager.swift`
- Test: `Tests/TBDDaemonTests/TmuxManagerTests.swift` (use the existing tmux command-builder test file; if none exists, create `Tests/TBDDaemonTests/TmuxManagerCommandTests.swift`)

- [ ] **Step 1: Write failing command-builder tests**

```swift
// in the tmux command-builder test suite
@Test func serverPIDQueryShape() {
    #expect(TmuxManager.serverPIDQuery(server: "tbd-abc")
        == ["-L", "tbd-abc", "display-message", "-p", "#{pid}"])
}

@Test func listAllPanePIDsCommandShape() {
    #expect(TmuxManager.listAllPanePIDsCommand(server: "tbd-abc")
        == ["-L", "tbd-abc", "list-panes", "-a", "-F", "#{pane_pid}"])
}
```

- [ ] **Step 2: Run — expect FAIL (no such static funcs)**

Run: `swift test --filter serverPIDQueryShape`
Expected: FAIL — `type 'TmuxManager' has no member 'serverPIDQuery'`.

- [ ] **Step 3: Add command builders + instance methods + protocol conformance**

Add static builders near the other builders in `TmuxManager.swift` (after `panePIDQuery`, ~line 179):

```swift
    public static func serverPIDQuery(server: String) -> [String] {
        ["-L", server, "display-message", "-p", "#{pid}"]
    }

    public static func listAllPanePIDsCommand(server: String) -> [String] {
        ["-L", server, "list-panes", "-a", "-F", "#{pane_pid}"]
    }
```

Add instance methods near `panePID` (~line 353):

```swift
    /// The tmux server's own process pid (the parent of every pane process),
    /// or nil if the server can't be queried (e.g. no sessions / not running).
    public func serverPID(server: String) async -> Int32? {
        if dryRun { return nil }
        let args = Self.serverPIDQuery(server: server)
        guard let out = try? await runTmux(args) else { return nil }
        return Int32(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Every live pane's `pane_pid` across all sessions on the server.
    public func livePanePIDs(server: String) async -> Set<Int32> {
        if dryRun { return [] }
        let args = Self.listAllPanePIDsCommand(server: server)
        guard let out = try? await runTmux(args) else { return [] }
        var pids: Set<Int32> = []
        for line in out.split(separator: "\n") {
            if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) { pids.insert(pid) }
        }
        return pids
    }
```

(The `TmuxProcessQuerying` protocol that these satisfy is declared in Task 3; conformance is added there.)

- [ ] **Step 4: Run — expect PASS**

Run: `swift test --filter serverPIDQueryShape` and `swift test --filter listAllPanePIDsCommandShape`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Tmux/TmuxManager.swift Tests/TBDDaemonTests/
git commit -m "feat(daemon): add tmux serverPID + livePanePIDs queries"
```

---

## Task 3: AgentReaper — structural orphan detection + ownership gate

**Files:**
- Create: `Sources/TBDDaemon/Process/AgentReaper.swift`
- Test: `Tests/TBDDaemonTests/Process/AgentReaperTests.swift` (extend)

- [ ] **Step 1: Write the reaper + tmux-query protocol**

```swift
// Sources/TBDDaemon/Process/AgentReaper.swift
import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "reaper")

/// The two tmux queries AgentReaper needs. TmuxManager conforms; tests inject a fake.
public protocol TmuxProcessQuerying: Sendable {
    func serverPID(server: String) async -> Int32?
    func livePanePIDs(server: String) async -> Set<Int32>
}

extension TmuxManager: TmuxProcessQuerying {}

public struct AgentReaper: Sendable {
    let tmux: TmuxProcessQuerying
    let signaller: ProcessSignaller
    /// Number of liveness polls before escalating / giving up.
    let graceAttempts: Int
    /// Delay between liveness polls.
    let pollInterval: Duration

    public init(
        tmux: TmuxProcessQuerying,
        signaller: ProcessSignaller,
        graceAttempts: Int = 30,
        pollInterval: Duration = .milliseconds(100)
    ) {
        self.tmux = tmux
        self.signaller = signaller
        self.graceAttempts = graceAttempts
        self.pollInterval = pollInterval
    }

    /// Children of the server process that are not any live pane's pane_pid.
    /// Structural: no pane references them, so the UI cannot reach them.
    func findStructuralOrphans(server: String) async -> [Int32] {
        guard let serverPID = await tmux.serverPID(server: server) else { return [] }
        let children = Set(signaller.children(ofServerPID: serverPID))
        let panes = await tmux.livePanePIDs(server: server)
        return Array(children.subtracting(panes))
    }

    /// Defense-in-depth ownership check before any signal.
    func isTBDOwned(_ pid: Int32) -> Bool {
        guard let cmd = signaller.commandLine(pid) else { return false }
        return cmd.contains("claude-overlay.json") || cmd.contains("/TBD/plugin")
    }
}
```

- [ ] **Step 2: Write a fake `TmuxProcessQuerying` + failing tests**

Append to `FakeProcessSignaller.swift`:

```swift
final class FakeTmuxQuerier: TmuxProcessQuerying, @unchecked Sendable {
    var serverPIDs: [String: Int32] = [:]
    var panePIDs: [String: Set<Int32>] = [:]
    func serverPID(server: String) async -> Int32? { serverPIDs[server] }
    func livePanePIDs(server: String) async -> Set<Int32> { panePIDs[server] ?? [] }
}
```

Append to `AgentReaperTests.swift`:

```swift
@Suite struct AgentReaperDetectionTests {
    private func reaper(_ tmux: FakeTmuxQuerier, _ sig: FakeProcessSignaller) -> AgentReaper {
        AgentReaper(tmux: tmux, signaller: sig, graceAttempts: 2, pollInterval: .milliseconds(1))
    }

    @Test func orphansAreChildrenMinusLivePanes() async {
        let tmux = FakeTmuxQuerier(); let sig = FakeProcessSignaller()
        tmux.serverPIDs["tbd-x"] = 1000
        sig.childrenByServer[1000] = [11, 22, 33]
        tmux.panePIDs["tbd-x"] = [22]               // only 22 has a live pane
        let orphans = await reaper(tmux, sig).findStructuralOrphans(server: "tbd-x")
        #expect(Set(orphans) == [11, 33])
    }

    @Test func livePaneIsNeverAnOrphan() async {
        let tmux = FakeTmuxQuerier(); let sig = FakeProcessSignaller()
        tmux.serverPIDs["tbd-x"] = 1000
        sig.childrenByServer[1000] = [42]
        tmux.panePIDs["tbd-x"] = [42]
        let orphans = await reaper(tmux, sig).findStructuralOrphans(server: "tbd-x")
        #expect(orphans.isEmpty)
    }

    @Test func noServerPIDYieldsNoOrphans() async {
        let tmux = FakeTmuxQuerier(); let sig = FakeProcessSignaller()
        let orphans = await reaper(tmux, sig).findStructuralOrphans(server: "gone")
        #expect(orphans.isEmpty)
    }

    @Test func fingerprintMatchesTBDArgvOnly() {
        let tmux = FakeTmuxQuerier(); let sig = FakeProcessSignaller()
        sig.cmdlines[11] = "claude --settings /Users/x/tbd/runtime/claude-overlay.json"
        sig.cmdlines[12] = "claude --plugin-dir /Users/x/Library/Application Support/TBD/plugin"
        sig.cmdlines[13] = "claude --resume ABC"           // a user's own claude
        let r = reaper(tmux, sig)
        #expect(r.isTBDOwned(11) == true)
        #expect(r.isTBDOwned(12) == true)
        #expect(r.isTBDOwned(13) == false)
    }
}
```

- [ ] **Step 3: Run — expect FAIL (build) then PASS**

Run: `swift test --filter AgentReaperDetectionTests`
Expected: PASS once Step 1–2 compile.

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDDaemon/Process/AgentReaper.swift Tests/TBDDaemonTests/Process/
git commit -m "feat(daemon): AgentReaper structural orphan detection + ownership gate"
```

---

## Task 4: AgentReaper — reap + escalate-after-hangup ladder

**Files:**
- Modify: `Sources/TBDDaemon/Process/AgentReaper.swift`
- Test: `Tests/TBDDaemonTests/Process/AgentReaperTests.swift` (extend)

- [ ] **Step 1: Write failing tests for the escalation ladder**

```swift
@Suite struct AgentReaperEscalationTests {
    private func reaper(_ sig: FakeProcessSignaller) -> AgentReaper {
        AgentReaper(tmux: FakeTmuxQuerier(), signaller: sig, graceAttempts: 2, pollInterval: .milliseconds(1))
    }

    @Test func reapSendsSigtermThenSigkillWhenProcessSurvives() async {
        let sig = FakeProcessSignaller()
        sig.behaviors[7] = .init(aliveInitially: true, aliveAfterTerminate: true, aliveAfterKill: false)
        await reaper(sig).reap(7)
        #expect(sig.terminated == [7])
        #expect(sig.killed == [7])
    }

    @Test func reapStopsAtSigtermWhenProcessDies() async {
        let sig = FakeProcessSignaller()
        sig.behaviors[8] = .init(aliveInitially: true, aliveAfterTerminate: false, aliveAfterKill: false)
        await reaper(sig).reap(8)
        #expect(sig.terminated == [8])
        #expect(sig.killed.isEmpty)            // died on SIGTERM — no SIGKILL
    }

    @Test func escalateAfterHangupDoesNothingWhenAlreadyDead() async {
        let sig = FakeProcessSignaller()
        sig.behaviors[9] = .init(aliveInitially: false)
        await reaper(sig).escalateAfterHangup(9)
        #expect(sig.terminated.isEmpty)
        #expect(sig.killed.isEmpty)
    }

    @Test func escalateAfterHangupReapsSurvivor() async {
        let sig = FakeProcessSignaller()
        sig.behaviors[10] = .init(aliveInitially: true, aliveAfterTerminate: true, aliveAfterKill: false)
        await reaper(sig).escalateAfterHangup(10)
        #expect(sig.terminated == [10])
        #expect(sig.killed == [10])
    }
}
```

- [ ] **Step 2: Run — expect FAIL (no `reap` / `escalateAfterHangup`)**

Run: `swift test --filter AgentReaperEscalationTests`
Expected: FAIL — no member `reap`.

- [ ] **Step 3: Implement the ladder in `AgentReaper.swift`**

```swift
    /// SIGTERM → poll for `graceAttempts × pollInterval` → SIGKILL if still alive.
    /// Used by the sweep (no prior SIGHUP) and by `escalateAfterHangup`.
    func reap(_ pid: Int32) async {
        signaller.terminate(pid)
        for _ in 0..<graceAttempts {
            if !signaller.isAlive(pid) { return }
            try? await Task.sleep(for: pollInterval)
        }
        if signaller.isAlive(pid) {
            logger.warning("reaper: pid \(pid, privacy: .public) survived SIGTERM — sending SIGKILL")
            signaller.forceKill(pid)
        }
    }

    /// Called right after `kill-window` (which already sent SIGHUP). A healthy
    /// agent exits within the grace window — only a wedged one survives, and is
    /// then escalated. No-op if the pid is already gone.
    func escalateAfterHangup(_ pid: Int32) async {
        for _ in 0..<graceAttempts {
            if !signaller.isAlive(pid) { return }
            try? await Task.sleep(for: pollInterval)
        }
        guard signaller.isAlive(pid) else { return }
        logger.warning("reaper: agent pid \(pid, privacy: .public) survived kill-window SIGHUP — escalating")
        await reap(pid)
    }
```

- [ ] **Step 4: Run — expect PASS**

Run: `swift test --filter AgentReaperEscalationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Process/AgentReaper.swift Tests/TBDDaemonTests/Process/AgentReaperTests.swift
git commit -m "feat(daemon): AgentReaper SIGTERM->SIGKILL escalation ladder"
```

---

## Task 5: AgentReaper — sweep + reap-server-children

**Files:**
- Modify: `Sources/TBDDaemon/Process/AgentReaper.swift`
- Test: `Tests/TBDDaemonTests/Process/AgentReaperTests.swift` (extend)

- [ ] **Step 1: Write failing tests**

```swift
@Suite struct AgentReaperSweepTests {
    private func reaper(_ tmux: FakeTmuxQuerier, _ sig: FakeProcessSignaller) -> AgentReaper {
        AgentReaper(tmux: tmux, signaller: sig, graceAttempts: 1, pollInterval: .milliseconds(1))
    }

    @Test func sweepReapsOwnedOrphansAcrossServers() async {
        let tmux = FakeTmuxQuerier(); let sig = FakeProcessSignaller()
        tmux.serverPIDs = ["tbd-a": 100, "tbd-b": 200]
        sig.childrenByServer = [100: [11, 12], 200: [21]]
        tmux.panePIDs = ["tbd-a": [12], "tbd-b": []]      // 11 and 21 are orphans
        // Both orphans carry the TBD fingerprint.
        sig.cmdlines = [11: "claude --plugin-dir /x/TBD/plugin",
                        21: "claude --settings /x/claude-overlay.json"]
        sig.behaviors = [11: .init(aliveAfterTerminate: false), 21: .init(aliveAfterTerminate: false)]
        await reaper(tmux, sig).sweep(servers: ["tbd-a", "tbd-b"])
        #expect(Set(sig.terminated) == [11, 21])
    }

    @Test func sweepSkipsUnownedOrphans() async {
        let tmux = FakeTmuxQuerier(); let sig = FakeProcessSignaller()
        tmux.serverPIDs = ["tbd-a": 100]
        sig.childrenByServer = [100: [11]]
        tmux.panePIDs = ["tbd-a": []]                     // 11 is structurally an orphan
        sig.cmdlines = [11: "claude --resume USERS-OWN"]  // but NOT TBD-owned
        await reaper(tmux, sig).sweep(servers: ["tbd-a"])
        #expect(sig.terminated.isEmpty)
        #expect(sig.killed.isEmpty)
    }

    @Test func reapServerChildrenSignalsOwnedChildren() async {
        let tmux = FakeTmuxQuerier(); let sig = FakeProcessSignaller()
        tmux.serverPIDs = ["tbd-a": 100]
        sig.childrenByServer = [100: [11, 12]]
        sig.cmdlines = [11: "claude --plugin-dir /x/TBD/plugin", 12: "claude --resume USERS-OWN"]
        sig.behaviors = [11: .init(aliveAfterTerminate: false)]
        await reaper(tmux, sig).reapServerChildren(server: "tbd-a")
        #expect(sig.terminated == [11])                   // only the owned child
    }
}
```

- [ ] **Step 2: Run — expect FAIL (no `sweep` / `reapServerChildren`)**

Run: `swift test --filter AgentReaperSweepTests`
Expected: FAIL.

- [ ] **Step 3: Implement in `AgentReaper.swift`**

```swift
    /// Reap every structural orphan (gated by ownership) across the given servers.
    public func sweep(servers: [String]) async {
        for server in servers {
            for pid in await findStructuralOrphans(server: server) where isTBDOwned(pid) {
                logger.info("reaper: sweeping orphan pid \(pid, privacy: .public) on \(server, privacy: .public)")
                await reap(pid)
            }
        }
    }

    /// Reap the server's owned child processes before the server itself is
    /// killed, so they don't reparent to launchd and escape.
    public func reapServerChildren(server: String) async {
        guard let serverPID = await tmux.serverPID(server: server) else { return }
        for pid in signaller.children(ofServerPID: serverPID) where isTBDOwned(pid) {
            logger.info("reaper: reaping child pid \(pid, privacy: .public) before kill-server \(server, privacy: .public)")
            await reap(pid)
        }
    }
```

- [ ] **Step 4: Run — expect PASS**

Run: `swift test --filter AgentReaperSweepTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Process/AgentReaper.swift Tests/TBDDaemonTests/Process/AgentReaperTests.swift
git commit -m "feat(daemon): AgentReaper sweep + pre-kill-server child reaping"
```

---

## Task 6: WorktreeLifecycle — inject reaper + killWindowAndReap, wire archive

**Files:**
- Modify: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle.swift`
- Modify: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Archive.swift:117-122`
- Test: `Tests/TBDDaemonTests/WorktreeLifecycleReaperTests.swift` (create)

- [ ] **Step 1: Inject the signaller + reaper knobs into WorktreeLifecycle**

In `WorktreeLifecycle.swift`, add stored props after `preSessionPollInterval` (line 60) and params to `init` (mirroring the existing injectable-timeout precedent):

```swift
    /// Process-signal seam for the agent reaper. Injectable for tests.
    public let processSignaller: ProcessSignaller
    /// Reaper grace knobs (kept small in tests to avoid real sleeps).
    public let reaperGraceAttempts: Int
    public let reaperPollInterval: Duration
```

Add to the `init` signature (after `preSessionPollInterval`):

```swift
        processSignaller: ProcessSignaller = ProductionProcessSignaller(),
        reaperGraceAttempts: Int = 30,
        reaperPollInterval: Duration = .milliseconds(100)
```

Add to the init body:

```swift
        self.processSignaller = processSignaller
        self.reaperGraceAttempts = reaperGraceAttempts
        self.reaperPollInterval = reaperPollInterval
```

Add a computed reaper + the teardown helper (inside `WorktreeLifecycle` or a small extension in the same file):

```swift
    var reaper: AgentReaper {
        AgentReaper(tmux: tmux, signaller: processSignaller,
                    graceAttempts: reaperGraceAttempts, pollInterval: reaperPollInterval)
    }

    /// Kill a tmux window, then confirm the pane process actually died and
    /// escalate (SIGTERM→SIGKILL) if it survived the SIGHUP (wedged agent).
    func killWindowAndReap(server: String, windowID: String, paneID: String) async {
        let panePID = Int32((try? await tmux.panePID(server: server, paneID: paneID)) ?? "")
        try? await tmux.killWindow(server: server, windowID: windowID)
        if let panePID { await reaper.escalateAfterHangup(panePID) }
    }
```

- [ ] **Step 2: Write the failing test**

```swift
// Tests/TBDDaemonTests/WorktreeLifecycleReaperTests.swift
import Testing
import Foundation
@testable import TBDDaemonLib

@Suite struct WorktreeLifecycleReaperTests {
    /// A wedged pane process that survives kill-window's SIGHUP gets escalated.
    @Test func killWindowAndReapEscalatesSurvivor() async throws {
        let sig = FakeProcessSignaller()
        // panePID in dryRun is "0" → Int32(0). Use 0's behavior to model survival.
        sig.behaviors[0] = .init(aliveInitially: true, aliveAfterTerminate: true, aliveAfterKill: false)
        let lifecycle = makeLifecycle(signaller: sig)
        await lifecycle.killWindowAndReap(server: "tbd-x", windowID: "@1", paneID: "%1")
        #expect(sig.terminated == [0])
        #expect(sig.killed == [0])
    }

    @Test func killWindowAndReapNoOpWhenPaneAlreadyDead() async throws {
        let sig = FakeProcessSignaller()
        sig.behaviors[0] = .init(aliveInitially: false)
        let lifecycle = makeLifecycle(signaller: sig)
        await lifecycle.killWindowAndReap(server: "tbd-x", windowID: "@1", paneID: "%1")
        #expect(sig.terminated.isEmpty)
        #expect(sig.killed.isEmpty)
    }
}
```

> **Implementer note:** `makeLifecycle(signaller:)` must build a `WorktreeLifecycle` with
> `TmuxManager(dryRun: true)` (so `panePID` returns "0" and `killWindow` no-ops),
> in-memory DB, `reaperGraceAttempts: 2`, `reaperPollInterval: .milliseconds(1)`, and the
> injected `processSignaller`. Reuse the existing test factory if one exists in the daemon
> test target (search `WorktreeLifecycle(` in `Tests/`); otherwise add a minimal local
> helper following that pattern.

- [ ] **Step 3: Run — expect FAIL, then implement helper (Step 1) until PASS**

Run: `swift test --filter WorktreeLifecycleReaperTests`
Expected: FAIL first (no `killWindowAndReap`), PASS after Step 1.

- [ ] **Step 4: Wire archive to use the helper**

In `WorktreeLifecycle+Archive.swift`, replace the loop at lines 117–122:

```swift
        // Kill all tmux windows for this worktree, reaping any wedged agent
        // that survives kill-window's SIGHUP.
        for terminal in terminals {
            await killWindowAndReap(
                server: worktree.tmuxServer,
                windowID: terminal.tmuxWindowID,
                paneID: terminal.tmuxPaneID
            )
        }
```

- [ ] **Step 5: Run full daemon tests — expect PASS**

Run: `swift test --filter WorktreeLifecycle`
Expected: PASS (existing archive tests still green; reaper tests green).

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDDaemon/Lifecycle/WorktreeLifecycle.swift Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Archive.swift Tests/TBDDaemonTests/WorktreeLifecycleReaperTests.swift
git commit -m "feat(daemon): escalate-reap wedged agents on archive"
```

---

## Task 7: Wire reconcile — kill-window escalation (×2) + pre-kill-server reap

**Files:**
- Modify: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Reconcile.swift` (lines ~122–131, ~218–226, ~238–246)
- Test: `Tests/TBDDaemonTests/WorktreeLifecycleReaperTests.swift` (extend)

- [ ] **Step 1: Replace the missing-worktree window-kill loop (lines ~122–131)**

```swift
            for terminal in terminals {
                await killWindowAndReap(
                    server: wt.tmuxServer,
                    windowID: terminal.tmuxWindowID,
                    paneID: terminal.tmuxPaneID
                )
            }
```

- [ ] **Step 2: Reap children before kill-server (lines ~218–226)**

```swift
        if allLiveWorktreesForCleanup.isEmpty {
            // No live worktrees — reap the server's agent processes first so a
            // wedged one doesn't reparent to launchd, then kill the server.
            await reaper.reapServerChildren(server: tmuxServer)
            do {
                try await tmux.killServer(server: tmuxServer)
            } catch {
                logger.warning("reconcile: failed to kill tmux server \(tmuxServer, privacy: .public): \(error, privacy: .public)")
            }
        } else {
```

- [ ] **Step 3: Escalate after killing orphaned windows (lines ~238–246)**

```swift
            do {
                let tmuxWindows = try await tmux.listWindows(server: tmuxServer, session: "main")
                for window in tmuxWindows where !trackedWindowIDs.contains(window.windowID) {
                    await killWindowAndReap(
                        server: tmuxServer,
                        windowID: window.windowID,
                        paneID: window.paneID
                    )
                }
            } catch {
                logger.warning("reconcile: failed to list tmux windows for server \(tmuxServer, privacy: .public): \(error, privacy: .public)")
            }
```

> Note: `killWindowAndReap` swallows kill-window errors internally (`try?`), matching the
> prior best-effort behavior; the surrounding `do/catch` now only guards `listWindows`.

- [ ] **Step 4: Write a test asserting kill-server is preceded by child reaping**

Add to `WorktreeLifecycleReaperTests.swift`:

```swift
    @Test func reapServerChildrenRunsForOwnedChildren() async {
        // Unit-level guard on the reaper method reconcile now calls before kill-server.
        let tmux = FakeTmuxQuerier(); let sig = FakeProcessSignaller()
        tmux.serverPIDs = ["tbd-x": 500]
        sig.childrenByServer = [500: [77]]
        sig.cmdlines = [77: "claude --plugin-dir /x/TBD/plugin"]
        sig.behaviors = [77: .init(aliveAfterTerminate: false)]
        let reaper = AgentReaper(tmux: tmux, signaller: sig, graceAttempts: 1, pollInterval: .milliseconds(1))
        await reaper.reapServerChildren(server: "tbd-x")
        #expect(sig.terminated == [77])
    }
```

> Full reconcile-path integration (DB + dryRun tmux) is covered by existing reconcile tests;
> this task's behavioral guarantees are unit-tested via the reaper. Verify existing reconcile
> tests still pass after the edits.

- [ ] **Step 5: Run — expect PASS**

Run: `swift test --filter Reconcile && swift test --filter WorktreeLifecycleReaperTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Reconcile.swift Tests/TBDDaemonTests/WorktreeLifecycleReaperTests.swift
git commit -m "feat(daemon): escalate-reap on reconcile + reap children before kill-server"
```

---

## Task 8: Daemon — startup sweep + periodic reaperTask

**Files:**
- Modify: `Sources/TBDDaemon/Daemon.swift` (task fields ~59–61; `start()` after reconcile loop ~258; `stop()` ~336+)

- [ ] **Step 1: Add the task field**

Near `sshRefreshTask`/`gitFetchTask`/`gitStatusTask` (lines 59–61):

```swift
    public nonisolated(unsafe) var reaperTask: Task<Void, Never>?
```

- [ ] **Step 2: Add an owned-servers helper + startup sweep + periodic task in `start()`**

After the per-repo reconcile loop (after line ~258, before the periodic git tasks), add:

```swift
        // 11b. Reap orphaned/wedged agent processes: sweep now, then periodically.
        let reaper = AgentReaper(tmux: tmux, signaller: ProductionProcessSignaller())
        let ownedServers: () async -> [String] = { [database] in
            guard let repos = try? await database.repos.list() else { return [] }
            return Array(Set(repos.map { TmuxManager.serverName(forRepoPath: $0.path) }))
        }
        await reaper.sweep(servers: await ownedServers())
        self.reaperTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await reaper.sweep(servers: await ownedServers())
            }
        }
```

> **Implementer note:** confirm the exact accessor for the repo list and the database
> handle name in `Daemon.swift` (search `repos.list(` and how `tmux`/`database` are bound in
> `start()`). Adjust `database`/`tmux` references to the actual local/stored names. The
> `serverName(forRepoPath:)` API is confirmed at `TmuxManager.swift:50`.

- [ ] **Step 3: Cancel in `stop()`**

In `stop()` (alongside the other `…Task?.cancel()` calls):

```swift
        reaperTask?.cancel()
        reaperTask = nil
```

- [ ] **Step 4: Build + full test suite**

Run: `swift build && swift test`
Expected: build succeeds; all tests pass.

- [ ] **Step 5: Manual smoke test (real reaping)**

```bash
scripts/restart.sh
# Verify exactly one TBDDaemon + one TBDApp from the worktree path:
ps aux | grep -E "\.build/debug/TBD" | grep -v grep
# Create a wedged orphan on a throwaway server and confirm a manual sweep would catch it
# (the daemon only sweeps servers for registered repos; this validates the mechanism):
cat > /tmp/wedge.sh <<'EOF'
trap '' HUP; while :; do :; done
EOF
chmod +x /tmp/wedge.sh
# (Optional) observe daemon logs while archiving a worktree that has a wedged agent:
log stream --level debug --predicate 'subsystem == "com.tbd.daemon" AND category == "reaper"'
```

Expected: archiving/reconciling a worktree whose agent ignores SIGHUP results in a
`reaper: … escalating` log line and the process disappearing from `ps`.

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDDaemon/Daemon.swift
git commit -m "feat(daemon): startup + periodic orphan-agent reaper sweep"
```

---

## Final verification

- [ ] `swift build` clean.
- [ ] `swift test` green (full suite).
- [ ] `swiftlint --strict` clean (no `print()` in Sources; `os.Logger` used).
- [ ] `scripts/restart.sh` then `ps aux | grep -E "\.build/debug/TBD" | grep -v grep` shows exactly one daemon + one app from the worktree.
- [ ] Dispatch `/code-review:code-review` over local changes; address findings; repeat until clean.
- [ ] Open PR via the `/pr` skill with the tbd worktree deep-link as the last body line.

---

## Self-review (against the spec)

- **Spec §3 safety model** → Tasks 3 (`isTBDOwned`, live-pane exclusion), 4 (escalation only after grace), 5 (`sweepSkipsUnownedOrphans`, `livePaneIsNeverAnOrphan`). ✓
- **Spec §4.1 ProcessSignaller** → Task 1. ✓ (signature refined: `terminate(_:)`/`forceKill(_:)` with group-leader-safe internal logic, instead of `groupOf:` — documented in the seam.)
- **Spec §4.2 AgentReaper** → Tasks 3–5. ✓
- **Spec §4.3 wiring** → archive (Task 6), reconcile ×2 + kill-server (Task 7), startup + periodic (Task 8). ✓
- **Spec §6 testing matrix** → orphan math, fingerprint, escalation ladder (both branches), safety negatives, teardown escalation, kill-server ordering, sweep — all present across Tasks 3–7. ✓
- **No DB migration / RPC / shared-model change** → confirmed; none introduced. ✓
- **Type consistency** → `terminate`/`forceKill`/`isAlive`/`children(ofServerPID:)`/`commandLine`, `findStructuralOrphans`/`isTBDOwned`/`reap`/`escalateAfterHangup`/`sweep`/`reapServerChildren`, `serverPID`/`livePanePIDs`, `killWindowAndReap` used consistently across tasks. ✓
