import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// A compacted conversation renders as one standalone row that opens the full
/// summary in the overlay. It is never a user bubble (the parser classifies it
/// `.compactSummary`) and never folded into an activity group, because the row
/// exists to show that a compaction happened.
@MainActor
@Suite("Compact summary row")
struct CompactSummaryRowTests {
    private let summary = "This session is being continued from a previous conversation that ran out of context.\n\nSummary:\n1. Primary Request and Intent: refactor the acme widget loader."

    // MARK: Native cell

    @Test("native cell: compress glyph, 'Conversation compacted' and the summary size, opens the summary")
    func nativePresentation() throws {
        let ts = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let node = TranscriptRenderNode.makeSystemReminder(
            id: "c1", kind: .compactSummary, text: String(repeating: "x", count: 12_345), timestamp: ts)
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(p.iconSystemName == "arrow.down.right.and.arrow.up.left")
        #expect(p.titleSegments == [
            ActivityRowSegment(text: "Conversation compacted", style: .primary),
            ActivityRowSegment(text: "·", style: .tertiary),
            ActivityRowSegment(text: "12.3K chars", style: .tertiary),
        ])
        #expect(p.badges.isEmpty, "the title already says what the row is; no 'info' capsule")
        #expect(p.openTargetID == "c1")
        #expect(p.isError == false)
        #expect(p.timestamp == ts)
        #expect(p.style == .chrome)
    }

    /// The other branch of the same `systemReminder` formatter: an ordinary
    /// reminder keeps its labelled-capsule presentation.
    @Test("an ordinary reminder still renders as a labelled reminder")
    func ordinaryReminderUnchanged() throws {
        let node = TranscriptRenderNode.makeSystemReminder(
            id: "s1", kind: .toolReminder, text: "<system-reminder>x</system-reminder>")
        let p = try #require(ActivityRowFormatter.presentation(for: node))
        #expect(p.iconSystemName == "info.circle")
        #expect(p.badges == [ActivityRowBadge(text: "system-reminder", kind: .neutral)])
    }

    // MARK: Grouping

    @Test("a compaction between two tool calls stands alone instead of joining a group")
    func compactionBetweenToolCallsIsNotGrouped() throws {
        let items: [TranscriptItem] = [
            tool("t1", "Read", #"{"file_path":"A.swift"}"#),
            compaction("c1"),
            tool("t2", "Bash", #"{"command":"make"}"#),
        ]

        let presentation = TranscriptPresentation.build(items: items)

        #expect(presentation.nodes.map(\.id) == ["t1", "c1", "t2"])
        let node = try #require(presentation.nodes.first(where: { $0.id == "c1" }))
        guard case .systemReminder(_, .compactSummary, _, _, _, _) = node.kind else {
            Issue.record("expected the compaction to render as its own system row")
            return
        }
    }

    @Test("a compaction splits a run of activity into two groups")
    func compactionSplitsActivityRuns() {
        let items: [TranscriptItem] = [
            tool("t1", "Read", #"{"file_path":"A.swift"}"#),
            tool("t2", "Bash", #"{"command":"make"}"#),
            compaction("c1"),
            tool("t3", "Grep", #"{"pattern":"x"}"#),
            tool("t4", "Bash", #"{"command":"make test"}"#),
        ]

        let presentation = TranscriptPresentation.build(items: items)

        #expect(presentation.nodes.map(\.id) == ["t1#activity-group", "c1", "t3#activity-group"])
    }

    /// The other branch: an ordinary injected reminder in the same position is
    /// activity and folds into the surrounding group.
    @Test("an ordinary reminder between two tool calls still folds into the group")
    func ordinaryReminderStillGroups() {
        let items: [TranscriptItem] = [
            tool("t1", "Read", #"{"file_path":"A.swift"}"#),
            .systemReminder(id: "s1", kind: .toolReminder,
                            text: "<system-reminder>x</system-reminder>", timestamp: nil),
            tool("t2", "Bash", #"{"command":"make"}"#),
        ]

        let presentation = TranscriptPresentation.build(items: items)

        #expect(presentation.nodes.map(\.id) == ["t1#activity-group"])
    }

    // MARK: Overlay

    @Test("the overlay's title bar names the compact summary")
    func overlayHeaderLabel() {
        #expect(TranscriptOverlayView.headerLabel(item: compaction("c1")) == "Compact summary")
    }

    // MARK: Helpers

    private func compaction(_ id: String) -> TranscriptItem {
        .systemReminder(id: id, kind: .compactSummary, text: summary, timestamp: nil)
    }

    /// A tool call with no result yet.
    private func tool(_ id: String, _ name: String, _ input: String) -> TranscriptItem {
        .toolCall(
            id: id, name: name, inputJSON: input, inputTruncatedTo: nil,
            result: nil, subagent: nil, timestamp: nil
        )
    }
}
