import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "mock")

/// Seeds an in-memory (or isolated) `TBDDatabase` from a `MockScenario`.
///
/// Called during daemon startup when `TBD_MOCK=1` is set, before the RPC
/// server opens, so every subsequent client request sees fully-populated data
/// without any reconciliation passes touching the filesystem.
public struct MockSeeder: Sendable {
    public init() {}

    /// Materialize `scenario` into `db`.
    ///
    /// - Parameters:
    ///   - scenario: The decoded fixture document.
    ///   - db: Destination database. Should be an isolated or in-memory instance.
    ///   - fixtureDirectory: Base directory used to resolve `transcriptFixture`
    ///     filenames. Transcript paths are built as
    ///     `fixtureDirectory/transcripts/<fixtureName>`.
    public func seed(
        scenario: MockScenario,
        into db: TBDDatabase,
        fixtureDirectory: URL
    ) async throws {
        for repoSeed in scenario.repos {
            try await seedRepo(repoSeed, into: db, fixtureDirectory: fixtureDirectory)
        }
        logger.debug("MockSeeder: seeded \(scenario.repos.count, privacy: .public) repo(s)")
    }

    // MARK: - Private

    private func seedRepo(
        _ repoSeed: MockScenario.RepoSeed,
        into db: TBDDatabase,
        fixtureDirectory: URL
    ) async throws {
        let repo = try await db.repos.create(
            path: repoSeed.path,
            displayName: repoSeed.displayName,
            defaultBranch: repoSeed.defaultBranch ?? "main"
        )
        logger.debug("MockSeeder: created repo '\(repo.displayName, privacy: .public)'")

        let tmuxServer = TmuxManager.serverName(forRepoPath: repoSeed.path)
        // Maps worktree name → id so parentName references can be resolved.
        var nameToID: [String: UUID] = [:]

        for (wtIdx, wtSeed) in repoSeed.worktrees.enumerated() {
            let parentID = wtSeed.parentName.flatMap { nameToID[$0] }
            let suffix = wtSeed.pathSuffix ?? wtSeed.name
            let path = "\(repoSeed.path)/.tbd/worktrees/\(suffix)"
            let status = wtSeed.status ?? .active

            let wt = try await db.worktrees.create(
                repoID: repo.id,
                name: wtSeed.name,
                displayName: wtSeed.displayName,
                branch: wtSeed.branch,
                path: path,
                tmuxServer: tmuxServer,
                status: status,
                parentWorktreeID: parentID
            )
            nameToID[wtSeed.name] = wt.id
            logger.debug("MockSeeder: created worktree '\(wt.name, privacy: .public)' [idx=\(wtIdx, privacy: .public)]")

            if let conflicts = wtSeed.hasConflicts, conflicts {
                try await db.worktrees.updateHasConflicts(id: wt.id, hasConflicts: true)
            }
            if let pr = wtSeed.prStatus {
                try await db.worktrees.setPRStatus(id: wt.id, status: pr)
            }
            if let aam = wtSeed.autoArchiveOnMerge {
                try await db.worktrees.setAutoArchiveOnMerge(id: wt.id, value: aam)
            }

            for (termIdx, tSeed) in (wtSeed.terminals ?? []).enumerated() {
                try await seedTerminal(
                    tSeed,
                    worktreeID: wt.id,
                    index: wtIdx * 100 + termIdx,
                    into: db,
                    fixtureDirectory: fixtureDirectory
                )
            }
        }
    }

    private func seedTerminal(
        _ tSeed: MockScenario.TerminalSeed,
        worktreeID: UUID,
        index: Int,
        into db: TBDDatabase,
        fixtureDirectory: URL
    ) async throws {
        let terminal = try await db.terminals.create(
            worktreeID: worktreeID,
            tmuxWindowID: "mock-w-\(index)",
            tmuxPaneID: "mock-p-\(index)",
            label: tSeed.label,
            claudeSessionID: tSeed.claudeSessionID,
            kind: tSeed.kind
        )

        if let state = tSeed.activityState {
            try await db.terminals.setActivityState(id: terminal.id, activityState: state)
        }

        if let fixture = tSeed.transcriptFixture {
            let transcriptPath = fixtureDirectory
                .appendingPathComponent("transcripts")
                .appendingPathComponent(fixture)
                .path
            let sessionID = tSeed.claudeSessionID ?? "mock-session-\(terminal.id.uuidString)"
            try await db.terminals.updateSession(
                id: terminal.id,
                sessionID: sessionID,
                transcriptPath: transcriptPath
            )
        }

        if tSeed.suspended == true {
            let sessionID = tSeed.claudeSessionID ?? "mock-session-\(terminal.id.uuidString)"
            try await db.terminals.setSuspended(id: terminal.id, sessionID: sessionID)
        }

        logger.debug("MockSeeder: created terminal kind=\(tSeed.kind?.rawValue ?? "nil", privacy: .public) for worktree \(worktreeID, privacy: .public)")
    }
}
