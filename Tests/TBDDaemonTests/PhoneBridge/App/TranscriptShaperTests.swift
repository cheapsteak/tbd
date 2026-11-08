import Foundation
import TBDShared
import Testing

@testable import TBDDaemonLib

/// The time every fixture item carries, and the same time in Unix
/// milliseconds as a phone row's `at`.
private let fixtureDate = Date(timeIntervalSince1970: 1_762_499_460)
private let fixtureAt: Int64 = 1_762_499_460_000

/// The row the shaper should make, with every field the test does not name
/// left nil.
private func row(
    _ id: String, _ kind: PhoneItemKind, at: Int64? = fixtureAt,
    text: String? = nil, truncated: Bool = false,
    toolName: String? = nil, target: String? = nil, toolStatus: String? = nil,
    added: Int? = nil, removed: Int? = nil,
    agentType: String? = nil, itemCount: Int? = nil, sender: String? = nil
) -> PhoneItem {
    PhoneItem(
        id: id, kind: kind, at: at, text: text, truncated: truncated,
        toolName: toolName, target: target, toolStatus: toolStatus,
        added: added, removed: removed, agentType: agentType, itemCount: itemCount, sender: sender)
}

/// A tool call item whose input is `inputJSON`.
private func call(_ id: String, _ name: String, _ inputJSON: String, result: ToolResult? = nil) -> TranscriptItem {
    .toolCall(
        id: id, name: name, inputJSON: inputJSON, inputTruncatedTo: nil,
        result: result, subagent: nil, timestamp: fixtureDate)
}

private let okResult = ToolResult(text: "done", truncatedTo: nil, isError: false)
private let errorResult = ToolResult(text: "failed", truncatedTo: nil, isError: true)

/// Tier 1: pure functions over values. Nothing touches the disk, a clock or
/// the network.
@Suite("Transcript shaper")
struct TranscriptShaperTests {
    // MARK: - Messages

    @Test func aUserPromptIsAUserRow() {
        let item = TranscriptItem.userPrompt(id: "u1", text: "The login page loops. Can you fix it?", timestamp: fixtureDate)

        let shaped = TranscriptShaper.shape(item, ShapingContext())

        #expect(shaped == row("u1", .user, text: "The login page loops. Can you fix it?"))
    }

    @Test func aOneLineSlashPromptIsASlashRow() {
        let item = TranscriptItem.userPrompt(id: "u1", text: "/model opus", timestamp: fixtureDate)

        let shaped = TranscriptShaper.shape(item, ShapingContext())

        #expect(shaped == row("u1", .slash, text: "/model opus"))
    }

    @Test func aSlashPromptWithANewlineIsAUserRow() {
        let item = TranscriptItem.userPrompt(id: "u1", text: "/review\nthe redirect change", timestamp: fixtureDate)

        let shaped = TranscriptShaper.shape(item, ShapingContext())

        #expect(shaped == row("u1", .user, text: "/review\nthe redirect change"))
    }

    @Test func assistantTextIsAnAssistantRow() {
        let item = TranscriptItem.assistantText(id: "a1#0", text: "I'll look at the redirect first.", timestamp: fixtureDate)

        let shaped = TranscriptShaper.shape(item, ShapingContext())

        #expect(shaped == row("a1#0", .assistant, text: "I'll look at the redirect first."))
    }

    @Test func anItemWithNoTimestampHasNoAt() {
        let item = TranscriptItem.userPrompt(id: "u1", text: "hello", timestamp: nil)

        let shaped = TranscriptShaper.shape(item, ShapingContext())

        #expect(shaped == row("u1", .user, at: nil, text: "hello"))
    }

    @Test func aVerifiedPeerIsLabeledByItsName() {
        let sender = PeerSender(name: "acme-api/update-deps", from: "acme-api", verified: true, pid: 4242)
        let item = TranscriptItem.peerMessage(
            id: "p1", sender: sender, text: "The migration is done.", deliveredPayload: nil, timestamp: fixtureDate)

        let shaped = TranscriptShaper.shape(item, ShapingContext())

        #expect(shaped == row("p1", .peer, text: "The migration is done.", sender: "acme-api/update-deps"))
    }

    @Test func anUnverifiedPeerCarriesTheMark() {
        let sender = PeerSender(name: "acme-api/update-deps", from: "acme-api", verified: false, pid: nil)
        let item = TranscriptItem.peerMessage(
            id: "p1", sender: sender, text: "The migration is done.", deliveredPayload: nil, timestamp: fixtureDate)

        let shaped = TranscriptShaper.shape(item, ShapingContext())

        #expect(shaped == row("p1", .peer, text: "The migration is done.", sender: "acme-api (unverified)"))
    }

    @Test func aLongSenderIsCutAndKeepsItsMark() throws {
        let sender = PeerSender(name: nil, from: String(repeating: "\"", count: 1_000), verified: false, pid: nil)
        let item = TranscriptItem.peerMessage(
            id: "p1", sender: sender, text: "hi", deliveredPayload: nil, timestamp: fixtureDate)

        let shaped = try #require(TranscriptShaper.shape(item, ShapingContext()))
        let label = try #require(shaped.sender)

        #expect(PhoneFrameBudget.escapedLength(label[...].unicodeScalars) <= TranscriptShaper.senderLimit)
        #expect(label.hasSuffix(TranscriptShaper.unverifiedSuffix))
    }

    // MARK: - Tool rows

    @Test(arguments: ["Edit", "Write", "MultiEdit"])
    func aFileEditToolIsAFileEditRow(name: String) {
        let item = call("toolu_e", name, #"{"file_path":"/repo/src/auth/redirect.ts","new_string":"b","old_string":"a"}"#, result: okResult)
        let ctx = ShapingContext(fileEdits: ["toolu_e": FileEditStats(added: 12, removed: 3)])

        let shaped = TranscriptShaper.shape(item, ctx)

        #expect(shaped == row(
            "toolu_e", .fileEdit, toolName: name, target: "redirect.ts", toolStatus: "ok", added: 12, removed: 3))
    }

    @Test(arguments: ["Agent", "Task"])
    func aSubagentCallIsASubagentRow(name: String) {
        let item = call(
            "toolu_s", name,
            #"{"description":"Find every caller of setSession","prompt":"Search the repo.","subagent_type":"Explore"}"#,
            result: okResult)
        let ctx = ShapingContext(
            subagentAgentIDs: ["toolu_s": "a0123456789abcdef"],
            subagentItemCount: { agentID in agentID == "a0123456789abcdef" ? 14 : nil })

        let shaped = TranscriptShaper.shape(item, ctx)

        #expect(shaped == row(
            "toolu_s", .subagent, toolName: name, target: "Find every caller of setSession", toolStatus: "ok",
            agentType: "Explore", itemCount: 14))
    }

    @Test func aSubagentWithNoAgentIDYetHasNoCount() {
        let item = call("toolu_s", "Agent", #"{"description":"Survey the tests","subagent_type":"Explore"}"#)
        let ctx = ShapingContext(subagentItemCount: { _ in 14 })

        let shaped = TranscriptShaper.shape(item, ctx)

        #expect(shaped == row(
            "toolu_s", .subagent, toolName: "Agent", target: "Survey the tests", toolStatus: "running",
            agentType: "Explore"))
    }

    @Test func aSubagentCountIsHeldToTheLimit() throws {
        let item = call("toolu_s", "Agent", #"{"description":"Survey the tests","subagent_type":"Explore"}"#, result: okResult)
        let ctx = ShapingContext(subagentAgentIDs: ["toolu_s": "a1"], subagentItemCount: { _ in 50_000_000 })

        let shaped = try #require(TranscriptShaper.shape(item, ctx))

        #expect(shaped.itemCount == PhoneAppConstants.subagentCountLimit)
    }

    @Test func anyOtherToolIsAToolRow() {
        let item = call("toolu_b", "Bash", #"{"command":"npm test -- login"}"#)

        let shaped = TranscriptShaper.shape(item, ShapingContext())

        #expect(shaped == row("toolu_b", .tool, toolName: "Bash", target: "npm test -- login", toolStatus: "running"))
    }

    @Test func aToolWithAnErrorResultIsAnError() {
        let item = call("toolu_b", "Bash", #"{"command":"git switch -c fix-login"}"#, result: errorResult)

        let shaped = TranscriptShaper.shape(item, ShapingContext())

        #expect(shaped == row("toolu_b", .tool, toolName: "Bash", target: "git switch -c fix-login", toolStatus: "error"))
    }

    @Test func aToolWithNothingToNameHasNoTarget() {
        let item = call("toolu_t", "TodoWrite", #"{"todos":[]}"#, result: okResult)

        let shaped = TranscriptShaper.shape(item, ShapingContext())

        #expect(shaped == row("toolu_t", .tool, toolName: "TodoWrite", toolStatus: "ok"))
    }

    @Test func aJoinedResultSetsTheStatus() {
        let item = call("toolu_b", "Bash", #"{"command":"swift test"}"#)

        let alone = TranscriptShaper.shape(item, ShapingContext())
        let joinedOK = TranscriptShaper.shape(item, ShapingContext(joinedResults: ["toolu_b": okResult]))
        let joinedError = TranscriptShaper.shape(item, ShapingContext(joinedResults: ["toolu_b": errorResult]))
        let joinedElsewhere = TranscriptShaper.shape(item, ShapingContext(joinedResults: ["toolu_other": okResult]))

        #expect(alone?.toolStatus == "running")
        #expect(joinedOK == row("toolu_b", .tool, toolName: "Bash", target: "swift test", toolStatus: "ok"))
        #expect(joinedError?.toolStatus == "error")
        #expect(joinedElsewhere?.toolStatus == "running")
    }

    @Test func theItemsOwnResultWinsOverAJoinedOne() {
        let item = call("toolu_b", "Bash", #"{"command":"swift test"}"#, result: errorResult)

        let shaped = TranscriptShaper.shape(item, ShapingContext(joinedResults: ["toolu_b": okResult]))

        #expect(shaped?.toolStatus == "error")
    }

    @Test func aLongTargetIsCut() throws {
        let fileName = String(repeating: "é", count: 2_000)
        let item = call("toolu_r", "Read", #"{"file_path":"/repo/\#(fileName)"}"#, result: okResult)

        let shaped = try #require(TranscriptShaper.shape(item, ShapingContext()))

        #expect(shaped.target == String(repeating: "é", count: TranscriptShaper.targetLimit / 2))
    }

    // MARK: - Details

    @Test func detailsAreOffByDefault() {
        let ctx = ShapingContext()
        let thinking = TranscriptItem.thinking(id: "a1#0", text: "The cookie must be set first.", timestamp: fixtureDate)
        let reminder = TranscriptItem.systemReminder(id: "s1", kind: .hookOutput, text: "lint passed", timestamp: fixtureDate)
        let prompt = TranscriptItem.userPrompt(id: "u1", text: "hello", timestamp: fixtureDate)

        #expect(!ctx.showDetails)
        #expect(TranscriptShaper.shape(thinking, ctx) == nil)
        #expect(TranscriptShaper.shape(reminder, ctx) == nil)
        #expect(TranscriptShaper.shape(prompt, ctx) == row("u1", .user, text: "hello"))
    }

    @Test func thinkingShowsWithDetails() {
        let item = TranscriptItem.thinking(id: "a1#0", text: "The cookie must be set first.", timestamp: fixtureDate)

        let shaped = TranscriptShaper.shape(item, ShapingContext(showDetails: true))

        #expect(shaped == row("a1#0", .thinking, text: "The cookie must be set first."))
    }

    @Test func aSystemReminderIsASystemNoteWithDetails() {
        let item = TranscriptItem.systemReminder(
            id: "s1", kind: .hookOutput, text: "PostToolUse hook: lint passed", timestamp: fixtureDate,
            source: "PostToolUse:Bash")

        let shaped = TranscriptShaper.shape(item, ShapingContext(showDetails: true))

        #expect(shaped == row("s1", .systemNote, text: "PostToolUse hook: lint passed"))
    }

    @Test func aReminderTheParserCutIsTruncated() {
        let item = TranscriptItem.systemReminder(
            id: "s1", kind: .nestedMemory, text: "short", timestamp: fixtureDate, truncatedTo: 9_000)

        let shaped = TranscriptShaper.shape(item, ShapingContext(showDetails: true))

        #expect(shaped == row("s1", .systemNote, text: "short", truncated: true))
    }

    @Test func aSlashCommandItemIsNeverShown() {
        let item = TranscriptItem.slashCommand(id: "c1", name: "compact", args: nil, timestamp: fixtureDate)

        #expect(TranscriptShaper.shape(item, ShapingContext()) == nil)
        #expect(TranscriptShaper.shape(item, ShapingContext(showDetails: true)) == nil)
    }

    // MARK: - Previews

    @Test func aLongMessageIsCutAtACharacterBoundary() throws {
        let text = String(repeating: "é", count: 2_500)
        #expect(text.utf8.count == 5_000)

        let cut = TranscriptShaper.preview(text)
        let shaped = try #require(TranscriptShaper.shape(
            .userPrompt(id: "u1", text: text, timestamp: fixtureDate), ShapingContext()))

        #expect(cut.text.utf8.count <= 4_096)
        #expect(cut.truncated)
        #expect(cut.text == String(repeating: "é", count: 2_048))
        #expect(shaped == row("u1", .user, text: cut.text, truncated: true))
    }

    @Test func noCutSplitsACharacter() {
        // Each character is two scalars and three UTF-8 bytes.
        let text = String(repeating: "e\u{301}", count: 2_000)

        let cut = TranscriptShaper.preview(text)

        #expect(cut.truncated)
        #expect(cut.text == String(repeating: "e\u{301}", count: 1_365))
        #expect(cut.text.unicodeScalars.count == 2 * 1_365)
    }

    @Test func aPreviewCountsTheBytesTheTextTakesInJSON() {
        let quotes = TranscriptShaper.preview(String(repeating: "\"", count: 5_000))
        let controls = TranscriptShaper.preview(String(repeating: "\u{1}", count: 5_000))

        // A quote encodes as 2 bytes, a control character as 6.
        #expect(quotes.text.count == 2_048)
        #expect(quotes.truncated)
        #expect(controls.text.count == 682)
        #expect(controls.truncated)
    }

    @Test func aMessageAtTheLimitIsWhole() {
        let text = String(repeating: "a", count: 4_096)

        let cut = TranscriptShaper.preview(text)
        let short = TranscriptShaper.preview("hello")

        #expect(cut.text == text)
        #expect(!cut.truncated)
        #expect(short.text == "hello")
        #expect(!short.truncated)
    }
}
