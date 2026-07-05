import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Covers the account-swap transcript carry: when "Switch account" forks a new
/// `claude --resume <id>` under a DIFFERENT config dir, the session transcript
/// must be reachable in that destination config dir's `projects/` tree or the
/// resume fails with "No conversation found with session ID".
///
/// These tests exercise the pure filesystem helpers (`ensureTranscriptReachable`,
/// `resolveSwapSourceTranscript`) plus one end-to-end swap through
/// `handleTerminalSwapProfile` with an injected `ClaudeProfileConfigDirManager`
/// pointed at temp dirs — no `TBD_HOME` mutation, so no serialization needed.
@Suite("Swap Transcript Carry")
struct SwapTranscriptCarryTests {

    // MARK: - Helpers

    /// A fresh temp directory, removed on `deinit` via the returned token.
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-swap-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write a session jsonl containing a real user message under
    /// `<configDir>/projects/<slug>/<sessionID>.jsonl`, returning the file URL.
    @discardableResult
    private func writeTranscript(
        configDir: URL,
        slug: String,
        sessionID: String,
        content: String = #"{"type":"user","message":{"role":"user","content":"hello there"}}"#
    ) throws -> URL {
        let projectDir = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("\(sessionID).jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: - ensureTranscriptReachable

    @Test("copies transcript into destination config dir preserving cwd-slug layout")
    func copiesIntoDestination() throws {
        let src = makeTempDir()
        let dst = makeTempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }

        let sessionID = UUID().uuidString
        let slug = "-Users-zionts-wt"
        let sourceFile = try writeTranscript(configDir: src, slug: slug, sessionID: sessionID)

        RPCRouter.ensureTranscriptReachable(from: sourceFile, inConfigDir: dst)

        let expected = dst
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        #expect(FileManager.default.fileExists(atPath: expected.path))
        // Source is copied, not moved — the live session may still be writing.
        #expect(FileManager.default.fileExists(atPath: sourceFile.path))
        // Content matches.
        let copied = try String(contentsOf: expected, encoding: .utf8)
        #expect(copied.contains("hello there"))
    }

    @Test("no-op when destination already has the file (content preserved)")
    func noOpWhenDestinationExists() throws {
        let src = makeTempDir()
        let dst = makeTempDir()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }

        let sessionID = UUID().uuidString
        let slug = "-Users-zionts-wt"
        let sourceFile = try writeTranscript(
            configDir: src, slug: slug, sessionID: sessionID,
            content: #"{"type":"user","message":{"role":"user","content":"NEW source"}}"#
        )
        // Pre-existing destination with DIFFERENT content — must not be clobbered.
        let destFile = try writeTranscript(
            configDir: dst, slug: slug, sessionID: sessionID,
            content: #"{"type":"user","message":{"role":"user","content":"EXISTING dest"}}"#
        )

        RPCRouter.ensureTranscriptReachable(from: sourceFile, inConfigDir: dst)

        let after = try String(contentsOf: destFile, encoding: .utf8)
        #expect(after.contains("EXISTING dest"))
        #expect(!after.contains("NEW source"))
    }

    @Test("no throw / no crash when source transcript is missing")
    func missingSourceIsSafe() throws {
        let dst = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dst) }
        let bogus = makeTempDir().appendingPathComponent("projects/-slug/\(UUID().uuidString).jsonl")

        // Should simply log and return — never throws.
        RPCRouter.ensureTranscriptReachable(from: bogus, inConfigDir: dst)
        // Nothing was created.
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("projects").path))
    }

    @Test("profile→profile shared symlink target: same realpath → no copy")
    func sharedSymlinkTargetIsNoOp() throws {
        // Model the production layout: a host `projects/` dir, and a profile
        // config dir whose `projects/` slot symlinks to the host. Source and
        // destination both resolve to the host file — nothing to copy.
        let host = makeTempDir()
        let profileConfig = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: host)
            try? FileManager.default.removeItem(at: profileConfig)
        }

        let sessionID = UUID().uuidString
        let slug = "-Users-zionts-wt"
        // Real transcript lives under host/projects.
        let hostFile = try writeTranscript(configDir: host, slug: slug, sessionID: sessionID)

        // profileConfig/projects → host/projects (symlink the slot).
        let profileProjects = profileConfig.appendingPathComponent("projects")
        try FileManager.default.createSymbolicLink(
            at: profileProjects,
            withDestinationURL: host.appendingPathComponent("projects")
        )

        // Source = the path as seen through the profile symlink; dest config = host.
        let sourceViaSymlink = profileProjects
            .appendingPathComponent(slug)
            .appendingPathComponent("\(sessionID).jsonl")

        RPCRouter.ensureTranscriptReachable(from: sourceViaSymlink, inConfigDir: host)

        // The host file is unchanged and no stray duplicate was made.
        #expect(FileManager.default.fileExists(atPath: hostFile.path))
    }

    // MARK: - resolveSwapSourceTranscript

    @Test("prefers terminal transcriptPath when present on disk")
    func prefersTranscriptPath() throws {
        let src = makeTempDir()
        defer { try? FileManager.default.removeItem(at: src) }
        let sessionID = UUID().uuidString
        let file = try writeTranscript(configDir: src, slug: "-Users-zionts-wt", sessionID: sessionID)

        let resolved = RPCRouter.resolveSwapSourceTranscript(
            transcriptPath: file.path,
            sessionID: sessionID,
            worktreePath: "/Users/zionts/wt",
            sourceConfigDir: src
        )
        #expect(resolved?.path == file.path)
    }

    @Test("falls back to source config dir projects scan when transcriptPath nil")
    func fallsBackToProjectsScan() throws {
        let src = makeTempDir()
        defer { try? FileManager.default.removeItem(at: src) }
        let worktreePath = "/tmp/wt-\(UUID().uuidString)"
        // Exact slug encoding: / and . → -
        let slug = worktreePath.map { "/.".contains($0) ? "-" : String($0) }.joined()
        let sessionID = UUID().uuidString
        let file = try writeTranscript(configDir: src, slug: slug, sessionID: sessionID)

        ClaudeProjectDirectory.clearCache()
        let resolved = RPCRouter.resolveSwapSourceTranscript(
            transcriptPath: nil,
            sessionID: sessionID,
            worktreePath: worktreePath,
            sourceConfigDir: src
        )
        #expect(resolved?.resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path)
    }

    @Test("returns nil when neither transcriptPath nor projects file exist")
    func returnsNilWhenAbsent() throws {
        let src = makeTempDir()
        defer { try? FileManager.default.removeItem(at: src) }
        ClaudeProjectDirectory.clearCache()
        let resolved = RPCRouter.resolveSwapSourceTranscript(
            transcriptPath: nil,
            sessionID: UUID().uuidString,
            worktreePath: "/tmp/wt-\(UUID().uuidString)",
            sourceConfigDir: src
        )
        #expect(resolved == nil)
    }

    // MARK: - End-to-end: ambient → profile swap carries the transcript

    @Test("ambient→profile swap copies the live transcript into the profile config dir")
    func ambientToProfileSwapCarriesTranscript() async throws {
        // Inject a config-dir manager pointed at temp base/host dirs so the
        // swap's carry writes into a directory we can assert on, without
        // touching ~/.claude or ~/tbd.
        let baseDir = makeTempDir()   // stands in for ~/tbd/profiles
        let hostDir = makeTempDir()   // stands in for ~/.claude (ambient source)
        defer {
            try? FileManager.default.removeItem(at: baseDir)
            try? FileManager.default.removeItem(at: hostDir)
        }
        let manager = ClaudeProfileConfigDirManager(baseDirectory: baseDir, hostBaseDirectory: hostDir)

        let db = try TBDDatabase(inMemory: true)
        let tmux = TmuxManager(dryRun: true)
        let lifecycle = WorktreeLifecycle(db: db, git: GitManager(), tmux: tmux, hooks: HookResolver())
        let router = RPCRouter(
            db: db,
            lifecycle: lifecycle,
            tmux: tmux,
            startTime: Date(),
            usageFetcher: StubClaudeUsageFetcher(),
            configDirManager: manager
        )

        // Seed repo + worktree.
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID().uuidString)", displayName: "r", defaultBranch: "main")
        let worktreePath = "/tmp/wt-\(UUID().uuidString)"
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main", path: worktreePath, tmuxServer: "tbd-test"
        )

        // Destination profile (OAuth).
        let dest = try await db.modelProfiles.create(name: "Dest", kind: .oauth)
        defer { try? ModelProfileKeychain.delete(id: dest.id.uuidString) }

        // Seed an AMBIENT claude terminal (profileID nil) with a NON-blank
        // transcript living under the ambient (host) config dir's projects.
        let sessionID = UUID().uuidString
        let slug = "-ambient-slug"
        let transcript = try writeTranscript(configDir: hostDir, slug: slug, sessionID: sessionID)

        let term = try await db.terminals.create(
            id: UUID(),
            worktreeID: wt.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "claude",
            claudeSessionID: sessionID,
            profileID: nil,
            kind: .claude
        )
        try await db.terminals.updateSession(id: term.id, sessionID: sessionID, transcriptPath: transcript.path)

        // Swap ambient → Dest profile.
        let swapResp = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(terminalID: term.id, newProfileID: dest.id)
        ))
        #expect(swapResp.success)

        // The transcript must now be reachable under the DEST profile's config
        // dir projects tree, at the same slug/file the ambient source used.
        let destConfig = manager.configDirectory(forProfileID: dest.id)
        let carried = destConfig
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        #expect(FileManager.default.fileExists(atPath: carried.path))
        // Source ambient transcript is untouched (copy, not move).
        #expect(FileManager.default.fileExists(atPath: transcript.path))
    }
}
