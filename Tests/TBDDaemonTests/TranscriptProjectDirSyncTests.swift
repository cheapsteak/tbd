import Testing
import Foundation
@testable import TBDDaemonLib

/// Unit tests for the copy-if-newer transcript sync unit. Pure temp-dir
/// filesystem tests — no TBD_HOME, no ~/.claude, no daemon state.
@Suite("TranscriptProjectDirSync")
struct TranscriptProjectDirSyncTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL, mtime: Date? = nil) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes(
                [.modificationDate: mtime], ofItemAtPath: url.path)
        }
    }

    private func contents(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - derivedProjectDir

    @Test func derivedProjectDirMungesSlashesAndDots() throws {
        let root = URL(fileURLWithPath: "/tmp/projects", isDirectory: true)
        let derived = TranscriptProjectDirSync.derivedProjectDir(
            worktreePath: "/Users/dev/my.app/wt", projectsRoot: root)
        #expect(derived.lastPathComponent == "-Users-dev-my-app-wt")
        #expect(derived.deletingLastPathComponent().path == "/tmp/projects")
    }

    // MARK: - copyIfNewer

    @Test func copyIfNewerCopiesWhenDestinationMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("src/a.jsonl")
        let dest = dir.appendingPathComponent("dst/a.jsonl")
        try write("hello", to: source)

        let copied = TranscriptProjectDirSync.copyIfNewer(from: source, to: dest)

        #expect(copied)
        #expect(contents(dest) == "hello")
    }

    @Test func copyIfNewerOverwritesStaleDestination() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("src/a.jsonl")
        let dest = dir.appendingPathComponent("dst/a.jsonl")
        try write("new content", to: source, mtime: Date())
        try write("old content", to: dest, mtime: Date(timeIntervalSinceNow: -600))

        let copied = TranscriptProjectDirSync.copyIfNewer(from: source, to: dest)

        #expect(copied)
        #expect(contents(dest) == "new content")
    }

    @Test func copyIfNewerLeavesFresherDestinationIntact() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("src/a.jsonl")
        let dest = dir.appendingPathComponent("dst/a.jsonl")
        try write("stale snapshot", to: source, mtime: Date(timeIntervalSinceNow: -600))
        try write("fresher work", to: dest, mtime: Date())

        let copied = TranscriptProjectDirSync.copyIfNewer(from: source, to: dest)

        #expect(!copied)
        #expect(contents(dest) == "fresher work")
    }

    @Test func copyIfNewerLeavesEquallyFreshDestinationIntact() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stamp = Date(timeIntervalSinceNow: -60)
        let source = dir.appendingPathComponent("src/a.jsonl")
        let dest = dir.appendingPathComponent("dst/a.jsonl")
        try write("source", to: source, mtime: stamp)
        try write("destination", to: dest, mtime: stamp)

        let copied = TranscriptProjectDirSync.copyIfNewer(from: source, to: dest)

        #expect(!copied)
        #expect(contents(dest) == "destination")
    }

    @Test func copyIfNewerNoopsOnMissingSource() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("src/missing.jsonl")
        let dest = dir.appendingPathComponent("dst/missing.jsonl")

        let copied = TranscriptProjectDirSync.copyIfNewer(from: source, to: dest)

        #expect(!copied)
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    // MARK: - syncDirectoryContents

    @Test func syncDirectoryContentsRecursesAndPreservesNewerDestination() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceDir = dir.appendingPathComponent("src", isDirectory: true)
        let destDir = dir.appendingPathComponent("dst", isDirectory: true)
        try write("s1", to: sourceDir.appendingPathComponent("s1.jsonl"))
        try write("memory", to: sourceDir.appendingPathComponent("memory/MEMORY.md"))
        try write("agent", to: sourceDir.appendingPathComponent("s1/subagents/agent-a.jsonl"))
        // Destination already has fresher work for one file.
        try write("stale s2", to: sourceDir.appendingPathComponent("s2.jsonl"),
                  mtime: Date(timeIntervalSinceNow: -600))
        try write("fresh s2", to: destDir.appendingPathComponent("s2.jsonl"), mtime: Date())

        TranscriptProjectDirSync.syncDirectoryContents(from: sourceDir, to: destDir)

        #expect(contents(destDir.appendingPathComponent("s1.jsonl")) == "s1")
        #expect(contents(destDir.appendingPathComponent("memory/MEMORY.md")) == "memory")
        #expect(contents(destDir.appendingPathComponent("s1/subagents/agent-a.jsonl")) == "agent")
        #expect(contents(destDir.appendingPathComponent("s2.jsonl")) == "fresh s2")
    }

    // MARK: - syncSession

    @Test func syncSessionCopiesJsonlAndSubagents() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceDir = dir.appendingPathComponent("old-slug", isDirectory: true)
        let destDir = dir.appendingPathComponent("new-slug", isDirectory: true)
        let jsonl = sourceDir.appendingPathComponent("sess-1.jsonl")
        try write("transcript", to: jsonl)
        try write("sub", to: sourceDir.appendingPathComponent("sess-1/subagents/agent-x.jsonl"))

        TranscriptProjectDirSync.syncSession(jsonl: jsonl, intoProjectDir: destDir)

        #expect(contents(destDir.appendingPathComponent("sess-1.jsonl")) == "transcript")
        #expect(contents(destDir.appendingPathComponent("sess-1/subagents/agent-x.jsonl")) == "sub")
    }

    // MARK: - ensureSessionResumable

    @Test func ensureSessionResumableCopiesFromStoredPathWhenDestinationMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("projects", isDirectory: true)
        let worktreePath = dir.appendingPathComponent("wt").path
        let stored = dir.appendingPathComponent("elsewhere/sess-1.jsonl")
        try write("stored transcript", to: stored)

        TranscriptProjectDirSync.ensureSessionResumable(
            sessionID: "sess-1", worktreePath: worktreePath,
            projectsRoot: root, storedTranscriptPath: stored.path)

        let derived = TranscriptProjectDirSync.derivedProjectDir(
            worktreePath: worktreePath, projectsRoot: root)
        #expect(contents(derived.appendingPathComponent("sess-1.jsonl")) == "stored transcript")
    }

    @Test func ensureSessionResumableOverwritesStaleDestination() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("projects", isDirectory: true)
        let worktreePath = dir.appendingPathComponent("wt").path
        let stored = dir.appendingPathComponent("elsewhere/sess-1.jsonl")
        try write("live latest", to: stored, mtime: Date())
        let derived = TranscriptProjectDirSync.derivedProjectDir(
            worktreePath: worktreePath, projectsRoot: root)
        try write("old snapshot", to: derived.appendingPathComponent("sess-1.jsonl"),
                  mtime: Date(timeIntervalSinceNow: -600))

        TranscriptProjectDirSync.ensureSessionResumable(
            sessionID: "sess-1", worktreePath: worktreePath,
            projectsRoot: root, storedTranscriptPath: stored.path)

        #expect(contents(derived.appendingPathComponent("sess-1.jsonl")) == "live latest")
    }

    @Test func ensureSessionResumableLeavesFresherDestinationIntact() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("projects", isDirectory: true)
        let worktreePath = dir.appendingPathComponent("wt").path
        let stored = dir.appendingPathComponent("elsewhere/sess-1.jsonl")
        try write("older stored", to: stored, mtime: Date(timeIntervalSinceNow: -600))
        let derived = TranscriptProjectDirSync.derivedProjectDir(
            worktreePath: worktreePath, projectsRoot: root)
        try write("newer derived", to: derived.appendingPathComponent("sess-1.jsonl"), mtime: Date())

        TranscriptProjectDirSync.ensureSessionResumable(
            sessionID: "sess-1", worktreePath: worktreePath,
            projectsRoot: root, storedTranscriptPath: stored.path)

        #expect(contents(derived.appendingPathComponent("sess-1.jsonl")) == "newer derived")
    }

    // MARK: - locateSessionTranscript

    @Test func locateSessionTranscriptFindsNewestCopyAcrossProjectDirs() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("projects", isDirectory: true)
        try write("stale copy", to: root.appendingPathComponent("-old-slug-a/sess-1.jsonl"),
                  mtime: Date(timeIntervalSinceNow: -600))
        try write("fresh copy", to: root.appendingPathComponent("-old-slug-b/sess-1.jsonl"),
                  mtime: Date())
        try write("other session", to: root.appendingPathComponent("-old-slug-b/sess-2.jsonl"))

        let located = TranscriptProjectDirSync.locateSessionTranscript(
            sessionID: "sess-1", projectsRoot: root)
        #expect(contents(try #require(located)) == "fresh copy")
    }

    /// The profile-bound resume case: a model profile's config dir mirrors the
    /// host store by symlinking its `projects` slot
    /// (`~/tbd/profiles/<id>/claude/projects -> ~/.claude/projects`).
    /// `FileManager.contentsOfDirectory(at:)` lists a symlinked directory URL
    /// as EMPTY, so this scan used to find nothing and every profile-bound
    /// resume silently started a fresh conversation.
    @Test func locateSessionTranscriptFindsSessionThroughSymlinkedProjectsRoot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostRoot = dir.appendingPathComponent("host-projects", isDirectory: true)
        try write("archived transcript", to: hostRoot.appendingPathComponent("-old-slug/sess-1.jsonl"))
        let profileRoot = dir.appendingPathComponent("profile/projects", isDirectory: true)
        try FileManager.default.createDirectory(
            at: profileRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: profileRoot, withDestinationURL: hostRoot)

        let located = TranscriptProjectDirSync.locateSessionTranscript(
            sessionID: "sess-1", projectsRoot: profileRoot)

        #expect(contents(try #require(located)) == "archived transcript")
    }

    /// Same defect, one layer up: the by-ID scan through a symlinked root has
    /// to end with the transcript mirrored into the derived project dir, which
    /// is itself addressed *through* the symlink.
    @Test func ensureSessionResumableMirrorsThroughSymlinkedProjectsRoot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostRoot = dir.appendingPathComponent("host-projects", isDirectory: true)
        try write("archived transcript", to: hostRoot.appendingPathComponent("-old-slug/sess-1.jsonl"))
        let profileRoot = dir.appendingPathComponent("profile/projects", isDirectory: true)
        try FileManager.default.createDirectory(
            at: profileRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: profileRoot, withDestinationURL: hostRoot)
        let worktreePath = dir.appendingPathComponent("wt-new-location").path

        TranscriptProjectDirSync.ensureSessionResumable(
            sessionID: "sess-1", worktreePath: worktreePath,
            projectsRoot: profileRoot, storedTranscriptPath: nil)

        let derived = TranscriptProjectDirSync.derivedProjectDir(
            worktreePath: worktreePath, projectsRoot: profileRoot)
        #expect(contents(derived.appendingPathComponent("sess-1.jsonl")) == "archived transcript")
        // The mirror landed in the host store the symlink points at, not in a
        // shadow directory beside it.
        let hostDerived = TranscriptProjectDirSync.derivedProjectDir(
            worktreePath: worktreePath, projectsRoot: hostRoot)
        #expect(contents(hostDerived.appendingPathComponent("sess-1.jsonl")) == "archived transcript")
    }

    /// `syncDirectoryContents` shares the blindness: a symlinked `sourceDir`
    /// (e.g. a `subagents/` slot mirrored elsewhere) listed as empty and the
    /// whole subtree was silently skipped.
    @Test func syncDirectoryContentsFollowsSymlinkedSourceDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realDir = dir.appendingPathComponent("real", isDirectory: true)
        try write("agent", to: realDir.appendingPathComponent("agent-a.jsonl"))
        try write("nested", to: realDir.appendingPathComponent("deeper/agent-b.jsonl"))
        let linkedSource = dir.appendingPathComponent("linked-src", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedSource, withDestinationURL: realDir)
        let destDir = dir.appendingPathComponent("dst", isDirectory: true)

        TranscriptProjectDirSync.syncDirectoryContents(from: linkedSource, to: destDir)

        #expect(contents(destDir.appendingPathComponent("agent-a.jsonl")) == "agent")
        #expect(contents(destDir.appendingPathComponent("deeper/agent-b.jsonl")) == "nested")
    }

    @Test func locateSessionTranscriptReturnsNilWhenSessionAbsent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("projects", isDirectory: true)
        try write("other session", to: root.appendingPathComponent("-slug/sess-2.jsonl"))

        #expect(TranscriptProjectDirSync.locateSessionTranscript(
            sessionID: "sess-1", projectsRoot: root) == nil)
    }

    /// The moved-while-archived revive case: no terminal row survived to
    /// store a transcript path, and the OLD munged dir doesn't resolve from
    /// the worktree's CURRENT path — the by-session-ID scan must still find
    /// and mirror the transcript.
    @Test func ensureSessionResumableFallsBackToByIDScanWithoutStoredPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("projects", isDirectory: true)
        let worktreePath = dir.appendingPathComponent("wt-new-location").path
        try write("archived transcript", to: root.appendingPathComponent("-old-slug/sess-1.jsonl"))

        TranscriptProjectDirSync.ensureSessionResumable(
            sessionID: "sess-1", worktreePath: worktreePath,
            projectsRoot: root, storedTranscriptPath: nil)

        let derived = TranscriptProjectDirSync.derivedProjectDir(
            worktreePath: worktreePath, projectsRoot: root)
        #expect(contents(derived.appendingPathComponent("sess-1.jsonl")) == "archived transcript")
    }

    @Test func ensureSessionResumableNoopsWithoutAnySource() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let worktreePath = dir.appendingPathComponent("wt").path

        TranscriptProjectDirSync.ensureSessionResumable(
            sessionID: "sess-1", worktreePath: worktreePath,
            projectsRoot: root, storedTranscriptPath: nil)

        let derived = TranscriptProjectDirSync.derivedProjectDir(
            worktreePath: worktreePath, projectsRoot: root)
        #expect(!FileManager.default.fileExists(
            atPath: derived.appendingPathComponent("sess-1.jsonl").path))
    }
}
