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
/// process, and `OrphanGC`'s existing legs cover neither: the agent-worktree leg
/// iterates `db.repos.list()` and so only sees repo-backed worktrees, while the
/// archived legs only touch rows that are already `.archived`. A live desk is
/// therefore never at risk from those legs, which is right — and a desk that
/// died was reclaimed by nothing, which is what this closes.
///
/// **Its subject is a desk that got recorded and then died**, which is the only
/// orphan shape it can see: it enumerates `desks.json`, so a spawn that failed
/// before writing an entry is not here at all. That half is
/// `SupervisionDeskManager`'s own, which archives the scratch row on every
/// failing exit and so hands it to the deletion-queue leg.
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
/// live agent is exactly what the doctrine forbids, and design §9 is explicit
/// that a topology gesture ending a project takes its mark, its mode selection
/// and its supervisor binding — not the desk, because **no coverage gesture
/// disposes a desk**. Once the desk is not live, it is reclaimed regardless of
/// whether the project still resolves — so adding the project check would gate
/// nothing and would need a second reader of `supervision.json`.
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

    /// What the sweep found when it looked a desk's worktree row up.
    ///
    /// **A read that did not answer is not a row that is gone**, and collapsing
    /// the two is how a sweep reaps a live desk on a transient database error.
    /// The terminal read is kept apart the same way, by its `Bool?`.
    public enum WorktreeLookup: Sendable, Equatable {
        case row(Worktree)
        /// The row is genuinely absent — the read answered, with nothing.
        case gone
        /// The read failed. Keeps.
        case unreadable
    }

    /// What `forget` did, which is not always "dropped it".
    public enum ForgetResult: Sendable, Equatable {
        case dropped
        /// The record no longer holds the entry this sweep judged — a spawn for
        /// the same project landed while the sweep ran. Its desk is live and
        /// nobody judged it, so it is left exactly as it is.
        case changed
        case writeFailed
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
    ///   - worktree: what the worktree read answered — a row, a genuine
    ///     absence, or a read that failed.
    ///   - liveCWDs: the sweep's single `lsof` pass, already canonicalized —
    ///     the same evidence `AgentWorktreeCollector` gates on. A process
    ///     sitting in the desk's directory **or anywhere below it** is the desk
    ///     running.
    ///   - graceSeconds: a desk spawned moments ago may not have shown up in
    ///     the `lsof` pass yet, so a young record is kept regardless.
    public func decide(
        _ candidate: Candidate, terminalExists: Bool?, worktree: WorktreeLookup,
        liveCWDs: [String], graceSeconds: Int
    ) -> Decision {
        let age = now().timeIntervalSince(candidate.entry.spawnedAt.date)
        if age < Double(graceSeconds) {
            return .keep("desk-within-grace")
        }
        guard let terminalExists else { return .keep("desk-row-read-failed") }

        let row: Worktree
        switch worktree {
        case .unreadable:
            return .keep("desk-worktree-read-failed")
        case .gone:
            // The row is gone, so there is nothing to archive and nothing on
            // disk this sweep can attribute. Drop the record only.
            return .reap("desk-worktree-row-gone")
        case .row(let found):
            row = found
        }
        // Only a scratch space under the scratch base is a desk's, and only
        // those are this leg's to touch. Anything else in the record is either
        // an older layout or a hand edit, and reclaiming it would be acting on
        // a resource this sweep does not own.
        guard row.repoID == nil,
              LocalWorktree(row)?.path.hasPrefix(scratchBase.path + "/") == true else {
            return .keep("desk-not-a-scratch-space")
        }
        guard row.status == .active else { return .keep("desk-already-archived") }

        let canonical = AgentWorktreeCollector.canon(row.localPath)
        // The shared prefix-boundary match, not equality: an agent's own shell
        // sits in a subdirectory as often as in the root, and equality would
        // read that as "nothing is running here" and archive a live desk.
        if AgentWorktreeCollector.liveCWDsContain(liveCWDs, path: canonical) {
            // A process is sitting in the desk's directory. **Never reclaim a
            // live desk**, whatever its terminal row or its project says.
            return .keep("desk-live")
        }
        guard terminalExists else { return .reap("desk-terminal-row-gone") }
        return .reap("desk-process-gone")
    }

    /// Drop from the record the exact entry this sweep judged.
    ///
    /// Read-modify-write per reap rather than once per sweep: `desks.json` is
    /// also written by `SupervisionDeskManager` when a project is turned on, and
    /// a whole-file rewrite computed at the top of a sweep would clobber a desk
    /// spawned while the sweep ran.
    ///
    /// **Re-reading is not enough on its own** — the entry has to match too. A
    /// spawn for *this* project landing between `candidates()` and this write
    /// leaves a different entry under the same key, and dropping it would
    /// unrecord a desk that is live and that nothing judged. That is the same
    /// resurrection hazard `SupervisionDeskManager` guards on its side, from
    /// the other end.
    @discardableResult
    public func forget(project: String, expecting entry: SupervisionDeskEntry) -> ForgetResult {
        do {
            let file = try desks.load()
            guard file.desk(for: project) == entry else {
                logger.notice("""
                gc: the desk record for \(project, privacy: .public) changed while the sweep ran; \
                leaving it alone
                """)
                return .changed
            }
            try desks.save(file.forgetting(project))
            return .dropped
        } catch {
            logger.warning("""
            gc: could not drop the desk record for \(project, privacy: .public): \
            \(String(describing: error), privacy: .public)
            """)
            return .writeFailed
        }
    }
}
