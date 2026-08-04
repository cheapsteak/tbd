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
            expansionOverrides: ["t1#activity-group": true]
        )

        #expect(presentation.nodes.map(\.id) == ["t1#activity-group", "t1", "t2"])
    }

    @Test("a lone activity renders as its own row, with no group wrapper")
    func singleActivityIsNotWrapped() {
        let presentation = TranscriptPresentation.build(
            items: [tool("t1", "Read", #"{"file_path":"A.swift"}"#)]
        )

        #expect(presentation.nodes.map(\.id) == ["t1"])
        #expect(presentation.nodes.allSatisfy { node in
            if case .activityGroupSummary = node.kind { return false }
            return true
        })
    }

    @Test("a lone activity stays unwrapped between narrative turns and when expanded")
    func singleActivityUnwrappedInEveryPosition() {
        let betweenTurns = TranscriptPresentation.build(items: [
            .assistantText(id: "a1", text: "Starting.", timestamp: nil),
            tool("t1", "Read", #"{"file_path":"A.swift"}"#),
            .assistantText(id: "a2", text: "Done.", timestamp: nil)
        ])
        #expect(betweenTurns.nodes.map(\.id) == ["a1", "t1", "a2"])

        // An expansion override for a group that no longer exists must not
        // resurrect the wrapper (stale overrides survive in the pane's state).
        let withStaleOverride = TranscriptPresentation.build(
            items: [tool("t1", "Read", #"{"file_path":"A.swift"}"#)],
            expansionOverrides: ["t1#activity-group": true]
        )
        #expect(withStaleOverride.nodes.map(\.id) == ["t1"])
    }

    @Test("two consecutive activities still fold into a summary")
    func twoActivitiesStillGroup() {
        let presentation = TranscriptPresentation.build(items: [
            tool("t1", "Read", #"{"file_path":"A.swift"}"#),
            tool("t2", "Bash", #"{"command":"swift test"}"#)
        ])

        #expect(presentation.nodes.map(\.id) == ["t1#activity-group"])
    }

    @Test("append-only polls keep the active group identity stable")
    func stableGroupIdentity() {
        let first = TranscriptPresentation.build(items: [
            tool("t1", "Read", #"{"file_path":"A.swift"}"#),
            tool("t2", "Bash", #"{"command":"swift test"}"#)
        ])
        let appended = TranscriptPresentation.build(items: [
            tool("t1", "Read", #"{"file_path":"A.swift"}"#),
            tool("t2", "Bash", #"{"command":"swift test"}"#),
            tool("t3", "Grep", #"{"pattern":"foo"}"#),
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
        // A second, succeeded item so the run still forms a group — a lone
        // activity renders unwrapped and has no summary to expand.
        let succeeded = succeededTool("ok", "Read", #"{"file_path":"A.swift"}"#)

        let failed = TranscriptPresentation.build(items: [failure, succeeded])
        let awaiting = TranscriptPresentation.build(items: [question, succeeded])

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
            items: [failure, succeeded],
            expansionOverrides: ["bad#activity-group": false]
        )
        guard case .activityGroupSummary(let collapsedSummary) = collapsedFailure.nodes[0].kind else {
            Issue.record("expected collapsed attention summary")
            return
        }
        #expect(!collapsedSummary.isExpanded)
    }

    @Test("unfinished tool calls are active rather than reported complete")
    func pendingGroupStatus() {
        let presentation = TranscriptPresentation.build(items: [
            tool("t1", "Bash", #"{"command":"swift test"}"#),
            succeededTool("t2", "Read", #"{"file_path":"A.swift"}"#)
        ])
        guard case .activityGroupSummary(let summary) = presentation.nodes[0].kind else {
            Issue.record("expected activity summary")
            return
        }
        #expect(summary.pendingCount == 1)
        #expect(summary.statusLabel == "In progress")
    }

    @Test("an all-succeeded group carries no status label")
    func succeededGroupHasNoStatusLabel() {
        let presentation = TranscriptPresentation.build(items: [
            succeededTool("t1", "Read", #"{"file_path":"A.swift"}"#),
            succeededTool("t2", "Bash", #"{"command":"swift build"}"#)
        ])
        guard case .activityGroupSummary(let summary) = presentation.nodes[0].kind else {
            Issue.record("expected activity summary")
            return
        }
        #expect(summary.errorCount == 0)
        #expect(summary.pendingCount == 0)
        #expect(!summary.requiresResponse)
        #expect(summary.statusLabel == nil)
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

    @Test("explicitly expanded group stays expanded when a failure later arrives")
    func expandedGroupStaysExpandedWhenFailureArrives() {
        let pendingTool = tool("t1", "Bash", #"{"command":"sleep 10"}"#)

        // A second, succeeded item so the run forms a group at all.
        let companion = succeededTool("t2", "Read", #"{"file_path":"A.swift"}"#)

        // First build: pending tool (not expanded by default since no error/question)
        let firstPresentation = TranscriptPresentation.build(
            items: [pendingTool, companion],
            expansionOverrides: ["t1#activity-group": true]
        )

        guard case .activityGroupSummary(let firstSummary) = firstPresentation.nodes[0].kind else {
            Issue.record("expected activity group summary")
            return
        }
        #expect(firstSummary.isExpanded)
        #expect(firstSummary.errorCount == 0)

        // Second build: same tool now has an error
        let failedTool = TranscriptItem.toolCall(
            id: "t1", name: "Bash", inputJSON: #"{"command":"sleep 10"}"#,
            inputTruncatedTo: nil,
            result: ToolResult(text: "failed", truncatedTo: nil, isError: true),
            subagent: nil, timestamp: nil
        )

        let secondPresentation = TranscriptPresentation.build(
            items: [failedTool, companion],
            expansionOverrides: ["t1#activity-group": true]
        )

        guard case .activityGroupSummary(let secondSummary) = secondPresentation.nodes[0].kind else {
            Issue.record("expected activity group summary after failure")
            return
        }
        // The user's explicit expansion should be preserved
        #expect(secondSummary.isExpanded)
        #expect(secondSummary.errorCount == 1)
        #expect(secondSummary.statusLabel == "1 failed")
    }

    @Test("explicitly collapsed failure group stays collapsed when a second failure arrives")
    func collapsedFailureGroupStaysCollapsed() {
        let firstFailure = TranscriptItem.toolCall(
            id: "t1", name: "Bash", inputJSON: #"{"command":"exit 1"}"#,
            inputTruncatedTo: nil,
            result: ToolResult(text: "failed", truncatedTo: nil, isError: true),
            subagent: nil, timestamp: nil
        )

        // A second, succeeded item so the run forms a group at all.
        let companion = succeededTool("t9", "Read", #"{"file_path":"A.swift"}"#)

        // First build: one failure (expanded by default), but we override to collapsed
        let firstPresentation = TranscriptPresentation.build(
            items: [firstFailure, companion],
            expansionOverrides: ["t1#activity-group": false]
        )

        guard case .activityGroupSummary(let firstSummary) = firstPresentation.nodes[0].kind else {
            Issue.record("expected activity group summary")
            return
        }
        #expect(!firstSummary.isExpanded)
        #expect(firstSummary.errorCount == 1)

        // Second build: add another failure
        let secondFailure = TranscriptItem.toolCall(
            id: "t2", name: "Read", inputJSON: #"{"file_path":"missing.txt"}"#,
            inputTruncatedTo: nil,
            result: ToolResult(text: "not found", truncatedTo: nil, isError: true),
            subagent: nil, timestamp: nil
        )

        let secondPresentation = TranscriptPresentation.build(
            items: [firstFailure, companion, secondFailure],
            expansionOverrides: ["t1#activity-group": false]
        )

        guard case .activityGroupSummary(let secondSummary) = secondPresentation.nodes[0].kind else {
            Issue.record("expected activity group summary after second failure")
            return
        }
        // The user's explicit collapse should be preserved despite now having 2 errors
        #expect(!secondSummary.isExpanded)
        #expect(secondSummary.errorCount == 2)
        #expect(secondSummary.statusLabel == "2 failed")
    }

    @Test("no override falls back to default expansion behavior")
    func noOverrideFallsBackToDefault() {
        // Test with a plain group (no error, no question) - should collapse by default
        let plainItems = [
            tool("t1", "Read", #"{"file_path":"A.swift"}"#),
            tool("t2", "Grep", #"{"pattern":"foo"}"#)
        ]
        let plainPresentation = TranscriptPresentation.build(
            items: plainItems,
            expansionOverrides: [:]
        )
        guard case .activityGroupSummary(let plainSummary) = plainPresentation.nodes[0].kind else {
            Issue.record("expected plain activity group")
            return
        }
        #expect(!plainSummary.isExpanded)

        // Test with a failing group - should expand by default
        let failure = TranscriptItem.toolCall(
            id: "f1", name: "Bash", inputJSON: #"{"command":"exit 1"}"#,
            inputTruncatedTo: nil,
            result: ToolResult(text: "failed", truncatedTo: nil, isError: true),
            subagent: nil, timestamp: nil
        )
        let failurePresentation = TranscriptPresentation.build(
            items: [failure, succeededTool("f2", "Read", #"{"file_path":"A.swift"}"#)],
            expansionOverrides: [:]
        )
        guard case .activityGroupSummary(let failureSummary) = failurePresentation.nodes[0].kind else {
            Issue.record("expected failure activity group")
            return
        }
        #expect(failureSummary.isExpanded)
    }

    /// A tool call with no result yet — counts as pending.
    private func tool(_ id: String, _ name: String, _ input: String) -> TranscriptItem {
        .toolCall(
            id: id, name: name, inputJSON: input, inputTruncatedTo: nil,
            result: nil, subagent: nil, timestamp: nil
        )
    }

    /// A tool call that finished successfully: neither pending nor an error, so
    /// it pads a run into a real group without changing the group's status.
    private func succeededTool(_ id: String, _ name: String, _ input: String) -> TranscriptItem {
        .toolCall(
            id: id, name: name, inputJSON: input, inputTruncatedTo: nil,
            result: ToolResult(text: "ok", truncatedTo: nil, isError: false),
            subagent: nil, timestamp: nil
        )
    }
}
