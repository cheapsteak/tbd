import Darwin
import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib

/// `LeftoverTmuxServerProbe` — whether a tmux server an earlier build started
/// is still running, read off its socket and the process table without running
/// tmux.
///
/// Every socket here is real and lives under a short scratch root
/// (`fencedScratchRoot`), because a path over darwin's 104-byte `sun_path`
/// limit never reaches a connect at all and would green on an answer that
/// never went near a socket. No tmux binary is run, and the process table is
/// always injected, so no answer depends on what tmux the machine is running.
@Suite("Leftover tmux server probe")
struct LeftoverTmuxServerProbeTests {

    /// A fresh short directory, removed by the returned closure.
    private func makeScratchRoot() throws -> (String, () -> Void) {
        let root = fencedScratchRoot(prefix: "ltp")
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        return (root, { try? FileManager.default.removeItem(atPath: root) })
    }

    /// Create `path` and every directory above it, and return it.
    private func makeDirectory(_ path: String) throws -> String {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)
        return path
    }

    // MARK: - Where tmux puts its socket

    /// tmux's own fallback when `TMUX_TMPDIR` is unset, and an empty value is
    /// unset to tmux too.
    @Test("with TMUX_TMPDIR unset or empty, the only candidate is under the fallback root",
          arguments: [[:], ["TMUX_TMPDIR": ""]] as [[String: String]])
    func candidatesWithoutTMUXTMPDIR(environment: [String: String]) {
        let paths = LeftoverTmuxServerProbe.candidateSocketPaths(
            server: "tbd-acme", environment: environment, uid: 501)

        #expect(paths == ["/private/tmp/tmux-501/tbd-acme"])
    }

    @Test("a TMUX_TMPDIR that resolves comes first, resolved, and the fallback follows")
    func candidatesHonourAResolvingTMUXTMPDIR() throws {
        let (root, cleanup) = try makeScratchRoot()
        defer { cleanup() }
        let configured = try makeDirectory("\(root)/configured")
        let resolved = try #require(LeftoverTmuxServerProbe.resolvedPath(configured))

        let paths = LeftoverTmuxServerProbe.candidateSocketPaths(
            server: "tbd-acme", environment: ["TMUX_TMPDIR": configured],
            fallbackRoot: "\(root)/fallback", uid: 501)

        #expect(paths == [
            "\(resolved)/tmux-501/tbd-acme",
            "\(root)/fallback/tmux-501/tbd-acme",
        ])
    }

    /// tmux resolves `TMUX_TMPDIR` with `realpath(3)` and falls back without
    /// a word when that fails, so a value naming nothing is not a candidate.
    @Test("a TMUX_TMPDIR that names a missing directory is dropped")
    func candidatesDropAMissingTMUXTMPDIR() throws {
        let (root, cleanup) = try makeScratchRoot()
        defer { cleanup() }

        let paths = LeftoverTmuxServerProbe.candidateSocketPaths(
            server: "tbd-acme", environment: ["TMUX_TMPDIR": "\(root)/missing"],
            fallbackRoot: "\(root)/fallback", uid: 501)

        #expect(paths == ["\(root)/fallback/tmux-501/tbd-acme"])
    }

    @Test("a TMUX_TMPDIR that resolves to the fallback root gives one candidate")
    func candidatesAreNotDuplicated() throws {
        let (root, cleanup) = try makeScratchRoot()
        defer { cleanup() }
        let created = try makeDirectory("\(root)/fallback")
        let fallback = try #require(LeftoverTmuxServerProbe.resolvedPath(created))

        let paths = LeftoverTmuxServerProbe.candidateSocketPaths(
            server: "tbd-acme", environment: ["TMUX_TMPDIR": "\(root)/fallback"],
            fallbackRoot: fallback, uid: 501)

        #expect(paths == ["\(fallback)/tmux-501/tbd-acme"])
    }

    @Test("the candidates name the daemon's own uid by default")
    func candidatesNameTheCurrentUID() {
        let paths = LeftoverTmuxServerProbe.candidateSocketPaths(
            server: "tbd-acme", environment: [:])

        #expect(paths == ["/private/tmp/tmux-\(getuid())/tbd-acme"])
    }

    // MARK: - What a real socket answers

    @Test("a socket something listens on reads as running")
    func aListeningSocketReadsAsRunning() async throws {
        let (root, cleanup) = try makeScratchRoot()
        defer { cleanup() }
        let path = "\(root)/listening"
        // Room for the probe's own connect: nothing here ever accepts, so a
        // full queue would refuse it and read as gone.
        let fd = try #require(HolderRendezvousFixture.bind(at: path, listening: true, backlog: 4))
        defer { close(fd) }

        #expect(await LeftoverTmuxServerProbe.state(ofSocketAt: path) == .running)
    }

    @Test("a path with no socket reads as absent")
    func aMissingSocketReadsAsAbsent() async throws {
        let (root, cleanup) = try makeScratchRoot()
        defer { cleanup() }

        #expect(await LeftoverTmuxServerProbe.state(ofSocketAt: "\(root)/missing") == .absent)
    }

    @Test("a socket bound but not listening reads as absent")
    func aBoundButNotListeningSocketReadsAsAbsent() async throws {
        let (root, cleanup) = try makeScratchRoot()
        defer { cleanup() }
        let path = "\(root)/bound"
        let fd = try #require(HolderRendezvousFixture.bind(at: path, listening: false))
        defer { close(fd) }

        #expect(await LeftoverTmuxServerProbe.state(ofSocketAt: path) == .absent)
    }

    /// The case the probe exists for: tmux never unlinks its socket file when
    /// its server exits, so a server that is gone leaves a file nothing
    /// listens behind.
    @Test("a socket file its server left behind reads as absent")
    func anAbandonedSocketFileReadsAsAbsent() async throws {
        let (root, cleanup) = try makeScratchRoot()
        defer { cleanup() }
        let path = "\(root)/abandoned"
        #expect(HolderRendezvousFixture.bindAndAbandon(at: path))
        #expect(FileManager.default.fileExists(atPath: path),
                "precondition: the abandoned socket file must still be on disk")

        #expect(await LeftoverTmuxServerProbe.state(ofSocketAt: path) == .absent)
    }

    /// A path that cannot be connected to at all proves nothing about the
    /// server, so it reads as running and nothing is parked on its account.
    @Test("a path too long for a socket address reads as running")
    func aPathTooLongForASocketReadsAsRunning() async {
        let path = "/tmp/" + String(repeating: "a", count: 200)

        #expect(await LeftoverTmuxServerProbe.state(ofSocketAt: path) == .running)
    }

    /// The production probe, end to end: it builds the candidates from the
    /// environment and fallback root it was given and asks the socket at each.
    @Test("the production probe asks the socket under the given TMUX_TMPDIR")
    func theProductionProbeAsksTheConfiguredSocket() async throws {
        let (root, cleanup) = try makeScratchRoot()
        defer { cleanup() }
        let configured = try makeDirectory("\(root)/configured/tmux-\(getuid())")
        let fd = try #require(HolderRendezvousFixture.bind(
            at: "\(configured)/tbd-acme", listening: true, backlog: 4))
        defer { close(fd) }
        _ = try makeDirectory("\(root)/fallback/tmux-\(getuid())")
        let probe = LeftoverTmuxServerProbe.production(
            environment: ["TMUX_TMPDIR": "\(root)/configured"],
            fallbackRoot: "\(root)/fallback",
            tmuxProcesses: { _ in [] })

        #expect(await probe.state("tbd-acme") == .running)
        #expect(await probe.state("tbd-acme-other") == .absent)
    }

    /// The case the candidate list exists for: tmux falls back to `/tmp` when
    /// `TMUX_TMPDIR` names a missing directory, so a server is listening there
    /// and only the fallback can find it.
    @Test("a listener under the fallback root reads as running when TMUX_TMPDIR names a missing directory")
    func aListenerUnderTheFallbackReadsAsRunning() async throws {
        let (root, cleanup) = try makeScratchRoot()
        defer { cleanup() }
        let fallback = try makeDirectory("\(root)/fallback/tmux-\(getuid())")
        let fd = try #require(HolderRendezvousFixture.bind(
            at: "\(fallback)/tbd-acme", listening: true, backlog: 4))
        defer { close(fd) }
        let probe = LeftoverTmuxServerProbe.production(
            environment: ["TMUX_TMPDIR": "\(root)/missing"],
            fallbackRoot: "\(root)/fallback",
            tmuxProcesses: { _ in [] })

        #expect(await probe.state("tbd-acme") == .running)
    }

    /// A listener under a `TMUX_TMPDIR` that resolves is found even though
    /// the fallback is empty, and a listener under the fallback is found even
    /// though that `TMUX_TMPDIR` resolves: either one answering is running.
    @Test("a listener at either candidate reads as running")
    func aListenerAtEitherCandidateReadsAsRunning() async throws {
        let (root, cleanup) = try makeScratchRoot()
        defer { cleanup() }
        _ = try makeDirectory("\(root)/configured/tmux-\(getuid())")
        let fallback = try makeDirectory("\(root)/fallback/tmux-\(getuid())")
        let fd = try #require(HolderRendezvousFixture.bind(
            at: "\(fallback)/tbd-acme", listening: true, backlog: 4))
        defer { close(fd) }
        let probe = LeftoverTmuxServerProbe.production(
            environment: ["TMUX_TMPDIR": "\(root)/configured"],
            fallbackRoot: "\(root)/fallback",
            tmuxProcesses: { _ in [] })

        #expect(await probe.state("tbd-acme") == .running)
    }

    @Test("a server absent from every candidate reads as gone")
    func aServerAbsentFromEveryCandidateReadsAsGone() async throws {
        let (root, cleanup) = try makeScratchRoot()
        defer { cleanup() }
        let configured = try makeDirectory("\(root)/configured/tmux-\(getuid())")
        // A socket file a gone server left behind under one candidate, and
        // nothing at all under the other.
        #expect(HolderRendezvousFixture.bindAndAbandon(at: "\(configured)/tbd-acme"))
        _ = try makeDirectory("\(root)/fallback/tmux-\(getuid())")
        let probe = LeftoverTmuxServerProbe.production(
            environment: ["TMUX_TMPDIR": "\(root)/configured"],
            fallbackRoot: "\(root)/fallback",
            tmuxProcesses: { _ in [] })

        #expect(await probe.state("tbd-acme") == .absent)
    }

    @Test("an empty candidate list proves nothing and reads as running")
    func anEmptyCandidateListReadsAsRunning() async {
        #expect(await LeftoverTmuxServerProbe.state(ofSocketsAt: []) == .running)
    }

    // MARK: - How a failed connect is read

    @Test("a connect that succeeds reads as running")
    func aSuccessfulConnectReadsAsRunning() async {
        #expect(await LeftoverTmuxServerProbe.classify(connecting: {}) == .running)
    }

    /// Only positive evidence that nothing listens reads as gone.
    @Test("a missing path or a refused connect reads as absent", arguments: [ENOENT, ECONNREFUSED])
    func positiveAbsenceReadsAsAbsent(code: Int32) async {
        let state = await LeftoverTmuxServerProbe.classify {
            throw HolderClient.Error.cannotConnect(path: "/tmp/acme", errno: code)
        }

        #expect(state == .absent)
    }

    /// Every other failure proves nothing about the server: a socket the
    /// daemon may not open, a path it could not even address, and an error
    /// that is not the client's at all.
    @Test("a connect that proves nothing reads as running")
    func aConnectThatProvesNothingReadsAsRunning() async {
        struct Unrelated: Error {}
        let failures: [any Error] = [
            HolderClient.Error.cannotConnect(path: "/tmp/acme", errno: EACCES),
            HolderClient.Error.socketPathTooLong(path: "/tmp/acme", limit: 104),
            Unrelated(),
        ]

        for failure in failures {
            let state = await LeftoverTmuxServerProbe.classify { throw failure }
            #expect(state == .running, "\(failure) read as \(state)")
        }
    }

    // MARK: - The process table

    /// A tmux process of this user with this command line after `argv[0]`.
    private static func tmux(_ arguments: String...) -> LeftoverTmuxProcess {
        LeftoverTmuxProcess(
            pid: 4242, owner: getuid(), arguments: ["/opt/acme/bin/tmux"] + arguments)
    }

    /// A user id that is not this one.
    private static var anotherUser: uid_t { getuid() &+ 1 }

    /// The production probe with no candidate socket present — this daemon has
    /// no `TMUX_TMPDIR`, and the fallback root is an empty scratch directory —
    /// and `processes` as the process table.
    private func probeWithEverySocketAbsent(
        root: String, processes: [LeftoverTmuxProcess]?
    ) throws -> LeftoverTmuxServerProbe {
        _ = try makeDirectory("\(root)/fallback/tmux-\(getuid())")
        return LeftoverTmuxServerProbe.production(
            environment: [:],
            fallbackRoot: "\(root)/fallback",
            tmuxProcesses: { uid in
                #expect(uid == getuid(), "the lister was handed another user's id")
                return processes
            })
    }

    /// The case the process signal exists for: the server's socket is under a
    /// `TMUX_TMPDIR` this daemon does not have, so every candidate is absent,
    /// and the server's own command line is what still names it.
    @Test("every socket absent and a tmux process naming the server reads as running")
    func aTmuxProcessNamingTheServerReadsAsRunning() async throws {
        let (root, cleanup) = try makeScratchRoot()
        defer { cleanup() }
        let probe = try probeWithEverySocketAbsent(root: root, processes: [
            Self.tmux("-u", "-L", "tbd-acme", "set-option", "-g", "status", "off", ";",
                      "new-session", "-d", "-s", "acme"),
        ])

        #expect(await probe.state("tbd-acme") == .running)
    }

    @Test("every socket absent and a tmux process naming another server reads as gone")
    func aTmuxProcessNamingAnotherServerReadsAsGone() async throws {
        let (root, cleanup) = try makeScratchRoot()
        defer { cleanup() }
        let probe = try probeWithEverySocketAbsent(root: root, processes: [
            Self.tmux("-u", "-L", "tbd-other", "new-session", "-d"),
        ])

        #expect(await probe.state("tbd-acme") == .absent)
    }

    /// A tmux process whose command line cannot be read may be any server,
    /// so it keeps every server running, the one it would name and any other.
    @Test("every socket absent and a tmux process with an unreadable command line reads as running")
    func aTmuxProcessWithUnreadableArgumentsReadsAsRunning() async throws {
        let (root, cleanup) = try makeScratchRoot()
        defer { cleanup() }
        let probe = try probeWithEverySocketAbsent(root: root, processes: [
            Self.tmux("-L", "tbd-other"),
            LeftoverTmuxProcess(pid: 4243, owner: getuid(), arguments: nil),
        ])

        #expect(await probe.state("tbd-acme") == .running)
        #expect(await probe.state("tbd-other") == .running)
    }

    /// The case the owner exists for: on a Mac with several users, another
    /// user's tmux has a readable path and an unreadable command line. Its
    /// sockets are under its own `tmux-<uid>`, so it cannot be this server.
    @Test("every socket absent and another user's tmux process with an unreadable command line reads as gone")
    func anotherUsersTmuxProcessReadsAsGone() async throws {
        let (root, cleanup) = try makeScratchRoot()
        defer { cleanup() }
        let probe = try probeWithEverySocketAbsent(root: root, processes: [
            LeftoverTmuxProcess(pid: 4243, owner: Self.anotherUser, arguments: nil),
        ])

        #expect(await probe.state("tbd-acme") == .absent)
    }

    /// Another user's process is passed over even when its command line was
    /// read and names the server: the name is that user's server, not this one.
    @Test("another user's tmux process naming the server does not keep it running")
    func anotherUsersTmuxProcessNamingTheServerIsPassedOver() {
        let state = LeftoverTmuxServerProbe.processState(
            server: "tbd-acme",
            processes: [LeftoverTmuxProcess(
                pid: 4243, owner: Self.anotherUser,
                arguments: ["/opt/acme/bin/tmux", "-L", "tbd-acme"])],
            uid: getuid())

        #expect(state == .absent)
    }

    /// An owner that could not be read may be this user, so the process
    /// counts as one of this user's.
    @Test("a tmux process whose owner could not be read counts as this user's")
    func aTmuxProcessWithAnUnreadableOwnerCounts() {
        let unreadable = LeftoverTmuxProcess(pid: 4243, owner: nil, arguments: nil)
        let naming = LeftoverTmuxProcess(
            pid: 4244, owner: nil, arguments: ["/opt/acme/bin/tmux", "-L", "tbd-acme"])
        let other = LeftoverTmuxProcess(
            pid: 4245, owner: nil, arguments: ["/opt/acme/bin/tmux", "-L", "tbd-other"])

        #expect(LeftoverTmuxServerProbe.processState(
            server: "tbd-acme", processes: [unreadable], uid: getuid()) == .running)
        #expect(LeftoverTmuxServerProbe.processState(
            server: "tbd-acme", processes: [naming], uid: getuid()) == .running)
        #expect(LeftoverTmuxServerProbe.processState(
            server: "tbd-acme", processes: [other], uid: getuid()) == .absent)
    }

    @Test("every socket absent and no tmux process reads as gone")
    func noTmuxProcessReadsAsGone() async throws {
        let (root, cleanup) = try makeScratchRoot()
        defer { cleanup() }
        let probe = try probeWithEverySocketAbsent(root: root, processes: [])

        #expect(await probe.state("tbd-acme") == .absent)
    }

    @Test("every socket absent and a process table that could not be read reads as running")
    func anUnreadableProcessTableReadsAsRunning() async throws {
        let (root, cleanup) = try makeScratchRoot()
        defer { cleanup() }
        let probe = try probeWithEverySocketAbsent(root: root, processes: nil)

        #expect(await probe.state("tbd-acme") == .running)
    }

    /// A socket that answers settles it, so the table is not read at all.
    @Test("a socket that answers reads as running without reading the process table")
    func anAnsweringSocketSkipsTheProcessTable() async throws {
        let (root, cleanup) = try makeScratchRoot()
        defer { cleanup() }
        let fallback = try makeDirectory("\(root)/fallback/tmux-\(getuid())")
        let fd = try #require(HolderRendezvousFixture.bind(
            at: "\(fallback)/tbd-acme", listening: true, backlog: 4))
        defer { close(fd) }
        var tableReads = 0

        let state = await LeftoverTmuxServerProbe.state(
            server: "tbd-acme",
            socketPaths: ["\(fallback)/tbd-acme"],
            uid: getuid(),
            tmuxProcesses: {
                tableReads += 1
                return []
            })

        #expect(state == .running)
        #expect(tableReads == 0)
    }

    // MARK: - Which processes are tmux, and whose

    /// The lister over a fake table: pid 10 is this user's tmux, 11 another
    /// user's tmux, 12 a tmux whose owner cannot be read, 13 not tmux, and 14
    /// a process whose path cannot be read. Only 10 and 12 have their command
    /// lines asked for.
    @Test("the lister reads the command line of every tmux process but another user's")
    func theListerSkipsAnotherUsersCommandLine() {
        let uid = getuid()
        let paths: [pid_t: String] = [
            10: "/opt/acme/bin/tmux", 11: "/usr/local/bin/tmux",
            12: "/opt/acme/bin/tmux", 13: "/bin/zsh",
        ]
        let owners: [pid_t: uid_t] = [10: uid, 11: Self.anotherUser, 13: uid, 14: uid]
        var asked: [pid_t] = []

        let processes = LeftoverTmuxServerProbe.tmuxProcesses(
            among: [10, 11, 12, 13, 14],
            uid: uid,
            executablePath: { paths[$0] },
            owner: { owners[$0] },
            procArgs: { pid in
                asked.append(pid)
                return Self.procArgs(argc: 3, path: "/opt/acme/bin/tmux",
                                     argv: ["tmux", "-L", "tbd-\(pid)"], environment: [])
            })

        #expect(asked == [10, 12])
        #expect(processes == [
            LeftoverTmuxProcess(pid: 10, owner: uid, arguments: ["tmux", "-L", "tbd-10"]),
            LeftoverTmuxProcess(pid: 11, owner: Self.anotherUser, arguments: nil),
            LeftoverTmuxProcess(pid: 12, owner: nil, arguments: ["tmux", "-L", "tbd-12"]),
        ])
    }

    /// The real kernel call, against this process: the owner it reads is the
    /// one `getuid()` reports.
    @Test("the real user id read for this process is getuid()")
    func realUserIDOfThisProcess() {
        #expect(LeftoverTmuxServerProbe.realUserID(of: getpid()) == getuid())
        #expect(LeftoverTmuxServerProbe.realUserID(of: 0) == nil)
    }

    // MARK: - Which command lines name the server

    /// The separate and joined forms, alone and inside a cluster of short
    /// options, as tmux's `getopt` reads them.
    @Test("a -L naming the server is found in every form getopt accepts", arguments: [
        ["-L", "tbd-acme"],
        ["-Ltbd-acme"],
        ["-uL", "tbd-acme"],
        ["-uLtbd-acme"],
        ["-u", "-f", "/dev/null", "-L", "tbd-acme", "new-session", "-d"],
    ])
    func aMinusLNamingTheServerIsFound(arguments: [String]) {
        #expect(LeftoverTmuxServerProbe.commandLine(
            ["tmux"] + arguments, namesServer: "tbd-acme"))
    }

    /// Only `-L`'s own value counts, and only when it is the server exactly.
    @Test("a command line that does not name the server with -L is not a match", arguments: [
        ["-L", "tbd-acme-other"],
        ["-Ltbd-acme2"],
        ["-L"],
        ["-S", "/private/tmp/tmux-501/tbd-acme"],
        ["-c", "tbd-acme"],
        ["-fL", "tbd-acme"],
        ["new-session", "-s", "tbd-acme"],
        ["--", "tbd-acme"],
    ])
    func aCommandLineWithoutTheServerIsNoMatch(arguments: [String]) {
        #expect(!LeftoverTmuxServerProbe.commandLine(
            ["tmux"] + arguments, namesServer: "tbd-acme"))
    }

    @Test("argv[0] is not read as an option")
    func argvZeroIsNotAnOption() {
        #expect(!LeftoverTmuxServerProbe.commandLine(["-Ltbd-acme"], namesServer: "tbd-acme"))
    }

    // MARK: - Reading argv out of KERN_PROCARGS2

    /// A `KERN_PROCARGS2` buffer: argc, the executable path, padding, argv,
    /// then the environment.
    private static func procArgs(argc: Int32, path: String, argv: [String], environment: [String]) -> [UInt8] {
        var raw = withUnsafeBytes(of: argc) { Array($0) }
        raw += Array(path.utf8) + [0, 0, 0, 0]
        for entry in argv + environment {
            raw += Array(entry.utf8) + [0]
        }
        return raw
    }

    @Test("the argv in a KERN_PROCARGS2 buffer is read, and the environment is not")
    func argvIsReadAndTheEnvironmentIsNot() {
        let raw = Self.procArgs(
            argc: 3, path: "/opt/acme/bin/tmux", argv: ["tmux", "-L", "tbd-acme"],
            environment: ["ACME_TOKEN=secret", "PATH=/usr/bin"])

        #expect(LeftoverTmuxServerProbe.arguments(inProcArgs: raw) == ["tmux", "-L", "tbd-acme"])
    }

    /// A buffer that cannot be read is no command line at all, which the
    /// process signal counts as running.
    @Test("a KERN_PROCARGS2 buffer that ends before argv does is unreadable")
    func aTruncatedBufferIsUnreadable() {
        let whole = Self.procArgs(
            argc: 3, path: "/opt/acme/bin/tmux", argv: ["tmux", "-L", "tbd-acme"], environment: [])

        #expect(LeftoverTmuxServerProbe.arguments(inProcArgs: Array(whole.dropLast())) == nil)
        #expect(LeftoverTmuxServerProbe.arguments(inProcArgs: [3, 0]) == nil)
        #expect(LeftoverTmuxServerProbe.arguments(inProcArgs: Self.procArgs(
            argc: 0, path: "/opt/acme/bin/tmux", argv: [], environment: [])) == nil)
    }
}
