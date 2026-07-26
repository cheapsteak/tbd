import Foundation
import Testing
import TBDShared

@testable import TBDApp

// MARK: - PaneHistoryPaletteFilter / labels
//
// The palette's popover, auto-focus, and keyboard navigation are SwiftUI/
// AppKit interaction and are NOT exercised here — they need LIVE
// verification (restart the app and check: icon appears left of the
// chevrons and is disabled at ≤1 history entry, popover opens with the
// search field focused, ↑/↓ move the highlight, Enter navigates + closes,
// Esc closes without navigating, and a mouse click on a row does the same
// as Enter). What IS covered below is the pure logic: substring filtering
// (including full-path matching for file entries), the disabled-when-≤1
// gate, and that a filtered row's index still drives the same MRU
// `go(to:)` cursor-jump the old right-click dropdown used.

@Suite("PaneHistoryPaletteFilter")
struct PaneHistoryPaletteFilterTests {
    private func entries() -> [PaneContent] {
        [
            .codeViewer(id: UUID(), path: "/repo/Sources/TBDApp/AppState.swift"),
            .webview(id: UUID(), url: URL(string: "https://github.com/foo/bar")!),
            .liveTranscript(id: UUID(), terminalID: UUID()),
        ]
    }

    @Test func emptyQueryReturnsEveryEntryInOrder() {
        let indices = PaneHistoryPaletteFilter.filteredIndices(entries: entries(), query: "")
        #expect(indices == [0, 1, 2])
    }

    @Test func matchesLabelCaseInsensitively() {
        // "TRANSCRIPT" should match the liveTranscript entry's "Transcript" label.
        let indices = PaneHistoryPaletteFilter.filteredIndices(entries: entries(), query: "TRANSCRIPT")
        #expect(indices == [2])
    }

    @Test func matchesWebviewHostAndPath() {
        let indices = PaneHistoryPaletteFilter.filteredIndices(entries: entries(), query: "github.com/foo")
        #expect(indices == [1])
    }

    @Test func matchesFileEntryOnFullPathNotJustBasename() {
        // "AppState.swift" alone is the basename shown; "Sources/TBDApp" is
        // only in the full path — must still match (requirement 3 in the
        // spec: file entries match on their full path).
        let indices = PaneHistoryPaletteFilter.filteredIndices(entries: entries(), query: "Sources/TBDApp")
        #expect(indices == [0])
    }

    @Test func noMatchReturnsEmpty() {
        let indices = PaneHistoryPaletteFilter.filteredIndices(entries: entries(), query: "nonexistent-zzz")
        #expect(indices.isEmpty)
    }

    @Test func labelForCodeViewerIsBasenameOnly() {
        // Row display drops the full path entirely (single-line, basename
        // only) — this is the same helper the row view calls for its label.
        #expect(paneHistoryLabel(for: .codeViewer(id: UUID(), path: "/a/b/c.swift")) == "c.swift")
    }
}

@Suite("PaneHistoryPaletteButtonModel")
struct PaneHistoryPaletteButtonModelTests {
    @Test func disabledWithZeroOrOneEntry() {
        #expect(PaneHistoryPaletteButtonModel.isEnabled(entryCount: 0) == false)
        #expect(PaneHistoryPaletteButtonModel.isEnabled(entryCount: 1) == false)
    }

    @Test func enabledWithTwoOrMoreEntries() {
        #expect(PaneHistoryPaletteButtonModel.isEnabled(entryCount: 2) == true)
        #expect(PaneHistoryPaletteButtonModel.isEnabled(entryCount: 10) == true)
    }
}

// MARK: - Selection reuses the same MRU cursor-jump

@Suite("PaneHistoryPalette selection drives MRUHistory.go(to:)")
struct PaneHistoryPaletteSelectionTests {
    /// A filtered row's position in the visible list is NOT the same as its
    /// index in `history.entries` once a query has narrowed the list. This
    /// reproduces exactly what `PaneHistoryPaletteView.select(_:)` does:
    /// resolve the row back to its absolute `entries` index via
    /// `filteredIndices`, then jump with the same `go(to:)` the old
    /// right-click dropdown used — never a parallel navigation path.
    @Test func selectingAFilteredRowJumpsToItsAbsoluteEntry() {
        let slotID = UUID()
        var history = PaneHistory()
        // Build up an MRU order: /old, /middle, /keep (cursor lands on /keep).
        history.recordReplacement(
            outgoing: .codeViewer(id: slotID, path: "/old"),
            incoming: .codeViewer(id: slotID, path: "/middle")
        )
        history.recordReplacement(
            outgoing: .codeViewer(id: slotID, path: "/middle"),
            incoming: .codeViewer(id: slotID, path: "/keep")
        )
        // entries is now MRU order: [/keep, /middle, /old], cursor == 0.
        #expect(history.entries == [
            .codeViewer(id: slotID, path: "/keep"),
            .codeViewer(id: slotID, path: "/middle"),
            .codeViewer(id: slotID, path: "/old"),
        ])

        // Query "old" narrows the visible list to just entry index 2.
        let filtered = PaneHistoryPaletteFilter.filteredIndices(entries: history.entries, query: "old")
        #expect(filtered == [2])

        // Selecting that (only) visible row must land on absolute index 2.
        let target = filtered[0]
        let jumped = history.go(to: target)

        #expect(jumped == .codeViewer(id: slotID, path: "/old"))
        #expect(history.cursor == 2)
    }
}
