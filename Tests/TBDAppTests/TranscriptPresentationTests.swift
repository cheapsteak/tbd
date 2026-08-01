import Foundation
import Testing
import TBDShared
@testable import TBDApp

@Suite("Transcript presentation")
struct TranscriptPresentationTests {
    @Test("consecutive activity folds between narrative turns")
    func groupsActivity() {
        let items: [TranscriptItem] = [
            .assistantText(id: "a1", text: "Starting.", timestamp: nil),
            tool("t1", "Read", #"{"file_path":"Sources/A.swift"}"#),
            tool("t2", "Bash", #"{"command":"swift test"}"#),
            .assistantText(id: "a2", text: "Done.", timestamp: nil)
        ]

        let presentation = TranscriptPresentation.build(items: items)

        #expect(presentation.nodes.count == 3)
        guard case .activityGroupSummary(let summary) = presentation.nodes[1].kind else {
            Issue.record("expected activity group summary")
            return
        }
        #expect(summary.id == "t1#activity-group")
        #expect(summary.itemCount == 2)
        #expect(summary.labels == ["Reads", "Commands"])
        #expect(!summary.isExpanded)
    }

    @Test("expanded group flattens existing child rows after its summary")
    func expandsActivity() {
        let items = [
            tool("t1", "Read", #"{"file_path":"A.swift"}"#),
            tool("t2", "Bash", #"{"command":"swift test"}"#)
        ]

        let presentation = TranscriptPresentation.build(
            items: items,
            toggledGroupIDs: ["t1#activity-group"]
        )

        #expect(presentation.nodes.map(\.id) == ["t1#activity-group", "t1", "t2"])
    }

    @Test("append-only polls keep the active group identity stable")
    func stableGroupIdentity() {
        let first = TranscriptPresentation.build(
            items: [tool("t1", "Read", #"{"file_path":"A.swift"}"#)]
        )
        let appended = TranscriptPresentation.build(items: [
            tool("t1", "Read", #"{"file_path":"A.swift"}"#),
            tool("t2", "Bash", #"{"command":"swift test"}"#),
        ])

        #expect(first.nodes.first?.id == "t1#activity-group")
        #expect(appended.nodes.first?.id == "t1#activity-group")
    }

    @Test("errors and questions start expanded and surface status")
    func attentionGroupsStartExpanded() {
        let failure = TranscriptItem.toolCall(
            id: "bad", name: "Bash", inputJSON: #"{"command":"exit 1"}"#,
            inputTruncatedTo: nil,
            result: ToolResult(text: "failed", truncatedTo: nil, isError: true),
            subagent: nil, timestamp: nil
        )
        let question = tool("ask", "AskUserQuestion", #"{"questions":[]}"#)

        let failed = TranscriptPresentation.build(items: [failure])
        let awaiting = TranscriptPresentation.build(items: [question])

        guard case .activityGroupSummary(let failedSummary) = failed.nodes[0].kind,
              case .activityGroupSummary(let questionSummary) = awaiting.nodes[0].kind else {
            Issue.record("expected attention summaries")
            return
        }
        #expect(failedSummary.isExpanded)
        #expect(failedSummary.statusLabel == "1 failed")
        #expect(questionSummary.isExpanded)
        #expect(questionSummary.statusLabel == "Needs response")

        let collapsedFailure = TranscriptPresentation.build(
            items: [failure],
            toggledGroupIDs: ["bad#activity-group"]
        )
        guard case .activityGroupSummary(let collapsedSummary) = collapsedFailure.nodes[0].kind else {
            Issue.record("expected collapsed attention summary")
            return
        }
        #expect(!collapsedSummary.isExpanded)
    }

    @Test("unfinished tool calls are active rather than reported complete")
    func pendingGroupStatus() {
        let presentation = TranscriptPresentation.build(
            items: [tool("t1", "Bash", #"{"command":"swift test"}"#)]
        )
        guard case .activityGroupSummary(let summary) = presentation.nodes[0].kind else {
            Issue.record("expected activity summary")
            return
        }
        #expect(summary.pendingCount == 1)
        #expect(summary.statusLabel == "In progress")
    }

    @Test("index classifies, deduplicates, and retains latest click target")
    func buildsSessionIndex() {
        let items = [
            tool("w1", "Write", #"{"file_path":"docs/report.md","content":"a"}"#),
            tool("w2", "Edit", #"{"file_path":"docs/report.md"}"#),
            tool("r1", "Read", #"{"file_path":"Sources/App.swift"}"#),
            tool("web1", "WebFetch", #"{"url":"https://example.com/guide"}"#),
            tool("web2", "mcp__playwright__browser_search", #"{"query":"SwiftUI inspector"}"#),
            tool("a1", "Task", #"{"description":"Review transcript hierarchy"}"#)
        ]

        let presentation = TranscriptPresentation.build(items: items)

        #expect(presentation.indexSections.map(\.category) == [.changed, .sources, .web, .delegates])
        #expect(presentation.indexEntryCount == 5)
        let changed = presentation.indexSections[0].entries[0]
        #expect(changed.title == "report.md")
        #expect(changed.count == 2)
        #expect(changed.transcriptItemID == "w2")
    }

    @Test("unknown tools and malformed input never create guessed entries")
    func rejectsUnknownInputs() {
        let items = [
            tool("u1", "CustomScraper", #"{"url":"https://example.com"}"#),
            tool("u2", "Read", "not-json")
        ]

        #expect(TranscriptPresentation.build(items: items).indexSections.isEmpty)
    }

    @Test("rail switches to inspector below the wide threshold")
    func widthPolicy() {
        #expect(SessionIndexDisplayMode.resolve(width: 979) == .inspector)
        #expect(SessionIndexDisplayMode.resolve(width: 980) == .inlineRail)
    }

    private func tool(_ id: String, _ name: String, _ input: String) -> TranscriptItem {
        .toolCall(
            id: id, name: name, inputJSON: input, inputTruncatedTo: nil,
            result: nil, subagent: nil, timestamp: nil
        )
    }
}
