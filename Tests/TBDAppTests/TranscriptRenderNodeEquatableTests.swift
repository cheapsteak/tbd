import Foundation
import Testing
import TBDShared

@testable import TBDApp

/// Regression armor for the cheap `TranscriptRenderNode.==` (issue #129).
///
/// The synthesized `==` was replaced with an O(1) identity + content-version
/// compare. These tests verify:
///   A. Basic equality truth table.
///   B. Every "content mutated under a stable id" case that must be !=
///      (the correctness-critical invariant — a false positive would silently
///      drop a SwiftUI re-render).
///   C. `Kind.==` hand-written structural equality covers every associated
///      value for every case.
///   D. Micro-benchmark printing before/after numbers for the perf record.
@Suite("TranscriptRenderNodeEquatable")
struct TranscriptRenderNodeEquatableTests {

    // MARK: - Helpers

    private func makeToolCallNode(
        id: String = "tool-1",
        name: String = "Bash",
        inputJSON: String = "{}",
        inputTruncatedTo: Int? = nil,
        result: ToolResult? = nil,
        timestamp: Date? = nil,
        badgeUsage: TokenUsage? = nil
    ) -> TranscriptRenderNode {
        TranscriptRenderNode(
            id: id,
            kind: .toolCall(id: id, name: name, inputJSON: inputJSON,
                            inputTruncatedTo: inputTruncatedTo, result: result,
                            timestamp: timestamp),
            badgeUsage: badgeUsage
        )
    }

    private func makeAssistantNode(
        id: String = "ast-1",
        text: String = "hello",
        usage: TokenUsage? = nil,
        badgeUsage: TokenUsage? = nil
    ) -> TranscriptRenderNode {
        TranscriptRenderNode(
            id: id,
            kind: .chatBubble(.assistantText(id: id, text: text, timestamp: nil, usage: usage)),
            badgeUsage: badgeUsage
        )
    }

    private func makeUserPromptNode(
        id: String = "usr-1",
        text: String = "hi"
    ) -> TranscriptRenderNode {
        TranscriptRenderNode(
            id: id,
            kind: .chatBubble(.userPrompt(id: id, text: text, timestamp: nil)),
            badgeUsage: nil
        )
    }

    private func makeSystemReminderNode(
        id: String = "sys-1",
        kind: SystemKind = .other,
        text: String = "reminder"
    ) -> TranscriptRenderNode {
        TranscriptRenderNode(
            id: id,
            kind: .systemReminder(id: id, kind: kind, text: text, timestamp: nil),
            badgeUsage: nil
        )
    }

    private func makeSkillBodyNode(
        id: String = "skill-1",
        text: String = "body"
    ) -> TranscriptRenderNode {
        TranscriptRenderNode(
            id: id,
            kind: .skillBody(id: id, text: text, timestamp: nil),
            badgeUsage: nil
        )
    }

    private func makeSubagentNode(
        id: String = "sub-1",
        parentID: String = "parent-1",
        count: Int = 3,
        agentType: String? = nil
    ) -> TranscriptRenderNode {
        TranscriptRenderNode(
            id: id,
            kind: .subagentSummary(parentItemID: parentID, count: count, agentType: agentType),
            badgeUsage: nil
        )
    }

    // MARK: - A. Equality truth table

    @Test func sameIdIdenticalPayload_isEqual() {
        let a = makeToolCallNode(id: "t1", inputJSON: "{\"cmd\":\"ls\"}")
        let b = makeToolCallNode(id: "t1", inputJSON: "{\"cmd\":\"ls\"}")
        #expect(a == b)
    }

    @Test func differentId_identicalPayload_isNotEqual() {
        let a = makeToolCallNode(id: "t1", inputJSON: "{}")
        let b = makeToolCallNode(id: "t2", inputJSON: "{}")
        #expect(a != b)
    }

    // MARK: - B. Content-mutated-under-stable-id cases (each must be !=)

    // toolCall: result nil → populated
    @Test func toolCall_resultNilVsPopulated_isNotEqual() {
        let a = makeToolCallNode(id: "t1", result: nil)
        let b = makeToolCallNode(id: "t1", result: ToolResult(text: "output", truncatedTo: nil, isError: false))
        #expect(a != b)
        // positive control: same result → equal
        let c = makeToolCallNode(id: "t1", result: nil)
        #expect(a == c)
    }

    // toolCall: result text grows ("a" → "ab")
    @Test func toolCall_resultTextGrows_isNotEqual() {
        let a = makeToolCallNode(id: "t1", result: ToolResult(text: "a", truncatedTo: nil, isError: false))
        let b = makeToolCallNode(id: "t1", result: ToolResult(text: "ab", truncatedTo: nil, isError: false))
        #expect(a != b)
        let c = makeToolCallNode(id: "t1", result: ToolResult(text: "a", truncatedTo: nil, isError: false))
        #expect(a == c)
    }

    // toolCall: result.isError false → true
    @Test func toolCall_resultIsErrorChanges_isNotEqual() {
        let a = makeToolCallNode(id: "t1", result: ToolResult(text: "out", truncatedTo: nil, isError: false))
        let b = makeToolCallNode(id: "t1", result: ToolResult(text: "out", truncatedTo: nil, isError: true))
        #expect(a != b)
    }

    // toolCall: result.truncatedTo nil → 100
    @Test func toolCall_resultTruncatedToChanges_isNotEqual() {
        let a = makeToolCallNode(id: "t1", result: ToolResult(text: "out", truncatedTo: nil, isError: false))
        let b = makeToolCallNode(id: "t1", result: ToolResult(text: "out", truncatedTo: 100, isError: false))
        #expect(a != b)
    }

    // toolCall: inputJSON changes
    @Test func toolCall_inputJSONChanges_isNotEqual() {
        let a = makeToolCallNode(id: "t1", inputJSON: "{\"cmd\":\"ls\"}")
        let b = makeToolCallNode(id: "t1", inputJSON: "{\"cmd\":\"pwd\"}")
        #expect(a != b)
        let c = makeToolCallNode(id: "t1", inputJSON: "{\"cmd\":\"ls\"}")
        #expect(a == c)
    }

    // toolCall: inputTruncatedTo nil → 50
    @Test func toolCall_inputTruncatedToChanges_isNotEqual() {
        let a = makeToolCallNode(id: "t1", inputTruncatedTo: nil)
        let b = makeToolCallNode(id: "t1", inputTruncatedTo: 50)
        #expect(a != b)
    }

    // toolCall: name changes
    @Test func toolCall_nameChanges_isNotEqual() {
        let a = makeToolCallNode(id: "t1", name: "Bash")
        let b = makeToolCallNode(id: "t1", name: "Read")
        #expect(a != b)
    }

    // toolCall: timestamp nil → a Date
    @Test func toolCall_timestampChanges_isNotEqual() {
        let ts = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let a = makeToolCallNode(id: "t1", timestamp: nil)
        let b = makeToolCallNode(id: "t1", timestamp: ts)
        #expect(a != b)
    }

    // chatBubble assistantText: text grows
    @Test func assistantText_textGrows_isNotEqual() {
        let a = makeAssistantNode(id: "a1", text: "hi")
        let b = makeAssistantNode(id: "a1", text: "hi there")
        #expect(a != b)
        let c = makeAssistantNode(id: "a1", text: "hi")
        #expect(a == c)
    }

    // chatBubble assistantText: usage nil → TokenUsage
    @Test func assistantText_usageNilVsPopulated_isNotEqual() {
        let a = makeAssistantNode(id: "a1", usage: nil)
        let b = makeAssistantNode(id: "a1", usage: TokenUsage(inputTokens: 10, cacheCreationTokens: 0, cacheReadTokens: 0))
        #expect(a != b)
    }

    // chatBubble userPrompt: text changes
    @Test func userPrompt_textChanges_isNotEqual() {
        let a = makeUserPromptNode(id: "u1", text: "original")
        let b = makeUserPromptNode(id: "u1", text: "edited")
        #expect(a != b)
        let c = makeUserPromptNode(id: "u1", text: "original")
        #expect(a == c)
    }

    // systemReminder: text changes
    @Test func systemReminder_textChanges_isNotEqual() {
        let a = makeSystemReminderNode(id: "s1", text: "old reminder")
        let b = makeSystemReminderNode(id: "s1", text: "new reminder")
        #expect(a != b)
    }

    // systemReminder: kind changes (.skillBody vs .other)
    @Test func systemReminder_kindChanges_isNotEqual() {
        let a = makeSystemReminderNode(id: "s1", kind: .skillBody, text: "body")
        let b = makeSystemReminderNode(id: "s1", kind: .other, text: "body")
        #expect(a != b)
    }

    // skillBody: text changes
    @Test func skillBody_textChanges_isNotEqual() {
        let a = makeSkillBodyNode(id: "k1", text: "version A")
        let b = makeSkillBodyNode(id: "k1", text: "version B")
        #expect(a != b)
        let c = makeSkillBodyNode(id: "k1", text: "version A")
        #expect(a == c)
    }

    // subagentSummary: count changes
    @Test func subagentSummary_countChanges_isNotEqual() {
        let a = makeSubagentNode(id: "sb1", parentID: "p1", count: 1)
        let b = makeSubagentNode(id: "sb1", parentID: "p1", count: 2)
        #expect(a != b)
    }

    // subagentSummary: agentType nil → "explorer"
    @Test func subagentSummary_agentTypeChanges_isNotEqual() {
        let a = makeSubagentNode(id: "sb1", parentID: "p1", count: 3, agentType: nil)
        let b = makeSubagentNode(id: "sb1", parentID: "p1", count: 3, agentType: "explorer")
        #expect(a != b)
    }

    // badgeUsage: nil vs TokenUsage
    @Test func badgeUsage_nilVsPopulated_isNotEqual() {
        let a = makeToolCallNode(id: "t1", badgeUsage: nil)
        let b = makeToolCallNode(id: "t1", badgeUsage: TokenUsage(inputTokens: 5, cacheCreationTokens: 0, cacheReadTokens: 0))
        #expect(a != b)
    }

    // badgeUsage: two different TokenUsage values
    @Test func badgeUsage_differentValues_isNotEqual() {
        let u1 = TokenUsage(inputTokens: 100, cacheCreationTokens: 10, cacheReadTokens: 5)
        let u2 = TokenUsage(inputTokens: 200, cacheCreationTokens: 20, cacheReadTokens: 10)
        let a = makeToolCallNode(id: "t1", badgeUsage: u1)
        let b = makeToolCallNode(id: "t1", badgeUsage: u2)
        #expect(a != b)
    }

    // MARK: - C. Kind hand-written == (every case, every associated value)

    // chatBubble: equal when item equal
    @Test func kind_chatBubble_equalWhenItemsEqual() {
        let k1 = TranscriptRenderNode.Kind.chatBubble(.userPrompt(id: "u1", text: "hello", timestamp: nil))
        let k2 = TranscriptRenderNode.Kind.chatBubble(.userPrompt(id: "u1", text: "hello", timestamp: nil))
        #expect(k1 == k2)
    }

    // chatBubble: not equal when item differs
    @Test func kind_chatBubble_notEqualWhenItemsDiffer() {
        let k1 = TranscriptRenderNode.Kind.chatBubble(.userPrompt(id: "u1", text: "hello", timestamp: nil))
        let k2 = TranscriptRenderNode.Kind.chatBubble(.userPrompt(id: "u1", text: "goodbye", timestamp: nil))
        #expect(k1 != k2)
    }

    // systemReminder: all four associated values contribute
    @Test func kind_systemReminder_allValuesContribute() {
        let ts = Date(timeIntervalSinceReferenceDate: 500_000)
        let base = TranscriptRenderNode.Kind.systemReminder(id: "s1", kind: .other, text: "msg", timestamp: ts)
        #expect(base == TranscriptRenderNode.Kind.systemReminder(id: "s1", kind: .other, text: "msg", timestamp: ts))
        #expect(base != TranscriptRenderNode.Kind.systemReminder(id: "s2", kind: .other, text: "msg", timestamp: ts))
        #expect(base != TranscriptRenderNode.Kind.systemReminder(id: "s1", kind: .skillBody, text: "msg", timestamp: ts))
        #expect(base != TranscriptRenderNode.Kind.systemReminder(id: "s1", kind: .other, text: "other", timestamp: ts))
        #expect(base != TranscriptRenderNode.Kind.systemReminder(id: "s1", kind: .other, text: "msg", timestamp: nil))
    }

    // skillBody: all three associated values contribute
    @Test func kind_skillBody_allValuesContribute() {
        let ts = Date(timeIntervalSinceReferenceDate: 600_000)
        let base = TranscriptRenderNode.Kind.skillBody(id: "k1", text: "body", timestamp: ts)
        #expect(base == TranscriptRenderNode.Kind.skillBody(id: "k1", text: "body", timestamp: ts))
        #expect(base != TranscriptRenderNode.Kind.skillBody(id: "k2", text: "body", timestamp: ts))
        #expect(base != TranscriptRenderNode.Kind.skillBody(id: "k1", text: "other", timestamp: ts))
        #expect(base != TranscriptRenderNode.Kind.skillBody(id: "k1", text: "body", timestamp: nil))
    }

    // toolCall: all six associated values contribute
    @Test func kind_toolCall_allValuesContribute() {
        let ts = Date(timeIntervalSinceReferenceDate: 700_000)
        let result = ToolResult(text: "out", truncatedTo: nil, isError: false)
        let base = TranscriptRenderNode.Kind.toolCall(
            id: "t1", name: "Bash", inputJSON: "{}", inputTruncatedTo: nil, result: result, timestamp: ts
        )
        #expect(base == TranscriptRenderNode.Kind.toolCall(
            id: "t1", name: "Bash", inputJSON: "{}", inputTruncatedTo: nil, result: result, timestamp: ts
        ))
        #expect(base != TranscriptRenderNode.Kind.toolCall(
            id: "t2", name: "Bash", inputJSON: "{}", inputTruncatedTo: nil, result: result, timestamp: ts
        ))
        #expect(base != TranscriptRenderNode.Kind.toolCall(
            id: "t1", name: "Read", inputJSON: "{}", inputTruncatedTo: nil, result: result, timestamp: ts
        ))
        #expect(base != TranscriptRenderNode.Kind.toolCall(
            id: "t1", name: "Bash", inputJSON: "{\"x\":1}", inputTruncatedTo: nil, result: result, timestamp: ts
        ))
        #expect(base != TranscriptRenderNode.Kind.toolCall(
            id: "t1", name: "Bash", inputJSON: "{}", inputTruncatedTo: 50, result: result, timestamp: ts
        ))
        #expect(base != TranscriptRenderNode.Kind.toolCall(
            id: "t1", name: "Bash", inputJSON: "{}", inputTruncatedTo: nil, result: nil, timestamp: ts
        ))
        #expect(base != TranscriptRenderNode.Kind.toolCall(
            id: "t1", name: "Bash", inputJSON: "{}", inputTruncatedTo: nil, result: result, timestamp: nil
        ))
    }

    // subagentSummary: all three associated values contribute
    @Test func kind_subagentSummary_allValuesContribute() {
        let base = TranscriptRenderNode.Kind.subagentSummary(parentItemID: "p1", count: 3, agentType: "explorer")
        #expect(base == TranscriptRenderNode.Kind.subagentSummary(parentItemID: "p1", count: 3, agentType: "explorer"))
        #expect(base != TranscriptRenderNode.Kind.subagentSummary(parentItemID: "p2", count: 3, agentType: "explorer"))
        #expect(base != TranscriptRenderNode.Kind.subagentSummary(parentItemID: "p1", count: 4, agentType: "explorer"))
        #expect(base != TranscriptRenderNode.Kind.subagentSummary(parentItemID: "p1", count: 3, agentType: nil))
    }

    // cross-case inequality
    @Test func kind_crossCase_notEqual() {
        let skill = TranscriptRenderNode.Kind.skillBody(id: "k1", text: "body", timestamp: nil)
        let reminder = TranscriptRenderNode.Kind.systemReminder(id: "k1", kind: .other, text: "body", timestamp: nil)
        #expect(skill != reminder)

        let chatBubble = TranscriptRenderNode.Kind.chatBubble(.userPrompt(id: "u1", text: "body", timestamp: nil))
        #expect(skill != chatBubble)
        #expect(reminder != chatBubble)
    }

    // MARK: - D. Micro-benchmark: three variants

    @Test func benchmark_equality_cheap_vs_structural() {
        // Build 163 nodes with realistic large payloads. Use distinct String
        // buffers (String(repeating:)) to avoid COW sharing — models the
        // cross-poll case where new node values are freshly allocated.
        let inputJSON     = String(repeating: "x", count: 2_000)
        let resultText    = String(repeating: "y", count: 5_000)
        let assistantText = String(repeating: "z", count: 3_000)

        var nodesA: [TranscriptRenderNode] = []
        nodesA.reserveCapacity(163)
        for i in 0..<130 {
            let id = "tool-\(i)"
            nodesA.append(TranscriptRenderNode(
                id: id,
                kind: .toolCall(
                    id: id, name: "Bash", inputJSON: inputJSON,
                    inputTruncatedTo: nil,
                    result: ToolResult(text: resultText, truncatedTo: nil, isError: false),
                    timestamp: nil
                ),
                badgeUsage: nil
            ))
        }
        for i in 0..<33 {
            let id = "ast-\(i)"
            nodesA.append(TranscriptRenderNode(
                id: id,
                kind: .chatBubble(.assistantText(id: id, text: assistantText, timestamp: nil, usage: nil)),
                badgeUsage: nil
            ))
        }

        // Second array: fresh (non-COW-shared) buffers with identical content,
        // modelling the cross-poll allocation pattern.
        let inputJSON2     = String(repeating: "x", count: 2_000)
        let resultText2    = String(repeating: "y", count: 5_000)
        let assistantText2 = String(repeating: "z", count: 3_000)
        var nodesB: [TranscriptRenderNode] = []
        nodesB.reserveCapacity(163)
        for i in 0..<130 {
            let id = "tool-\(i)"
            nodesB.append(TranscriptRenderNode(
                id: id,
                kind: .toolCall(
                    id: id, name: "Bash", inputJSON: inputJSON2,
                    inputTruncatedTo: nil,
                    result: ToolResult(text: resultText2, truncatedTo: nil, isError: false),
                    timestamp: nil
                ),
                badgeUsage: nil
            ))
        }
        for i in 0..<33 {
            let id = "ast-\(i)"
            nodesB.append(TranscriptRenderNode(
                id: id,
                kind: .chatBubble(.assistantText(id: id, text: assistantText2, timestamp: nil, usage: nil)),
                badgeUsage: nil
            ))
        }

        let N = 2_000
        let total = N * nodesA.count

        // Accumulate bool results into a counter so the optimizer cannot
        // dead-code-eliminate the comparison loops in a release build.
        var structuralMatches = 0
        var cheapWithSignpostMatches = 0
        var cheapNoSignpostMatches = 0

        let clock = ContinuousClock()

        // VARIANT 1 — structural: faithfully reproduces what the synthesized == did
        // (full recursive walk through all associated values via Kind.== and
        // badgeUsage ==). Kind.== is hand-written but structurally identical.
        let structuralTime = clock.measure {
            for _ in 0..<N {
                for (l, r) in zip(nodesA, nodesB) {
                    if l.kind == r.kind && l.badgeUsage == r.badgeUsage {
                        structuralMatches &+= 1
                    }
                }
            }
        }

        // VARIANT 2 — cheapWithSignpost: the current production ==
        // (id + contentVersion, with the OSSignposter interval inside).
        let cheapWithSignpostTime = clock.measure {
            for _ in 0..<N {
                for (l, r) in zip(nodesA, nodesB) {
                    if l == r {
                        cheapWithSignpostMatches &+= 1
                    }
                }
            }
        }

        // VARIANT 3 — cheapNoSignpost: same O(1) compare but without the
        // signpost call, to isolate the true comparison cost from signpost overhead.
        let cheapNoSignpostTime = clock.measure {
            for _ in 0..<N {
                for (l, r) in zip(nodesA, nodesB) {
                    if l.id == r.id && l.contentVersion == r.contentVersion {
                        cheapNoSignpostMatches &+= 1
                    }
                }
            }
        }

        let structuralMs        = Double(structuralTime.components.attoseconds)        / 1e15
        let cheapWithSignpostMs = Double(cheapWithSignpostTime.components.attoseconds)  / 1e15
        let cheapNoSignpostMs   = Double(cheapNoSignpostTime.components.attoseconds)    / 1e15
        let ratioNoSignpost     = structuralMs / cheapNoSignpostMs
        let ratioWithSignpost   = structuralMs / cheapWithSignpostMs

        print(String(format:
            "BENCH structural=%.1fms cheapWithSignpost=%.1fms cheapNoSignpost=%.1fms" +
            "  ratios: structural/cheapNoSignpost=%.1fx structural/cheapWithSignpost=%.1fx",
            structuralMs, cheapWithSignpostMs, cheapNoSignpostMs,
            ratioNoSignpost, ratioWithSignpost))

        // All three variants must agree: identical arrays → all matches.
        #expect(structuralMatches        == total)
        #expect(cheapWithSignpostMatches == total)
        #expect(cheapNoSignpostMatches   == total)
    }
}
