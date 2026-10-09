import Testing
@testable import TBDApp

// Tier 1: pure functions; no daemon, no view.

/// The remote transcript pane's earlier-history decisions: what the header
/// overlay shows in each state, and how a read relates to the one before it
/// (docs/specs/2026-09-25-remote-session-transcript-design.md, "Loading
/// earlier history" and "Layout").
@MainActor
@Suite("Remote transcript earlier history")
struct RemoteTranscriptEarlierHistoryTests {
    private typealias Content = RemoteTranscriptEarlierHeader.Content
    private typealias ReadPlan = RemoteTranscriptPaneView.ReadPlan

    @Test("the header shows the four states")
    func headerStates() {
        #expect(Content.resolve(state: .idle, hasEarlier: true, nearTop: true) == .hidden)
        #expect(Content.resolve(state: .loading, hasEarlier: true, nearTop: true) == .spinner)
        #expect(Content.resolve(state: .failed("nope"), hasEarlier: true, nearTop: true)
            == .retryButton("Load earlier messages"))
        #expect(Content.resolve(state: .reachedStart, hasEarlier: false, nearTop: true)
            == .text("Start of conversation"))
        #expect(Content.resolve(state: .expired, hasEarlier: false, nearTop: true)
            == .text("Earlier history is no longer available"))
    }

    @Test("loading and failed show wherever the table is scrolled; the end notices only near the top")
    func headerVisibilityAwayFromTheTop() {
        #expect(Content.resolve(state: .idle, hasEarlier: true, nearTop: false) == .hidden,
                "idle away from the top shows nothing")
        #expect(Content.resolve(state: .loading, hasEarlier: true, nearTop: false) == .spinner)
        #expect(Content.resolve(state: .failed("nope"), hasEarlier: true, nearTop: false)
            == .retryButton("Load earlier messages"))
        #expect(Content.resolve(state: .reachedStart, hasEarlier: false, nearTop: false) == .hidden)
        #expect(Content.resolve(state: .expired, hasEarlier: false, nearTop: false) == .hidden)
    }

    /// With `remote_transcript_live_sync_enabled` off the daemon never reports
    /// `hasEarlier`, so the driver never leaves `.idle` and the pane looks as
    /// it did before the flag existed — even at the top of the table.
    @Test("without hasEarlier the header never shows, so a flag-off pane is unchanged")
    func flagOffShowsNoHeader() {
        for nearTop in [false, true] {
            #expect(Content.resolve(state: .idle, hasEarlier: false, nearTop: nearTop) == .hidden)
            #expect(Content.resolve(state: .loading, hasEarlier: false, nearTop: nearTop) == .hidden)
            #expect(Content.resolve(state: .failed("x"), hasEarlier: false, nearTop: nearTop) == .hidden)
        }
    }

    @Test("a head bump re-reads with the anchor; a generation bump scrolls to the bottom")
    func readPlan() {
        let base = ReadPlan.Mark(generation: 1, head: 0)
        #expect(ReadPlan.next(previous: nil, current: base) == .incremental, "the first read")
        #expect(ReadPlan.next(previous: base, current: base) == .incremental)
        #expect(ReadPlan.next(previous: base, current: .init(generation: 1, head: 1)) == .anchoredReread)
        #expect(ReadPlan.next(previous: base, current: .init(generation: 2, head: 0)) == .resetToBottom)
        #expect(ReadPlan.next(previous: base, current: .init(generation: 2, head: 1)) == .resetToBottom,
                "a new conversation is never anchored, even when head moved too")
    }
}
