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

    @Test("first line reads the line holding the first non-blank character, whatever follows it")
    func firstLineSkipsBlankLinesAndStopsAtTheLine() {
        #expect(PromptOutline.firstLine(of: "  \n\t\n   fix   the\tbuild  \nsecond line\n") == "fix the build")
        #expect(PromptOutline.firstLine(of: "only line") == "only line")
        #expect(PromptOutline.firstLine(of: " \n \n") == "")
        #expect(PromptOutline.firstLine(of: "") == "")
        #expect(PromptOutline.firstLine(of: "first\r\nsecond") == "first")
    }

    /// The cache's outline is the builder's, entry for entry, through
    /// appends, a changed prompt, an untyped marker and a removal; and each
    /// rebuild projects only the prompts it has not seen at their content.
    @Test("the outline cache matches the builder and projects only new or changed prompts")
    func cacheMatchesBuilderAndProjectsOnlyNewRows() {
        let sender = PeerSender(name: "build-bot", from: "build-bot", verified: true, pid: nil)
        var items: [TranscriptItem] = [
            .userPrompt(id: "p1", text: "fix it", timestamp: nil),
            .assistantText(id: "a1", text: "done", timestamp: nil, usage: nil),
            .userPrompt(id: "i1", text: "[Image: source: /tmp/a.png]", timestamp: nil),
            .peerMessage(id: "m1", sender: sender, text: "green", deliveredPayload: nil, timestamp: nil),
        ]
        var cache = PromptOutlineCache()

        #expect(cache.entries(from: nodes(items)) == PromptOutline.entries(from: nodes(items)))
        // Two prompts, the marker (which makes no entry) and the peer; the
        // reply is no candidate.
        #expect(cache.projectionCount == 3)

        // The same nodes again: nothing is projected.
        _ = cache.entries(from: nodes(items))
        #expect(cache.projectionCount == 3)

        // A reply and a prompt appended: only the prompt is projected.
        items += [
            .assistantText(id: "a2", text: "more", timestamp: nil, usage: nil),
            .userPrompt(id: "p2", text: "and the tests", timestamp: nil),
        ]
        #expect(cache.entries(from: nodes(items)) == PromptOutline.entries(from: nodes(items)))
        #expect(cache.projectionCount == 4)

        // A prompt whose content changes under the same id is projected again.
        items[items.count - 1] = .userPrompt(id: "p2", text: "and the lint", timestamp: nil)
        #expect(cache.entries(from: nodes(items)) == PromptOutline.entries(from: nodes(items)))
        #expect(cache.projectionCount == 5)

        // A prompt that leaves the nodes is pruned, so its return is projected
        // again rather than served from a cache that grew with every rebuild.
        let first = items.removeFirst()
        #expect(cache.entries(from: nodes(items)) == PromptOutline.entries(from: nodes(items)))
        #expect(cache.projectionCount == 5)
        items.insert(first, at: 0)
        #expect(cache.entries(from: nodes(items)) == PromptOutline.entries(from: nodes(items)))
        #expect(cache.projectionCount == 6)
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
