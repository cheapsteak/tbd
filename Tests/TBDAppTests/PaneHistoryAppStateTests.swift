import Foundation
import Testing
import TBDShared

@testable import TBDApp

// MARK: - AppState integration
//
// PaneHistory (== MRUHistory<PaneContent>, see TBDShared/PanelSurface/MRUHistory.swift)
// moved to TBDShared so it can be reused generically. These tests exercise
// AppState's use of it and stay here since AppState (SwiftUI/AppKit) is
// TBDApp-only and isn't reachable from TBDSharedTests.

@MainActor
@Suite("PaneHistory AppState integration")
struct PaneHistoryAppStateTests {
    private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "TBDAppTests.PaneHistory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    @Test func persistenceRoundTrip() {
        withIsolatedDefaults { defaults in
            let slotID = UUID()
            var history = PaneHistory()
            history.recordReplacement(
                outgoing: .liveTranscript(id: slotID, terminalID: UUID()),
                incoming: .codeViewer(id: slotID, path: "/a.md")
            )

            let state = AppState(userDefaults: defaults)
            state.paneHistories[slotID] = history

            // A fresh AppState on the same suite restores the identical history.
            let restored = AppState(userDefaults: defaults)
            #expect(restored.paneHistories[slotID] == history)
        }
    }

    @Test func recordPaneReplacementPushesIntoKeyedHistory() {
        withIsolatedDefaults { defaults in
            let state = AppState(userDefaults: defaults)
            let slotID = UUID()

            state.recordPaneReplacement(.init(
                paneID: slotID,
                outgoing: .codeViewer(id: slotID, path: "/a"),
                incoming: .codeViewer(id: slotID, path: "/b")
            ))

            #expect(state.paneHistories[slotID]?.canGoBack == true)
        }
    }

    @Test func popHistoryForRemovedPaneRestoresPreviousContent() {
        withIsolatedDefaults { defaults in
            let state = AppState(userDefaults: defaults)
            let slotID = UUID()
            let viewer = PaneContent.codeViewer(id: slotID, path: "/a")
            let transcript = PaneContent.liveTranscript(id: slotID, terminalID: UUID())
            state.recordPaneReplacement(.init(paneID: slotID, outgoing: viewer, incoming: transcript))

            // Toggle-off on a reused slot restores the pre-transcript content
            // instead of destroying the pane; the transcript stays reachable.
            #expect(state.popHistoryForRemovedPane(slotID) == viewer)
            #expect(state.paneHistories[slotID]?.canGoForward == true)

            // Only the transcript remains besides the cursor entry: the pane
            // really goes away, history with it.
            #expect(state.popHistoryForRemovedPane(slotID) == nil)
            #expect(state.paneHistories[slotID] == nil)
        }
    }

    @Test func popHistoryForRemovedPaneSkipsChainedTranscripts() {
        withIsolatedDefaults { defaults in
            let state = AppState(userDefaults: defaults)
            let slotID = UUID()
            let viewer = PaneContent.codeViewer(id: slotID, path: "/a")
            let transcriptT1 = PaneContent.liveTranscript(id: slotID, terminalID: UUID())
            let transcriptT2 = PaneContent.liveTranscript(id: slotID, terminalID: UUID())
            state.recordPaneReplacement(.init(paneID: slotID, outgoing: viewer, incoming: transcriptT1))
            state.recordPaneReplacement(.init(paneID: slotID, outgoing: transcriptT1, incoming: transcriptT2))

            // Toggling T2's transcript off must not resurrect T1's transcript.
            #expect(state.popHistoryForRemovedPane(slotID) == viewer)
        }
    }

    @Test func popHistoryForRemovedPaneRemovesWhenOnlyTranscriptsRemain() {
        withIsolatedDefaults { defaults in
            let state = AppState(userDefaults: defaults)
            let slotID = UUID()
            let transcriptT1 = PaneContent.liveTranscript(id: slotID, terminalID: UUID())
            let transcriptT2 = PaneContent.liveTranscript(id: slotID, terminalID: UUID())
            state.recordPaneReplacement(.init(paneID: slotID, outgoing: transcriptT1, incoming: transcriptT2))

            // Nothing non-transcript to restore: pane really closes, history goes.
            #expect(state.popHistoryForRemovedPane(slotID) == nil)
            #expect(state.paneHistories[slotID] == nil)
        }
    }

    @Test func popHistoryForRemovedPaneFindsViewerOnTheNewerSide() {
        withIsolatedDefaults { defaults in
            let state = AppState(userDefaults: defaults)
            let slotID = UUID()
            let transcript = PaneContent.liveTranscript(id: slotID, terminalID: UUID())
            let viewer = PaneContent.codeViewer(id: slotID, path: "/a")
            // transcript → viewer, then jump BACK onto the transcript entry.
            state.recordPaneReplacement(.init(paneID: slotID, outgoing: transcript, incoming: viewer))
            _ = state.paneHistories[slotID]?.goBack()

            // No older non-transcript entry — the newer viewer is restored.
            #expect(state.popHistoryForRemovedPane(slotID) == viewer)
        }
    }

    @Test func restoreDropsMalformedPersistedHistory() {
        withIsolatedDefaults { defaults in
            let slotID = UUID()
            var history = PaneHistory()
            history.recordReplacement(
                outgoing: .codeViewer(id: slotID, path: "/a"),
                incoming: .codeViewer(id: slotID, path: "/b")
            )

            let state = AppState(userDefaults: defaults)
            state.paneHistories = [slotID: history]

            // Corrupt the persisted blob: cursor beyond entries.count.
            let key = "com.tbd.app.paneHistories"
            let blob = String(data: defaults.data(forKey: key)!, encoding: .utf8)!
                .replacingOccurrences(of: "\"cursor\":0", with: "\"cursor\":9")
            defaults.set(Data(blob.utf8), forKey: key)

            let restored = AppState(userDefaults: defaults)
            #expect(restored.paneHistories[slotID] == nil,
                    "an out-of-range cursor must not be restored (crashes entries[cursor])")
        }
    }

    @Test func prunePaneHistoriesDropsOrphansKeepsLiveSlots() {
        withIsolatedDefaults { defaults in
            let state = AppState(userDefaults: defaults)
            let tabID = UUID()
            let liveSlotID = UUID()
            let orphanID = UUID()
            state.layouts[tabID] = .split(
                id: UUID(), direction: .horizontal,
                children: [
                    .pane(.terminal(terminalID: tabID)),
                    .pane(.codeViewer(id: liveSlotID, path: "/a")),
                ],
                ratios: [0.5, 0.5]
            )
            var history = PaneHistory()
            history.recordReplacement(
                outgoing: .codeViewer(id: liveSlotID, path: "/old"),
                incoming: .codeViewer(id: liveSlotID, path: "/a")
            )
            state.paneHistories = [liveSlotID: history, orphanID: history]

            state.prunePaneHistories()

            #expect(state.paneHistories[liveSlotID] == history)
            #expect(state.paneHistories[orphanID] == nil, "orphaned histories must not accumulate")
        }
    }
}
