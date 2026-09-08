import Foundation
import Testing
@testable import TBDShared

/// `IncrementalTranscript.hasAssistantMessage(id:)` — the set lookup that
/// retires a streamed message's provisional row once the JSONL carries it.
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

    /// One assistant line: where it sits in the file and the `message.id` it
    /// carries. A struct, not a tuple, so `\.id` is a usable key path.
    private struct AssistantRow {
        let index: Int
        let id: String
    }

    /// The assistant lines of a file, in order, each paired with its `message.id`.
    private func assistantIDsByIndex(_ lines: [String]) throws -> [AssistantRow] {
        try lines.indices.compactMap { (idx: Int) -> AssistantRow? in
            let row = try json(of: lines[idx])
            guard row["type"] as? String == "assistant",
                  let message = row["message"] as? [String: Any],
                  let id = message["id"] as? String else { return nil }
            return AssistantRow(index: idx, id: id)
        }
    }

    @Test("a message split across two assistant lines is recorded, and only it")
    func recordsIDAcrossAChunkSplit() throws {
        let lines = try fixtureLines()
        let assistants = try assistantIDsByIndex(lines)

        // The capture writes one assistant line per content block, so one
        // message id appears on two consecutive lines. Split between them.
        let repeated = try #require(assistants.first { candidate in
            assistants.filter { $0.id == candidate.id }.count >= 2
        })
        let occurrences = assistants.filter { $0.id == repeated.id }.map(\.index)
        let split = occurrences[1]

        var transcript = IncrementalTranscript()
        transcript.ingest(lines: Array(lines[..<split]))
        #expect(transcript.hasAssistantMessage(id: repeated.id),
                "the first line of the message already carries its id")

        transcript.ingest(lines: Array(lines[split...]))
        #expect(transcript.hasAssistantMessage(id: repeated.id),
                "the second chunk must not lose what the first recorded")
        #expect(transcript.hasAssistantMessage(id: "msg_01NeverStreamedAnywhere") == false,
                "an id that never appeared must not be confirmed")
    }

    @Test("every assistant id in the capture is recorded, whole-file or line at a time")
    func recordsEveryIDLineAtATime() throws {
        let lines = try fixtureLines()
        let expected = Set(try assistantIDsByIndex(lines).map(\.id))
        #expect(expected.count >= 2, "capture must carry more than one message id")

        var whole = IncrementalTranscript()
        whole.ingest(lines: lines)
        var drip = IncrementalTranscript()
        for line in lines { drip.ingest(lines: [line]) }

        for id in expected {
            #expect(whole.hasAssistantMessage(id: id))
            #expect(drip.hasAssistantMessage(id: id))
        }
        #expect(whole.assistantMessageIDCount == expected.count)
        #expect(drip.assistantMessageIDCount == expected.count)
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
        #expect(transcript.assistantMessageIDCount == 0)
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
        #expect(transcript.hasAssistantMessage(id: assistant.id) == false)
        #expect(transcript.items.isEmpty == false, "the row itself must still parse into an item")
    }

    @Test("a fresh transcript confirms nothing")
    func freshTranscriptAnswersFalse() throws {
        let transcript = IncrementalTranscript()
        #expect(transcript.hasAssistantMessage(id: "msg_011CdaZp7Yk4EfhnpgNgpDKq") == false)
        #expect(transcript.assistantMessageIDCount == 0)
    }
}
