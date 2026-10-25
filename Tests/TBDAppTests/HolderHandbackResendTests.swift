import AppKit
import Clocks
import Darwin
import Foundation
import TBDShared
import Testing

@testable import TBDApp
import TestSupport

/// A holder handback that never reached the daemon is sent again, in the
/// background, a bounded number of times.
///
/// A lost `pane.detach` leaves the session's viewer claim standing, and while
/// this app lives nothing else clears it: every later attach is refused as
/// owned by a viewer. The resends carry on across reconnects, which is safe
/// because each daemon process numbers its attaches from a random base, so a
/// generation names no claim in a successor; a successor answers a detach for
/// it with success and an `attach.ready` for it with a refusal, and both are
/// answers — neither is sent again.
///
/// Tier 1 for the resends (an in-process stub and an injected clock); tier 2
/// for the panel test, which runs the real reader over a `socketpair`.
@MainActor
@Suite("A holder handback lost in transit is resent in the background", .fastPassBounded)
struct HolderHandbackResendTests {

    // `nonisolated`: the stub below reads it off the main actor.
    nonisolated private static let generation: UInt64 = 9

    /// Plays the daemon's holder RPCs from a script indexed by call number,
    /// logging every one in order.
    private final class ScriptedDaemon: HolderAttaching, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        private var detachCount = 0
        private var readyCount = 0
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

    private func handBack(
        _ daemon: ScriptedDaemon, clock: any Clock<Duration> = ImmediateClock<Duration>()
    ) async -> Task<Void, Never>? {
        await daemon.detachResendingInBackground(
            worktreeID: UUID(), paneID: "", terminalID: UUID(), generation: Self.generation,
            snapshotPreamble: Data(), clock: clock)
    }

    private func release(
        _ daemon: ScriptedDaemon, clock: any Clock<Duration> = ImmediateClock<Duration>()
    ) async -> Task<Void, Never>? {
        await daemon.releaseUnconfirmedAttach(
            worktreeID: UUID(), paneID: "", terminalID: UUID(), generation: Self.generation,
            kind: "abandoned", clock: clock)
    }

    // MARK: - The handback

    @Test("a handback lost in transit is resent until it lands")
    func aLostHandbackIsResent() async throws {
        let daemon = ScriptedDaemon(detach: { call in
            if call < 2 { throw DaemonClientError.connectionFailed("refused") }
        })

        let resending = try #require(await handBack(daemon), "a lost handback must be resent")
        await resending.value

        #expect(daemon.detaches == 3, "two lost copies, then the one that landed: \(daemon.detaches)")
    }

    @Test("a handback returns after its first attempt and resends in the background")
    func theHandbackReturnsBeforeItsResends() async throws {
        let clock = EventDrivenTestClock()
        let daemon = ScriptedDaemon(detach: { call in
            if call == 0 { throw DaemonClientError.daemonNotRunning }
        })

        let resending = try #require(await handBack(daemon, clock: clock))
        // Back already, with only the first copy sent: whoever held the ledger
        // for this handback is free to settle it now.
        #expect(daemon.detaches == 1)

        try await clock.requireAdvanceWhenArmed(
            by: HolderAttachRetry.delays[0], timeout: TestDeadlines.saturatedPass)
        await resending.value
        #expect(daemon.detaches == 2)
    }

    @Test("a handback the daemon answered is not resent, whatever it answered")
    func anAnsweredHandbackIsNotResent() async {
        let accepted = ScriptedDaemon()
        #expect(await handBack(accepted) == nil)
        #expect(accepted.detaches == 1)

        // Any RPC error is an answer — the daemon was reached.
        let refused = ScriptedDaemon(detach: { _ in
            throw DaemonClientError.rpcError("malformed request", code: nil)
        })
        #expect(await handBack(refused) == nil)
        #expect(refused.detaches == 1)
    }

    @Test("the resends are bounded by the schedule")
    func theResendsAreBounded() async throws {
        let daemon = ScriptedDaemon(detach: { _ in throw DaemonClientError.connectionFailed("refused") })

        let resending = try #require(await handBack(daemon))
        await resending.value

        #expect(daemon.detaches == HolderAttachRetry.delays.count + 1, "\(daemon.detaches)")
    }

    @Test("a cancelled resend sends nothing more")
    func aCancelledResendStops() async throws {
        let clock = EventDrivenTestClock()
        let daemon = ScriptedDaemon(detach: { _ in throw DaemonClientError.daemonNotRunning })

        let resending = try #require(await handBack(daemon, clock: clock))
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        resending.cancel()
        await resending.value

        #expect(daemon.detaches == 1, "a cancelled wait must not be followed by a resend")
    }

    // MARK: - The release of an unconfirmed attach

    @Test("a release whose requests both got answers resends nothing")
    func anAnsweredReleaseResendsNothing() async {
        // The ack refused — the daemon never minted this generation, or has
        // settled it — and the detach accepted, which it does either way.
        let daemon = ScriptedDaemon(ready: { _ in
            throw DaemonClientError.rpcError("attach.ready refused: superseded", code: nil)
        })

        #expect(await release(daemon) == nil, "a refused ack is an answer, not a reason to resend")
        #expect(daemon.events == ["ready", "detach"])
    }

    @Test("a release whose ack was lost resends the ack, then detaches again")
    func aLostReleaseAckIsResentThenDetached() async throws {
        let daemon = ScriptedDaemon(ready: { call in
            if call == 0 { throw DaemonClientError.sendFailed("short send") }
        })

        let resending = try #require(await release(daemon))
        await resending.value

        #expect(daemon.events == ["ready", "detach", "ready", "detach"], """
            an ack that never arrived can leave the attach pending, and the daemon's ready \
            timeout turns that into a claim after the first detach went by — so the ack is \
            resent and a fresh detach follows it: \(daemon.events)
            """)
    }

    @Test("a release whose resent ack is refused still detaches")
    func aRefusedResentAckStillDetaches() async throws {
        let daemon = ScriptedDaemon(ready: { call in
            if call == 0 { throw DaemonClientError.receiveFailed("reset") }
            throw DaemonClientError.rpcError("attach.ready refused: superseded", code: nil)
        })

        let resending = try #require(await release(daemon))
        await resending.value

        #expect(daemon.events == ["ready", "detach", "ready", "detach"],
                "a refused ack has reached the daemon, so the detach must follow it: \(daemon.events)")
    }

    @Test("a release whose detach was lost resends only the detach")
    func aLostReleaseDetachIsResent() async throws {
        let daemon = ScriptedDaemon(detach: { call in
            if call == 0 { throw DaemonClientError.connectionFailed("refused") }
        })

        let resending = try #require(await release(daemon))
        await resending.value

        #expect(daemon.events == ["ready", "detach", "detach"], "\(daemon.events)")
    }

    // MARK: - Through the panel

    @Test("a panel's lost handback settles the ledger after one attempt and is resent behind it")
    func aPanelSettlesItsLedgerBeforeTheResend() async throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        for fd in pair {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        }
        defer { Darwin.close(pair[1]) }
        let daemon = ScriptedDaemon(
            attachment: HolderAttachment(
                ptyFD: pair[0], generation: Self.generation, snapshotPreamble: Data()),
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
        let clock = EventDrivenTestClock()
        let coordinator = TerminalPanelRepresentable.Coordinator(clock: clock)
        coordinator.appState = state
        coordinator.panelID = terminalID
        coordinator.terminalView = view
        view.terminalDelegate = coordinator
        coordinator.holderAttachClient = daemon

        await coordinator.startHolderClient(terminalView: view)
        #expect(daemon.events == ["attach", "ready"], "the attach must be live first: \(daemon.events)")

        coordinator.cleanup()
        // The ledger settles on the first attempt: a successor waits for the
        // panel to be off the descriptor and for one detach, not for a resend
        // schedule that can run for seconds.
        let ledger = state.holderHandbackLedger
        try await waitFor("the handback's ledger entry to settle", observed: { "\(daemon.events)" }) {
            await MainActor.run { !ledger.isInFlight(terminalID: terminalID) }
        }
        #expect(daemon.detaches == 1, "the ledger waited out a resend: \(daemon.events)")

        try await clock.requireAdvanceWhenArmed(
            by: HolderAttachRetry.delays[0], timeout: TestDeadlines.saturatedPass)
        try await waitFor("the handback to be resent", observed: { "\(daemon.events)" }) {
            daemon.detaches >= 2
        }
        #expect(daemon.detaches == 2, "one lost copy, then the resend that landed: \(daemon.events)")
    }
}
