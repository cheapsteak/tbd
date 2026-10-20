import Foundation
import Testing
@testable import TBDShared

/// `IncrementalTranscript.hasRow(uuid:)` — the lookup that retires a block the
/// session mod streamed, once the JSONL holds the row with the block's `uuid`.
///
/// Every line here comes from `incremental-transcript-sample.jsonl`, a real
/// captured Claude Code session. The one case the capture does not contain — a
/// sidechain row — is made by editing one field of a real line.
@Suite("IncrementalTranscript row uuids")
struct IncrementalTranscriptRowUUIDTests {

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

    /// The `uuid` of every line that carries one, in file order.
    private func uuids(_ lines: [String]) throws -> [String] {
        try lines.compactMap { try json(of: $0)["uuid"] as? String }
    }

    @Test("every row's uuid is recorded, however the lines arrive")
    func recordsEveryRowUUID() throws {
        let lines = try fixtureLines()
        let expected = Set(try uuids(lines))
        try #require(!expected.isEmpty, "the capture must carry uuids, or this proves nothing")

        var whole = IncrementalTranscript()
        whole.ingest(lines: lines)
        var drip = IncrementalTranscript()
        for line in lines { drip.ingest(lines: [line]) }

        for uuid in expected {
            #expect(whole.hasRow(uuid: uuid))
            #expect(drip.hasRow(uuid: uuid))
        }
        #expect(whole.rowUUIDCount == expected.count)
        #expect(drip.rowUUIDCount == expected.count)
    }

    /// The whole point: a row confirms only once it is ingested, so a block
    /// streamed ahead of its row is unconfirmed until the row lands.
    @Test("a row's uuid is absent until its line is ingested")
    func aRowConfirmsOnlyOnceIngested() throws {
        let lines = try fixtureLines()
        let last = try #require(try uuids(lines).last)
        let lastIndex = try #require(try lines.lastIndex { try json(of: $0)["uuid"] as? String == last })

        var transcript = IncrementalTranscript()
        transcript.ingest(lines: Array(lines[..<lastIndex]))
        #expect(transcript.hasRow(uuid: last) == false)

        transcript.ingest(lines: Array(lines[lastIndex...]))
        #expect(transcript.hasRow(uuid: last))
    }

    @Test("a sidechain row's uuid is not recorded")
    func ignoresSidechainRows() throws {
        let lines = try fixtureLines()
        let source = try #require(try lines.first { try json(of: $0)["uuid"] is String })
        // The capture holds no subagent turn, so take a real line and flip its
        // `isSidechain` — the field that marks a subagent's row.
        var row = try json(of: source)
        row["isSidechain"] = true
        let uuid = try #require(row["uuid"] as? String)

        var transcript = IncrementalTranscript()
        transcript.ingest(lines: [try line(from: row)])
        #expect(transcript.hasRow(uuid: uuid) == false,
                "the mod streams the main loop alone, so a subagent's row confirms nothing")
        #expect(transcript.rowUUIDCount == 0)
    }

    @Test("a fresh transcript confirms nothing")
    func freshTranscriptAnswersFalse() {
        let transcript = IncrementalTranscript()
        #expect(transcript.hasRow(uuid: "00000000-0000-0000-0000-000000000000") == false)
        #expect(transcript.rowUUIDCount == 0)
    }
}
