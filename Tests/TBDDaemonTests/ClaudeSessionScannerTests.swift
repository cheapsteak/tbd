import Testing
import Foundation
import TBDShared
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
        let summaries = ClaudeSessionScanner.listSessions(projectDir: dir)
        let summary = try #require(summaries.first(where: { $0.filePath.hasSuffix("sample-session.jsonl") }))
        #expect(summary.lineCount == 13)
    }

    @Test("first user message is the first real user turn")
    func firstUserMessage() throws {
        let dir = fixtureURL.deletingLastPathComponent()
        let summaries = ClaudeSessionScanner.listSessions(projectDir: dir)
        let summary = try #require(summaries.first(where: { $0.filePath.hasSuffix("sample-session.jsonl") }))
        #expect(summary.firstUserMessage == "Hello, can you help me refactor this function?")
    }

    /// The fixture's last prompt was QUEUED while the agent was busy, so Claude
    /// Code recorded it as a `queued_command` attachment and never wrote a
    /// `type:"user"` line for it. Reading only user lines left the subtitle
    /// stuck on the previous turn.
    @Test("last user message is the last real user turn, queued or typed")
    func lastUserMessage() throws {
        let dir = fixtureURL.deletingLastPathComponent()
        let summaries = ClaudeSessionScanner.listSessions(projectDir: dir)
        let summary = try #require(summaries.first(where: { $0.filePath.hasSuffix("sample-session.jsonl") }))
        #expect(summary.lastUserMessage == "Also check the retry path while you are in there.")
    }

    @Test("a session whose only prompt was queued still gets a subtitle")
    func queuedOnlySessionHasSubtitle() throws {
        let line = #"""
        {"type":"attachment","uuid":"q1","timestamp":"2026-08-19T21:10:05.458Z","attachment":{"type":"queued_command","prompt":"only ever queued","commandMode":"prompt"}}
        """#
        let summary = try scanOneSession(named: "queued-only", lines: [line])
        #expect(summary.firstUserMessage == "only ever queued")
        #expect(summary.lastUserMessage == "only ever queued")
    }

    /// A queued background-task notification is harness-injected, not something
    /// the user said — it must never become the session's subtitle.
    @Test("queued task notification is not treated as a user message")
    func queuedTaskNotificationIsNotASubtitle() throws {
        let lines = [
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"real question"}}"#,
            #"""
            {"type":"attachment","uuid":"q1","attachment":{"type":"queued_command","prompt":"<task-notification>\n<task-id>abc</task-id>\n</task-notification>","commandMode":"task-notification"}}
            """#,
        ]
        let summary = try scanOneSession(named: "queued-notification", lines: lines)
        #expect(summary.firstUserMessage == "real question")
        #expect(summary.lastUserMessage == "real question")
    }

    /// Peer traffic is the other thing that only ever arrives queued, and it
    /// matches no system prefix, so it classifies as a real prompt and DOES
    /// become the subtitle. Pinned deliberately: it is a message this session
    /// received, and the alternative was showing a subtitle that predates it.
    /// Giving peer messages their own kind is a design change, and this test
    /// is what makes that change deliberate rather than accidental.
    @Test("a queued peer message becomes the subtitle")
    func queuedPeerMessageIsASubtitle() throws {
        let peer = #"<cross-session-message from-name="acme-worker">[note] standing down</cross-session-message>"#
        let lines = [
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"real question"}}"#,
            #"""
            {"type":"attachment","uuid":"q1","attachment":{"type":"queued_command","prompt":"<cross-session-message from-name=\"acme-worker\">[note] standing down</cross-session-message>","commandMode":"prompt","isMeta":true}}
            """#,
        ]
        let summary = try scanOneSession(named: "queued-peer", lines: lines)
        #expect(summary.firstUserMessage == "real question")
        #expect(summary.lastUserMessage == peer)
    }

    /// A peer message carrying the harness-written `origin` dictionary (the
    /// shape in `Tests/Fixtures/peer-messages.jsonl`, superseding the
    /// no-`origin` queued-attachment shape pinned above) is routed through
    /// `PeerOriginExtractor` instead of showing the raw envelope. Scans the
    /// committed fixture directly: its first line is a verified peer sender
    /// and becomes the session's first message.
    @Test("peer session summary attributes the verified sender and strips the envelope")
    func peerSessionSummaryAttributesVerifiedSender() throws {
        let dir = fixtureURL.deletingLastPathComponent()
        let summaries = ClaudeSessionScanner.listSessions(projectDir: dir)
        let summary = try #require(summaries.first(where: { $0.filePath.hasSuffix("peer-messages.jsonl") }))

        let first = try #require(summary.firstUserMessage)
        #expect(first.hasPrefix("🛠 Acme Deploy Watch: "))
        #expect(!first.contains("Another Claude session sent a message:"))
        #expect(!first.contains("<cross-session-message"))

        let last = try #require(summary.lastUserMessage)
        #expect(!last.contains("Another Claude session sent a message:"))
        #expect(!last.contains("<cross-session-message"))
    }

    /// An asserted (unverified) peer sender is labeled by `from` rather than a
    /// display name — mirrors fixture row 3 (`origin.from == "acme-bot"`, no
    /// `name`/`verifiedPeerPid`), reproduced here as an isolated single-line
    /// session so the assertion is not coupled to the fixture's overall
    /// chronology.
    @Test("asserted peer sender is labeled by from, not a display name")
    func assertedPeerSenderLabeledByFrom() throws {
        let line = #"""
        {"type":"user","message":{"role":"user","content":"Another Claude session sent a message:\nStatus report for acme/widgets#4321\n\"deploy: draft at 11:30 and arm it for 12:30\"\n\nIt reports state; it does not request anything.\n\nThis came from another Claude session — not typed by your user, but very likely working on their behalf."},"isMeta":true,"origin":{"kind":"peer","from":"acme-bot"}}
        """#
        let summary = try scanOneSession(named: "peer-asserted", lines: [line])
        #expect(summary.lastUserMessage == "acme-bot: Status report for acme/widgets#4321")
    }

    /// Writes `lines` as a lone session file in a fresh temp project dir and
    /// returns its summary.
    private func scanOneSession(named: String, lines: [String]) throws -> SessionSummary {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-\(named)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: tmp.appendingPathComponent("\(named).jsonl"), atomically: true, encoding: .utf8)
        let summaries = ClaudeSessionScanner.listSessions(projectDir: tmp)
        return try #require(summaries.first)
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

        let summaries = ClaudeSessionScanner.listSessions(projectDir: tmp)
        let summary = try #require(summaries.first)
        #expect(summary.firstUserMessage?.count == 300)
        #expect(summary.lastUserMessage?.count == 300)
    }

    @Test("extracts session metadata from header line")
    func sessionMetadata() throws {
        let dir = fixtureURL.deletingLastPathComponent()
        let summaries = ClaudeSessionScanner.listSessions(projectDir: dir)
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

        let summaries = ClaudeSessionScanner.listSessions(projectDir: tmpDir)
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

    /// Tier 3 (the cwd content scan) enumerates the projects base, and a
    /// model profile's `projects` slot IS a symlink into the host store —
    /// `contentsOfDirectory` lists such a URL as empty, so the scan used to
    /// come up dry for every profile-bound session whose path had moved.
    /// Tiers 1 and 2 are unaffected (`fileExists` follows the symlink).
    @Test("directory resolution: cwd scan follows a symlinked projects root")
    func cwdScanThroughSymlinkedProjectsBase() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let worktreePath = "/Users/test/symlink-scan-\(UUID().uuidString.prefix(8))"
        let hostBase = tmp.appendingPathComponent("host-projects", isDirectory: true)
        // Slug deliberately unrelated to the worktree path so tiers 1 and 2 miss.
        let staleSlug = "-moved-elsewhere-\(UUID().uuidString.prefix(8))"
        let dir = hostBase.appendingPathComponent(staleSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{\"type\":\"user\",\"cwd\":\"\(worktreePath)\",\"message\":{\"content\":\"hi\"}}\n"
            .write(to: dir.appendingPathComponent("sess.jsonl"), atomically: true, encoding: .utf8)
        let profileBase = tmp.appendingPathComponent("profile-projects", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: profileBase, withDestinationURL: hostBase)

        let resolved = ClaudeProjectDirectory.resolve(
            worktreePath: worktreePath, projectsBase: profileBase)

        #expect(resolved?.lastPathComponent == staleSlug)
    }

    // MARK: - isSessionBlank

    /// Build a tmp projects-base + per-worktree subdirectory so tests can
    /// pass an explicit `projectsBase` to isSessionBlank (avoids racing on
    /// the global ClaudeProjectDirectory cache during parallel test runs).
    private func makeProjectDir(worktreePath: String) throws -> (base: URL, dir: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let encoded = worktreePath.map { "/." .contains($0) ? "-" : String($0) }.joined()
        let dir = base.appendingPathComponent(encoded)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (base, dir)
    }

    @Test("isSessionBlank: missing JSONL returns true")
    func blankMissingFile() throws {
        let wt = "/Users/test/blank-missing-\(UUID().uuidString.prefix(8))"
        let layout = try makeProjectDir(worktreePath: wt)
        defer { try? FileManager.default.removeItem(at: layout.base) }
        ClaudeProjectDirectory.clearCache()

        #expect(ClaudeSessionScanner.isSessionBlank(
            sessionID: "deadbeef", worktreePath: wt, projectsBase: layout.base
        ) == true)
    }

    @Test("isSessionBlank: empty JSONL returns true")
    func blankEmptyFile() throws {
        let wt = "/Users/test/blank-empty-\(UUID().uuidString.prefix(8))"
        let layout = try makeProjectDir(worktreePath: wt)
        defer { try? FileManager.default.removeItem(at: layout.base) }
        ClaudeProjectDirectory.clearCache()

        let sessionID = "abc"
        try Data().write(to: layout.dir.appendingPathComponent("\(sessionID).jsonl"))

        #expect(ClaudeSessionScanner.isSessionBlank(
            sessionID: sessionID, worktreePath: wt, projectsBase: layout.base
        ) == true)
    }

    @Test("isSessionBlank: only metadata lines returns true")
    func blankMetadataOnly() throws {
        let wt = "/Users/test/blank-meta-\(UUID().uuidString.prefix(8))"
        let layout = try makeProjectDir(worktreePath: wt)
        defer { try? FileManager.default.removeItem(at: layout.base) }
        ClaudeProjectDirectory.clearCache()

        let sessionID = "metaonly"
        let lines = """
        {"type":"permission-mode","sessionId":"metaonly","cwd":"\(wt)","gitBranch":"main","permissionMode":"auto"}
        {"type":"file-history-snapshot","snapshot":{},"sessionId":"metaonly"}
        """
        try lines.data(using: .utf8)!.write(to: layout.dir.appendingPathComponent("\(sessionID).jsonl"))

        #expect(ClaudeSessionScanner.isSessionBlank(
            sessionID: sessionID, worktreePath: wt, projectsBase: layout.base
        ) == true)
    }

    @Test("isSessionBlank: real user content returns false")
    func nonBlankWithContent() throws {
        let wt = "/Users/test/nonblank-\(UUID().uuidString.prefix(8))"
        let layout = try makeProjectDir(worktreePath: wt)
        defer { try? FileManager.default.removeItem(at: layout.base) }
        ClaudeProjectDirectory.clearCache()

        let sessionID = "real"
        let lines = """
        {"type":"permission-mode","sessionId":"real","cwd":"\(wt)","permissionMode":"auto"}
        {"type":"user","message":{"role":"user","content":"Hello, please refactor this."},"sessionId":"real"}
        """
        try lines.data(using: .utf8)!.write(to: layout.dir.appendingPathComponent("\(sessionID).jsonl"))

        #expect(ClaudeSessionScanner.isSessionBlank(
            sessionID: sessionID, worktreePath: wt, projectsBase: layout.base
        ) == false)
    }

    @Test("isSessionBlank: assistant text content returns false")
    func nonBlankAssistant() throws {
        let wt = "/Users/test/nonblank-asst-\(UUID().uuidString.prefix(8))"
        let layout = try makeProjectDir(worktreePath: wt)
        defer { try? FileManager.default.removeItem(at: layout.base) }
        ClaudeProjectDirectory.clearCache()

        let sessionID = "asst"
        let lines = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Sure thing."}]},"sessionId":"asst"}
        """
        try lines.data(using: .utf8)!.write(to: layout.dir.appendingPathComponent("\(sessionID).jsonl"))

        #expect(ClaudeSessionScanner.isSessionBlank(
            sessionID: sessionID, worktreePath: wt, projectsBase: layout.base
        ) == false)
    }

    // MARK: - isSessionBlank with transcriptFilePath

    @Test("isSessionBlank: transcriptFilePath bypasses project dir resolution")
    func transcriptPathBypassesResolve() throws {
        // Scenario: resolve() cannot find the project dir (simulates the
        // stale-nil-cache bug where the dir exists but the cache says it
        // doesn't). transcriptFilePath lets the caller side-step resolve().
        let wt = "/Users/test/cache-bypass-\(UUID().uuidString.prefix(8))"
        let emptyBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: emptyBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyBase) }

        // Write real session content to a separate location (mirrors how the
        // SessionStart hook records the actual transcript path independently
        // of the project-dir resolution).
        let transcriptDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: transcriptDir) }
        let sessionFile = transcriptDir.appendingPathComponent("test.jsonl")
        try """
        {"type":"user","message":{"role":"user","content":"Hello!"},"sessionId":"test"}
        """.data(using: .utf8)!.write(to: sessionFile)

        // Without transcriptFilePath: resolve() uses emptyBase which has no
        // encoded dir → returns nil → blank.
        #expect(ClaudeSessionScanner.isSessionBlank(
            sessionID: "test", worktreePath: wt, projectsBase: emptyBase
        ) == true)

        // With transcriptFilePath: bypasses resolve() entirely → finds content.
        #expect(ClaudeSessionScanner.isSessionBlank(
            sessionID: "test", worktreePath: wt, transcriptFilePath: sessionFile.path, projectsBase: emptyBase
        ) == false)
    }

    @Test("isSessionBlank: transcriptFilePath for missing file falls back to project dir")
    func transcriptPathFallback() throws {
        let wt = "/Users/test/cache-fallback-\(UUID().uuidString.prefix(8))"
        let layout = try makeProjectDir(worktreePath: wt)
        defer { try? FileManager.default.removeItem(at: layout.base) }
        ClaudeProjectDirectory.clearCache()

        // Project dir exists (via makeProjectDir) but session file doesn't →
        // isSessionBlank returns true regardless of path used.
        #expect(ClaudeSessionScanner.isSessionBlank(
            sessionID: "test", worktreePath: wt, projectsBase: layout.base
        ) == true)

        // Non-existent transcriptFilePath: falls back to project dir resolution,
        // which also finds no session file → true.
        #expect(ClaudeSessionScanner.isSessionBlank(
            sessionID: "test", worktreePath: wt, transcriptFilePath: "/nonexistent/path.jsonl", projectsBase: layout.base
        ) == true)
    }

    @Test("isSessionBlank: transcriptFilePath with empty file returns true")
    func transcriptPathEmpty() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let sessionFile = tmpDir.appendingPathComponent("empty.jsonl")
        try Data().write(to: sessionFile)

        #expect(ClaudeSessionScanner.isSessionBlank(
            sessionID: "test", worktreePath: "/any/path", transcriptFilePath: sessionFile.path
        ) == true)
    }

    @Test("isSessionBlank: transcriptFilePath with content returns false")
    func transcriptPathWithContent() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let sessionFile = tmpDir.appendingPathComponent("content.jsonl")
        let lines = """
        {"type":"user","message":{"role":"user","content":"Hello, world!"},"sessionId":"test"}
        """
        try lines.data(using: .utf8)!.write(to: sessionFile)

        #expect(ClaudeSessionScanner.isSessionBlank(
            sessionID: "test", worktreePath: "/any/path", transcriptFilePath: sessionFile.path
        ) == false)
    }

    // MARK: - Cache TTL tests

    @Test("ClaudeProjectDirectory: positive entries are re-validated against filesystem")
    func positiveEntryRevalidation() throws {
        let wt = "/Users/test/revalidate-\(UUID().uuidString.prefix(8))"
        let layout = try makeProjectDir(worktreePath: wt)
        defer { try? FileManager.default.removeItem(at: layout.base) }
        ClaudeProjectDirectory.clearCache()

        // First call: hit, cache records it (makeProjectDir already created the dir)
        let first = ClaudeProjectDirectory.resolve(worktreePath: wt, projectsBase: layout.base)
        #expect(first != nil)

        // Second call: should return cached result (re-validated as existing)
        let second = ClaudeProjectDirectory.resolve(worktreePath: wt, projectsBase: layout.base)
        #expect(second != nil)

        // Delete the directory
        try FileManager.default.removeItem(at: layout.dir)

        // Third call: positive entry is re-validated, finds it missing, returns nil
        let third = ClaudeProjectDirectory.resolve(worktreePath: wt, projectsBase: layout.base)
        #expect(third == nil)
    }
}
