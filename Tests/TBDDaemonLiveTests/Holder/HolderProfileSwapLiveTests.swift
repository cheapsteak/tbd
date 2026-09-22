import Darwin
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// "Switch account" on a holder-backed tab, against a **real** holder and a
/// **real** job.
///
/// The scripted suites state the routing and the refusals; this one proves the
/// composition, because what the spec promises is not a return value: the old
/// process is gone, a new one runs under the same row, the session id did not
/// change, and the command the new child was given is a resume of that very
/// session. Only a real pid and a real argv can say any of it.
@Suite(.serialized)
struct HolderProfileSwapLiveTests {

    /// The session the row carries. Never reaches a real Claude: `PATH` finds
    /// a four-line stub first.
    static let sessionID = "sess-holder-profile-swap"

    /// A job that ignores `/exit` — it never reads its terminal — and exits on
    /// `SIGTERM`. The middle rung of the park's ladder is therefore what ends
    /// it, which is the ordinary case for an agent that is busy.
    static let job = "while :; do sleep 0.2; done"

    @Test func inPlaceSwapReparksAndResumesUnderTheNewAccount() async throws {
        let fixture = try await SwapFixture.make()
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow(blank: false)
        let oldChild = try #require(terminal.childPID)
        let oldHolder = try #require(terminal.holderPID)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminal.id,
                newProfileID: fixture.destProfileID,
                mode: .inPlace)))
        #expect(response.success, "the swap failed: \(response.error ?? "")")

        let after = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(after.id == terminal.id, "the swap moved the session to another row")
        #expect(after.claudeSessionID == Self.sessionID,
                "the swap changed the session id an in-place switch must preserve")
        #expect(after.profileID == fixture.destProfileID, "the row is not on the new account")
        #expect(!after.isParked, "the swap left the row parked")

        // The process table, which is where the claim actually lives.
        let goneSignal = kill(oldChild, 0)
        let goneErrno = errno
        #expect(goneSignal == -1 && goneErrno == ESRCH,
                "the old job survived the swap (kill returned \(goneSignal), errno \(goneErrno))")
        #expect(!holderProcessIsAlive(oldHolder), "the old holder outlived the swap")
        let newChild = try #require(after.childPID, "the swapped row records no child")
        let newHolder = try #require(after.holderPID, "the swapped row records no holder")
        #expect(newChild != oldChild && newHolder != oldHolder,
                "the swap re-used the pids of the session it just ended")
        #expect(holderProcessIsAlive(newChild), "the swapped row's job is not running")
        #expect(after.holderChildStartedAt != nil,
                "the swapped row has no identity anchor for its new child")

        // WHAT it launched. Every assertion above is satisfied by a holder
        // running the wrong command entirely. The stub is what can tell.
        //
        // Waiting on the env file is what makes the argv file safe to read:
        // the stub writes the argv first and the environment last.
        let launched = await pollUntil("the swapped session to reach its claude stub") {
            (try? String(contentsOfFile: fixture.launchEnvPath, encoding: .utf8))?
                .contains("TBD_TERMINAL_ID=") ?? false
        }
        #expect(launched, "the swap never launched anything through the pinned shell")
        let argv = ((try? String(contentsOfFile: fixture.launchArgvPath, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        let resumeIndex = argv.firstIndex(of: "--resume")
        #expect(resumeIndex != nil, "the swap did not resume anything: \(argv)")
        if let resumeIndex, resumeIndex + 1 < argv.count {
            // Adjacency, not mere presence: a resume of some OTHER session
            // would pass a containment check.
            #expect(argv[resumeIndex + 1] == Self.sessionID, "resumed the wrong session: \(argv)")
        }
        let launchEnv = (try? String(contentsOfFile: fixture.launchEnvPath, encoding: .utf8)) ?? ""
        #expect(launchEnv.contains("TBD_TERMINAL_ID=\(terminal.id.uuidString)"),
                "the resumed agent is attributed to the wrong terminal: \(launchEnv)")
    }

    /// The other plan. A blank session resumed would show "no conversation
    /// found", so the tmux arm spawns fresh instead and this one matches it.
    @Test func inPlaceSwapOfABlankSessionSpawnsFresh() async throws {
        let fixture = try await SwapFixture.make()
        defer { fixture.tearDown() }
        let terminal = try await fixture.spawnHolderRow(blank: true)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminal.id,
                newProfileID: fixture.destProfileID,
                mode: .inPlace)))
        #expect(response.success, "the swap failed: \(response.error ?? "")")

        let after = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(!after.isParked)
        #expect(after.profileID == fixture.destProfileID)
        let freshID = try #require(after.claudeSessionID)
        #expect(freshID != Self.sessionID,
                "a blank session was re-homed under the id it could not resume")

        let launched = await pollUntil("the swapped session to reach its claude stub") {
            (try? String(contentsOfFile: fixture.launchEnvPath, encoding: .utf8))?
                .contains("TBD_TERMINAL_ID=") ?? false
        }
        #expect(launched, "the swap never launched anything through the pinned shell")
        let argv = ((try? String(contentsOfFile: fixture.launchArgvPath, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        #expect(!argv.contains("--resume"),
                "a blank session was resumed rather than started fresh: \(argv)")
        let idIndex = argv.firstIndex(of: "--session-id")
        #expect(idIndex != nil, "the fresh spawn named no session: \(argv)")
        if let idIndex, idIndex + 1 < argv.count {
            #expect(argv[idIndex + 1] == freshID,
                    "the row and the spawn disagree about the new session: \(argv)")
        }
    }
}

// MARK: - Fixture

/// A database, a worktree on disk, a real `HolderRegistry` with a real
/// spawner, and an `RPCRouter` whose hibernation coordinator shares that
/// registry — assembled the way `Daemon.swift` assembles them.
private final class SwapFixture {

    let db: TBDDatabase
    let registry: HolderRegistry
    let router: RPCRouter
    let worktree: Worktree
    let destProfileID: UUID

    /// Where the stub `claude` records the argv it was launched with, one
    /// argument per line, and the `TBD_` environment it saw. Neither exists
    /// until the swap has actually launched something. The argv file is
    /// written first and the env file last, so a reader that waits for the env
    /// file has a complete argv file to read.
    var launchArgvPath: String { "\(home)/launch-argv" }
    var launchEnvPath: String { "\(home)/launch-env" }

    private let home: String
    private let tempDir: URL
    private var torndown = false

    /// A pid this fixture spawned, and the kernel's record of when that pid
    /// started.
    ///
    /// The start time is what makes the pid safe to signal later. A pid is
    /// free the instant its corpse is collected, and on a box running dozens
    /// of agent sessions the next process to take it is somebody else's — so
    /// `tearDown` signals a remembered pid only while the kernel still reports
    /// the same start instant, which is the answer `AgentReaper` gives to the
    /// same question about a holder row.
    private struct SpawnedProcess {
        let pid: Int32
        /// nil when the pid was already gone by the time it was recorded,
        /// which makes it unidentifiable and therefore never signalled.
        let startedAt: Date?
        /// Whether this process is a child of the test process itself. The
        /// holder is — `HolderSpawner` `posix_spawn`s it directly — so its
        /// corpse must be reaped or it outlives the suite. The job is the
        /// holder's child, not ours, and the kernel reaps it.
        let ourChild: Bool
    }

    private var spawned: [SpawnedProcess] = []

    /// The stand-in login shell the wake spawn runs, plus the `claude` stub it
    /// puts ahead of everything else on PATH.
    ///
    /// The shell HONOURS its `-i -l -c <command>` argv rather than ignoring
    /// it, because that argv is the artifact under test: evaluating it turns
    /// the composition's inline `export TBD_…` statements into real
    /// environment variables and launches "claude", so the stub can record
    /// both. The stub returns rather than blocking, so the shell reaches its
    /// `exec sleep` and the job stays exactly one pid — the one the row names
    /// and the one teardown kills.
    private static func writeGateShell(in home: String) throws -> String {
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let binDir = "\(home)/bin"
        try FileManager.default.createDirectory(
            atPath: binDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(home)/launch-argv"
        printf 'SWAPPED-OK\\n'
        env | grep '^TBD_' > "\(home)/launch-env"
        """.write(toFile: "\(binDir)/claude", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: "\(binDir)/claude")

        let path = "\(home)/gate-shell"
        // The command is the LAST argument whatever flags precede it, which is
        // what keeps this shell honest about a `shellFlags` change.
        try """
        #!/bin/sh
        PATH="\(binDir):$PATH"
        export PATH
        for tbd_arg in "$@"; do tbd_command="$tbd_arg"; done
        eval "$tbd_command"
        exec sleep 30
        """.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }

    static func make() async throws -> SwapFixture {
        let home = fencedScratchRoot(prefix: "tbdswp")
        let shell = try writeGateShell(in: home)
        let environment = ["TBD_HOME": home, "PATH": "/usr/bin:/bin", "SHELL": shell]

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPtyHolderEnabled(true)

        let executable = try #require(
            HolderProcessFixture.locateExecutable(),
            "TBDHolder must be built beside the test bundle")
        let registry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: environment,
            listTerminals: { [] },
            spawner: HolderSpawner(executableURL: executable))

        let tmux = TmuxManager(dryRun: true)
        let configDirManager = ClaudeProfileConfigDirManager(
            baseDirectory: URL(fileURLWithPath: home)
                .appendingPathComponent("profiles", isDirectory: true),
            hostBaseDirectory: URL(fileURLWithPath: home)
                .appendingPathComponent("claude", isDirectory: true))
        let lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
            configDirManager: configDirManager)
        let router = RPCRouter(
            db: db, lifecycle: lifecycle, tmux: tmux, startTime: Date(),
            configDirManager: configDirManager,
            actuationLog: makeTestActuationLog())
        router.holderRegistry = registry
        await router.hibernationCoordinator.setHolderRegistry(registry)

        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        let repo = try await db.repos.create(
            path: repoDir.path, displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main", path: repoDir.path,
            tmuxServer: TmuxManager.serverName(forRepoPath: repoDir.path))
        let dest = try await db.modelProfiles.create(name: "Dest", kind: .oauth)

        return SwapFixture(
            db: db, registry: registry, router: router, worktree: worktree,
            destProfileID: dest.id, home: home, tempDir: tempDir)
    }

    private init(
        db: TBDDatabase, registry: HolderRegistry, router: RPCRouter,
        worktree: Worktree, destProfileID: UUID, home: String, tempDir: URL
    ) {
        self.db = db
        self.registry = registry
        self.router = router
        self.worktree = worktree
        self.destProfileID = destProfileID
        self.home = home
        self.tempDir = tempDir
    }

    /// A real holder supervising a real job, plus the row that names both —
    /// created in the order `WorktreeLifecycle+Create` creates them, so the
    /// registry has adopted the session before the swap reads anything.
    ///
    /// `blank: false` writes a transcript with one complete turn in it, which
    /// is what makes the swap plan a resume; `blank: true` leaves the row with
    /// no transcript at all, which is what makes it plan a fresh spawn.
    func spawnHolderRow(blank: Bool) async throws -> Terminal {
        let terminalID = UUID()
        let handle = try await registry.spawn(
            terminalID: terminalID,
            launch: HolderLaunchRequest(
                executable: "/bin/sh",
                arguments: ["-c", HolderProfileSwapLiveTests.job],
                workingDirectory: "/tmp",
                environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
                columns: 80,
                rows: 24))
        remember(handle)

        _ = try await db.terminals.create(
            id: terminalID,
            worktreeID: worktree.id,
            tmuxWindowID: "",
            tmuxPaneID: "",
            label: TerminalLabel.claudeCode,
            claudeSessionID: HolderProfileSwapLiveTests.sessionID,
            kind: .claude,
            transport: .holder,
            holderPID: handle.holderPID,
            childPID: handle.childPID,
            holderChildStartedAt: Date())
        if !blank {
            let transcript = "\(home)/\(HolderProfileSwapLiveTests.sessionID).jsonl"
            try #"{"type":"user","message":{"content":"switch me"}}"#
                .write(toFile: transcript, atomically: true, encoding: .utf8)
            try await db.terminals.updateSession(
                id: terminalID,
                sessionID: HolderProfileSwapLiveTests.sessionID,
                transcriptPath: transcript)
        }
        return try #require(try await db.terminals.get(id: terminalID))
    }

    /// Records the pair this spawn produced, and names it in the run log.
    ///
    /// The log line is the diagnosis: a holder that outlives a run is a
    /// `setsid` process that re-parents to launchd and keeps its job going,
    /// and a pid printed with the scratch root it belongs to is what makes the
    /// next occurrence answerable from the run log alone. stderr rather than
    /// `print`, for the reason `FlakyTestSupport` uses it: stdout is Swift
    /// Testing's, and both streams reach the tee'd run log.
    private func remember(_ handle: HolderHandle) {
        spawned.append(SpawnedProcess(
            pid: handle.holderPID,
            startedAt: ProcessStartTime.startTime(pid: handle.holderPID),
            ourChild: true))
        spawned.append(SpawnedProcess(
            pid: handle.childPID,
            startedAt: ProcessStartTime.startTime(pid: handle.childPID),
            ourChild: false))
        let line = "SwapFixture: holder pid \(handle.holderPID), "
            + "job pid \(handle.childPID), scratch root \(home)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Kills whatever the rows still name, sweeps whatever they no longer do,
    /// then clears the scratch roots.
    ///
    /// Reading the rows rather than a remembered list is the safety property:
    /// a park clears the pids off its row precisely because those processes
    /// are gone, and signalling a remembered number on a box running dozens of
    /// agent sessions would signal somebody else's work. The row pass is also
    /// the only one that can reach the generation the WAKE spawned, which this
    /// fixture never sees a handle for.
    func tearDown() {
        guard !torndown else { return }
        torndown = true
        for row in (try? blockingTerminals()) ?? [] where row.transport == .holder {
            if let holderPID = row.holderPID, holderPID > 1 {
                kill(holderPID, SIGKILL)
                var ignored: Int32 = 0
                _ = waitpid(holderPID, &ignored, 0)
            }
            if let childPID = row.childPID, childPID > 1, holderProcessIsAlive(childPID) {
                kill(childPID, SIGKILL)
            }
        }
        sweepRememberedProcesses()
        let registry = self.registry
        Task.detached { await registry.releaseAll() }
        try? FileManager.default.removeItem(atPath: home)
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// The second pass, for the branch where the first one has nothing to work
    /// from.
    ///
    /// `blockingTerminals` waits up to `TestGate.deadline` and returns `[]` on
    /// expiry — and on that branch the sweep above kills nothing, while the
    /// holder it would have killed is a process built to outlive this one:
    /// `TBDHolder` calls `setsid()` and ignores `SIGHUP`, so it survives a dead
    /// test process and keeps its job running, and nothing in the product
    /// reclaims it (`OrphanGC` enumerates the real `~/tbd/holders`, and
    /// `AgentReaper` works from rows this in-memory database never gave
    /// anyone).
    ///
    /// Remembering is safe here only because the kill is identity-checked:
    /// a reissued pid reports a different start instant and is left alone,
    /// exactly as `AgentReaper` leaves one alone. The two passes cannot fight
    /// — a pid the rows already accounted for is either reaped, and reports no
    /// start time at all, or a corpse a second `SIGKILL` cannot disturb.
    private func sweepRememberedProcesses() {
        for process in spawned {
            guard let anchor = process.startedAt,
                  let current = ProcessStartTime.startTime(pid: process.pid),
                  // Both values come from the same kernel field, so a match is
                  // exact; the tolerance only keeps the comparison off
                  // floating-point equality.
                  abs(current.timeIntervalSince(anchor)) < 0.001
            else { continue }
            kill(process.pid, SIGKILL)
            if process.ourChild {
                var ignored: Int32 = 0
                _ = waitpid(process.pid, &ignored, 0)
            }
        }
    }

    /// The rows, read from a non-async teardown on a bounded wait.
    ///
    /// `gateHoldingTask` / `waitForGate` rather than `Task.detached` and a raw
    /// semaphore wait: a teardown that blocks a cooperative-pool thread can
    /// deadlock the runner, and the gate helpers are the repo's answer to it
    /// (`Tests/CLAUDE.md`, "Thread-blocking gates run off the cooperative
    /// pool"). Same spelling as `HibernationFixture.blockingTerminals`.
    private func blockingTerminals() throws -> [Terminal] {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let db = self.db
        _ = gateHoldingTask {
            box.value = try? await db.terminals.list()
            done.signal()
        }
        done.waitForGate("SwapFixture.tearDown reading the terminal rows")
        return box.value ?? []
    }

    private final class ResultBox: @unchecked Sendable {
        var value: [Terminal]?
    }
}
