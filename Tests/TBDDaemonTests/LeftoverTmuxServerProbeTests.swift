import Darwin
import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib

/// `LeftoverTmuxServerProbe` — whether a tmux server an earlier build started
/// is still running, read off its socket without running tmux.
///
/// Every socket here is real and lives under a short scratch root
/// (`fencedScratchRoot`), because a path over darwin's 104-byte `sun_path`
/// limit never reaches a connect at all and would green on an answer that
/// never went near a socket. No tmux binary is run.
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
            fallbackRoot: "\(root)/fallback")

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
            fallbackRoot: "\(root)/fallback")

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
            fallbackRoot: "\(root)/fallback")

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
            fallbackRoot: "\(root)/fallback")

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
}
