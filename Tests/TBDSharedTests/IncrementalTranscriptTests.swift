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

    @Test("an empty ingest reports no change")
    func emptyIngestIsNoChange() throws {
        var incremental = IncrementalTranscript()
        #expect(incremental.ingest(lines: []).isEmpty)
    }
}
