import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "mock")

/// Wraps a lower-level failure with the identity of the fixture item that
/// triggered it, so a partial-seed abort names the exact repo/worktree/terminal
/// the operator needs to fix — instead of a bare GRDB constraint error.
public struct MockSeedError: LocalizedError, CustomStringConvertible {
    /// Human-readable identifier, e.g. `repo 'acme'`,
    /// `worktree 'feature-x' in repo 'acme'`, `terminal[2] in worktree 'feature-x'`.
    public let item: String
    public let underlying: Error
    public var description: String { "Mock seeding failed for \(item): \(underlying)" }

    public var errorDescription: String? { description }
}

/// A worktree's `parentName` referenced a name not seeded earlier in the same repo.
///
/// `parentName` must name a worktree listed EARLIER in the same repo's array
/// (see `WorktreeSeed.parentName`). A typo, wrong case, or forward-reference
/// leaves it unresolvable — surfaced here rather than silently dropped.
private struct UnresolvedParentError: LocalizedError, CustomStringConvertible {
    let parentName: String
    var description: String {
        "parentName '\(parentName)' does not match any worktree seeded earlier in this repo"
    }

    var errorDescription: String? { description }
}

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

    /// Run `body`, re-throwing any failure wrapped in a `MockSeedError` tagged
    /// with `item`. Already-wrapped errors pass through unchanged so the
    /// innermost (most specific) `item` context wins.
    private func wrap<T>(_ item: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as MockSeedError {
            throw error
        } catch {
            throw MockSeedError(item: item, underlying: error)
        }
    }

    private func seedRepo(
        _ repoSeed: MockScenario.RepoSeed,
        into db: TBDDatabase,
        fixtureDirectory: URL
    ) async throws {
        let repo = try await wrap("repo '\(repoSeed.displayName)'") {
            try await db.repos.create(
                path: repoSeed.path,
                displayName: repoSeed.displayName,
                defaultBranch: repoSeed.defaultBranch ?? "main"
            )
        }
        logger.debug("MockSeeder: created repo '\(repo.displayName, privacy: .public)'")

        let tmuxServer = TmuxManager.serverName(forRepoPath: repoSeed.path)
        // Maps worktree name → id so parentName references can be resolved.
        var nameToID: [String: UUID] = [:]

        for (wtIdx, wtSeed) in repoSeed.worktrees.enumerated() {
            let suffix = wtSeed.pathSuffix ?? wtSeed.name
            let path = "\(repoSeed.path)/.tbd/worktrees/\(suffix)"
            let status = wtSeed.status ?? .active
            let wtItem = "worktree '\(wtSeed.name)' in repo '\(repoSeed.displayName)'"

            // A `parentName` that never resolves would silently produce a root
            // row instead of a child — a wrong scenario. Fail loud instead.
            let parentID: UUID?
            if let parentName = wtSeed.parentName {
                guard let resolved = nameToID[parentName] else {
                    throw MockSeedError(item: wtItem, underlying: UnresolvedParentError(parentName: parentName))
                }
                parentID = resolved
            } else {
                parentID = nil
            }

            let wt = try await wrap(wtItem) {
                try await db.worktrees.create(
                    repoID: repo.id,
                    name: wtSeed.name,
                    displayName: wtSeed.displayName,
                    branch: wtSeed.branch,
                    path: path,
                    tmuxServer: tmuxServer,
                    status: status,
                    parentWorktreeID: parentID
                )
            }
            nameToID[wtSeed.name] = wt.id
            logger.debug("MockSeeder: created worktree '\(wt.name, privacy: .public)' [idx=\(wtIdx, privacy: .public)]")

            try await wrap(wtItem) {
                if let conflicts = wtSeed.hasConflicts, conflicts {
                    try await db.worktrees.updateHasConflicts(id: wt.id, hasConflicts: true)
                }
                if let pr = wtSeed.prStatus {
                    try await db.worktrees.setPRStatus(id: wt.id, status: pr)
                }
                if let aam = wtSeed.autoArchiveOnMerge {
                    try await db.worktrees.setAutoArchiveOnMerge(id: wt.id, value: aam)
                }
                if let ahm = wtSeed.autoHibernateOnMerge {
                    try await db.worktrees.setAutoHibernateOnMerge(id: wt.id, value: ahm)
                }
            }

            for (termIdx, tSeed) in (wtSeed.terminals ?? []).enumerated() {
                try await seedTerminal(
                    tSeed,
                    worktreeID: wt.id,
                    worktreeName: wtSeed.name,
                    terminalIndex: termIdx,
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
        worktreeName: String,
        terminalIndex: Int,
        index: Int,
        into db: TBDDatabase,
        fixtureDirectory: URL
    ) async throws {
        let item = "terminal[\(terminalIndex)] in worktree '\(worktreeName)'"
        try await wrap(item) {
            let terminal = try await db.terminals.create(
                worktreeID: worktreeID,
                tmuxWindowID: "mock-w-\(index)",
                tmuxPaneID: "mock-p-\(index)",
                label: tSeed.label,
                claudeSessionID: tSeed.claudeSessionID,
                kind: tSeed.kind
            )

            if let state = tSeed.activityState {
                // Mock fixtures are composed by TBD, not observed from any
                // machine interface — `.derived` is the honest source, and the
                // seeded row carries it like every other.
                try await db.terminals.setActivityState(
                    id: terminal.id, activityState: state, source: .derived)
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
}
