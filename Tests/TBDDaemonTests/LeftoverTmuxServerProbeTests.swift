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

    // MARK: - Where tmux puts its socket

    @Test("the socket path honours TMUX_TMPDIR and names tmux-<uid>/<server>")
    func socketPathHonoursTMUXTMPDIR() {
        let path = LeftoverTmuxServerProbe.socketPath(
            server: "tbd-acme", environment: ["TMUX_TMPDIR": "/tmp/acme-tmux"], uid: 501)

        #expect(path == "/tmp/acme-tmux/tmux-501/tbd-acme")
    }

    /// tmux's own fallback when `TMUX_TMPDIR` is unset — and an empty value is
    /// unset to tmux too.
    @Test("the socket path falls back to /private/tmp when TMUX_TMPDIR is unset or empty",
          arguments: [[:], ["TMUX_TMPDIR": ""]] as [[String: String]])
    func socketPathFallsBack(environment: [String: String]) {
        let path = LeftoverTmuxServerProbe.socketPath(
            server: "tbd-acme", environment: environment, uid: 501)

        #expect(path == "/private/tmp/tmux-501/tbd-acme")
    }

    @Test("the socket path names the daemon's own uid by default")
    func socketPathNamesTheCurrentUID() {
        let path = LeftoverTmuxServerProbe.socketPath(
            server: "tbd-acme", environment: ["TMUX_TMPDIR": "/tmp/acme-tmux"])

        #expect(path == "/tmp/acme-tmux/tmux-\(getuid())/tbd-acme")
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

    /// The production probe, end to end: it builds the path from the
    /// environment it was given and asks the socket there.
    @Test("the production probe asks the socket under the given TMUX_TMPDIR")
    func theProductionProbeAsksTheConfiguredSocket() async throws {
        let (root, cleanup) = try makeScratchRoot()
        defer { cleanup() }
        let directory = "\(root)/tmux-\(getuid())"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        let fd = try #require(HolderRendezvousFixture.bind(
            at: "\(directory)/tbd-acme", listening: true, backlog: 4))
        defer { close(fd) }
        let probe = LeftoverTmuxServerProbe.production(environment: ["TMUX_TMPDIR": root])

        #expect(await probe.state("tbd-acme") == .running)
        #expect(await probe.state("tbd-acme-other") == .absent)
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
