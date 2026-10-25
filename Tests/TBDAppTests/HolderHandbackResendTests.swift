import AppKit
import Clocks
import Darwin
import Foundation
import TBDShared
import Testing

@testable import TBDApp
import TestSupport

/// A holder handback that never reached the daemon is sent again — to the
/// daemon that holds the claim, and to no other.
///
/// A lost `pane.detach` leaves the session's viewer claim standing, and while
/// this app lives nothing else clears it: every later attach is refused as
/// owned by a viewer. Resending it is right only while the daemon on the other
/// end is the one that minted the generation — generations restart at 1 in
/// every daemon process, so a resend into a successor could hand back a claim
/// some other attach holds under the same number. The connection the attach
/// was vended over is the witness, and the stub here plays it.
///
/// Tier 1 for the resend itself (an in-process stub and an injected clock);
/// tier 2 for the panel test, which runs the real reader over a `socketpair`.
@MainActor
@Suite("A holder handback lost in transit is resent while the same daemon holds the claim",
       .fastPassBounded)
struct HolderHandbackResendTests {

    // `nonisolated`: the stub below reads them off the main actor.
    nonisolated private static let connection = FDSidecarClient.ConnectionID(rawValue: 3)
    nonisolated private static let generation: UInt64 = 9

    /// Plays the daemon's holder RPCs from a script indexed by call number,
    /// and the sidecar connection, which stays live until `dropConnection`.
    private final class ScriptedDaemon: HolderAttaching, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        private var detachCount = 0
        private var readyCount = 0
        private var live: FDSidecarClient.ConnectionID? = HolderHandbackResendTests.connection
        private let attachment: HolderAttachment?
        private let detachScript: @Sendable (Int) throws -> Void
        private let readyScript: @Sendable (Int) throws -> Void

        init(
            attachment: HolderAttachment? = nil,
            ready: @escaping @Sendable (Int) throws -> Void = { _ in },
            detach: @escaping @Sendable (Int) throws -> Void = { _ in }
        ) {
            self.attachment = attachment
            readyScript = ready
            detachScript = detach
        }

        var events: [String] { lock.withLock { log } }
        var detaches: Int { lock.withLock { detachCount } }

        func dropConnection() { lock.withLock { live = nil } }

        func isDaemonConnectionLive(_ connection: FDSidecarClient.ConnectionID) -> Bool {
            lock.withLock { live == connection }
        }

        func attach(
            worktreeID: UUID, paneID: String, terminalID: UUID
        ) async throws -> HolderAttachment {
            lock.withLock { log.append("attach") }
            guard let attachment else { throw DaemonClientError.attachUnavailable("unavailable") }
            return attachment
        }

        func ready(
            worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64
        ) async throws {
            let call = lock.withLock {
                log.append("ready")
                readyCount += 1
                return readyCount - 1
            }
            try readyScript(call)
        }

        func detach(
            worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64,
            snapshotPreamble: Data
        ) async throws {
            let call = lock.withLock {
                log.append("detach")
                detachCount += 1
                return detachCount - 1
            }
            try detachScript(call)
        }
    }

    private func detach(
        _ daemon: ScriptedDaemon,
        connection: FDSidecarClient.ConnectionID? = HolderHandbackResendTests.connection,
        clock: any Clock<Duration> = ImmediateClock<Duration>()
    ) async throws {
        try await daemon.detachResendingInTransit(
            worktreeID: UUID(), paneID: "", terminalID: UUID(), generation: Self.generation,
            snapshotPreamble: Data(), connection: connection, clock: clock)
    }

    // MARK: - The resend

    @Test("a detach lost in transit is resent until it lands")
    func aLostDetachIsResent() async throws {
        let daemon = ScriptedDaemon(detach: { call in
            if call < 2 { throw DaemonClientError.connectionFailed("refused") }
        })

        try await detach(daemon)

        #expect(daemon.detaches == 3, "two lost copies, then the one that landed: \(daemon.detaches)")
    }

    @Test("the resends stop when the connection that holds the claim goes away")
    func aConnectionChangeStopsTheResends() async throws {
        let clock = EventDrivenTestClock()
        let daemon = ScriptedDaemon(detach: { _ in throw DaemonClientError.daemonNotRunning })

        let sending = Task { @MainActor in
            do {
                try await self.detach(daemon, clock: clock)
                return false
            } catch {
                return true
            }
        }
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        // The daemon restarted, or the app reconnected: whoever answers next
        // may number its attaches from 1 again.
        daemon.dropConnection()
        await clock.advance(by: .seconds(60))
        let threw = await sending.value

        #expect(threw, "a detach that could not be delivered must still report its failure")
        #expect(daemon.detaches == 1,
                "a detach was resent past a connection change, where it could hand back another claim")
    }

    @Test("an answer from the daemon is not resent")
    func anAnswerIsNotResent() async {
        let daemon = ScriptedDaemon(detach: { _ in
            throw DaemonClientError.rpcError("malformed request", code: nil)
        })

        await #expect(throws: DaemonClientError.self) { try await self.detach(daemon) }
        #expect(daemon.detaches == 1)
    }

    @Test("a detach whose connection is unknown is not resent")
    func anUnknownConnectionIsNotResent() async {
        let daemon = ScriptedDaemon(detach: { _ in throw DaemonClientError.connectionFailed("refused") })

        await #expect(throws: DaemonClientError.self) {
            try await self.detach(daemon, connection: nil)
        }
        #expect(daemon.detaches == 1, "with no witness to the daemon's identity, nothing may be resent")
    }

    @Test("the resends are bounded by the schedule")
    func theResendsAreBounded() async {
        let daemon = ScriptedDaemon(detach: { _ in throw DaemonClientError.connectionFailed("refused") })

        await #expect(throws: DaemonClientError.self) { try await self.detach(daemon) }
        #expect(daemon.detaches == HolderAttachRetry.delays.count + 1, "\(daemon.detaches)")
    }

    @Test("an abandoned attach's ack lost in transit is resent before its detach")
    func aLostReleaseAckIsResent() async {
        let daemon = ScriptedDaemon(ready: { call in
            if call == 0 { throw DaemonClientError.sendFailed("short send") }
        })

        await daemon.releaseUnconfirmedAttach(
            worktreeID: UUID(), paneID: "", terminalID: UUID(), generation: Self.generation,
            kind: "abandoned", connection: Self.connection, clock: ImmediateClock<Duration>())

        #expect(daemon.events == ["ready", "ready", "detach"], """
            an ack that never arrived leaves the attach pending, and a detach does not clear a \
            pending attach: \(daemon.events)
            """)
    }

    // MARK: - Through the panel

    @Test("a panel's handback that fails in transit is resent over the attach's own connection")
    func aPanelResendsItsHandback() async throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        for fd in pair {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        }
        defer { Darwin.close(pair[1]) }
        let daemon = ScriptedDaemon(
            attachment: HolderAttachment(
                ptyFD: pair[0], generation: Self.generation, snapshotPreamble: Data(),
                daemonConnection: Self.connection),
            detach: { call in
                if call == 0 { throw DaemonClientError.connectionFailed("refused") }
            })

        let worktreeID = UUID()
        let terminalID = UUID()
        let state = AppState()
        state.terminals[worktreeID] = [Terminal(
            id: terminalID, worktreeID: worktreeID, tmuxWindowID: "", tmuxPaneID: "",
            label: "Shell", kind: .shell, transport: .holder)]
        let suiteName = "TBDAppTests.HolderHandbackResend.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let view = TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 300),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: defaults))
        let coordinator = TerminalPanelRepresentable.Coordinator(clock: ImmediateClock<Duration>())
        coordinator.appState = state
        coordinator.panelID = terminalID
        coordinator.terminalView = view
        view.terminalDelegate = coordinator
        coordinator.holderAttachClient = daemon

        await coordinator.startHolderClient(terminalView: view)
        #expect(daemon.events == ["attach", "ready"], "the attach must be live first: \(daemon.events)")

        coordinator.cleanup()
        try await waitFor("the handback to be resent", observed: { "\(daemon.events)" }) {
            daemon.detaches >= 2
        }
        let ledger = state.holderHandbackLedger
        try await waitFor("the handback to settle") {
            await MainActor.run { !ledger.isInFlight(terminalID: terminalID) }
        }

        #expect(daemon.detaches == 2, """
            a handback lost in transit must be resent while the attach's connection is live — \
            once, since the second copy landed: \(daemon.events)
            """)
    }
}
