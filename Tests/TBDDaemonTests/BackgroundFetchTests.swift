import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib

/// The periodic fetch must stay quiet for a local-only repo (no `origin`) yet
/// still report a real failure when `origin` exists.
struct BackgroundFetchTests {
    let tempDir: URL
    let repoDir: URL
    let remoteDir: URL
    let git = GitManager()

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-bgfetch-test-\(UUID().uuidString)")
        repoDir = tempDir.appendingPathComponent("repo")
        remoteDir = tempDir.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func initRepo() async throws {
        try await shell("git init -b main && git commit --allow-empty -m 'init'", at: repoDir)
    }

    @Test func noRemotesIsSkippedNoOrigin() async throws {
        defer { cleanup() }
        try await initRepo()
        let outcome = await Daemon.backgroundFetch(repoPath: repoDir.path, branch: "main", git: git)
        guard case .skippedNoOrigin = outcome else {
            Issue.record("expected .skippedNoOrigin, got \(outcome)")
            return
        }
    }

    @Test func reachableOriginIsFetched() async throws {
        defer { cleanup() }
        try await shell("git init --bare -b main", at: remoteDir)
        try await initRepo()
        try await shell("git remote add origin '\(remoteDir.path)' && git push -u origin main", at: repoDir)
        let outcome = await Daemon.backgroundFetch(repoPath: repoDir.path, branch: "main", git: git)
        guard case .fetched = outcome else {
            Issue.record("expected .fetched, got \(outcome)")
            return
        }
    }

    @Test func unreachableOriginIsFailed() async throws {
        defer { cleanup() }
        try await initRepo()
        let missing = tempDir.appendingPathComponent("does-not-exist.git").path
        try await shell("git remote add origin '\(missing)'", at: repoDir)
        let outcome = await Daemon.backgroundFetch(repoPath: repoDir.path, branch: "main", git: git)
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
    }

    @Test func remoteNamesIsEmptyWithoutRemotes() async throws {
        defer { cleanup() }
        try await initRepo()
        let names = try await git.remoteNames(repoPath: repoDir.path)
        #expect(names.isEmpty)
    }

    @Test func remoteNamesListsOrigin() async throws {
        defer { cleanup() }
        try await initRepo()
        try await shell("git remote add origin '\(remoteDir.path)'", at: repoDir)
        let names = try await git.remoteNames(repoPath: repoDir.path)
        #expect(names.contains("origin"))
    }

    @Test func remoteNamesThrowsOutsideARepo() async throws {
        defer { cleanup() }
        let plain = tempDir.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) {
            _ = try await git.remoteNames(repoPath: plain.path)
        }
    }
}
