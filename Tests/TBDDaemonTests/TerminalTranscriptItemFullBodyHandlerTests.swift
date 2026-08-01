import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("terminal.transcriptItemFullBody handler")
struct TerminalTranscriptItemFullBodyHandlerTests {
    let db: TBDDatabase
    let router: RPCRouter

    init() throws {
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        self.router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date()
        )
    }

    @Test("returns error when terminal not found")
    func returnsErrorWhenTerminalNotFound() async throws {
        let request = try RPCRequest(
            method: RPCMethod.terminalTranscriptItemFullBody,
            params: TerminalTranscriptItemFullBodyParams(
                terminalID: UUID(),
                itemID: "toolu_anything"
            )
        )
        let response = await router.handle(request)

        #expect(!response.success)
        #expect(response.error?.contains("Terminal not found") == true)
    }

    @Test("returns placeholder when item not found")
    func returnsPlaceholderWhenItemNotFound() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        let wtPath = "/tmp/no-such-worktree-\(UUID().uuidString)"
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: wtPath,
            tmuxServer: "tbd-test"
        )
        let sessionID = "nonexistent-session-\(UUID().uuidString)"
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@mock-0",
            tmuxPaneID: "%mock-0",
            claudeSessionID: sessionID
        )

        // Make sure the cache is clean so resolution actually consults the
        // (empty) filesystem rather than a stale entry from another test.
        ClaudeProjectDirectory.clearCache()

        let request = try RPCRequest(
            method: RPCMethod.terminalTranscriptItemFullBody,
            params: TerminalTranscriptItemFullBodyParams(
                terminalID: terminal.id,
                itemID: "toolu_missing"
            )
        )
        let response = await router.handle(request)

        #expect(response.success)
        let result = try response.decodeResult(TerminalTranscriptItemFullBodyResult.self)
        #expect(result.text == "Output no longer available.")
    }

    @Test("returns full body for matching tool result")
    func returnsFullBodyForMatchingToolResult() async throws {
        // ClaudeProjectDirectory.resolve() looks under the host store's
        // projects/<encoded>/, so we plant the fixture there under a unique
        // encoded dir name and clean up afterward.
        let projectsBase = Self.hostProjectsBase
        try FileManager.default.createDirectory(at: projectsBase, withIntermediateDirectories: true)

        // Pick a worktree path under /private/tmp so the tier-1 encoding
        // (`/` and `.` → `-`) yields a unique encoded directory name we can
        // safely create and remove.
        let unique = UUID().uuidString
        let wtPath = "/private/tmp/tbd-fullbody-\(unique)"
        let encoded = wtPath.map { "/.".contains($0) ? "-" : String($0) }.joined()
        let projectDir = projectsBase.appendingPathComponent(encoded)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectDir) }

        let sessionID = UUID().uuidString
        let bigPayload = String(repeating: "y", count: 5000)
        let line: [String: Any] = [
            "type": "user",
            "uuid": UUID().uuidString,
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": "toolu_full",
                        "content": bigPayload,
                    ]
                ],
            ],
        ]
        let lineData = try JSONSerialization.data(withJSONObject: line)
        let lineStr = String(data: lineData, encoding: .utf8)!
        let jsonlPath = projectDir.appendingPathComponent("\(sessionID).jsonl").path
        try (lineStr + "\n").write(toFile: jsonlPath, atomically: true, encoding: .utf8)

        // Drop any stale resolution from previous tests so our brand-new
        // project dir is actually consulted.
        ClaudeProjectDirectory.clearCache()

        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: wtPath,
            tmuxServer: "tbd-test"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@mock-0",
            tmuxPaneID: "%mock-0",
            claudeSessionID: sessionID
        )

        let request = try RPCRequest(
            method: RPCMethod.terminalTranscriptItemFullBody,
            params: TerminalTranscriptItemFullBodyParams(
                terminalID: terminal.id,
                itemID: "toolu_full"
            )
        )
        let response = await router.handle(request)

        #expect(response.success)
        let result = try response.decodeResult(TerminalTranscriptItemFullBodyResult.self)
        #expect(result.text.count == 5000)
        #expect(result.text == bigPayload)
    }

    // MARK: - includeBody

    /// The `projects/` root `ClaudeProjectDirectory.resolve` searches when no
    /// base is injected.
    ///
    /// Resolved the same way the production code resolves it, rather than
    /// hand-built from `NSHomeDirectory()`. These fixtures are planted where
    /// the resolver will look, and the resolver honours `TBD_CLAUDE_HOST_HOME`
    /// — so hand-building it planted real `<encoded>/` directories in the
    /// developer's own `~/.claude/projects` on every run, outside the fence
    /// `scripts/test.sh` puts around that store. The `defer`-based cleanup hid
    /// it from the wrapper's fingerprint too: the directories were gone again
    /// before the after-snapshot was taken.
    private static var hostProjectsBase: URL {
        ClaudeProfileConfigDirManager.resolveHostBaseDirectory()
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// Plants a single-line JSONL fixture in the only place
    /// `ClaudeProjectDirectory` looks (the host store's `projects/<encoded>/`)
    /// and registers a terminal pointing at it. The caller removes `projectDir`.
    private func plantFixture(line: [String: Any]) async throws -> (terminalID: UUID, projectDir: URL) {
        let projectsBase = Self.hostProjectsBase
        try FileManager.default.createDirectory(at: projectsBase, withIntermediateDirectories: true)

        let wtPath = "/private/tmp/tbd-fullbody-\(UUID().uuidString)"
        let encoded = wtPath.map { "/.".contains($0) ? "-" : String($0) }.joined()
        let projectDir = projectsBase.appendingPathComponent(encoded)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let sessionID = UUID().uuidString
        let lineData = try JSONSerialization.data(withJSONObject: line)
        let lineStr = try #require(String(data: lineData, encoding: .utf8))
        try (lineStr + "\n").write(
            toFile: projectDir.appendingPathComponent("\(sessionID).jsonl").path,
            atomically: true, encoding: .utf8)
        ClaudeProjectDirectory.clearCache()

        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "test-wt", branch: "tbd/test-wt",
            path: wtPath, tmuxServer: "tbd-test")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@mock-0", tmuxPaneID: "%mock-0",
            claudeSessionID: sessionID)
        return (terminal.id, projectDir)
    }

    /// A `nested_memory` attachment row: a large injected CLAUDE.md body plus
    /// the injection metadata the overlay renders.
    private func injectedMemoryLine(body: String, path: String) -> [String: Any] {
        [
            "type": "attachment",
            "uuid": "att-acme",
            "timestamp": "2026-07-24T10:00:00.000Z",
            "attachment": [
                "type": "nested_memory",
                "displayPath": ".github/CLAUDE.md",
                "path": path,
                "content": ["path": path, "type": "Project", "content": body],
            ],
        ]
    }

    @Test("includeBody: false returns the metadata with no body text")
    func metadataOnlyOmitsBody() async throws {
        let body = String(repeating: "z", count: 43_000)
        let planted = try await plantFixture(
            line: injectedMemoryLine(body: body, path: "/srv/acme-prod/.github/CLAUDE.md"))
        defer { try? FileManager.default.removeItem(at: planted.projectDir) }

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalTranscriptItemFullBody,
            params: TerminalTranscriptItemFullBodyParams(
                terminalID: planted.terminalID, itemID: "att-acme", includeBody: false)))

        #expect(response.success)
        let result = try response.decodeResult(TerminalTranscriptItemFullBodyResult.self)
        #expect(result.text.isEmpty, "the 43 KB body must not cross the wire")
        let attachment = try #require(result.attachment)
        #expect(attachment.memoryType == "Project")
        #expect(attachment.path == "/srv/acme-prod/.github/CLAUDE.md")
    }

    @Test("default (includeBody: true) still returns the body alongside the metadata")
    func defaultIncludesBody() async throws {
        let body = String(repeating: "z", count: 43_000)
        let planted = try await plantFixture(
            line: injectedMemoryLine(body: body, path: "/srv/acme-prod/.github/CLAUDE.md"))
        defer { try? FileManager.default.removeItem(at: planted.projectDir) }

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalTranscriptItemFullBody,
            params: TerminalTranscriptItemFullBodyParams(
                terminalID: planted.terminalID, itemID: "att-acme")))

        #expect(response.success)
        let result = try response.decodeResult(TerminalTranscriptItemFullBodyResult.self)
        #expect(result.text == body)
        #expect(result.attachment?.memoryType == "Project")
    }

    /// Wire back-compat: params encoded by a client predating `includeBody`
    /// (key absent) must still get the body.
    @Test("params without includeBody behave as includeBody: true")
    func legacyParamsIncludeBody() async throws {
        let body = "acme guidance"
        let planted = try await plantFixture(
            line: injectedMemoryLine(body: body, path: "/srv/acme-prod/.github/CLAUDE.md"))
        defer { try? FileManager.default.removeItem(at: planted.projectDir) }

        let legacyParams = #"{"terminalID":"\#(planted.terminalID.uuidString)","itemID":"att-acme"}"#
        let response = await router.handle(RPCRequest(
            method: RPCMethod.terminalTranscriptItemFullBody, params: legacyParams))

        #expect(response.success)
        let result = try response.decodeResult(TerminalTranscriptItemFullBodyResult.self)
        #expect(result.text == body)
    }
}
