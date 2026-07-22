import Foundation
import Testing
import TBDShared

@testable import TBDApp

@Suite("PaneHistory")
struct PaneHistoryTests {
    private let slotID = UUID()

    private func viewer(_ path: String) -> PaneContent {
        .codeViewer(id: slotID, path: path)
    }

    @Test func recordReplacement_bootstrapsMRUNewestFirst() {
        var history = PaneHistory()
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)

        history.recordReplacement(outgoing: viewer("/a"), incoming: viewer("/b"))

        #expect(history.entries == [viewer("/b"), viewer("/a")], "entries[0] is newest")
        #expect(history.cursor == 0)
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

        #expect(history.entries == [viewer("/c"), viewer("/b"), viewer("/a")])
        #expect(history.goBack() == viewer("/b"))
        #expect(history.goBack() == viewer("/a"))
        #expect(history.goBack() == nil, "at the oldest entry")
        #expect(history.goForward() == viewer("/b"))
        #expect(history.goForward() == viewer("/c"))
        #expect(history.goForward() == nil, "at the newest entry")
        #expect(history.entries.count == 3, "navigation must not add entries")
    }

    /// The spec's worked example: navigating after going back COMMITS the
    /// current entry to the front instead of truncating forward entries —
    /// nothing is ever dropped by going back.
    @Test func navigatingAfterGoingBackKeepsAllEntries() {
        var history = PaneHistory()
        history.recordReplacement(outgoing: viewer("/A"), incoming: viewer("/B"))
        #expect(history.entries == [viewer("/B"), viewer("/A")])

        #expect(history.goBack() == viewer("/A"))
        #expect(history.entries == [viewer("/B"), viewer("/A")], "back never reorders")

        history.recordReplacement(outgoing: viewer("/A"), incoming: viewer("/C"))
        #expect(history.entries == [viewer("/C"), viewer("/A"), viewer("/B")],
                "commit moves A to front, C inserted — B still reachable")
        #expect(history.cursor == 0)

        #expect(history.goBack() == viewer("/A"))
        #expect(history.goBack() == viewer("/B"))
        #expect(history.goForward() == viewer("/A"))
    }

    @Test func recordReplacement_dedupeMovesExistingEntryToFront() {
        var history = PaneHistory()
        history.recordReplacement(outgoing: viewer("/a"), incoming: viewer("/b"))
        history.recordReplacement(outgoing: viewer("/b"), incoming: viewer("/c"))

        // Navigating to /a — already in the list — moves it, never duplicates.
        history.recordReplacement(outgoing: viewer("/c"), incoming: viewer("/a"))

        #expect(history.entries == [viewer("/a"), viewer("/c"), viewer("/b")])
        #expect(history.cursor == 0)
    }

    @Test func capsAtMaxEntriesEvictingTail() {
        var history = PaneHistory()
        for i in 1...20 {
            history.recordReplacement(outgoing: viewer("/\(i - 1)"), incoming: viewer("/\(i)"))
        }

        #expect(history.entries.count == PaneHistory.maxEntries)
        #expect(history.entries.first == viewer("/20"), "newest at index 0")
        #expect(history.entries.last == viewer("/11"), "oldest entries evicted")
        #expect(!history.canGoForward)
    }

    @Test func capEvictsTailNeverTheCurrentEntry() {
        var history = PaneHistory()
        for i in 1...10 {
            history.recordReplacement(outgoing: viewer("/\(i - 1)"), incoming: viewer("/\(i)"))
        }
        // Walk back to the oldest entry (/1) at the tail.
        for _ in 1...9 { _ = history.goBack() }
        #expect(history.cursor == 9)

        // Navigating from /1 first commits it to the front, so the cap
        // evicts the tail (/2) — never the entry the user was viewing.
        history.recordReplacement(outgoing: viewer("/1"), incoming: viewer("/new"))

        #expect(history.entries.count == PaneHistory.maxEntries)
        #expect(history.entries[0] == viewer("/new"))
        #expect(history.entries[1] == viewer("/1"), "current entry survived the cap")
        #expect(!history.entries.contains(viewer("/2")), "tail evicted")
        #expect(history.cursor == 0)
    }

    @Test func goToJumpsCursorWithoutReordering() {
        var history = PaneHistory()
        history.recordReplacement(outgoing: viewer("/a"), incoming: viewer("/b"))
        history.recordReplacement(outgoing: viewer("/b"), incoming: viewer("/c"))
        let before = history.entries

        #expect(history.go(to: 2) == viewer("/a"))
        #expect(history.entries == before, "jump never reorders")
        #expect(!history.canGoBack, "cursor at the oldest entry")
        #expect(history.canGoForward)
        #expect(history.go(to: 2) == nil, "jumping to the cursor is a no-op")
        #expect(history.go(to: 99) == nil)
    }

    @Test func buttonEnablementFollowsCursor() {
        var history = PaneHistory()
        history.recordReplacement(outgoing: viewer("/a"), incoming: viewer("/b"))
        history.recordReplacement(outgoing: viewer("/b"), incoming: viewer("/c"))

        // cursor 0: back only.
        #expect(history.canGoBack && !history.canGoForward)
        _ = history.goBack()
        // cursor 1 (middle): both.
        #expect(history.canGoBack && history.canGoForward)
        _ = history.goBack()
        // cursor 2 (oldest): forward only.
        #expect(!history.canGoBack && history.canGoForward)
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
