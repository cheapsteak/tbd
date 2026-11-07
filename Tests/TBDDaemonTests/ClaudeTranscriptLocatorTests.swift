import Foundation
import Testing
import TBDShared
@testable import TBDDaemonLib

@Suite("ClaudeTranscriptLocator")
struct ClaudeTranscriptLocatorTests {
    private func terminal(sessionID: String?, transcriptPath: String?) -> TBDShared.Terminal {
        TBDShared.Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            claudeSessionID: sessionID, transcriptPath: transcriptPath)
    }

    @Test func aStoredPathWins() {
        let t = terminal(sessionID: "sess-1", transcriptPath: "/acme/stored/sess-1.jsonl")
        #expect(ClaudeTranscriptLocator.filePath(terminal: t, worktreePath: "/acme/wt") == "/acme/stored/sess-1.jsonl")
    }

    @Test func aMissingSessionIDGivesNil() {
        let t = terminal(sessionID: nil, transcriptPath: nil)
        #expect(ClaudeTranscriptLocator.filePath(terminal: t, worktreePath: "/acme/wt") == nil)
    }

    @Test func theFallbackJoinsTheProjectDirAndSessionID() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let worktreePath = "/acme/locator-\(UUID().uuidString.prefix(8))"
        let folder = worktreePath.map { "/.".contains($0) ? "-" : String($0) }.joined()
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
        ClaudeProjectDirectory.clearCache()

        let t = terminal(sessionID: "sess-2", transcriptPath: "")
        let path = ClaudeTranscriptLocator.filePath(terminal: t, worktreePath: worktreePath, projectsBase: tmp)

        #expect(path?.hasSuffix("/sess-2.jsonl") == true)
        #expect(path?.contains(folder) == true)
    }

    /// A terminal on a model profile that has had no SessionStart hook yet
    /// keeps its JSONL under the profile's own `projects/`, so that root is
    /// searched before the host store's, even when both hold the session's
    /// file.
    @Test func aProfileRootIsSearchedBeforeTheHostRoot() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let hostRoot = tmp.appendingPathComponent("host-projects", isDirectory: true)
        let profileRoot = tmp.appendingPathComponent("profile-projects", isDirectory: true)
        let worktreePath = "/acme/locator-\(UUID().uuidString.prefix(8))"
        let folder = Self.projectFolder(for: worktreePath)
        for root in [hostRoot, profileRoot] {
            let projectDir = root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            try Data().write(to: projectDir.appendingPathComponent("sess-3.jsonl"))
        }

        let t = terminal(sessionID: "sess-3", transcriptPath: nil)
        let path = ClaudeTranscriptLocator.filePath(
            terminal: t, worktreePath: worktreePath,
            projectsBase: hostRoot, profileProjectsBase: profileRoot)

        #expect(path?.hasPrefix(profileRoot.path + "/") == true, "path was \(path ?? "nil")")
        #expect(path?.hasSuffix("/\(folder)/sess-3.jsonl") == true, "path was \(path ?? "nil")")
    }

    /// A Bedrock profile runs Claude in the host store and has no project
    /// directory under its own root, so the search falls through to the host
    /// root.
    @Test func aProfileRootWithNoProjectDirFallsThroughToTheHostRoot() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let hostRoot = tmp.appendingPathComponent("host-projects", isDirectory: true)
        let profileRoot = tmp.appendingPathComponent("profile-projects", isDirectory: true)
        let worktreePath = "/acme/locator-\(UUID().uuidString.prefix(8))"
        let folder = Self.projectFolder(for: worktreePath)
        try FileManager.default.createDirectory(
            at: hostRoot.appendingPathComponent(folder, isDirectory: true),
            withIntermediateDirectories: true)

        let t = terminal(sessionID: "sess-4", transcriptPath: nil)
        let path = ClaudeTranscriptLocator.filePath(
            terminal: t, worktreePath: worktreePath,
            projectsBase: hostRoot, profileProjectsBase: profileRoot)

        #expect(path?.hasPrefix(hostRoot.path + "/") == true, "path was \(path ?? "nil")")
        #expect(path?.hasSuffix("/\(folder)/sess-4.jsonl") == true, "path was \(path ?? "nil")")
    }

    /// A project directory under the profile root is not enough: a profile
    /// that runs Claude in the host store can hold the worktree's project
    /// directory without this session's file. The session file in the host
    /// root wins over a profile root that lacks it.
    @Test func aProfileRootWithoutTheSessionFileFallsThroughToTheHostFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let hostRoot = tmp.appendingPathComponent("host-projects", isDirectory: true)
        let profileRoot = tmp.appendingPathComponent("profile-projects", isDirectory: true)
        let worktreePath = "/acme/locator-\(UUID().uuidString.prefix(8))"
        let folder = Self.projectFolder(for: worktreePath)
        for root in [hostRoot, profileRoot] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true)
        }
        let hostFile = hostRoot.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("sess-5.jsonl")
        try Data().write(to: hostFile)

        let t = terminal(sessionID: "sess-5", transcriptPath: nil)
        let path = ClaudeTranscriptLocator.filePath(
            terminal: t, worktreePath: worktreePath,
            projectsBase: hostRoot, profileProjectsBase: profileRoot)

        #expect(path == hostFile.path, "path was \(path ?? "nil")")
    }

    /// When no root holds the session's file, the answer is the host-only
    /// lookup's: nil while the host root has no project directory, even when
    /// the profile root has one.
    @Test func noSessionFileAndNoHostProjectDirGivesNil() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let hostRoot = tmp.appendingPathComponent("host-projects", isDirectory: true)
        let profileRoot = tmp.appendingPathComponent("profile-projects", isDirectory: true)
        let worktreePath = "/acme/locator-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(
            at: profileRoot.appendingPathComponent(Self.projectFolder(for: worktreePath), isDirectory: true),
            withIntermediateDirectories: true)

        let t = terminal(sessionID: "sess-6", transcriptPath: nil)
        let path = ClaudeTranscriptLocator.filePath(
            terminal: t, worktreePath: worktreePath,
            projectsBase: hostRoot, profileProjectsBase: profileRoot)

        #expect(path == nil, "path was \(path ?? "nil")")
    }

    /// A profile's `projects/` is usually a symlink into the host store, so
    /// the two roots are one, and the answer is the host root's path even
    /// when the session file can be reached through the profile root too.
    @Test func aProfileRootLinkedToTheHostRootGivesTheHostPath() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let hostRoot = tmp.appendingPathComponent("host-projects", isDirectory: true)
        let profileRoot = tmp.appendingPathComponent("profile-projects", isDirectory: true)
        let worktreePath = "/acme/locator-\(UUID().uuidString.prefix(8))"
        let folder = Self.projectFolder(for: worktreePath)
        let projectDir = hostRoot.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let hostFile = projectDir.appendingPathComponent("sess-7.jsonl")
        try Data().write(to: hostFile)
        try FileManager.default.createSymbolicLink(at: profileRoot, withDestinationURL: hostRoot)

        let t = terminal(sessionID: "sess-7", transcriptPath: nil)
        let path = ClaudeTranscriptLocator.filePath(
            terminal: t, worktreePath: worktreePath,
            projectsBase: hostRoot, profileProjectsBase: profileRoot)

        #expect(path == hostFile.path, "path was \(path ?? "nil")")
    }

    /// The stored path still wins over a profile root.
    @Test func aStoredPathWinsOverAProfileRoot() {
        let t = terminal(sessionID: "sess-1", transcriptPath: "/acme/stored/sess-1.jsonl")
        let path = ClaudeTranscriptLocator.filePath(
            terminal: t, worktreePath: "/acme/wt",
            profileProjectsBase: URL(fileURLWithPath: "/acme/profile/projects", isDirectory: true))
        #expect(path == "/acme/stored/sess-1.jsonl")
    }

    /// The tier-1 folder `ClaudeProjectDirectory` checks first: `/` and `.`
    /// become `-`.
    private static func projectFolder(for worktreePath: String) -> String {
        worktreePath.map { "/.".contains($0) ? "-" : String($0) }.joined()
    }
}
