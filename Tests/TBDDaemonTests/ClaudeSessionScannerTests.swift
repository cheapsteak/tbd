import Testing
import Foundation
@testable import TBDDaemonLib

@Suite("ClaudeSessionScanner")
struct ClaudeSessionScannerTests {

    /// URL of the committed fixture file.
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TBDDaemonTests/
            .deletingLastPathComponent()  // Tests/
            .appendingPathComponent("Fixtures/sample-session.jsonl")
    }

    @Test("counts all lines in fixture")
    func lineCount() throws {
        let dir = fixtureURL.deletingLastPathComponent()
        let summaries = try ClaudeSessionScanner.listSessions(projectDir: dir)
        let summary = try #require(summaries.first(where: { $0.filePath.hasSuffix("sample-session.jsonl") }))
        #expect(summary.lineCount == 11)
    }

    @Test("first user message is the first real user turn")
    func firstUserMessage() throws {
        let dir = fixtureURL.deletingLastPathComponent()
        let summaries = try ClaudeSessionScanner.listSessions(projectDir: dir)
        let summary = try #require(summaries.first(where: { $0.filePath.hasSuffix("sample-session.jsonl") }))
        #expect(summary.firstUserMessage == "Hello, can you help me refactor this function?")
    }

    @Test("last user message is the last real user turn")
    func lastUserMessage() throws {
        let dir = fixtureURL.deletingLastPathComponent()
        let summaries = try ClaudeSessionScanner.listSessions(projectDir: dir)
        let summary = try #require(summaries.first(where: { $0.filePath.hasSuffix("sample-session.jsonl") }))
        #expect(summary.lastUserMessage == "What does this error mean?")
    }

    @Test("scanner truncates first/last user message to 300 chars")
    func truncatesAt300() throws {
        let longText = String(repeating: "a", count: 400)
        let lineStr = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"\(longText)\"},\"sessionId\":\"trunc-test\"}\n"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("trunc-test.jsonl")
        try lineStr.data(using: .utf8)!.write(to: file)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let summaries = try ClaudeSessionScanner.listSessions(projectDir: tmp)
        let summary = try #require(summaries.first)
        #expect(summary.firstUserMessage?.count == 300)
        #expect(summary.lastUserMessage?.count == 300)
    }

    @Test("extracts session metadata from header line")
    func sessionMetadata() throws {
        let dir = fixtureURL.deletingLastPathComponent()
        let summaries = try ClaudeSessionScanner.listSessions(projectDir: dir)
        let summary = try #require(summaries.first(where: { $0.filePath.hasSuffix("sample-session.jsonl") }))
        #expect(summary.cwd == "/Users/test/project")
        #expect(summary.gitBranch == "main")
    }

    @Test("empty file returns summary with zero lines and no messages")
    func emptyFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmpFile = tmpDir.appendingPathComponent("empty.jsonl")
        try Data().write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let summaries = try ClaudeSessionScanner.listSessions(projectDir: tmpDir)
        let summary = summaries.first
        #expect(summary?.lineCount == 0)
        #expect(summary?.firstUserMessage == nil)
    }

    @Test("directory resolution: exact encoding resolves /Users/test/myproject")
    func exactEncoding() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let encoded = "-Users-test-myproject"
        let dir = tmp.appendingPathComponent(encoded)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        ClaudeProjectDirectory.clearCache()
        let resolved = ClaudeProjectDirectory.resolve(worktreePath: "/Users/test/myproject", projectsBase: tmp)
        #expect(resolved?.lastPathComponent == encoded)
    }
}
