import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "gc")

/// Enumerates and gates the hosted supervision desks recorded in
/// `~/tbd/supervision/desks.json`, so an orphaned one is reclaimed rather than
/// leaking a scratch space forever.
///
/// **Why this exists** (repo `CLAUDE.md`, "Every durable external resource needs
/// a named reconciler"). A hosted desk is a scratch worktree plus a spawned
/// process, created before either can be recorded — `SupervisionDeskManager`
/// makes the directory, makes the row, spawns the session, and only then writes
/// `desks.json`. A crash, a cancellation, or a failed spawn anywhere in that
/// sequence leaves a resource nobody owns, and `OrphanGC`'s existing legs do not
/// cover it: the agent-worktree leg iterates `db.repos.list()` and so only sees
/// repo-backed worktrees, while the archived legs only touch rows that are
/// already `.archived`. A live desk is therefore never at risk from those legs,
/// which is right — and an orphaned one was reclaimed by nothing, which is what
/// this closes.
///
/// **Every failure direction is toward keeping.** A read that does not answer,
/// a row that cannot be fetched, a path that does not look like a desk's: all
/// keep. Reclaiming a desk archives a worktree and drops a record; leaving one
/// costs a directory until the next sweep.
///
/// **The decision is liveness, and only liveness.** Three triggers were
/// considered — the terminal row gone, the tmux window gone, and the project no
/// longer resolving — and the first two are the same fact from two angles,
/// while the third turned out to change no outcome. A desk whose project stopped
/// resolving but whose session is *running* must not be reclaimed: killing a
/// live agent is exactly what the doctrine forbids, and closing that project's
/// coverage is the supervision path's job (design §9's recycle), never a
/// sweep's. Once the desk is not live, it is reclaimed regardless of whether the
/// project still resolves — so adding the project check would gate nothing and
/// would need a second reader of `supervision.json`.
public struct SupervisionDeskCollector: Sendable {
    let desks: SupervisionDesksStore
    /// Where a desk's scratch space is allowed to live. A recorded worktree
    /// outside it is not something this sweep will touch.
    let scratchBase: URL
    let now: @Sendable () -> Date

    public init(desks: SupervisionDesksStore, scratchBase: URL,
                now: @Sendable @escaping () -> Date) {
        self.desks = desks
        self.scratchBase = scratchBase
        self.now = now
    }

    /// One recorded desk, as the sweep sees it.
    public struct Candidate: Sendable, Equatable {
        public let project: String
        public let entry: SupervisionDeskEntry
    }

    /// What the sweep should do with one candidate. `keep` carries the reason
    /// so the plan line says which gate held.
    public enum Decision: Sendable, Equatable {
        case keep(String)
        case reap(String)
    }

    /// The recorded desks, ordered by project so a plan is stable to diff.
    ///
    /// An unreadable or malformed record yields no candidates rather than an
    /// error: the sweep must not reclaim anything on the strength of a file it
    /// could not read.
    public func candidates() -> [Candidate] {
        let file: SupervisionDesksFile
        do {
            file = try desks.load()
        } catch {
            logger.warning("""
            gc: supervision-desk phase skipped — \(self.desks.fileURL.path, privacy: .public) \
            could not be read: \(String(describing: error), privacy: .public)
            """)
            return []
        }
        return file.desks
            .sorted { $0.key < $1.key }
            .map { Candidate(project: $0.key, entry: $0.value) }
    }

    /// Gate one candidate.
    ///
    /// - Parameters:
    ///   - terminalExists: whether the desk's terminal row is still in the
    ///     database. Nil means the read failed, which keeps.
    ///   - worktree: the desk's worktree row, or nil when it is gone.
    ///   - liveCWDs: the sweep's single `lsof` pass, already canonicalized —
    ///     the same evidence `AgentWorktreeCollector` gates on. A process
    ///     sitting in the desk's directory is the desk running.
    ///   - graceSeconds: a desk spawned moments ago may not have shown up in
    ///     the `lsof` pass yet, so a young record is kept regardless.
    public func decide(
        _ candidate: Candidate, terminalExists: Bool?, worktree: Worktree?,
        liveCWDs: [String], graceSeconds: Int
    ) -> Decision {
        let age = now().timeIntervalSince(candidate.entry.spawnedAt.date)
        if age < Double(graceSeconds) {
            return .keep("desk-within-grace")
        }
        guard let terminalExists else { return .keep("desk-row-read-failed") }

        guard let worktree else {
            // The row is gone, so there is nothing to archive and nothing on
            // disk this sweep can attribute. Drop the record only.
            return .reap("desk-worktree-row-gone")
        }
        // Only a scratch space under the scratch base is a desk's, and only
        // those are this leg's to touch. Anything else in the record is either
        // an older layout or a hand edit, and reclaiming it would be acting on
        // a resource this sweep does not own.
        guard worktree.repoID == nil,
              LocalWorktree(worktree)?.path.hasPrefix(scratchBase.path + "/") == true else {
            return .keep("desk-not-a-scratch-space")
        }
        guard worktree.status == .active else { return .keep("desk-already-archived") }

        let canonical = AgentWorktreeCollector.canon(worktree.localPath)
        if liveCWDs.contains(canonical) {
            // A process is sitting in the desk's directory. **Never reclaim a
            // live desk**, whatever its terminal row or its project says.
            return .keep("desk-live")
        }
        guard terminalExists else { return .reap("desk-terminal-row-gone") }
        return .reap("desk-process-gone")
    }

    /// Drop one project's entry from the record.
    ///
    /// Read-modify-write per reap rather than once per sweep: `desks.json` is
    /// also written by `SupervisionDeskManager` when a project is turned on, and
    /// a whole-file rewrite computed at the top of a sweep would clobber a desk
    /// spawned while the sweep ran. Returns whether the record changed.
    @discardableResult
    public func forget(project: String) -> Bool {
        do {
            let file = try desks.load()
            let updated = file.forgetting(project)
            guard updated != file else { return false }
            try desks.save(updated)
            return true
        } catch {
            logger.warning("""
            gc: could not drop the desk record for \(project, privacy: .public): \
            \(String(describing: error), privacy: .public)
            """)
            return false
        }
    }
}
