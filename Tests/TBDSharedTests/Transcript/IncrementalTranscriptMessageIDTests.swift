import Foundation
import Testing
@testable import TBDShared

/// `IncrementalTranscript`'s two message-id sets: `hasAssistantMessage(id:)`,
/// the id seen on any line, and `hasAssistantText(id:)` — the narrower lookup
/// that retires a streamed message's provisional row once the JSONL carries the
/// line bearing that message's text.
///
/// The distinction is the point of this suite. Claude Code writes one assistant
/// line per content block under a shared `message.id`, and the capture below
/// contains exactly that: a thinking-only line followed, later, by the text
/// line for the same message.
///
/// Every line here comes from `incremental-transcript-sample.jsonl`, a real
/// captured Claude Code session. The two cases the capture does not contain —
/// a sidechain row, and an assistant row whose message is plain text and so
/// carries no `id` — are made by editing one field of a real line, and each
/// says which field.
@Suite("IncrementalTranscript assistant message ids")
struct IncrementalTranscriptMessageIDTests {

    private func fixtureLines() throws -> [String] {
        let url = try #require(Bundle.module.url(
            forResource: "incremental-transcript-sample", withExtension: "jsonl"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private func json(of line: String) throws -> [String: Any] {
        let data = try #require(line.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func line(from json: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try #require(String(data: data, encoding: .utf8))
    }

    /// One assistant line: where it sits in the file, the `message.id` it
    /// carries, and whether its content blocks include a non-empty `text` — the
    /// three facts every case here is stated in terms of. A struct, not a
    /// tuple, so `\.id` is a usable key path.
    private struct AssistantRow {
        let index: Int
        let id: String
        let carriesText: Bool
    }

    /// The assistant lines of a file, in order, each paired with its
    /// `message.id` and whether it delivers text.
    private func assistantIDsByIndex(_ lines: [String]) throws -> [AssistantRow] {
        try lines.indices.compactMap { (idx: Int) -> AssistantRow? in
            let row = try json(of: lines[idx])
            guard row["type"] as? String == "assistant",
                  let message = row["message"] as? [String: Any],
                  let id = message["id"] as? String else { return nil }
            let blocks = (message["content"] as? [[String: Any]]) ?? []
            let carriesText = blocks.contains {
                ($0["type"] as? String) == "text" && !((($0["text"] as? String) ?? "").isEmpty)
            }
            return AssistantRow(index: idx, id: id, carriesText: carriesText)
        }
    }

    /// Whether the transcript has built a settled assistant-text item — what
    /// confirmation promises is on screen in place of the withdrawn row.
    private func hasSettledText(_ transcript: IncrementalTranscript) -> Bool {
        transcript.items.contains {
            if case .assistantText = $0 { return true }
            return false
        }
    }

    /// The finding this suite exists for: the id arrives before the text does.
    ///
    /// The capture's message `msg_011CdaZp7Yk4EfhnpgNgpDKq` is written as a
    /// thinking-only line and then, separately, a text line. Ingested up to the
    /// split, the id has been seen and the message is *not* confirmed — because
    /// confirming there would withdraw a streaming row while its replacement
    /// did not exist yet. The text line is what confirms, and it brings the
    /// settled item with it.
    @Test("the id lands with the first block, but only the text line confirms")
    func recordsIDAcrossAChunkSplit() throws {
        let lines = try fixtureLines()
        let assistants = try assistantIDsByIndex(lines)

        // The capture writes one assistant line per content block, so one
        // message id appears on two consecutive lines. Split between them.
        let repeated = try #require(assistants.first { candidate in
            assistants.filter { $0.id == candidate.id }.count >= 2
        })
        let occurrences = assistants.filter { $0.id == repeated.id }
        #expect(occurrences.first?.carriesText == false,
                "the capture's first line for this message must be the thinking one")
        #expect(occurrences.last?.carriesText == true,
                "and its last must be the text one, or this proves nothing")
        let split = occurrences[1].index

        var transcript = IncrementalTranscript()
        transcript.ingest(lines: Array(lines[..<split]))
        #expect(transcript.hasAssistantMessage(id: repeated.id),
                "the first line of the message already carries its id")
        #expect(transcript.hasAssistantText(id: repeated.id) == false,
                "a thinking-only line must not confirm a message still streaming its text")
        #expect(hasSettledText(transcript) == false,
                "and there is indeed no settled text item to replace the row with")

        transcript.ingest(lines: Array(lines[split...]))
        #expect(transcript.hasAssistantMessage(id: repeated.id),
                "the second chunk must not lose what the first recorded")
        #expect(transcript.hasAssistantText(id: repeated.id),
                "the text line confirms")
        #expect(hasSettledText(transcript),
                "and the settled item it built is what the row is replaced by")
        #expect(transcript.hasAssistantMessage(id: "msg_01NeverStreamedAnywhere") == false,
                "an id that never appeared must not be confirmed")
        #expect(transcript.hasAssistantText(id: "msg_01NeverStreamedAnywhere") == false)
    }

    /// The other half of the same rule. A turn that only calls tools carries
    /// its id on every line and never a text block, so it is never confirmed —
    /// its row leaves by the composer's 60-second unconfirmed deadline instead.
    @Test("a turn that only calls tools is seen but never confirmed")
    func toolOnlyTurnIsSeenButNotConfirmed() throws {
        let lines = try fixtureLines()
        let assistants = try assistantIDsByIndex(lines)
        let textless = try #require(assistants.first { candidate in
            assistants.filter { $0.id == candidate.id }.allSatisfy { !$0.carriesText }
        }, "capture must hold a message that never delivers text")

        var transcript = IncrementalTranscript()
        transcript.ingest(lines: lines)
        #expect(transcript.hasAssistantMessage(id: textless.id),
                "every line of it was ingested")
        #expect(transcript.hasAssistantText(id: textless.id) == false,
                "but nothing it wrote is text, so nothing can replace a streamed row")
    }

    /// `buildItems` drops a `text` block whose string is empty, so treating one
    /// as confirmation would reproduce the same hazard in miniature: the row
    /// withdrawn, and no item where it stood.
    @Test("an empty text block confirms nothing")
    func emptyTextBlockDoesNotConfirm() throws {
        let lines = try fixtureLines()
        let assistants = try assistantIDsByIndex(lines)
        let withText = try #require(assistants.first(where: \.carriesText))
        // Take the real text line and blank the one field that matters.
        var row = try json(of: lines[withText.index])
        var message = try #require(row["message"] as? [String: Any])
        message["content"] = [["type": "text", "text": ""]]
        row["message"] = message

        var transcript = IncrementalTranscript()
        transcript.ingest(lines: [try line(from: row)])
        #expect(transcript.hasAssistantMessage(id: withText.id))
        #expect(transcript.hasAssistantText(id: withText.id) == false)
        #expect(hasSettledText(transcript) == false,
                "the parser built no item for it either, which is why it must not confirm")
    }

    @Test("every assistant id in the capture is recorded, whole-file or line at a time")
    func recordsEveryIDLineAtATime() throws {
        let lines = try fixtureLines()
        let rows = try assistantIDsByIndex(lines)
        let expected = Set(rows.map(\.id))
        let expectedText = Set(rows.filter(\.carriesText).map(\.id))
        #expect(expected.count >= 2, "capture must carry more than one message id")
        #expect(expectedText.count < expected.count,
                "capture must hold a textless message, or the two sets cannot be told apart")

        var whole = IncrementalTranscript()
        whole.ingest(lines: lines)
        var drip = IncrementalTranscript()
        for line in lines { drip.ingest(lines: [line]) }

        for id in expected {
            #expect(whole.hasAssistantMessage(id: id))
            #expect(drip.hasAssistantMessage(id: id))
            #expect(whole.hasAssistantText(id: id) == expectedText.contains(id))
            #expect(drip.hasAssistantText(id: id) == expectedText.contains(id))
        }
        #expect(whole.assistantMessageIDCount == expected.count)
        #expect(drip.assistantMessageIDCount == expected.count)
        #expect(whole.assistantTextMessageIDCount == expectedText.count)
        #expect(drip.assistantTextMessageIDCount == expectedText.count)
    }

    @Test("a sidechain assistant line's id is not recorded")
    func ignoresSidechainRows() throws {
        let lines = try fixtureLines()
        let assistant = try #require(try assistantIDsByIndex(lines).first)
        // The capture holds no subagent turn, so take a real assistant line and
        // flip its `isSidechain` — the one field that distinguishes a subagent's
        // row from the parent session's.
        var row = try json(of: lines[assistant.index])
        row["isSidechain"] = true

        var transcript = IncrementalTranscript()
        transcript.ingest(lines: [try line(from: row)])
        #expect(transcript.hasAssistantMessage(id: assistant.id) == false,
                "a subagent's message id must never confirm a parent's streamed message")
        #expect(transcript.hasAssistantText(id: assistant.id) == false)
        #expect(transcript.assistantMessageIDCount == 0)
        #expect(transcript.assistantTextMessageIDCount == 0)
    }

    @Test("an assistant line whose message is plain text records nothing")
    func toleratesStringContentWithNoMessageID() throws {
        let lines = try fixtureLines()
        let assistant = try #require(try assistantIDsByIndex(lines).first)
        // Claude Code writes some assistant rows with a plain-string `content`
        // and no `message.id` at all. Reproduce that shape by replacing the real
        // line's `message` object, keeping every other field of the capture.
        var row = try json(of: lines[assistant.index])
        row["message"] = ["role": "assistant", "content": "Of course! Please share the function."]

        var transcript = IncrementalTranscript()
        transcript.ingest(lines: [try line(from: row)])
        #expect(transcript.assistantMessageIDCount == 0, "no id on the row, nothing to record")
        #expect(transcript.assistantTextMessageIDCount == 0)
        #expect(transcript.hasAssistantMessage(id: assistant.id) == false)
        #expect(transcript.hasAssistantText(id: assistant.id) == false)
        #expect(transcript.items.isEmpty == false, "the row itself must still parse into an item")
    }

    @Test("a fresh transcript confirms nothing")
    func freshTranscriptAnswersFalse() throws {
        let transcript = IncrementalTranscript()
        #expect(transcript.hasAssistantMessage(id: "msg_011CdaZp7Yk4EfhnpgNgpDKq") == false)
        #expect(transcript.hasAssistantText(id: "msg_011CdaZp7Yk4EfhnpgNgpDKq") == false)
        #expect(transcript.assistantMessageIDCount == 0)
        #expect(transcript.assistantTextMessageIDCount == 0)
    }
}
