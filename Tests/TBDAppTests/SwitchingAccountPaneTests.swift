import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// "Switch account" on a holder-backed tab, as the pane sees it: the daemon
/// parks the row, re-homes it and wakes it, and the pane must ride those flips
/// as one switch — the last frame under a caption, then one rebuild into the
/// fresh attach — rather than as a hibernation followed by a wake.
///
/// Every `AppState` here is built against a throwaway `UserDefaults` suite and
/// torn down with it — TBDApp ships unbundled, so `.standard` is the running
/// developer's real `TBDApp.plist`.
@MainActor
@Suite("Switching account in place")
struct SwitchingAccountPaneTests {

    private func withAppState(_ body: (AppState) async throws -> Void) async rethrows {
        let name = "tbd-switching-account-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(AppState(userDefaults: defaults))
    }

    private static func holderRow(
        id: UUID = UUID(), worktreeID: UUID = UUID(), parked: Bool
    ) -> Terminal {
        Terminal(
            id: id, worktreeID: worktreeID, tmuxWindowID: "", tmuxPaneID: "",
            suspendedSnapshot: parked ? "the last frame" : nil,
            hibernatedAt: parked ? Date() : nil,
            hibernateReason: parked ? .auto : nil,
            transport: .holder)
    }

    // MARK: - The record's lifetime

    @Test("the record is set before the RPC and cleared after it succeeds")
    func recordSpansASuccessfulSwap() async {
        await withAppState { state in
            let row = Self.holderRow(parked: false)
            state.terminals[row.worktreeID] = [row]
            let dest = ModelProfile(name: "Acme", kind: .oauth)
            state.modelProfiles = [ModelProfileWithUsage(profile: dest)]
            var seenDuringRPC: SwitchingAccount?
            state.terminalProfileSwapper = { @MainActor terminalID, _, _, _, _ in
                seenDuringRPC = state.switchingAccountTerminals[terminalID]
                return row
            }

            await state.swapTerminalProfile(terminalID: row.id, newProfileID: dest.id)

            #expect(seenDuringRPC == SwitchingAccount(profileName: "Acme"),
                    "the record was not in place while the RPC ran")
            #expect(state.switchingAccountTerminals[row.id] == nil,
                    "the record outlived a swap that succeeded")
        }
    }

    @Test("the record is cleared after the RPC fails")
    func recordIsClearedAfterAFailedSwap() async {
        struct Refused: Error {}
        await withAppState { state in
            let row = Self.holderRow(parked: false)
            state.terminals[row.worktreeID] = [row]
            var seenDuringRPC: SwitchingAccount?
            state.terminalProfileSwapper = { @MainActor terminalID, _, _, _, _ in
                seenDuringRPC = state.switchingAccountTerminals[terminalID]
                throw Refused()
            }

            await state.swapTerminalProfile(terminalID: row.id, newProfileID: nil)

            #expect(seenDuringRPC == SwitchingAccount(profileName: nil),
                    "the record was not in place while the failing RPC ran")
            #expect(state.switchingAccountTerminals[row.id] == nil,
                    "the record outlived a swap that failed")
            #expect(state.alertMessage != nil, "the failure was not surfaced")
        }
    }

    /// Forking opens a new tab and never parks the source row, so it has no
    /// switch to render.
    @Test("a fork sets no record")
    func forkSetsNoRecord() async {
        await withAppState { state in
            let row = Self.holderRow(parked: false)
            state.terminals[row.worktreeID] = [row]
            var seenDuringRPC: SwitchingAccount?
            state.terminalProfileSwapper = { @MainActor terminalID, _, _, _, _ in
                seenDuringRPC = state.switchingAccountTerminals[terminalID]
                return Self.holderRow(worktreeID: row.worktreeID, parked: false)
            }

            await state.swapTerminalProfile(terminalID: row.id, newProfileID: nil, mode: .fork)

            #expect(seenDuringRPC == nil)
        }
    }

    /// The cold path: a row already parked is re-homed and stays parked, so
    /// there is no park or wake to ride. A record there would flip the pane's
    /// identity to the switching one and back — two rebuilds of a pane that
    /// needs none — and strip its hibernation notice for the RPC's length.
    @Test("a swap of an already parked row sets no record and leaves the pane's identity alone")
    func coldPathSetsNoRecord() async {
        await withAppState { state in
            let row = Self.holderRow(parked: true)
            state.terminals[row.worktreeID] = [row]
            var identitiesDuringRPC: [String] = []
            var seenDuringRPC: SwitchingAccount?
            let identity = { @MainActor () -> String in
                let cached = state.terminals[row.worktreeID]!.first!
                return TerminalPanePresentation.identity(
                    for: cached, switching: state.switchingAccountTerminals[row.id],
                    attachEpoch: state.terminalAttachEpochs[row.id] ?? 0)
            }
            let before = identity()
            state.terminalProfileSwapper = { @MainActor terminalID, _, _, _, _ in
                seenDuringRPC = state.switchingAccountTerminals[terminalID]
                identitiesDuringRPC.append(identity())
                return row
            }

            await state.swapTerminalProfile(terminalID: row.id, newProfileID: nil)

            #expect(seenDuringRPC == nil, "a cold swap recorded a switch it has no park or wake for")
            #expect(identitiesDuringRPC == [before], "the pane's identity changed while the cold swap ran")
            #expect(identity() == before, "the pane's identity changed after the cold swap returned")
            #expect(TerminalPanePresentation.parkedNoticeMessage(
                for: row, switching: state.switchingAccountTerminals[row.id]) != nil)
        }
    }

    /// A swap whose park succeeded and whose re-home or wake then failed:
    /// the row is left parked, the RPC throws, and clearing the record is the
    /// pane's one rebuild — into the ordinary parked placeholder, notice and
    /// click-to-wake back, caption gone.
    @Test("a swap that fails after its park rebuilds the pane once, into the parked placeholder")
    func failureAfterTheParkRebuildsOnce() async {
        struct WakeFailed: Error {}
        await withAppState { state in
            let row = Self.holderRow(parked: false)
            state.terminals[row.worktreeID] = [row]
            let identity = { @MainActor () -> String in
                let cached = state.terminals[row.worktreeID]!.first!
                return TerminalPanePresentation.identity(
                    for: cached, switching: state.switchingAccountTerminals[row.id],
                    attachEpoch: state.terminalAttachEpochs[row.id] ?? 0)
            }
            let before = identity()
            var duringRPC: String?
            state.terminalProfileSwapper = { @MainActor _, _, _, _, _ in
                state.applyTerminalHibernationDelta(TerminalHibernationDelta(
                    terminalID: row.id, worktreeID: row.worktreeID,
                    hibernated: true, keepWarm: false, hibernateReason: .auto))
                duringRPC = identity()
                throw WakeFailed()
            }

            await state.swapTerminalProfile(terminalID: row.id, newProfileID: nil)

            let after = identity()
            let cached = state.terminals[row.worktreeID]!.first!
            #expect(duringRPC == before, "the swap's park rebuilt the switching pane")
            #expect(after != before, "the failed swap left the pane on its switching identity")
            #expect(cached.isParked)
            #expect(TerminalPanePresentation.switchingCaption(
                for: cached, switching: state.switchingAccountTerminals[row.id]) == nil,
                "the caption outlived the failed swap")
            #expect(TerminalPanePresentation.parkedNoticeMessage(
                for: cached, switching: state.switchingAccountTerminals[row.id]) != nil)
            #expect(TerminalPanePresentation.showsWakeOverlay(
                for: cached, switching: state.switchingAccountTerminals[row.id]))
        }
    }

    /// A second swap while the first is in flight: the daemon refuses it on
    /// the first's claim, and that refusal must not clear the first's record.
    @Test("a swap refused while another is in flight leaves the first's record in place")
    func overlappingSwapLeavesTheRecord() async {
        struct Refused: Error {}
        await withAppState { state in
            let row = Self.holderRow(parked: false)
            state.terminals[row.worktreeID] = [row]
            let first = SwitchingAccount(profileName: "Acme")
            state.switchingAccountTerminals[row.id] = first
            var seenDuringRPC: SwitchingAccount?
            state.terminalProfileSwapper = { @MainActor terminalID, _, _, _, _ in
                seenDuringRPC = state.switchingAccountTerminals[terminalID]
                throw Refused()
            }

            await state.swapTerminalProfile(terminalID: row.id, newProfileID: nil)

            #expect(seenDuringRPC == first, "the second swap replaced the first's record")
            #expect(state.switchingAccountTerminals[row.id] == first,
                    "the second swap's refusal cleared the first's record")
        }
    }

    // MARK: - Identity

    /// The half that keeps the pane on screen through the park: the same
    /// identity before and after the flip, so SwiftUI keeps the view it has.
    @Test("a switching pane keeps its identity across the park flip")
    func switchingIdentitySurvivesThePark() {
        let awake = Self.holderRow(parked: false)
        var parked = awake
        parked.hibernatedAt = Date()
        let switching = SwitchingAccount(profileName: "Acme")

        #expect(
            TerminalPanePresentation.identity(for: awake, switching: switching, attachEpoch: 0)
                == TerminalPanePresentation.identity(for: parked, switching: switching, attachEpoch: 0))
        // Setting the record on an awake row is not a flip either.
        #expect(
            TerminalPanePresentation.identity(for: awake, switching: nil, attachEpoch: 0)
                == TerminalPanePresentation.identity(for: awake, switching: switching, attachEpoch: 0))
    }

    /// And the other branch: an ordinary pane still rebuilds on every flip,
    /// which is how a hibernation reaches the frozen placeholder at all.
    @Test("an ordinary pane changes identity across the park flip")
    func ordinaryIdentityFollowsThePark() {
        let awake = Self.holderRow(parked: false)
        var parked = awake
        parked.hibernatedAt = Date()

        #expect(
            TerminalPanePresentation.identity(for: awake, switching: nil, attachEpoch: 0)
                != TerminalPanePresentation.identity(for: parked, switching: nil, attachEpoch: 0))
    }

    /// The one rebuild a switch does get: the swap's wake advances the epoch,
    /// and an ordinary wake does not.
    @Test("the swap's wake advances the attach epoch, and an ordinary wake does not")
    func wakeAdvancesTheEpochOnlyWhileSwitching() async {
        await withAppState { state in
            let switchingRow = Self.holderRow(parked: true)
            let ordinaryRow = Self.holderRow(worktreeID: switchingRow.worktreeID, parked: true)
            state.terminals[switchingRow.worktreeID] = [switchingRow, ordinaryRow]
            state.switchingAccountTerminals[switchingRow.id] = SwitchingAccount(profileName: nil)

            for row in [switchingRow, ordinaryRow] {
                state.applyTerminalHibernationDelta(TerminalHibernationDelta(
                    terminalID: row.id, worktreeID: row.worktreeID,
                    hibernated: false, keepWarm: false))
            }

            #expect(state.terminalAttachEpochs[switchingRow.id] == 1)
            #expect(state.terminalAttachEpochs[ordinaryRow.id] == nil)
        }
    }

    /// The reply can outrun the wake's delta. Applying the un-park from the
    /// reply advances the epoch once, and the late delta then changes nothing;
    /// a reply describing a parked row is left to the deltas.
    @Test("a reply that outruns the wake delta applies the wake once")
    func replyAppliesTheWakeOnce() async {
        await withAppState { state in
            // The swap's park delta lands while the RPC runs; its wake delta
            // does not arrive until after the reply.
            let awakeRow = Self.holderRow(parked: false)
            let worktreeID = awakeRow.worktreeID
            state.terminals[worktreeID] = [awakeRow]
            state.terminalProfileSwapper = { @MainActor _, _, _, _, _ in
                state.applyTerminalHibernationDelta(TerminalHibernationDelta(
                    terminalID: awakeRow.id, worktreeID: worktreeID,
                    hibernated: true, keepWarm: false, hibernateReason: .auto))
                return awakeRow
            }

            await state.swapTerminalProfile(terminalID: awakeRow.id, newProfileID: nil)
            #expect(state.terminalAttachEpochs[awakeRow.id] == 1)
            #expect(state.terminals[worktreeID]?.first?.isParked == false)
            state.applyTerminalHibernationDelta(TerminalHibernationDelta(
                terminalID: awakeRow.id, worktreeID: worktreeID,
                hibernated: false, keepWarm: false))
            #expect(state.terminalAttachEpochs[awakeRow.id] == 1,
                    "the late wake delta advanced the epoch a second time")
            #expect(state.terminals[worktreeID]?.first?.isParked == false)

            // A wake that failed: the reply describes a row still parked, and
            // the pane is left to the deltas.
            let failedWake = Self.holderRow(worktreeID: worktreeID, parked: false)
            var stillParked = failedWake
            stillParked.hibernatedAt = Date()
            state.terminals[worktreeID]?.append(failedWake)
            state.terminalProfileSwapper = { @MainActor _, _, _, _, _ in
                state.applyTerminalHibernationDelta(TerminalHibernationDelta(
                    terminalID: failedWake.id, worktreeID: worktreeID,
                    hibernated: true, keepWarm: false, hibernateReason: .auto))
                return stillParked
            }
            await state.swapTerminalProfile(terminalID: failedWake.id, newProfileID: nil)
            #expect(state.terminalAttachEpochs[failedWake.id] == nil)
            #expect(state.terminals[worktreeID]?.last?.isParked == true)
        }
    }

    /// A `terminal.list` refresh that lands after the wake commits un-parks
    /// the row by replacing it, and advances nothing; the wake delta that
    /// follows finds the row awake. The reply is what rebuilds the pane then —
    /// without it the pane would stay on the dead holder's attach.
    @Test("a refresh that un-parks the row mid-switch still gets the pane its one rebuild")
    func refreshThatUnparksStillRebuildsOnce() async {
        await withAppState { state in
            let row = Self.holderRow(parked: false)
            let worktreeID = row.worktreeID
            state.terminals[worktreeID] = [row]
            state.terminalProfileSwapper = { @MainActor _, _, _, _, _ in
                state.applyTerminalHibernationDelta(TerminalHibernationDelta(
                    terminalID: row.id, worktreeID: worktreeID,
                    hibernated: true, keepWarm: false, hibernateReason: .auto))
                state.adoptTerminalSnapshot([row], worktreeID: worktreeID)
                state.applyTerminalHibernationDelta(TerminalHibernationDelta(
                    terminalID: row.id, worktreeID: worktreeID,
                    hibernated: false, keepWarm: false))
                #expect(state.terminalAttachEpochs[row.id] == nil,
                        "precondition: the refresh carried the wake without advancing the epoch")
                return row
            }

            await state.swapTerminalProfile(terminalID: row.id, newProfileID: nil)

            #expect(state.terminalAttachEpochs[row.id] == 1)
        }
    }

    /// No hibernation delta at all — a subscription that dropped for the
    /// switch's length and came back with a refetch. The reply alone still
    /// rebuilds the pane, once.
    @Test("a swap whose deltas never arrive still rebuilds the pane once from the reply")
    func replyAloneRebuildsOnce() async {
        await withAppState { state in
            let row = Self.holderRow(parked: false)
            state.terminals[row.worktreeID] = [row]
            state.terminalProfileSwapper = { @MainActor _, _, _, _, _ in row }

            await state.swapTerminalProfile(terminalID: row.id, newProfileID: nil)

            #expect(state.terminalAttachEpochs[row.id] == 1)
        }
    }

    /// The tmux arm respawns the agent inside the window the pane is attached
    /// to, so its reply rebuilds nothing.
    @Test("an in-place swap of a tmux row sets no record and does not advance the attach epoch")
    func tmuxSwapDoesNotRebuild() async {
        await withAppState { state in
            let row = Terminal(
                worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1", transport: .tmux)
            state.terminals[row.worktreeID] = [row]
            var seenDuringRPC: SwitchingAccount?
            state.terminalProfileSwapper = { @MainActor terminalID, _, _, _, _ in
                seenDuringRPC = state.switchingAccountTerminals[terminalID]
                return row
            }

            await state.swapTerminalProfile(terminalID: row.id, newProfileID: nil)

            #expect(seenDuringRPC == nil, "a tmux swap recorded a switch it never parks for")
            #expect(state.terminalAttachEpochs[row.id] == nil)
        }
    }

    // MARK: - The parked chrome

    @Test("a switching parked row composes no hibernation notice and offers no click-to-wake")
    func switchingParkedRowHasNoHibernationChrome() {
        let parked = Self.holderRow(parked: true)
        let switching = SwitchingAccount(profileName: "Acme")

        #expect(TerminalPanePresentation.parkedNoticeMessage(for: parked, switching: switching) == nil)
        #expect(!TerminalPanePresentation.showsWakeOverlay(for: parked, switching: switching))
        #expect(TerminalPanePresentation.switchingCaption(for: parked, switching: switching)
                == "Switching account to Acme…")
    }

    @Test("an ordinary parked row keeps its hibernation notice and click-to-wake")
    func ordinaryParkedRowKeepsItsChrome() {
        let parked = Self.holderRow(parked: true)

        #expect(TerminalPanePresentation.parkedNoticeMessage(for: parked, switching: nil)
                == HibernatedBannerModel.message(for: .auto))
        #expect(TerminalPanePresentation.showsWakeOverlay(for: parked, switching: nil))
        #expect(TerminalPanePresentation.switchingCaption(for: parked, switching: nil) == nil)
    }

    @Test("the ambient account's caption names no profile")
    func ambientCaption() {
        #expect(SwitchingAccount(profileName: nil).caption == "Switching account…")
    }
}

extension AccessibilityBridgeSerialized {
    /// The caption as drawn: mounted offscreen and read back through the
    /// accessibility tree, both branches.
    @MainActor
    @Suite("Switching account caption, rendered")
    struct SwitchingAccountCaptionRenderTests {
        private static let size = NSSize(width: 480, height: 160)

        private static func parkedRow() -> Terminal {
            Terminal(
                worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
                suspendedSnapshot: "the last frame", hibernatedAt: Date(),
                hibernateReason: .auto, transport: .holder)
        }

        private static func labels(in host: OffscreenHost<SwitchingAccountCaptionOverlay>) -> String {
            host.accessibilityTreeDescription()
        }

        @Test("a switching parked row renders the caption")
        func switchingParkedRowRendersTheCaption() async {
            await withAccessibilityBridge {
                let host = OffscreenHost(
                    root: SwitchingAccountCaptionOverlay(
                        terminal: Self.parkedRow(),
                        switching: SwitchingAccount(profileName: "Acme")),
                    size: Self.size)
                defer { host.tearDown() }
                _ = await host.settle {
                    host.accessibilityIdentifiers().contains(
                        SwitchingAccountCaptionOverlay.accessibilityID)
                }

                let seen = host.accessibilityIdentifiers()
                let tree = Self.labels(in: host)
                #expect(seen.contains(SwitchingAccountCaptionOverlay.accessibilityID),
                        Comment(rawValue: tree))
                #expect(tree.contains("Switching account to Acme"), Comment(rawValue: tree))
                #expect(!tree.contains("Hibernated"), Comment(rawValue: tree))
            }
        }

        @Test("an ordinary parked row renders no caption")
        func ordinaryParkedRowRendersNoCaption() async {
            await withAccessibilityBridge {
                let host = OffscreenHost(
                    root: SwitchingAccountCaptionOverlay(terminal: Self.parkedRow(), switching: nil),
                    size: Self.size)
                defer { host.tearDown() }
                await host.pump(times: 20)

                let seen = host.accessibilityIdentifiers()
                #expect(!seen.contains(SwitchingAccountCaptionOverlay.accessibilityID),
                        Comment(rawValue: Self.labels(in: host)))
            }
        }
    }
}
