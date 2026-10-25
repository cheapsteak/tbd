import Foundation
import Testing
@testable import TBDApp
import TBDShared

@Suite("PromptOutline")
struct PromptOutlineTests {
    private func nodes(_ items: [TranscriptItem]) -> [TranscriptRenderNode] {
        transcriptRenderNodes(from: items)
    }

    @Test("entries cover prompts, slash commands and peers")
    func entriesCoverPromptsSlashAndPeers() {
        let sender = PeerSender(name: "build-bot", from: "build-bot", verified: true, pid: nil)
        let entries = PromptOutline.entries(from: nodes([
            .userPrompt(id: "p1", text: "fix it", timestamp: nil),
            .assistantText(id: "a1", text: "done", timestamp: nil, usage: nil),
            .userPrompt(id: "p2", text: "/review 1174", timestamp: nil),
            .peerMessage(id: "m1", sender: sender, text: "green", deliveredPayload: nil, timestamp: nil),
        ]))
        #expect(entries.map(\.rowIndex) == [0, 2, 3])
        #expect(entries.map(\.kind) == [.prompt, .prompt, .peer(sender: "build-bot")])
    }

    @Test("untyped markers produce no entries")
    func skipsUntypedMarkers() {
        let entries = PromptOutline.entries(from: nodes([
            .userPrompt(id: "i", text: "[Image: source: /tmp/a.png]", timestamp: nil),
            .userPrompt(id: "x", text: "[Request interrupted by user]", timestamp: nil),
            .userPrompt(
                id: "c",
                text: "This session is being continued from a previous conversation that ran out of context.",
                timestamp: nil),
        ]))
        #expect(entries.isEmpty)
    }

    @Test("first line unwraps paste and collapses whitespace")
    func firstLineUnwrapsPasteAndCollapsesWhitespace() {
        let pasted = "\n\n<pasted_content id=\"62f5\">\n  hello   world\nsecond\n</pasted_content id=\"62f5\">"
        #expect(PromptOutline.firstLine(of: pasted) == "hello world")
        #expect(PromptOutline.firstLine(of: "[Image #1]") == "[Image #1]")
    }

    @Test("tooltip is capped at 500 characters")
    func tooltipIsCappedAt500() {
        let entries = PromptOutline.entries(from: nodes([
            .userPrompt(id: "p", text: String(repeating: "x", count: 900), timestamp: nil),
        ]))
        #expect(entries.first?.tooltip.count == 500)
    }

    @Test("time label: time today, month and day earlier, empty for nil")
    func timeLabelTodayAndEarlier() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "GMT"))
        func date(_ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(
                year: 2026, month: 10, day: day, hour: hour, minute: minute)))
        }
        let now = try date(25, 15, 0)
        #expect(PromptOutline.timeLabel(
            try date(25, 14, 2), now: now, calendar: calendar, locale: Locale(identifier: "en_GB")) == "14:02")
        #expect(PromptOutline.timeLabel(
            try date(24, 9, 0), now: now, calendar: calendar, locale: Locale(identifier: "en_US")) == "Oct 24")
        #expect(PromptOutline.timeLabel(
            nil, now: now, calendar: calendar, locale: Locale(identifier: "en_US")) == "")
    }

    @Test("an unverified peer carries the header's unverified name")
    func unverifiedPeerUsesHeaderName() {
        let sender = PeerSender(name: nil, from: "x", verified: false, pid: nil)
        let entries = PromptOutline.entries(from: nodes([
            .peerMessage(id: "m", sender: sender, text: "hi", deliveredPayload: nil, timestamp: nil),
        ]))
        #expect(entries.first?.kind == .peer(sender: "x (unverified)"))
    }
}
