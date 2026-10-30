import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// The app's half of the holder claim reconcile
/// (docs/specs/2026-10-25-holder-claim-reconcile-design.md): which sweeps
/// `sweepHolderClaims` sends, what they carry, and the Settings toggle's
/// write. "A tick" here is one call to `sweepHolderClaims`, which is all the
/// poll tick adds; "a connect" is `holderClaimSweepDidConnect`, which both
/// connect sites call.
///
/// Driven through `holderClaimSweepSender` and
/// `holderClaimReconcileFlagSetter`; there is no fake transport. Every
/// `AppState` runs over its own throwaway `UserDefaults` suite — `.standard`
/// on this unbundled executable is the developer's real `TBDApp.plist`.
///
/// An app that has numbered no attach sends no sweep, so every test that
/// expects one numbers an attach first (`numberAnAttach`).
@MainActor
@Suite("Holder claim sweep")
struct HolderClaimSweepTests {
    private func withAppState(_ body: (AppState) async throws -> Void) async rethrows {
        let suite = TestDefaultsSuite("tbd-holder-claim-sweep")
        let defaults = suite.defaults
        defer { suite.tearDown() }
        try await body(AppState(userDefaults: defaults))
    }

    private static let unknownMethod = DaemonClientError.rpcError(
        "Unknown method: \(RPCMethod.holderReconcileClaims)", code: nil)

    /// Numbers one attach and ends its hold, the way a panel that attached and
    /// closed leaves the ledger: `throughSeq` becomes 1 and nothing is held.
    private static func numberAnAttach(_ state: AppState) {
        let ledger = state.holderHandbackLedger
        ledger.endHold(ledger.beginHold(terminalID: UUID()))
    }

    @Test func aTickSendsTheSnapshot() async throws {
        try await withAppState { state in
            state.isConnected = true
            let ledger = state.holderHandbackLedger
            let first = UUID()
            let second = UUID()
            _ = ledger.beginHold(terminalID: first)
            _ = ledger.beginHold(terminalID: second)
            // An ended hold leaves `held` but still counts toward `throughSeq`.
            ledger.endHold(ledger.beginHold(terminalID: UUID()))
            var sent: [HolderReconcileClaimsParams] = []
            var atSend: [HeldSnapshot] = []
            state.holderClaimSweepSender = { @MainActor params in
                sent.append(params)
                atSend.append(HeldSnapshot(ledger))
                return HolderReconcileClaimsResult()
            }

            await state.sweepHolderClaims()

            #expect(sent.count == 1)
            let params = try #require(sent.first)
            let snapshot = try #require(atSend.first)
            #expect(Set(params.held) == snapshot.held)
            #expect(params.throughSeq == snapshot.throughSeq)
            #expect(Set(params.held) == [first, second])
            #expect(params.throughSeq == 3)
            #expect(params.appPID == getpid())
        }
    }

    @Test func connectSendsASweep() async {
        await withAppState { state in
            state.isConnected = true
            Self.numberAnAttach(state)
            var sent = 0
            state.holderClaimSweepSender = { @MainActor _ in
                sent += 1
                return HolderReconcileClaimsResult()
            }

            await state.holderClaimSweepDidConnect(sweepNow: true)

            #expect(sent == 1)
        }
    }

    /// The poll tick's reconnect sends no sweep of its own: the same tick's
    /// sweep follows it, and one tick never sends two.
    @Test func aTickReconnectLeavesTheSweepToTheTick() async {
        await withAppState { state in
            state.isConnected = true
            Self.numberAnAttach(state)
            var sent = 0
            state.holderClaimSweepSender = { @MainActor _ in
                sent += 1
                return HolderReconcileClaimsResult()
            }

            await state.holderClaimSweepDidConnect(sweepNow: false)
            #expect(sent == 0)

            await state.sweepHolderClaims()
            #expect(sent == 1)
        }
    }

    @Test func noSweepWhileDisconnected() async {
        await withAppState { state in
            Self.numberAnAttach(state)
            var sent = 0
            state.holderClaimSweepSender = { @MainActor _ in
                sent += 1
                return HolderReconcileClaimsResult()
            }

            #expect(state.isConnected == false)
            await state.sweepHolderClaims()
            await state.holderClaimSweepDidConnect(sweepNow: true)
            #expect(sent == 0)

            // The control: the same state, connected, does send.
            state.isConnected = true
            await state.sweepHolderClaims()
            #expect(sent == 1)
        }
    }

    @Test func unknownMethodStopsSweepsUntilReconnect() async {
        await withAppState { state in
            state.isConnected = true
            Self.numberAnAttach(state)
            var sent = 0
            state.holderClaimSweepSender = { @MainActor _ in
                sent += 1
                if sent == 1 { throw Self.unknownMethod }
                return HolderReconcileClaimsResult()
            }

            await state.sweepHolderClaims()
            #expect(sent == 1)
            #expect(state.holderClaimSweepUnsupported)

            await state.sweepHolderClaims()
            await state.sweepHolderClaims()
            #expect(sent == 1, "an older daemon is not asked again until the next connect")

            await state.holderClaimSweepDidConnect(sweepNow: false)
            #expect(state.holderClaimSweepUnsupported == false)
            await state.sweepHolderClaims()
            await state.sweepHolderClaims()
            #expect(sent == 3)
        }
    }

    /// A daemon replaced under a running app may never register as a
    /// disconnect, since every RPC rides a one-shot connection, so "until the
    /// next connect" could mean for good. The state subscription restarting
    /// is the visible sign of a new daemon, and it allows sweeps again too.
    @Test func aNewSubscriptionAllowsSweepsAgain() async {
        await withAppState { state in
            state.isConnected = true
            Self.numberAnAttach(state)
            // `startSubscription` re-seeds program status from the daemon;
            // answered here, so the test sends no RPC of its own for it.
            state.programStatusListFetcher = { @MainActor in [] }
            var sent = 0
            state.holderClaimSweepSender = { @MainActor _ in
                sent += 1
                if sent == 1 { throw Self.unknownMethod }
                return HolderReconcileClaimsResult()
            }

            await state.sweepHolderClaims()
            #expect(state.holderClaimSweepUnsupported)
            await state.sweepHolderClaims()
            #expect(sent == 1)

            state.startSubscription()
            // Only the flag is under test: the subscription it started has no
            // daemon to reach, and is ended at once.
            state.stopSubscription()

            #expect(state.holderClaimSweepUnsupported == false, """
                a restarted subscription left claim sweeps off, so a daemon replaced without a \
                noticed disconnect never gets one
                """)
            await state.sweepHolderClaims()
            #expect(sent == 2)
        }
    }

    /// Before the app numbers its first attach, `throughSeq` is 0, and no
    /// claim carries a seq at or below it, so a sweep could take nothing back
    /// and none is sent — on a tick or on a connect. The first numbered
    /// attach turns them on.
    @Test func noSweepBeforeAnAttachIsNumbered() async throws {
        try await withAppState { state in
            state.isConnected = true
            var sent: [HolderReconcileClaimsParams] = []
            state.holderClaimSweepSender = { @MainActor params in
                sent.append(params)
                return HolderReconcileClaimsResult()
            }

            await state.sweepHolderClaims()
            await state.holderClaimSweepDidConnect(sweepNow: true)
            #expect(sent.isEmpty, "a sweep through seq 0 was sent, though it can cover no claim")
            #expect(state.holderClaimSweepInFlight == false)

            // The control: one numbered attach, and the same tick sends.
            Self.numberAnAttach(state)
            await state.sweepHolderClaims()

            #expect(sent.count == 1)
            let params = try #require(sent.first)
            #expect(params.throughSeq == 1)
            #expect(params.held.isEmpty)
        }
    }

    /// A transport error, and a daemon error that is not "unknown method",
    /// are both ignored: the next tick sends again.
    @Test(arguments: [
        DaemonClientError.connectionFailed("refused"),
        DaemonClientError.rpcError("the holder registry is busy", code: nil),
    ])
    func aFailedSweepIsIgnored(failure: DaemonClientError) async {
        await withAppState { state in
            state.isConnected = true
            Self.numberAnAttach(state)
            var sent = 0
            state.holderClaimSweepSender = { @MainActor _ in
                sent += 1
                if sent == 1 { throw failure }
                return HolderReconcileClaimsResult()
            }

            await state.sweepHolderClaims()
            #expect(sent == 1)
            #expect(state.holderClaimSweepUnsupported == false)
            #expect(state.holderClaimSweepInFlight == false)

            await state.sweepHolderClaims()
            #expect(sent == 2)
        }
    }

    @Test func aSlowSweepIsNotDoubled() async {
        await withAppState { state in
            state.isConnected = true
            Self.numberAnAttach(state)
            let entered = HolderTestGate()
            let release = HolderTestGate()
            var sent = 0
            state.holderClaimSweepSender = { @MainActor _ in
                sent += 1
                await entered.open()
                await release.wait()
                return HolderReconcileClaimsResult()
            }

            let slow = Task { @MainActor in await state.sweepHolderClaims() }
            await entered.wait()
            #expect(state.holderClaimSweepInFlight)

            await state.sweepHolderClaims()
            await state.sweepHolderClaims()
            await state.holderClaimSweepDidConnect(sweepNow: true)
            #expect(sent == 1, "a sweep still waiting on the daemon is never joined by another")

            await release.open()
            await slow.value
            #expect(state.holderClaimSweepInFlight == false)

            await state.sweepHolderClaims()
            #expect(sent == 2)
        }
    }

    @Test func theToggleWritesTheFlag() async {
        await withAppState { state in
            var written: [Bool] = []
            var refreshes = 0
            state.holderClaimReconcileFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                var capabilities = DaemonCapabilitiesResult(controlModeEnabled: false)
                capabilities.holderClaimReconcileEnabled = true
                return capabilities
            }

            await state.setHolderClaimReconcileEnabled(true)

            #expect(written == [true])
            #expect(refreshes == 1, "the toggle must read the daemon back, not its own guess")
            #expect(state.daemonCapabilities?.holderClaimReconcileEnabled == true)
        }
    }

    @Test func aFailedToggleWriteIsSurfacedWithoutARefresh() async {
        struct Boom: Error {}
        await withAppState { state in
            var refreshes = 0
            state.holderClaimReconcileFlagSetter = { @MainActor _ in throw Boom() }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return nil
            }

            await state.setHolderClaimReconcileEnabled(true)

            #expect(refreshes == 0, "a failed write must not be followed by a refresh")
            #expect(state.daemonCapabilities == nil)
            #expect(state.alertMessage != nil)
        }
    }
}
