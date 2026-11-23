import Darwin
import Foundation
import DaemonTestSupport
import Synchronization
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Tier 3 (docs/specs/2026-07-24-test-hardening-design.md §3): the reconcile
// test below spawns a process and reads the kernel's process table to find it,
// as the production probe does. That is what makes it tier 3 — the rest of
// `WorktreeLifecycleTests` stays in `TBDDaemonTests` because it injects the
// leftover-tmux probe and touches nothing outside the process.

/// A stand-in for a tmux server an earlier build of TBD left running, made of
/// the two things `LeftoverTmuxServerProbe` reads, so no tmux binary is needed:
///
/// - **Its socket.** A unix socket bound and listening at the path the probe
///   computes for a daemon with no `TMUX_TMPDIR`,
///   `<fallbackRoot>/tmux-<uid>/<server>`, where the fallback root is a scratch
///   directory of its own. `stopListening()` closes it and leaves the file on
///   disk, as a tmux server that exits leaves its socket, so a connect to it is
///   refused.
/// - **Its process.** `/bin/bash`, executed through a link named `tmux`, with
///   an argv that names the server with `-L` (see `arguments`). The kernel
///   keeps the argv exactly as given, `argv[0]` included, but takes the
///   command name (`p_comm`) and `proc_pidpath` from the file the link
///   resolves to, so the process table reads the process as `bash`, not
///   `tmux`. The probe still counts it as tmux because the names it is given
///   come from a saved tmux path naming the link (`tmuxExecutableNames`),
///   which adds the resolved name `bash` to `tmux`. `endProcess()` kills and
///   reaps it.
///
/// Nothing exists until `start()`. `tearDown()` undoes whatever is standing and
/// removes the scratch root, and the test registers it in a `defer` before
/// calling `start()`, so a half-finished start, a thrown error or a failed
/// `#require` still leaves nothing behind. When the test process dies before
/// any `defer` runs, the process ends by itself (see `lifetimeSeconds`).
private final class StandInTmuxServer {
    /// The probe's fallback root: the directory `tmux-<uid>` sits in.
    let fallbackRoot: String
    let socketPath: String
    /// The link named `tmux` that the process is executed through.
    let executablePath: String
    /// The process's argv, `argv[0]` included.
    ///
    /// To bash it is `bash -c '<command>' <arg0> <args…>`: `-c` is a flag, its
    /// first operand is the command, and every argument after that is a
    /// positional parameter, so bash runs the command and ignores the rest. To
    /// the probe's parser, which reads `-c` as tmux's `-c <shell-command>`, it
    /// is `tmux -c <value> -u -L <server> new-session -d -s main`, an earlier
    /// build's `new-session` naming its server with `-L`.
    ///
    /// The `; :` after `sleep` keeps bash from replacing itself with `sleep`,
    /// which it does for a command string of one simple command: the process
    /// would then carry `sleep`'s argv and name no server.
    let arguments: [String]
    private let scratchRoot: String
    private var listener: Int32?
    private var process: ExactArgvChild?

    /// Room for every connect the test makes while the socket listens.
    /// Nothing accepts, so each one stays queued, and a full queue would
    /// refuse the next connect and read as a server that is gone.
    private static let backlog: Int32 = 8

    /// How long the process lives if nothing ends it, so a test process that
    /// dies before its `defer` runs leaves nothing behind for long: the
    /// process, now launchd's, exits when its `sleep` does. That bound is the
    /// reclaim, since no sweep can find it — it holds no descriptor and no
    /// row. The test needs the process for a few seconds at most; 120 leaves
    /// a wide margin for a loaded runner, while bounding an orphan to two
    /// minutes. When `endProcess()` kills bash, its `sleep` child ends by
    /// itself within the same bound, and names no server.
    private static let lifetimeSeconds = 120

    init(server: String) {
        // Short and fenced: under `TBD_TEST_SCRATCH_ROOT`, so a killed run's
        // root is still reclaimed, and well inside darwin's 104-byte
        // `sun_path` for the socket below it.
        scratchRoot = fencedScratchRoot(prefix: "wlr")
        fallbackRoot = "\(scratchRoot)/fallback"
        socketPath = "\(fallbackRoot)/tmux-\(getuid())/\(server)"
        executablePath = "\(scratchRoot)/tmux"
        arguments = [
            "tmux", "-c", "/bin/sleep \(StandInTmuxServer.lifetimeSeconds); :",
            "-u", "-L", server, "new-session", "-d", "-s", "main",
        ]
    }

    /// The process's pid, while it is running.
    var processID: pid_t? { process?.pid }

    /// Binds the socket and starts the process.
    func start() throws {
        try FileManager.default.createDirectory(
            atPath: (socketPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: executablePath, withDestinationPath: "/bin/bash")
        listener = try Self.listeningSocket(at: socketPath)
        process = try ExactArgvChild(path: executablePath, argv: arguments)
    }

    /// Closes the socket and leaves its file where it was.
    func stopListening() {
        guard let listener else { return }
        close(listener)
        self.listener = nil
    }

    /// Kills and reaps the process. Once only: a second `kill` could reach a
    /// process that has since been given the same pid.
    func endProcess() {
        guard let process else { return }
        process.end()
        self.process = nil
    }

    func tearDown() {
        stopListening()
        endProcess()
        try? FileManager.default.removeItem(atPath: scratchRoot)
    }

    private static func listeningSocket(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StandInFailed(call: "socket", path: path, code: errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            close(fd)
            throw StandInFailed(call: "sun_path", path: path, code: ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
                for (index, byte) in bytes.enumerated() { chars[index] = CChar(bitPattern: byte) }
                chars[bytes.count] = 0
            }
        }
        let bound = withUnsafePointer(to: &address) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw StandInFailed(call: "bind", path: path, code: code)
        }
        guard Darwin.listen(fd, backlog) == 0 else {
            let code = errno
            close(fd)
            throw StandInFailed(call: "listen", path: path, code: code)
        }
        return fd
    }
}

private struct StandInFailed: Error, CustomStringConvertible {
    let call: String
    let path: String
    let code: Int32
    var description: String { "\(call) for \(path) failed with errno \(code)" }
}

/// A tmux server an earlier build started, judged end to end through
/// `reconcile(repoID:)` and the production probe (`LeftoverTmuxServerProbe`),
/// against a real socket and the kernel's real process table.
///
/// While the server runs, reconcile leaves its rows live: TBD can neither
/// reach nor stop those sessions. That holds while either signal says it
/// runs — its socket answering, or, with the socket refused, a tmux process
/// still naming it. Once both are gone (a reboot, or `tmux kill-server`), the
/// rows are PARKED (resumable Claude) or deleted (plain shell) — never
/// recreated: a parked session waits for a person's wake (#284).
///
/// The probe is the production one with two seams set: the fallback root is
/// the stand-in's scratch directory, never the real `/private/tmp/tmux-<uid>`,
/// and the process table it reads is narrowed to the stand-in's pid. Every
/// kernel read stays real — the table, the command name, the argv — but no
/// other tmux on the machine can decide the answer: a developer box may run
/// servers of its own, and one whose argv the kernel will not give reads as
/// running whatever server is asked about. The tmux names are the ones a
/// saved tmux path naming the stand-in's link gives (`tmuxExecutableNames`):
/// `tmux`, and `bash`, the name the link resolves to and the one the kernel
/// reports for the stand-in.
@Test func testReconcileRebootParksClaudeAndDeletesShell() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "acme", defaultBranch: "main"
    )
    let serverName = TmuxServerName.forRepoPath(repo.path)

    let standIn = StandInTmuxServer(server: serverName)
    defer { standIn.tearDown() }
    try standIn.start()

    let pid = try #require(standIn.processID)
    let link = standIn.executablePath
    let standInProcesses: @Sendable (uid_t) -> [LeftoverTmuxProcess]? = { uid in
        guard let table = ProcessTableSnapshot.read() else { return nil }
        return LeftoverTmuxServerProbe.tmuxProcesses(
            in: ProcessTableSnapshot(entries: table.entries.filter { $0.key == pid }),
            uid: uid,
            names: LeftoverTmuxServerProbe.tmuxExecutableNames(savedPath: link),
            executablePath: { ProcessLiveness.executablePath(pid: $0) },
            procArgs: { ProcessEnvironmentReader.procArgs(pid: $0) })
    }
    // The probe reads the process table only once every socket is refused, so
    // counting its reads tells which signal decided each pass below.
    let tableReads = ProcessTableReads()
    let probe = LeftoverTmuxServerProbe.production(
        environment: [:],
        fallbackRoot: standIn.fallbackRoot,
        tmuxProcesses: { uid in
            tableReads.record()
            return standInProcesses(uid)
        })
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), hooks: HookResolver(),
        leftoverTmuxProbe: probe
    )

    // The stand-in reads as a server through both signals before anything
    // depends on it.
    let candidates = LeftoverTmuxServerProbe.candidateSocketPaths(
        server: serverName, environment: [:], fallbackRoot: standIn.fallbackRoot)
    try #require(candidates == [standIn.socketPath],
                 "precondition: the stand-in's socket must be the one path the probe asks")
    let socketWhileListening = await LeftoverTmuxServerProbe.state(ofSocketAt: standIn.socketPath)
    try #require(socketWhileListening == .running,
                 "precondition: the stand-in's socket must answer while it listens")
    let sighted = standInProcesses(getuid())
    try #require(
        sighted == [LeftoverTmuxProcess(pid: pid, owner: getuid(), arguments: standIn.arguments)],
        "precondition: the process table must read the stand-in as this user's tmux, naming its server")

    // A worktree whose path == the repo path is reported by `git worktree
    // list`, so reconcile will not archive it as missing.
    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "wt", branch: "main",
        path: repoDir.path, tmuxServer: serverName
    )

    // Rows exactly as an earlier build recorded a session on that server: one
    // Claude window and one shell window, each with its window and pane IDs.
    let claudeWindow = (windowID: "@1", paneID: "%1")
    let shellWindow = (windowID: "@2", paneID: "%2")
    let sessionID = UUID().uuidString
    let claudeTerminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: claudeWindow.windowID, tmuxPaneID: claudeWindow.paneID,
        label: "claude", claudeSessionID: sessionID, kind: .claude
    )
    let shellTerminal = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: shellWindow.windowID, tmuxPaneID: shellWindow.paneID
    )

    // The server is running: both rows stay live and untouched. The socket
    // decides it — its answer settles the probe before the process table is
    // read, so a probe that ignored the socket and fell through to the
    // process, which also names the server, would read the table here.
    try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog())
    let claudeWhileRunning = try await db.terminals.get(id: claudeTerminal.id)
    let shellWhileRunning = try await db.terminals.get(id: shellTerminal.id)
    #expect(claudeWhileRunning?.isParked == false,
            "a session whose tmux server is running must not be parked")
    #expect(shellWhileRunning != nil,
            "a shell whose tmux server is running must not be deleted")
    #expect(tableReads.count == 0,
            "an answering socket must settle the probe without a read of the process table")

    // Its socket stops answering, as when the server listens somewhere this
    // daemon does not look, but its process still names it: still running,
    // and this time the process table decides it.
    standIn.stopListening()
    let socketAfterClose = await LeftoverTmuxServerProbe.state(ofSocketAt: standIn.socketPath)
    try #require(socketAfterClose == .absent,
                 "precondition: a closed socket must be refused, so only the process signal is left")
    try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog())
    let claudeWhileNamed = try await db.terminals.get(id: claudeTerminal.id)
    let shellWhileNamed = try await db.terminals.get(id: shellTerminal.id)
    #expect(claudeWhileNamed?.isParked == false,
            "a session whose tmux server's process still runs must not be parked")
    #expect(shellWhileNamed != nil,
            "a shell whose tmux server's process still runs must not be deleted")
    #expect(tableReads.count > 0,
            "a refused socket must leave the probe to read the process table")

    // Simulate the reboot: the whole server is gone. Its socket file stays
    // behind, as tmux leaves it, so the probe reads a refused connect, not a
    // missing path.
    standIn.endProcess()
    #expect(FileManager.default.fileExists(atPath: standIn.socketPath),
            "precondition: the gone server's socket file must still be on disk")

    try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog())

    let claudeAfter = try await db.terminals.get(id: claudeTerminal.id)
    let shellAfter = try await db.terminals.get(id: shellTerminal.id)
    let rowsAfter = try await db.terminals.list(worktreeID: wt.id)

    // Resumable Claude session: parked, not recreated, not deleted.
    #expect(claudeAfter != nil, "claude terminal must NOT be deleted on reboot")
    #expect(claudeAfter?.isParked == true, "claude terminal must be parked (resumable via wake)")
    #expect(claudeAfter?.hibernateReason == .recovery)
    #expect(claudeAfter?.claudeSessionID == sessionID, "session ID must be preserved for on-demand resume")
    #expect(claudeAfter?.tmuxWindowID == claudeWindow.windowID,
            "reboot must not recreate the claude window (no eager `claude --resume`)")

    // Plain shell: nothing resumable, deleted.
    #expect(shellAfter == nil, "shell terminal with no session must be deleted on reboot")

    // CRUCIAL #284 invariant: reconcile must not start the sessions a dead
    // server ran on its own — no mass `claude --resume` storm on reboot. The
    // parked session waits for a person's wake: the worktree holds that one
    // row, still on tmux, with no tab opened beside it and no holder spawned
    // for it.
    #expect(rowsAfter.map(\.id) == [claudeTerminal.id],
            "reconcile must not open a tab to resume the session (#284)")
    #expect(claudeAfter?.transport == .tmux,
            "reconcile must not move the parked session to a holder (#284)")
    #expect(claudeAfter?.holderPID == nil,
            "reconcile must not spawn a holder for the parked session (#284)")
}

/// How many times the probe has read the process table. A class around a
/// `Mutex`, so the probe's `@Sendable` lister can count into it.
private final class ProcessTableReads: Sendable {
    private let reads = Mutex(0)

    func record() { reads.withLock { $0 += 1 } }

    var count: Int { reads.withLock { $0 } }
}
