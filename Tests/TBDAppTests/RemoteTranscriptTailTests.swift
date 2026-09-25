import Foundation
import Testing
@testable import TBDApp
@testable import TBDShared

/// `RemoteTranscriptTail` against a hand-made remote cache file
/// (`Fixtures/remote-transcript-sample.jsonl`), copied into a scratch
/// directory so a test can append to or replace it the way the daemon's sync
/// does.
@MainActor
@Suite("Remote transcript tail")
struct RemoteTranscriptTailTests {

    private func fixtureLines() throws -> [String] {
        let url = try #require(Bundle.module.url(
            forResource: "remote-transcript-sample", withExtension: "jsonl",
            subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// A scratch `transcript.jsonl` holding `lines`.
    private func cacheFile(_ lines: [String]) throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-remote-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("transcript.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    private func append(_ lines: [String], to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }

    /// The daemon's reset: write elsewhere, rename over the cache file.
    private func replace(_ path: String, with lines: [String]) throws {
        let temp = path + ".tmp"
        try (lines.joined(separator: "\n") + "\n").write(toFile: temp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(
            URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: temp))
    }

    private func userPrompts(_ items: [TranscriptItem]) -> [String] {
        items.compactMap { if case .userPrompt(_, let text, _) = $0 { return text } else { return nil } }
    }

    @Test("the store key is namespaced by provider and session")
    func storeKey() {
        #expect(RemoteTranscriptTail.storeKey(provider: "acme", sessionID: "s1") == "remote:acme/s1")
        #expect(RemoteTranscriptTail.storeKey(RemoteSessionSelection(provider: "acme", sessionID: "s1"))
            == "remote:acme/s1")
    }

    @Test("the fixture parses into the items the pane renders, Bash call included")
    func fixtureParses() async throws {
        let path = try cacheFile(try fixtureLines())
        let items = try #require(await RemoteTranscriptTail().read(key: "k", path: path, generation: 0))
        #expect(userPrompts(items) == ["List the files in the repo root."])
        let bash = items.contains { item in
            if case .toolCall(let id, let name, _, _, let result, _, _, _) = item {
                return id == "toolu_remote_1" && name == "Bash" && result != nil
            }
            return false
        }
        #expect(bash, "the Bash call and its result must pair up")
    }

    @Test("an append under the same generation adds only the new records")
    func appendKeepsEarlierItems() async throws {
        let lines = try fixtureLines()
        let path = try cacheFile(Array(lines.prefix(2)))
        let tail = RemoteTranscriptTail()
        let first = try #require(await tail.read(key: "k", path: path, generation: 1))
        #expect(!first.isEmpty)

        try append(Array(lines.dropFirst(2)), to: path)
        let second = try #require(await tail.read(key: "k", path: path, generation: 1))
        #expect(second.first == first.first, "earlier items stay put")
        #expect(second.count > first.count)
    }

    @Test("a generation change drops what was held and reads the new file from the start")
    func generationChangeRereads() async throws {
        let lines = try fixtureLines()
        let path = try cacheFile(lines)
        let tail = RemoteTranscriptTail()
        _ = await tail.read(key: "k", path: path, generation: 1)

        let restarted = #"{"type":"user","uuid":"r2-u1","timestamp":"2026-09-25T11:00:00.000Z","message":{"role":"user","content":"A new conversation."}}"#
        try replace(path, with: [restarted])
        let items = try #require(await tail.read(key: "k", path: path, generation: 2))
        #expect(userPrompts(items) == ["A new conversation."])
        #expect(items.count == 1, "nothing from the previous generation survives")
    }

    /// A user-prompt line. `id` and `text` lengths are held fixed by callers
    /// that need two lines of identical byte length.
    private func promptLine(uuid: String, text: String) -> String {
        #"{"type":"user","uuid":""# + uuid
            + #"","timestamp":"2026-09-25T10:00:00.000Z","message":{"role":"user","content":""#
            + text + #""}}"#
    }

    /// The reset `TranscriptSource` cannot see on its own, so only the
    /// generation can force it. The new file is LONGER (no shrink), written
    /// later (no backwards mtime), and its first record has the same byte
    /// length as the old one, so every byte in the 512-byte window before the
    /// old read offset — which lies inside the shared long record — is
    /// unchanged. `TranscriptSource` alone reads that as an append and keeps
    /// the old first record; dropping it takes `RemoteTranscriptTail` calling
    /// `forget` on the generation change.
    @Test("a generation change resets even when the new file looks like an append")
    func generationChangeResetsWhatLooksLikeAnAppend() async throws {
        let longText = String(repeating: "x", count: 800)
        let oldFirst = promptLine(uuid: "g1-u1", text: "Old opening line.")
        let newFirst = promptLine(uuid: "g2-u1", text: "New opening line.")
        #expect(oldFirst.utf8.count == newFirst.utf8.count, "the fixture depends on equal lengths")
        let shared = promptLine(uuid: "shared-1", text: longText)
        let appended = promptLine(uuid: "g2-u3", text: "Appended after.")

        let path = try cacheFile([oldFirst, shared])
        let tail = RemoteTranscriptTail()
        let before = try #require(await tail.read(key: "k", path: path, generation: 1))
        #expect(userPrompts(before).count == 2)
        #expect(userPrompts(before).first == "Old opening line.")

        try replace(path, with: [newFirst, shared, appended])
        let after = try #require(await tail.read(key: "k", path: path, generation: 2))
        #expect(userPrompts(after).count == 3)
        #expect(userPrompts(after).first == "New opening line.")
        #expect(userPrompts(after).last == "Appended after.")
        #expect(!userPrompts(after).contains("Old opening line."),
                "a record from the previous generation survived the reset")
    }

    @Test("the same append-shaped rewrite without a generation change is read as an append")
    func appendShapedRewriteWithoutGenerationIsAnAppend() async throws {
        // The control for the test above: it pins the premise that
        // `TranscriptSource` by itself does NOT reset on this file shape, so
        // the reset above is the generation's doing and not the heuristics'.
        let longText = String(repeating: "x", count: 800)
        let oldFirst = promptLine(uuid: "g1-u1", text: "Old opening line.")
        let newFirst = promptLine(uuid: "g2-u1", text: "New opening line.")
        let shared = promptLine(uuid: "shared-1", text: longText)
        let appended = promptLine(uuid: "g2-u3", text: "Appended after.")

        let path = try cacheFile([oldFirst, shared])
        let tail = RemoteTranscriptTail()
        _ = await tail.read(key: "k", path: path, generation: 1)
        try replace(path, with: [newFirst, shared, appended])
        let after = try #require(await tail.read(key: "k", path: path, generation: 1))
        #expect(userPrompts(after).count == 3)
        #expect(userPrompts(after).first == "Old opening line.")
        #expect(userPrompts(after).last == "Appended after.")
    }

    @Test("a generation change with the same bytes re-reads rather than doubling")
    func generationChangeSameBytes() async throws {
        let path = try cacheFile(try fixtureLines())
        let tail = RemoteTranscriptTail()
        let first = try #require(await tail.read(key: "k", path: path, generation: 1))
        let second = try #require(await tail.read(key: "k", path: path, generation: 2))
        #expect(second == first)
    }

    @Test("an unreadable file is no news under the same generation")
    func unreadableSameGenerationIsNoNews() async throws {
        let path = try cacheFile(try fixtureLines())
        let tail = RemoteTranscriptTail()
        _ = await tail.read(key: "k", path: path, generation: 1)
        try FileManager.default.removeItem(atPath: path)
        #expect(await tail.read(key: "k", path: path, generation: 1) == nil)
    }

    @Test("an unreadable file after a generation change empties the pane")
    func unreadableAfterGenerationChangeEmpties() async throws {
        let path = try cacheFile(try fixtureLines())
        let tail = RemoteTranscriptTail()
        _ = await tail.read(key: "k", path: path, generation: 1)
        try FileManager.default.removeItem(atPath: path)
        #expect(await tail.read(key: "k", path: path, generation: 2) == [])
    }

    @Test("sessions are tailed independently")
    func keysAreIndependent() async throws {
        let lines = try fixtureLines()
        let pathA = try cacheFile(lines)
        let pathB = try cacheFile(Array(lines.prefix(1)))
        let tail = RemoteTranscriptTail()
        let a = try #require(await tail.read(key: "a", path: pathA, generation: 1))
        let b = try #require(await tail.read(key: "b", path: pathB, generation: 5))
        #expect(b.count == 1)
        #expect(a.count > b.count)
    }
}
