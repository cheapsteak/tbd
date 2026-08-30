import Foundation
import Testing
@testable import TBDShared

@Suite("IncrementalTranscript")
struct IncrementalTranscriptTests {

    /// Real captured lines: an assistant tool_use, then a later user
    /// tool_result resolving it. Loaded from the fixture so the bytes are
    /// Claude Code's own, not ours.
    private func fixtureLines() throws -> [String] {
        let url = try #require(Bundle.module.url(
            forResource: "incremental-transcript-sample", withExtension: "jsonl"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private func fixturePath() throws -> String {
        try #require(Bundle.module.url(
            forResource: "incremental-transcript-sample", withExtension: "jsonl")).path
    }

    @Test("a tool_result arriving in a later chunk resolves its earlier tool_use")
    func toolResultAcrossChunks() throws {
        let lines = try fixtureLines()
        let resultIdx = try #require(lines.firstIndex { $0.contains("tool_result") })
        #expect(resultIdx > 0, "fixture must have a tool_use before its tool_result")

        var incremental = IncrementalTranscript()
        incremental.ingest(lines: Array(lines[..<resultIdx]))
        let beforeResolved = incremental.items.contains { item in
            if case .toolCall(_, _, _, _, let result, _, _, _) = item { return result != nil }
            return false
        }
        #expect(beforeResolved == false, "no result should be resolved yet")

        incremental.ingest(lines: Array(lines[resultIdx...]))
        let afterResolved = incremental.items.contains { item in
            if case .toolCall(_, _, _, _, let result, _, _, _) = item { return result != nil }
            return false
        }
        #expect(afterResolved, "the later tool_result must patch the earlier tool_use")
    }

    @Test("chunk-split ingestion equals a whole-file parse, at every split point")
    func chunkSplitEquivalence() throws {
        let lines = try fixtureLines()
        let whole = TranscriptParser.parse(filePath: try fixturePath())
        #expect(whole.isEmpty == false, "fixture must produce items")

        for split in 1..<lines.count {
            var incremental = IncrementalTranscript()
            incremental.ingest(lines: Array(lines[..<split]))
            incremental.ingest(lines: Array(lines[split...]))
            #expect(incremental.items == whole, "mismatch when split at line \(split)")
        }
    }

    @Test("line-at-a-time ingestion equals a whole-file parse")
    func oneLineAtATime() throws {
        let lines = try fixtureLines()
        let whole = TranscriptParser.parse(filePath: try fixturePath())
        var incremental = IncrementalTranscript()
        for line in lines { incremental.ingest(lines: [line]) }
        #expect(incremental.items == whole)
    }

    /// The raw JSON of a tool-call row is held only so a late `tool_result` can
    /// rebuild that item. Once the result has landed nothing can name the row
    /// again, and a tool call's line — carrying the whole tool input — is
    /// typically the largest in a transcript. Left unpruned the map grows with
    /// every tool call the session ever made, for the life of the transcript.
    @Test("a resolved tool call stops retaining its raw row")
    func resolvedRowsAreNotRetained() throws {
        let lines = try fixtureLines()
        let resultIdx = try #require(lines.firstIndex { $0.contains("tool_result") })

        var incremental = IncrementalTranscript()
        incremental.ingest(lines: Array(lines[..<resultIdx]))
        #expect(incremental.retainedToolCallRowCount > 0,
                "a call still awaiting its result must keep the row that rebuilds it")

        incremental.ingest(lines: Array(lines[resultIdx...]))
        #expect(incremental.retainedToolCallRowCount == 0,
                "every call the fixture resolves must release its row")
    }

    /// The other half: a pane opening onto an already-complete transcript reads
    /// the calls and their results in one batch, so `buildItems` resolves them
    /// on the spot and no row is ever worth keeping.
    @Test("a whole-file ingest retains no tool-call rows at all")
    func wholeFileIngestRetainsNoRows() throws {
        var incremental = IncrementalTranscript()
        incremental.ingest(lines: try fixtureLines())
        #expect(incremental.retainedToolCallRowCount == 0)
    }

    @Test("an empty ingest reports no change")
    func emptyIngestIsNoChange() throws {
        var incremental = IncrementalTranscript()
        #expect(incremental.ingest(lines: []).isEmpty)
    }
}
