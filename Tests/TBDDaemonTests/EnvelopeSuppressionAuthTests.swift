import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Who may speak in a human's voice.
///
/// Every row here is about AUTHORITY, and the declared actor never changes an
/// outcome in any of them — that is the whole point. The connection is what is
/// authenticated; the request can only ask.
@Suite("envelope suppression is authenticated on the connection")
struct EnvelopeSuppressionAuthTests {

    /// A `ProcessSignaller` whose answers the test chooses, so a `.same` verdict
    /// and each way of failing one can be stated without a real process.
    ///
    /// The signalling requirements are inert: this suite never asks for a
    /// signal, and a stub that could send one would be a stub that could kill
    /// something on a mistake.
    private struct StubSignaller: ProcessSignaller {
        var alive = true
        var startedAt: Date?
        var command: String?
        func isAlive(_ pid: Int32) -> Bool { alive }
        func startTime(_ pid: Int32) -> Date? { startedAt }
        func commandLine(_ pid: Int32) -> String? { command }
        func stat(_ pid: Int32) -> String? { nil }
        func children(ofServerPID serverPID: Int32) -> [Int32] { [] }
        func terminate(_ pid: Int32) {}
        func forceKill(_ pid: Int32) {}
    }

    private static let appStart = Date(timeIntervalSince1970: 1_800_000_000)
    private static let appCommand = "/Applications/TBD.app/Contents/MacOS/TBDApp"
    private static let appPID: Int32 = 909

    private static func recordedApp() -> ProcessIdentity {
        ProcessIdentity(pid: appPID, startedAt: appStart, commandLine: appCommand)
    }

    private static func liveSignaller() -> StubSignaller {
        StubSignaller(alive: true, startedAt: appStart, command: appCommand)
    }

    private func harness(
        recorded: ProcessIdentity? = recordedApp(),
        signaller: any ProcessSignaller = liveSignaller()
    ) async throws -> SendHarness {
        try await SendHarness.make(
            recordedAppIdentity: { recorded },
            processSignaller: signaller)
    }

    // MARK: - The one row that authenticates

    /// The app's own connection, verified: the person is speaking in their own
    /// voice, exactly as at the keyboard, and Claude sees only the message.
    @Test func theAppsOwnConnectionSuppressesTheEnvelope() async throws {
        let harness = try await harness()
        let response = try await harness.send(
            TerminalSendParams(
                terminalID: harness.terminal.id, text: "hi", submit: true,
                envelope: .suppressed),
            actor: .app,
            connection: RPCConnectionContext(peerPID: Self.appPID))

        #expect(response.success, "error was: \(response.error ?? "none")")
        #expect(harness.tmux.pastedBodies == ["hi"])
    }

    // MARK: - The load-bearing negatives

    /// **A CLI connection.** Same request, same `{"kind":"app"}` actor, a
    /// different pid: the envelope stays. This is the row that stops any local
    /// process from typing as a human.
    @Test func aCLIConnectionAskingForSuppressionStillGetsTheEnvelope() async throws {
        let harness = try await harness()
        _ = try await harness.send(
            TerminalSendParams(
                terminalID: harness.terminal.id, text: "hi", submit: true,
                envelope: .suppressed),
            actor: .app,
            connection: RPCConnectionContext(peerPID: 4321))

        #expect(try #require(harness.tmux.pastedBodies.first).hasPrefix("<tbd-dispatch"))
    }

    /// An unreadable peer pid is not an app connection. It is "not established",
    /// and this check has no third answer.
    @Test func anUnreadablePeerPIDKeepsTheEnvelope() async throws {
        let harness = try await harness()
        _ = try await harness.send(
            TerminalSendParams(
                terminalID: harness.terminal.id, text: "hi", submit: true,
                envelope: .suppressed),
            actor: .app,
            connection: RPCConnectionContext(peerPID: nil))
        #expect(try #require(harness.tmux.pastedBodies.first).hasPrefix("<tbd-dispatch"))
    }

    /// No context at all — every non-socket caller of `handleRaw`, and the HTTP
    /// server — is the same answer as an unreadable pid.
    @Test func noConnectionContextKeepsTheEnvelope() async throws {
        let harness = try await harness()
        _ = try await harness.send(
            TerminalSendParams(
                terminalID: harness.terminal.id, text: "hi", submit: true,
                envelope: .suppressed),
            actor: .app,
            connection: nil)
        #expect(try #require(harness.tmux.pastedBodies.first).hasPrefix("<tbd-dispatch"))
    }

    /// The sidecar has no client: nothing was recorded, so there is nothing the
    /// peer pid could match.
    @Test func noRecordedSidecarClientKeepsTheEnvelope() async throws {
        let harness = try await harness(recorded: nil)
        _ = try await harness.send(
            TerminalSendParams(
                terminalID: harness.terminal.id, text: "hi", submit: true,
                envelope: .suppressed),
            actor: .app,
            connection: RPCConnectionContext(peerPID: Self.appPID))
        #expect(try #require(harness.tmux.pastedBodies.first).hasPrefix("<tbd-dispatch"))
    }

    /// **Pid reuse.** The pid matches what was recorded and the process at that
    /// number is somebody else. Each way of failing `.same` is its own row,
    /// because each is a different way the second half can save the first.
    @Test func aReVerifyThatIsNotSameKeepsTheEnvelope() async throws {
        let cases: [(String, StubSignaller)] = [
            ("not-running", StubSignaller(alive: false, startedAt: nil, command: nil)),
            ("start-time-unreadable",
             StubSignaller(alive: true, startedAt: nil, command: Self.appCommand)),
            ("start-time-mismatch",
             StubSignaller(alive: true, startedAt: Self.appStart.addingTimeInterval(5),
                           command: Self.appCommand)),
            ("command-unreadable",
             StubSignaller(alive: true, startedAt: Self.appStart, command: nil)),
            ("foreign-executable",
             StubSignaller(alive: true, startedAt: Self.appStart, command: "/bin/zsh")),
        ]
        for (name, signaller) in cases {
            let harness = try await harness(signaller: signaller)
            _ = try await harness.send(
                TerminalSendParams(
                    terminalID: harness.terminal.id, text: "hi", submit: true,
                    envelope: .suppressed),
                actor: .app,
                connection: RPCConnectionContext(peerPID: Self.appPID))
            #expect(
                try #require(harness.tmux.pastedBodies.first).hasPrefix("<tbd-dispatch"),
                "\(name) must keep the envelope")
        }
    }

    // MARK: - The declared actor never decides anything

    /// The authenticated connection suppresses however the request labels
    /// itself, and an unauthenticated one does not however it labels itself.
    /// Together these two say the actor field carries no authority at all.
    @Test func theDeclaredActorChangesNothingInEitherDirection() async throws {
        let authenticated = try await harness()
        _ = try await authenticated.send(
            TerminalSendParams(
                terminalID: authenticated.terminal.id, text: "hi", submit: true,
                envelope: .suppressed),
            actor: ActuationActor.session(worktree: "W", terminal: "T"),
            connection: RPCConnectionContext(peerPID: Self.appPID))
        #expect(authenticated.tmux.pastedBodies == ["hi"])

        let stranger = try await harness()
        _ = try await stranger.send(
            TerminalSendParams(
                terminalID: stranger.terminal.id, text: "hi", submit: true,
                envelope: .suppressed),
            actor: .app,
            connection: RPCConnectionContext(peerPID: 4321))
        #expect(try #require(stranger.tmux.pastedBodies.first).hasPrefix("<tbd-dispatch"))
    }

    /// A send that does not ASK for suppression never pays for the identity
    /// check, and gets the envelope on an authenticated connection like anyone
    /// else. The check runs on a composer send and nowhere else.
    @Test func anUnaskedSendKeepsTheEnvelopeOnTheAppsOwnConnection() async throws {
        let harness = try await harness()
        _ = try await harness.send(
            TerminalSendParams(terminalID: harness.terminal.id, text: "hi", submit: true),
            actor: .app,
            connection: RPCConnectionContext(peerPID: Self.appPID))
        #expect(try #require(harness.tmux.pastedBodies.first).hasPrefix("<tbd-dispatch"))
    }
}

/// `ProcessIdentity.ofPeer` over a real connected socket, so the one thing this
/// design rests on — that the kernel, not the caller, names the peer — is
/// checked rather than assumed.
@Suite("peer identity over a real socket")
struct PeerIdentityOverSocketpairTests {
    @Test func aSocketpairPeerIsThisProcess() throws {
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let identity = try #require(
            ProcessIdentity.ofPeer(onSocket: fds[0], signaller: ProductionProcessSignaller()))
        #expect(identity.pid == ProcessInfo.processInfo.processIdentifier)
    }
}
