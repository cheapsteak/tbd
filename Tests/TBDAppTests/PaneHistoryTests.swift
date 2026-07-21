import Foundation
import Testing

@testable import TBDApp

@Suite("PaneHistory")
struct PaneHistoryTests {
    private let slotID = UUID()

    private func viewer(_ path: String) -> PaneContent {
        .codeViewer(id: slotID, path: path)
    }

    @Test func recordReplacement_bootstrapsWithOutgoingThenIncoming() {
        var history = PaneHistory()
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)

        history.recordReplacement(outgoing: viewer("/a"), incoming: viewer("/b"))

        #expect(history.entries == [viewer("/a"), viewer("/b")])
        #expect(history.canGoBack)
        #expect(!history.canGoForward)
    }

    @Test func recordReplacement_identicalContentIsNoOp() {
        var history = PaneHistory()
        history.recordReplacement(outgoing: viewer("/a"), incoming: viewer("/a"))
        #expect(history.entries.isEmpty)
    }

    @Test func backAndForwardMoveCursorWithoutPushing() {
        var history = PaneHistory()
        history.recordReplacement(outgoing: viewer("/a"), incoming: viewer("/b"))
        history.recordReplacement(outgoing: viewer("/b"), incoming: viewer("/c"))

        #expect(history.goBack() == viewer("/b"))
        #expect(history.goBack() == viewer("/a"))
        #expect(history.goBack() == nil, "at the oldest entry")
        #expect(history.goForward() == viewer("/b"))
        #expect(history.goForward() == viewer("/c"))
        #expect(history.goForward() == nil, "at the newest entry")
        #expect(history.entries.count == 3, "navigation must not add entries")
    }

    @Test func replacementAfterGoingBackDropsForwardEntries() {
        var history = PaneHistory()
        history.recordReplacement(outgoing: viewer("/a"), incoming: viewer("/b"))
        history.recordReplacement(outgoing: viewer("/b"), incoming: viewer("/c"))
        _ = history.goBack()  // now at /b

        history.recordReplacement(outgoing: viewer("/b"), incoming: viewer("/d"))

        #expect(history.entries == [viewer("/a"), viewer("/b"), viewer("/d")])
        #expect(!history.canGoForward, "/c must be gone")
    }

    @Test func capsAtMaxEntriesDroppingOldest() {
        var history = PaneHistory()
        for i in 1...20 {
            history.recordReplacement(outgoing: viewer("/\(i - 1)"), incoming: viewer("/\(i)"))
        }

        #expect(history.entries.count == PaneHistory.maxEntries)
        #expect(history.entries.first == viewer("/11"), "oldest entries dropped")
        #expect(history.entries.last == viewer("/20"))
        #expect(!history.canGoForward)
    }

    @Test func goToJumpsToAbsoluteIndex() {
        var history = PaneHistory()
        history.recordReplacement(outgoing: viewer("/a"), incoming: viewer("/b"))
        history.recordReplacement(outgoing: viewer("/b"), incoming: viewer("/c"))

        #expect(history.go(to: 0) == viewer("/a"))
        #expect(!history.canGoBack)
        #expect(history.canGoForward)
        #expect(history.go(to: 0) == nil, "jumping to the cursor is a no-op")
        #expect(history.go(to: 99) == nil)
    }

    @Test func backAndForwardEntriesAreNearestFirst() {
        var history = PaneHistory()
        history.recordReplacement(outgoing: viewer("/a"), incoming: viewer("/b"))
        history.recordReplacement(outgoing: viewer("/b"), incoming: viewer("/c"))
        _ = history.goBack()  // at /b

        #expect(history.backEntries.map(\.content) == [viewer("/a")])
        #expect(history.forwardEntries.map(\.content) == [viewer("/c")])
    }
}

// MARK: - AppState integration

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

            // No back history left: the pane really goes away, history with it.
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

    @Test func popHistoryForRemovedPaneRemovesWhenOnlyTranscriptsBehind() {
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
                .replacingOccurrences(of: "\"cursor\":1", with: "\"cursor\":9")
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
                direction: .horizontal,
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
