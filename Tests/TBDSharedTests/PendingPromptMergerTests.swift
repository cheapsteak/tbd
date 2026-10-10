import Foundation
import Testing
@testable import TBDShared

// Tier 1: pure merge, no I/O.
@Suite struct PendingPromptMergerTests {
    private static let when = Date(timeIntervalSince1970: 1_000)

    private static func toolCall(_ id: String, name: String = "Bash",
                                 result: ToolResult? = nil) -> TranscriptItem {
        .toolCall(
            id: id, name: name, inputJSON: #"{"command":"touch x"}"#,
            inputTruncatedTo: nil, result: result, subagent: nil,
            timestamp: nil, usage: nil)
    }

    private static func text(_ id: String) -> TranscriptItem {
        .assistantText(id: id, text: id, timestamp: nil)
    }

    private static func seed(_ promptID: String, toolUseID: String?) -> PromptCardSeed {
        PromptCardSeed(
            promptID: promptID, toolUseID: toolUseID, toolName: "Bash",
            toolInputJSON: #"{"command":"touch x"}"#, timestamp: when)
    }

    @Test func inPlaceOnAnExistingRow() {
        let items = [Self.text("a"), Self.toolCall("toolu_X"), Self.text("b")]
        let result = PendingPromptMerger.merge(items: items, seeds: [Self.seed("p1", toolUseID: "toolu_X")])
        #expect(result.items == items, "the file decides the card's position; nothing moves or is added")
        #expect(result.cardItemIDs == ["toolu_X": "p1"])
        #expect(result.settledPromptIDs.isEmpty)
    }

    @Test func appendedWhenAbsent() {
        let items = [Self.text("a")]
        let result = PendingPromptMerger.merge(items: items, seeds: [Self.seed("p1", toolUseID: "toolu_X")])
        #expect(result.items.map(\.id) == ["a", "toolu_X"])
        #expect(result.cardItemIDs == ["toolu_X": "p1"])
        guard case .toolCall(_, let name, let input, _, let res, _, let ts, _) = result.items[1] else {
            Issue.record("expected an appended tool call, got \(result.items[1])")
            return
        }
        #expect(name == "Bash")
        #expect(input == #"{"command":"touch x"}"#)
        #expect(res == nil)
        #expect(ts == Self.when)
    }

    @Test func rowsArrivingLaterFromEarlierInTheTurnSitAboveTheCard() {
        let seeds = [Self.seed("p1", toolUseID: "toolu_X")]
        let first = PendingPromptMerger.merge(items: [Self.text("a")], seeds: seeds)
        #expect(first.items.map(\.id) == ["a", "toolu_X"])
        let later = PendingPromptMerger.merge(items: [Self.text("a"), Self.text("b")], seeds: seeds)
        #expect(later.items.map(\.id) == ["a", "b", "toolu_X"])
    }

    @Test func realRowReplacesTheAppendedCardUnderTheSameID() {
        let seeds = [Self.seed("p1", toolUseID: "toolu_X")]
        let appended = PendingPromptMerger.merge(items: [Self.text("a")], seeds: seeds)
        let landed = PendingPromptMerger.merge(items: [Self.text("a"), Self.toolCall("toolu_X")], seeds: seeds)
        #expect(appended.items.map(\.id) == landed.items.map(\.id))
        #expect(landed.cardItemIDs == ["toolu_X": "p1"])
    }

    @Test func fallbackIDWhenNoToolUseID() {
        let result = PendingPromptMerger.merge(items: [Self.text("a")], seeds: [Self.seed("p9", toolUseID: nil)])
        #expect(PendingPromptMerger.fallbackItemID(promptID: "p9") == "prompt-p9")
        #expect(result.items.map(\.id) == ["a", "prompt-p9"])
        #expect(result.cardItemIDs == ["prompt-p9": "p9"])
    }

    private static func questionSeed(_ promptID: String, isLive: Bool = true) -> PromptCardSeed {
        PromptCardSeed(
            promptID: promptID, toolUseID: nil, kind: .question, toolName: "AskUserQuestion",
            toolInputJSON: #"{"questions":[]}"#, timestamp: when, isLive: isLive)
    }

    /// A remote provider sending only `pending_question` never names the tool
    /// call; the `AskUserQuestion` row on disk is the card, not a second row.
    @Test func unpairedQuestionPairsWithTheLastOpenAskUserQuestionRow() {
        let answered = ToolResult(text: "A", truncatedTo: nil, isError: false)
        let items = [
            Self.toolCall("toolu_Q0", name: "AskUserQuestion", result: answered),
            Self.toolCall("toolu_Q1", name: "AskUserQuestion"),
            Self.toolCall("toolu_B", name: "Bash"),
            Self.toolCall("toolu_Q2", name: "AskUserQuestion"),
            Self.text("b"),
        ]
        let result = PendingPromptMerger.merge(items: items, seeds: [Self.questionSeed("q1")])
        #expect(result.items == items, "no prompt-<id> row is appended beside the real one")
        #expect(result.cardItemIDs == ["toolu_Q2": "q1"])
    }

    @Test func unpairedQuestionFallsBackWhenEveryQuestionRowHasAResult() {
        let answered = ToolResult(text: "A", truncatedTo: nil, isError: false)
        let items = [Self.toolCall("toolu_Q0", name: "AskUserQuestion", result: answered)]
        let result = PendingPromptMerger.merge(items: items, seeds: [Self.questionSeed("q1")])
        #expect(result.items.map(\.id) == ["toolu_Q0", "prompt-q1"])
        #expect(result.cardItemIDs == ["prompt-q1": "q1"])
    }

    /// A remote unpaired question that closed is held while the transcript
    /// catches up. Once its row has a result there is no open row left, and
    /// appending `prompt-<id>` would draw the answered question twice for the
    /// whole hold; the answered row is its row, and the prompt is settled.
    @Test func heldUnpairedQuestionSettlesOnTheNewestAnsweredQuestionRow() {
        let answered = ToolResult(text: "A", truncatedTo: nil, isError: false)
        let items = [
            Self.toolCall("toolu_Q0", name: "AskUserQuestion", result: answered),
            Self.text("a"),
            Self.toolCall("toolu_Q1", name: "AskUserQuestion", result: answered),
        ]
        let result = PendingPromptMerger.merge(items: items, seeds: [Self.questionSeed("q1", isLive: false)])
        #expect(result.items == items, "no duplicate prompt-<id> card")
        #expect(result.cardItemIDs.isEmpty)
        #expect(result.settledPromptIDs == ["q1"])
    }

    /// The same transcript with the prompt still live — open, or already
    /// answered from its card: the row has not landed yet, so the card is
    /// appended, and nothing is settled. The older answered row is not its row.
    @Test func openUnpairedQuestionStillAppendsWhenItsRowHasNotLanded() {
        let answered = ToolResult(text: "A", truncatedTo: nil, isError: false)
        let items = [Self.toolCall("toolu_Q0", name: "AskUserQuestion", result: answered)]
        let result = PendingPromptMerger.merge(items: items, seeds: [Self.questionSeed("q1", isLive: true)])
        #expect(result.items.map(\.id) == ["toolu_Q0", "prompt-q1"])
        #expect(result.cardItemIDs == ["prompt-q1": "q1"])
        #expect(result.settledPromptIDs.isEmpty)
    }

    /// A held question whose row is still open keeps carding that row.
    @Test func heldUnpairedQuestionWithAnOpenRowStaysInPlace() {
        let items = [Self.toolCall("toolu_Q1", name: "AskUserQuestion")]
        let result = PendingPromptMerger.merge(items: items, seeds: [Self.questionSeed("q1", isLive: false)])
        #expect(result.items == items)
        #expect(result.cardItemIDs == ["toolu_Q1": "q1"])
        #expect(result.settledPromptIDs.isEmpty)
    }

    @Test func unpairedPermissionNeverPairsWithAQuestionRow() {
        let items = [Self.toolCall("toolu_Q1", name: "AskUserQuestion")]
        let result = PendingPromptMerger.merge(items: items, seeds: [Self.seed("p1", toolUseID: nil)])
        #expect(result.cardItemIDs == ["prompt-p1": "p1"])
    }

    @Test func settledWhenTheResultIsOnDisk() {
        let done = ToolResult(text: "ok", truncatedTo: nil, isError: false)
        let items = [Self.toolCall("toolu_X", result: done)]
        let result = PendingPromptMerger.merge(items: items, seeds: [Self.seed("p1", toolUseID: "toolu_X")])
        #expect(result.items == items)
        #expect(result.cardItemIDs.isEmpty, "a tool call with its result is an ordinary row again")
        #expect(result.settledPromptIDs == ["p1"])
    }

    @Test func appendedSeedsKeepSeedOrder() {
        let result = PendingPromptMerger.merge(
            items: [],
            seeds: [Self.seed("p1", toolUseID: "toolu_A"), Self.seed("p2", toolUseID: nil),
                    Self.seed("p3", toolUseID: "toolu_B")])
        #expect(result.items.map(\.id) == ["toolu_A", "prompt-p2", "toolu_B"])
    }

    @Test func aDuplicateSeedNeverAppendsTwice() {
        let result = PendingPromptMerger.merge(
            items: [],
            seeds: [Self.seed("p1", toolUseID: "toolu_A"), Self.seed("p2", toolUseID: "toolu_A")])
        #expect(result.items.map(\.id) == ["toolu_A"])
        #expect(result.cardItemIDs == ["toolu_A": "p1"])
    }

    @Test func idsNeverUseLineOrTailPrefixes() {
        let result = PendingPromptMerger.merge(
            items: [Self.text("line-3")],
            seeds: [Self.seed("p1", toolUseID: "toolu_A"), Self.seed("p2", toolUseID: nil),
                    Self.seed("p3", toolUseID: "line-7"), Self.seed("p4", toolUseID: "tail-2")])
        for id in result.cardItemIDs.keys {
            #expect(!id.hasPrefix("line-") && !id.hasPrefix("tail-"), "card id \(id)")
        }
        #expect(Set(result.cardItemIDs.keys) == ["toolu_A", "prompt-p2", "prompt-p3", "prompt-p4"])
    }

    @Test func noSeedsLeavesItemsUntouched() {
        let items = [Self.text("a"), Self.toolCall("toolu_X")]
        let result = PendingPromptMerger.merge(items: items, seeds: [])
        #expect(result.items == items)
        #expect(result.cardItemIDs.isEmpty)
        #expect(result.settledPromptIDs.isEmpty)
    }
}
