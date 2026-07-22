import Foundation
import Testing

@testable import TBDShared

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

    @Test func seeded_startsWithOneEntryCursorZero() {
        let history = PaneHistory.seeded(with: viewer("/a"))
        #expect(history.entries == [viewer("/a")])
        #expect(history.cursor == 0)
        #expect(history.isWellFormed)
        #expect(!history.canGoBack && !history.canGoForward)
    }

    @Test func decodesPR472PersistedShape() throws {
        // Exact wire shape persisted by PR #472's app-side PaneHistory.
        let blob = """
        {"entries":[{"codeViewer":{"id":"\(slotID.uuidString)","path":"/b"}},{"codeViewer":{"id":"\(slotID.uuidString)","path":"/a"}}],"cursor":1}
        """.data(using: .utf8)!
        let history = try JSONDecoder().decode(PaneHistory.self, from: blob)
        #expect(history.entries == [viewer("/b"), viewer("/a")])
        #expect(history.cursor == 1)
        #expect(history.isWellFormed)
    }
}
