import CoreGraphics
import Foundation
import Testing
@testable import TBDApp
import TBDShared

// Tier 1: pure functions over render nodes made by the production builders.

/// A prompt rail notch's length: the work in each entry's turn
/// (`PromptOutline.workCounts`) and the log scale that turns it into points
/// (`PromptRailWorkScale`).
@Suite("Prompt rail work")
struct PromptRailWorkTests {
    // MARK: Counts

    /// A subagent launch is one more tool call: its own steps live in its
    /// transcript file, which the pane does not read.
    @Test("standalone tool calls count one each, a subagent launch included, and the last turn runs to the end")
    func standaloneToolCallsAndLastTurn() {
        let nodes = transcriptRenderNodes(from: [
            Self.prompt("p-0"),
            Self.reply("a-0"),
            Self.tool("t-0a", "Read"),
            Self.reply("a-0b"),
            Self.tool("t-0b", "Bash"),
            Self.prompt("p-1"),
            Self.reply("a-1"),
            Self.prompt("p-2"),
            Self.tool("t-2a", "Read"),
            Self.tool("t-2b", "Grep"),
            Self.tool("t-2c", "Agent"),
        ])
        #expect(Self.counts(nodes) == [2, 0, 3])
    }

    @Test("a peer message starts a turn of its own")
    func peerStartsATurn() {
        let sender = PeerSender(name: "build-bot", from: "build-bot", verified: true, pid: nil)
        let nodes = transcriptRenderNodes(from: [
            Self.prompt("p-0"),
            Self.tool("t-0", "Read"),
            .peerMessage(id: "m-1", sender: sender, text: "green", deliveredPayload: nil, timestamp: nil),
            Self.tool("t-1a", "Bash"),
            Self.tool("t-1b", "Bash"),
        ])
        #expect(PromptOutline.entries(from: nodes).map(\.id) == ["p-0", "m-1"])
        #expect(Self.counts(nodes) == [1, 2])
    }

    @Test("a prompt nobody typed starts no turn, and rows above the first entry belong to none")
    func untypedMarkerAndLeadingRows() {
        let nodes = transcriptRenderNodes(from: [
            Self.tool("t-x", "Read"),
            Self.prompt("p-0"),
            Self.tool("t-0a", "Read"),
            .userPrompt(id: "x", text: "[Request interrupted by user]", timestamp: nil),
            Self.tool("t-0b", "Bash"),
        ])
        #expect(Self.counts(nodes) == [2])
    }

    /// `itemCount` counts every grouped row, so a group reports its tool calls
    /// apart for the rail to read.
    @Test("a collapsed group counts its tool calls, not its other rows")
    func collapsedGroupCountsToolCalls() {
        let nodes = TranscriptPresentation.build(items: Self.groupRun, memo: TranscriptPresentationMemo()).nodes
        #expect(nodes.map(\.id) == ["p-0", "t-1#activity-group"])
        guard case .activityGroupSummary(let summary) = nodes[1].kind else {
            Issue.record("expected the run to fold into a group")
            return
        }
        #expect(!summary.isExpanded)
        #expect(summary.itemCount == 4)
        #expect(summary.toolCallCount == 2)
        #expect(Self.counts(nodes) == [2])
    }

    @Test("an expanded group is counted once, through its member rows")
    func expandedGroupIsCountedOnce() {
        let nodes = TranscriptPresentation.build(
            items: Self.groupRun, expansionOverrides: ["t-1#activity-group": true],
            memo: TranscriptPresentationMemo()).nodes
        #expect(nodes.map(\.id) == ["p-0", "t-1#activity-group", "t-1", "r-1", "t-2", "k-1"])
        #expect(Self.counts(nodes) == [2])
    }

    @Test("bookkeeping tools the transcript hides are no rows and count nothing")
    func hiddenBookkeepingToolsAreAbsent() {
        let items: [TranscriptItem] = [
            Self.prompt("p-0"),
            Self.tool("todo", "TodoWrite"),
            Self.tool("t-1", "Read"),
            Self.tool("task-u", "TaskUpdate"),
            Self.tool("task-c", "TaskCreate"),
            Self.tool("skill", "Skill"),
            Self.tool("t-2", "Bash"),
        ]
        #expect(Self.counts(transcriptRenderNodes(from: items)) == [2])
        let grouped = TranscriptPresentation.build(items: items, memo: TranscriptPresentationMemo()).nodes
        #expect(grouped.map(\.id) == ["p-0", "t-1#activity-group"])
        #expect(Self.counts(grouped) == [2])
    }

    @Test("a transcript with no entries has no counts")
    func noEntriesNoCounts() {
        let nodes = transcriptRenderNodes(from: [Self.reply("a-0"), Self.tool("t-0", "Read")])
        #expect(Self.counts(nodes).isEmpty)
    }

    @Test("the work label reads 1 tool call, and N tool calls otherwise")
    func workLabel() {
        #expect(PromptOutline.workLabel(0) == "0 tool calls")
        #expect(PromptOutline.workLabel(1) == "1 tool call")
        #expect(PromptOutline.workLabel(40) == "40 tool calls")
    }

    // MARK: Length

    @Test("a turn with no work is 4pt, and so is every notch of a session with none")
    func lengthAtZero() {
        #expect(PromptRailWorkScale.length(work: 0, busiest: 40) == 4)
        let idle = PromptRailWorkScale(counts: [0, 0, 0])
        #expect(idle.busiest == 1)
        #expect((0..<3).map { idle.length(at: $0) } == [4, 4, 4])
        #expect(PromptRailWorkScale(counts: []).busiest == 1)
    }

    @Test("the busiest turn is 16pt and the rest sit on a log scale below it")
    func lengthAtBusiest() {
        let scale = PromptRailWorkScale(counts: [3, 40, 0])
        #expect(scale.busiest == 40)
        #expect(scale.length(at: 1) == 16)
        #expect(scale.length(at: 2) == 4)
        let expected = 4 + 12 * log(4.0) / log(41.0)
        #expect(abs(Double(scale.length(at: 0)) - expected) < 1e-9,
                Comment(rawValue: "length \(scale.length(at: 0)), expected \(expected)"))
        // On a log scale a tenth of the busiest turn's work is well past a
        // tenth of the range.
        #expect(scale.length(at: 0) > 4 + 12 * 0.3)
    }

    @Test("a busier turn rescales every other notch")
    func busierTurnRescales() {
        let before = PromptRailWorkScale(counts: [3, 10])
        let after = PromptRailWorkScale(counts: [3, 10, 100])
        #expect(before.length(at: 1) == 16)
        #expect(after.length(at: 2) == 16)
        #expect(after.length(at: 1) < before.length(at: 1))
        #expect(after.length(at: 0) < before.length(at: 0))
        #expect(after.count(at: 1) == before.count(at: 1))
    }

    @Test("work outside the scale's range is held to its ends, and an uncounted entry is no work")
    func lengthClampsAndDefaults() {
        #expect(PromptRailWorkScale.length(work: 90, busiest: 40) == 16)
        #expect(PromptRailWorkScale.length(work: -3, busiest: 40) == 4)
        #expect(PromptRailWorkScale.length(work: 5, busiest: 0) == 16)
        let scale = PromptRailWorkScale(counts: [7])
        #expect(scale.count(at: 3) == 0)
        #expect(scale.length(at: 3) == 4)
    }

    // MARK: Helpers

    /// A prompt, then a run of activity: two tool calls, one of them a
    /// subagent launch, between a reminder and a skill body.
    private static var groupRun: [TranscriptItem] {
        [
            prompt("p-0"),
            tool("t-1", "Read"),
            .systemReminder(id: "r-1", kind: .toolReminder, text: "remember", timestamp: nil),
            tool("t-2", "Agent"),
            .systemReminder(id: "k-1", kind: .skillBody, text: "skill", timestamp: nil),
        ]
    }

    private static func counts(_ nodes: [TranscriptRenderNode]) -> [Int] {
        PromptOutline.workCounts(for: PromptOutline.entries(from: nodes), in: nodes)
    }

    private static func prompt(_ id: String) -> TranscriptItem {
        .userPrompt(id: id, text: "Prompt \(id)", timestamp: nil)
    }

    private static func reply(_ id: String) -> TranscriptItem {
        .assistantText(id: id, text: "Reply \(id)", timestamp: nil, usage: nil)
    }

    private static func tool(_ id: String, _ name: String) -> TranscriptItem {
        .toolCall(
            id: id, name: name, inputJSON: "{}", inputTruncatedTo: nil,
            result: nil, subagent: nil, timestamp: nil)
    }
}
