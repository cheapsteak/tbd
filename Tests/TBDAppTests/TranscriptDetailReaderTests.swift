import Foundation
import Testing
@testable import TBDApp
@testable import TBDShared

/// `TranscriptDetailReader` is the app-side stand-in for two daemon RPCs, so
/// every test here asserts against what the daemon's own path produces: the
/// same parser output, and the same "no longer available" placeholder.
@Suite("TranscriptDetailReader")
struct TranscriptDetailReaderTests {

    /// `subdirectory:` is required here where `TBDSharedTests` needs none: this
    /// target registers its fixtures with `.copy`, which preserves the
    /// `Fixtures/` directory, rather than `.process`, which flattens it. The
    /// target cannot switch — the Alacritty fixtures below it rely on their own
    /// nested layout.
    private func fixturePath() throws -> String {
        try #require(Bundle.module.url(
            forResource: "incremental-transcript-sample", withExtension: "jsonl",
            subdirectory: "Fixtures")).path
    }

    /// The first tool call in the fixture, which every body test needs.
    private func firstToolCallID(in path: String) throws -> String {
        let items = TranscriptParser.parse(filePath: path)
        let toolID = items.compactMap { item -> String? in
            if case .toolCall(let id, _, _, _, _, _, _, _) = item { return id }
            return nil
        }.first
        return try #require(toolID, "fixture must contain a tool call")
    }

    @Test("messages(path:) equals what the parser produces")
    func messagesMatchesParser() throws {
        let path = try fixturePath()
        let messages = TranscriptDetailReader.messages(path: path)
        #expect(messages == TranscriptParser.parse(filePath: path))
        #expect(!messages.isEmpty, "fixture must parse to something")
    }

    @Test("a missing file yields the same placeholder the daemon returns")
    func missingFilePlaceholder() {
        let result = TranscriptDetailReader.fullBody(
            path: "/nonexistent.jsonl", itemID: "nope", includeBody: true)
        #expect(result.text == "Output no longer available.")
        #expect(result.attachment == nil)
    }

    @Test("a missing file yields no messages rather than throwing")
    func missingFileMessages() {
        #expect(TranscriptDetailReader.messages(path: "/nonexistent.jsonl").isEmpty)
    }

    @Test("includeBody false returns no body")
    func metadataOnly() throws {
        let path = try fixturePath()
        let id = try firstToolCallID(in: path)
        #expect(TranscriptDetailReader.fullBody(path: path, itemID: id, includeBody: false).text == "")
    }

    @Test("includeBody true returns a body for a known tool call")
    func bodyForKnownItem() throws {
        let path = try fixturePath()
        let id = try firstToolCallID(in: path)
        let result = TranscriptDetailReader.fullBody(
            path: path, itemID: "\(id)#input", includeBody: true)
        #expect(result.text != TranscriptDetailReader.unavailable,
                "a tool call's own input must resolve")
        #expect(!result.text.isEmpty)
    }

    @Test("the gate is on only with the flag on and a usable path")
    func gateMatrix() {
        #expect(TranscriptDetailReader.shouldReadAppSide(enabled: true, path: "/a.jsonl"))
        #expect(!TranscriptDetailReader.shouldReadAppSide(enabled: false, path: "/a.jsonl"),
                "flag off must leave every caller on the RPC")
        #expect(!TranscriptDetailReader.shouldReadAppSide(enabled: true, path: nil),
                "no path means nothing to read app-side")
        #expect(!TranscriptDetailReader.shouldReadAppSide(enabled: true, path: ""),
                "an empty path must not read as a usable file")
        #expect(!TranscriptDetailReader.shouldReadAppSide(enabled: false, path: nil))
    }

    @Test("an unknown item id falls back to the placeholder")
    func unknownItemPlaceholder() throws {
        let path = try fixturePath()
        let result = TranscriptDetailReader.fullBody(
            path: path, itemID: "definitely-not-an-item#input", includeBody: true)
        #expect(result.text == TranscriptDetailReader.unavailable)
    }
}
