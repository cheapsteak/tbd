import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "worktreeLifecycle")

extension WorktreeLifecycle {
    public func reviveConversationOnFreshBranch(
        archivedWorktreeID: UUID,
        sessionID: String,
        cols: Int? = nil,
        rows: Int? = nil,
        date: Date = Date()
    ) async throws -> (
        completion: WorktreeCreateCompletion,
        result: WorktreeReviveConversationFreshResult
    ) {
        guard let archived = try await db.worktrees.get(id: archivedWorktreeID) else {
            throw WorktreeLifecycleError.worktreeNotFound(archivedWorktreeID)
        }
        guard archived.status == .archived else {
            throw WorktreeLifecycleError.worktreeNotArchived(archivedWorktreeID)
        }
        guard let repoID = archived.repoID,
              let repo = try await db.repos.get(id: repoID) else {
            throw WorktreeLifecycleError.invalidOperation(
                "Cannot revive a conversation on a fresh branch without a repository."
            )
        }
        // Validate against the SAME projects root the spawn will sync from.
        // `spawnPrimaryTerminals` resolves the worktree's model profile and
        // syncs under that profile's config dir; validating against the
        // ambient root instead proved nothing — a session present ambiently
        // but absent from the profile root passed here and then failed inside
        // Claude with "No conversation found with session ID". Profile
        // resolution failures fall back to nil (ambient), matching the spawn.
        var resolvedProfile: ResolvedModelProfile?
        if let resolver = modelProfileResolver {
            do {
                resolvedProfile = try await resolver.resolve(repoID: repo.id, override: nil)
            } catch {
                logger.warning(
                    "fresh revive: model profile resolution failed; validating against the ambient projects root")
                resolvedProfile = nil
            }
        }
        let projectsRoot = claudeProjectsRoot(
            profileConfigDirPath: ClaudeProfileConfigDirManager.resolveConfigDir(
                for: resolvedProfile)
        )
        guard TranscriptProjectDirSync.locateSessionTranscript(
            sessionID: sessionID,
            projectsRoot: projectsRoot
        ) != nil else {
            throw WorktreeLifecycleError.invalidOperation(
                "Cannot revive conversation: no transcript found for session \(sessionID)."
            )
        }

        var fetchWarning: Error?
        do {
            try await git.fetch(
                repoPath: repo.path,
                branch: repo.defaultBranch,
                timeout: .seconds(15)
            )
        } catch {
            fetchWarning = error
        }

        let remote = "origin/\(repo.defaultBranch)"
        let baseRef = await git.refExists(repoPath: repo.path, ref: remote)
            ? remote
            : repo.defaultBranch
        let baseSHA = try await git.headSHA(repoPath: repo.path, ref: baseRef)
        let baseDate = try await git.commitDate(repoPath: repo.path, ref: baseRef)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        let archivedDate = formatter.string(
            from: archived.archivedAt ?? archived.createdAt
        )
        let operationDate = formatter.string(from: date)
        let baseCommitDate = formatter.string(from: baseDate)
        let abbreviatedBaseSHA = String(baseSHA.prefix(7))
        let abbreviatedArchivedSHA = archived.archivedHeadSHA.map {
            String($0.prefix(7))
        } ?? "unknown"

        let pending = try await beginCreateWorktree(
            repoID: repo.id,
            displayName: "\(archived.displayName) (revived)"
        )
        // No context prompt is built or sent: the revived session opens idle at
        // the composer. The Notes seed below is the sole provenance surface.
        let notesSeed = """
        # Revived conversation

        Forked from **\(archived.displayName)** on \(operationDate).

        | | |
        | --- | --- |
        | Original branch | `\(archived.branch)` @ `\(abbreviatedArchivedSHA)` (archived \(archivedDate)) |
        | This branch | `\(pending.branch)` |
        | Branched from | `\(baseRef)` @ `\(abbreviatedBaseSHA)` (\(baseCommitDate)) |
        | Source session | `\(sessionID)` |

        """
        let carryover = ConversationCarryover(
            sourceSessionID: sessionID,
            notesSeed: notesSeed
        )
        let completion = try await completeCreateWorktree(
            worktreeID: pending.id,
            cols: cols,
            rows: rows,
            carryover: carryover,
            retryGeneratedNameOnCollision: false
        )
        guard let created = try await db.worktrees.get(id: pending.id) else {
            throw WorktreeLifecycleError.worktreeNotFound(pending.id)
        }

        let warning: String?
        if let fetchWarning {
            let ageDays = max(
                0,
                Int(date.timeIntervalSince(baseDate) / (24 * 60 * 60))
            )
            let age = ageDays == 1 ? "1 day old" : "\(ageDays) days old"
            warning = """
            Worktree creation succeeded, but fetching origin failed: \(String(describing: fetchWarning)). The selected base \(baseRef) at \(abbreviatedBaseSHA) (committed \(baseCommitDate), \(age)) may be stale.
            """
        } else {
            warning = nil
        }

        return (
            completion: completion,
            result: WorktreeReviveConversationFreshResult(
                worktree: created,
                warning: warning
            )
        )
    }
}
