import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared

@Suite struct AskUserQuestionMergeTests {
    private static func toolCall(_ id: String, name: String = "AskUserQuestion") -> TranscriptItem {
        .toolCall(
            id: id, name: name, inputJSON: "{}",
            inputTruncatedTo: nil, result: nil, subagent: nil,
            timestamp: nil, usage: nil
        )
    }

    private static func pending(_ id: String) -> PendingAskUserQuestion {
        PendingAskUserQuestion(
            toolUseID: id,
            inputJSON: "{\"questions\":[]}",
            timestamp: Date(timeIntervalSince1970: 1000)
        )
    }

    @Test func pendingPresent_NoJSONLMatch_AppendsSynthetic() {
        let jsonl: [TranscriptItem] = [
            Self.toolCall("toolu_real_other", name: "Bash")
        ]
        let result = AskUserQuestionMerger.merge(
            jsonlItems: jsonl,
            pending: [Self.pending("toolu_pending")]
        )
        #expect(result.items.count == 2)
        if case let .toolCall(id, name, _, truncated, res, sub, _, usage) = result.items[1] {
            #expect(id == "toolu_pending")
            #expect(name == "AskUserQuestion")
            #expect(truncated == nil)
            #expect(res == nil)
            #expect(sub == nil)
            #expect(usage == nil)
        } else {
            Issue.record("expected synthetic toolCall as last item, got \(result.items[1])")
        }
        #expect(result.satisfiedToolUseIDs == [])
    }

    @Test func pendingPresent_JSONLMatch_SuppressesSyntheticAndReportsSatisfied() {
        let jsonl: [TranscriptItem] = [
            Self.toolCall("toolu_real_other", name: "Bash"),
            Self.toolCall("toolu_pending")
        ]
        let result = AskUserQuestionMerger.merge(
            jsonlItems: jsonl,
            pending: [Self.pending("toolu_pending")]
        )
        #expect(result.items.count == 2, "synthetic must not be appended when JSONL matches")
        #expect(result.satisfiedToolUseIDs == ["toolu_pending"])
    }

    @Test func noPending_ReturnsJSONLByteIdentical() {
        let jsonl: [TranscriptItem] = [
            Self.toolCall("toolu_a"),
            Self.toolCall("toolu_b", name: "Bash")
        ]
        let result = AskUserQuestionMerger.merge(jsonlItems: jsonl, pending: [])
        #expect(result.items == jsonl)
        #expect(result.satisfiedToolUseIDs == [])
    }

    @Test func twoPendingDifferentToolIDs_BothAppearWhenNoMatch() {
        let result = AskUserQuestionMerger.merge(
            jsonlItems: [],
            pending: [Self.pending("toolu_a"), Self.pending("toolu_b")]
        )
        #expect(result.items.count == 2)
        let ids = result.items.compactMap { item -> String? in
            if case let .toolCall(id, _, _, _, _, _, _, _) = item { return id }
            return nil
        }
        #expect(Set(ids) == ["toolu_a", "toolu_b"])
    }

    @Test func mixedMatch_SuppressesMatchedOnly() {
        let jsonl: [TranscriptItem] = [
            Self.toolCall("toolu_a")
        ]
        let result = AskUserQuestionMerger.merge(
            jsonlItems: jsonl,
            pending: [Self.pending("toolu_a"), Self.pending("toolu_b")]
        )
        #expect(result.items.count == 2)
        #expect(result.satisfiedToolUseIDs == ["toolu_a"])
        if case let .toolCall(id, _, _, _, _, _, _, _) = result.items[1] {
            #expect(id == "toolu_b")
        } else {
            Issue.record("expected toolu_b synthetic, got \(result.items[1])")
        }
    }
}
