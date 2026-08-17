import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// Tier 1 — pure, in-process, no clock and no filesystem.
///
/// Covers the two halves of the transcript-presentation perf fix: the
/// single-pass bucketing inside the session-index builder (output must be
/// byte-for-byte what the per-category rescan produced) and the size-1 memo in
/// front of `TranscriptPresentation.build`.
@Suite("Transcript presentation memo and index ordering")
struct TranscriptPresentationMemoTests {

    // MARK: - Index section ordering

    @Test("session index keeps category order, first-seen entry order, counts, and omits empties")
    func indexSectionOrderingIsExact() throws {
        // Deliberately interleaved so that FIRST-SEEN category order
        // (web, delegates, sources, changed) is the exact reverse of the
        // declared `SessionIndexCategory.allCases` order the sections must come
        // out in — a builder that emitted buckets in encounter order, or in
        // Dictionary order, cannot pass this.
        let items: [TranscriptItem] = [
            tool("w1", "WebSearch", #"{"query":"swift memoization"}"#),
            tool("d1", "Task", #"{"description":"audit the index"}"#),
            tool("r1", "Read", #"{"file_path":"/repo/A.swift"}"#),
            tool("c1", "Write", #"{"file_path":"/repo/B.swift"}"#),
            tool("r2", "Read", #"{"file_path":"/repo/A.swift"}"#),
            tool("w2", "WebFetch", #"{"url":"https://example.com/spec"}"#),
            tool("r3", "Read", #"{"file_path":"/repo/C.swift"}"#),
            tool("c2", "Edit", #"{"file_path":"/repo/B.swift"}"#),
            tool("c3", "MultiEdit", #"{"file_path":"/repo/D.swift"}"#)
        ]

        let sections = TranscriptPresentation.build(
            items: items,
            memo: TranscriptPresentationMemo()
        ).indexSections

        #expect(sections.map(\.category) == [.changed, .sources, .web, .delegates])
        try #require(sections.count == 4)

        #expect(sections[0].entries.map(\.target) == ["/repo/B.swift", "/repo/D.swift"])
        #expect(sections[0].entries.map(\.count) == [2, 1])
        // A repeat bumps the count and re-points at the LATEST occurrence.
        #expect(sections[0].entries.map(\.transcriptItemID) == ["c2", "c3"])

        #expect(sections[1].entries.map(\.target) == ["/repo/A.swift", "/repo/C.swift"])
        #expect(sections[1].entries.map(\.count) == [2, 1])
        #expect(sections[1].entries.map(\.transcriptItemID) == ["r2", "r3"])

        #expect(sections[2].entries.map(\.target) == ["swift memoization", "https://example.com/spec"])
        #expect(sections[2].entries.map(\.count) == [1, 1])
        #expect(sections[2].entries.map(\.transcriptItemID) == ["w1", "w2"])

        #expect(sections[3].entries.map(\.target) == ["audit the index"])
        #expect(sections[3].entries.map(\.transcriptItemID) == ["d1"])

        // Empty categories are omitted entirely, not emitted as empty sections:
        // this fixture produces `changed` and `web` only.
        let sparse = TranscriptPresentation.build(
            items: [
                tool("w1", "WebFetch", #"{"url":"https://example.com/a"}"#),
                tool("c1", "Write", #"{"file_path":"/repo/B.swift"}"#)
            ],
            memo: TranscriptPresentationMemo()
        ).indexSections
        #expect(sparse.map(\.category) == [.changed, .web])
        #expect(sparse.allSatisfy { !$0.entries.isEmpty })
    }

    // MARK: - Memo

    @Test("a repeated build with identical inputs is served from the memo")
    func repeatedBuildHitsMemo() {
        let memo = TranscriptPresentationMemo()
        let items = pendingRun

        let first = TranscriptPresentation.build(items: items, memo: memo)
        let second = TranscriptPresentation.build(items: items, memo: memo)

        #expect(first.nodes == second.nodes)
        #expect(first.indexSections == second.indexSections)
        #expect(memo.statistics.hits == 1)
        #expect(memo.statistics.misses == 1)

        // Value equality, not buffer identity: the same transcript arriving in
        // fresh storage (the shape a decoded RPC payload has) is still a hit.
        let rewired = items.map(roundTripped)
        let third = TranscriptPresentation.build(items: rewired, memo: memo)
        #expect(third.nodes == first.nodes)
        #expect(memo.statistics.hits == 2)
        #expect(memo.statistics.misses == 1)
    }

    @Test("a tool call gaining its result recomputes, even though the count is unchanged")
    func inPlaceResultRecomputes() {
        let memo = TranscriptPresentationMemo()
        let pending = pendingRun
        let settled = settledRun

        // The trap a count-or-last-ID cache key falls into: same element count,
        // same IDs, same last item — only the first item's payload changed.
        #expect(pending.count == settled.count)
        #expect(pending.map(\.id) == settled.map(\.id))
        #expect(pending.last == settled.last)

        let before = TranscriptPresentation.build(items: pending, memo: memo)
        let after = TranscriptPresentation.build(items: settled, memo: memo)

        #expect(memo.statistics.hits == 0)
        #expect(memo.statistics.misses == 2)
        #expect(summary(of: before)?.pendingCount == 1)
        #expect(summary(of: after)?.pendingCount == 0)
        #expect(before.nodes != after.nodes)
    }

    @Test("changing only the expansion overrides recomputes")
    func expansionOverrideChangeRecomputes() {
        let memo = TranscriptPresentationMemo()
        let items = settledRun
        let groupID = "t1#activity-group"

        let collapsed = TranscriptPresentation.build(items: items, memo: memo)
        let expanded = TranscriptPresentation.build(
            items: items,
            expansionOverrides: [groupID: true],
            memo: memo
        )

        #expect(memo.statistics.hits == 0)
        #expect(memo.statistics.misses == 2)
        #expect(collapsed.nodes.map(\.id) == [groupID])
        #expect(expanded.nodes.map(\.id) == [groupID, "t1", "t2"])

        // And going back to the previous overrides is a miss too — the memo
        // holds one entry, so this proves it is keyed rather than accumulating.
        let collapsedAgain = TranscriptPresentation.build(items: items, memo: memo)
        #expect(collapsedAgain.nodes.map(\.id) == [groupID])
        #expect(memo.statistics.hits == 0)
        #expect(memo.statistics.misses == 3)
    }

    // MARK: - Fixtures

    /// Two consecutive tool calls — enough to form an activity group — with the
    /// first still awaiting its result.
    private var pendingRun: [TranscriptItem] {
        [
            tool("t1", "Bash", #"{"command":"swift build"}"#),
            succeededTool("t2", "Read", #"{"file_path":"/repo/A.swift"}"#)
        ]
    }

    /// The same run one poll later: `t1` has gained its result in place. Same
    /// count, same IDs, same last element.
    private var settledRun: [TranscriptItem] {
        [
            succeededTool("t1", "Bash", #"{"command":"swift build"}"#),
            succeededTool("t2", "Read", #"{"file_path":"/repo/A.swift"}"#)
        ]
    }

    private func tool(_ id: String, _ name: String, _ input: String) -> TranscriptItem {
        .toolCall(
            id: id, name: name, inputJSON: input, inputTruncatedTo: nil,
            result: nil, subagent: nil, timestamp: nil, usage: nil
        )
    }

    private func succeededTool(_ id: String, _ name: String, _ input: String) -> TranscriptItem {
        .toolCall(
            id: id, name: name, inputJSON: input, inputTruncatedTo: nil,
            result: ToolResult(text: "ok", truncatedTo: nil, isError: false),
            subagent: nil, timestamp: nil, usage: nil
        )
    }

    /// Sends an item through the Codable path the app actually receives items
    /// over, so the resulting array shares no storage with the original.
    private func roundTripped(_ item: TranscriptItem) -> TranscriptItem {
        do {
            let data = try JSONEncoder().encode(item)
            return try JSONDecoder().decode(TranscriptItem.self, from: data)
        } catch {
            Issue.record(error)
            return item
        }
    }

    private func summary(of presentation: TranscriptPresentation) -> ActivityGroupSummary? {
        for node in presentation.nodes {
            if case .activityGroupSummary(let summary) = node.kind { return summary }
        }
        return nil
    }
}
