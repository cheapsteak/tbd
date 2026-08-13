import Foundation
import TBDShared
import os

private let adoptionLogger = Logger(subsystem: "com.tbd.daemon", category: "remote.adoption")

/// Mints the `worktree` row for a sighted provider session.
///
/// The `remote_session` mirror and the `worktree` table have two different
/// owners: the mirror holds provider-owned liveness, the worktree row holds
/// TBD-owned policy (parent edge, sort order, display name, status). Adoption
/// is policy, so it lives here rather than inside `RemoteSessionStore` — the
/// mirror keeps its current job unchanged and this type reads the association
/// it pinned.
///
/// One rule governs existence: **a worktree row exists exactly when the
/// session resolves to a registered repo.** A session matching no repo gets no
/// row and appears only in the Provider Desk. Because the mirror re-attempts
/// resolution on later polls while its pin is still null, a session the user
/// could not match on Monday is adopted the moment they register its repo —
/// adoption therefore runs on every convergence, not only on first sighting.
///
/// The row is created once and never re-derived. A session that already owns a
/// row is skipped whole: adoption never reparents it, renames it, or rewrites
/// its branch on a later poll, because those are the user's to change.
struct RemoteSessionAdopter: Sendable {
    /// The session's own worktree UUID, echoed back by a provider that
    /// received it on `create`'s stdin and exported it into the session as
    /// `TBD_WORKTREE_ID`.
    static let worktreeIDMetaKey = "tbd_worktree_id"
    /// The worktree that spawned this session, stamped by whoever created it.
    static let parentWorktreeIDMetaKey = "tbd_parent_worktree_id"
    /// Well-known, and optional: a provider that reports no branch yields a
    /// row with an empty branch rather than no row at all.
    static let branchMetaKey = "branch"

    private let db: TBDDatabase

    init(db: TBDDatabase) {
        self.db = db
    }

    /// Adopt every session in a full snapshot. Returns the rows created, which
    /// is empty on the overwhelmingly common poll where every sighted session
    /// already owns one.
    ///
    /// The mirror is read once for the whole provider rather than once per
    /// session: the pin is what adoption needs from it, and a snapshot has
    /// already written every pin it is going to write.
    func adopt(sessions: [RemoteSessionPayload], provider: String) async -> [Worktree] {
        guard !sessions.isEmpty else { return [] }
        let mirrorRows: [RemoteSessionRow]
        do {
            mirrorRows = try await db.remoteSessions.rows(provider: provider)
        } catch {
            adoptionLogger.error(
                "adoption skipped for \(provider, privacy: .public): mirror unreadable: \(String(describing: error), privacy: .public)"
            )
            return []
        }
        let pinByID = Dictionary(
            mirrorRows.map { ($0.sessionID, $0.resolvedRepoIDUUID) }, uniquingKeysWith: { first, _ in first })

        var created: [Worktree] = []
        for session in sessions {
            guard let repoID = pinByID[session.id] ?? nil else { continue }
            if let row = await adoptOne(session: session, provider: provider, repoID: repoID) {
                created.append(row)
            }
        }
        return created
    }

    /// Adopt one session sighted on the events stream. Same rules as the
    /// snapshot path — the events path is a convergence point too, and a
    /// session that first resolves there must not have to wait for the next
    /// full poll to get its row.
    func adopt(session: RemoteSessionPayload, provider: String) async -> Worktree? {
        let mirrorRow: RemoteSessionRow?
        do {
            mirrorRow = try await db.remoteSessions.row(provider: provider, sessionID: session.id)
        } catch {
            adoptionLogger.error(
                "adoption skipped for \(provider, privacy: .public)/\(session.id, privacy: .public): mirror unreadable: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
        guard let repoID = mirrorRow?.resolvedRepoIDUUID else { return nil }
        return await adoptOne(session: session, provider: provider, repoID: repoID)
    }

    // MARK: - One session

    private func adoptOne(
        session: RemoteSessionPayload, provider: String, repoID: UUID
    ) async -> Worktree? {
        do {
            // Created once, never re-derived: an existing binding ends
            // adoption for this session, whatever the payload now says.
            if try await db.worktrees.findRemote(provider: provider, sessionID: session.id) != nil {
                return nil
            }
            // The pin outlives the repo it names — nothing clears it when a
            // repo is unregistered. Inserting against a dangling repoID would
            // trip the foreign key on every poll forever, so check first and
            // let the session fall back to being Provider-Desk-only.
            guard try await db.repos.get(id: repoID) != nil else {
                adoptionLogger.debug(
                    "not adopting \(provider, privacy: .public)/\(session.id, privacy: .public): pinned repo \(repoID.uuidString, privacy: .public) is no longer registered"
                )
                return nil
            }

            let id = try await resolveRowID(session: session, provider: provider)
            let parentWorktreeID = try await resolveParentID(session: session, provider: provider)
            let created = try await db.worktrees.createRemote(
                id: id,
                repoID: repoID,
                name: Self.rowName(provider: provider, sessionID: session.id),
                displayName: Self.displayName(session: session),
                branch: session.meta?[Self.branchMetaKey] ?? "",
                provider: provider,
                sessionID: session.id,
                parentWorktreeID: parentWorktreeID)
            adoptionLogger.debug(
                "adopted \(provider, privacy: .public)/\(session.id, privacy: .public) as worktree \(created.id.uuidString, privacy: .public) in repo \(repoID.uuidString, privacy: .public)"
            )
            return created
        } catch {
            adoptionLogger.error(
                "adoption failed for \(provider, privacy: .public)/\(session.id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// The id the new row gets: the session's echoed `tbd_worktree_id` when it
    /// is usable, a fresh UUID otherwise.
    ///
    /// The echo is what makes the binding self-healing. If TBD created the
    /// session but lost the row before writing it, the box is already
    /// exporting a `TBD_WORKTREE_ID` that resolves to nothing; recreating the
    /// row under that same id makes the variable good again rather than
    /// stranding it.
    ///
    /// An echo naming a row that exists but is NOT this session is ignored: a
    /// fresh UUID is minted and the existing row is left exactly as it is.
    /// Rebinding it would be worse than a dangling variable — the id could
    /// name a local worktree or another provider's lane, and a session cannot
    /// be allowed to take over a row by claiming its id.
    private func resolveRowID(session: RemoteSessionPayload, provider: String) async throws -> UUID {
        guard let raw = session.meta?[Self.worktreeIDMetaKey] else { return UUID() }
        guard let echoed = UUID(uuidString: raw) else {
            adoptionLogger.warning(
                "\(provider, privacy: .public)/\(session.id, privacy: .public) echoed an unparseable \(Self.worktreeIDMetaKey, privacy: .public)=\(raw, privacy: .public); minting a fresh worktree id"
            )
            return UUID()
        }
        // Reaching here means no row is bound to this session (the caller
        // already checked), so any row under the echoed id belongs to
        // something else.
        if try await db.worktrees.get(id: echoed) != nil {
            adoptionLogger.warning(
                "\(provider, privacy: .public)/\(session.id, privacy: .public) echoed \(Self.worktreeIDMetaKey, privacy: .public)=\(raw, privacy: .public), which names an existing unrelated worktree; ignoring the echo and minting a fresh worktree id"
            )
            return UUID()
        }
        return echoed
    }

    /// The parent edge from `tbd_parent_worktree_id`, or nil for a top-level
    /// row.
    ///
    /// Nil for every degenerate case — absent, unparseable, or naming no row —
    /// because a lane with no known parent belongs at the top of its repo,
    /// where the user can see and reparent it.
    ///
    /// An **archived** parent is treated as unknown for the same reason: the
    /// sidebar never renders an archived row's subtree, so storing that edge
    /// would file a live lane somewhere it cannot be seen. A main-worktree
    /// parent is refused on the same grounds — `WorktreeMoveError.parentIsMain`
    /// already forbids it for local rows, and the main row has no subtree in
    /// the sidebar either.
    private func resolveParentID(session: RemoteSessionPayload, provider: String) async throws -> UUID? {
        guard let raw = session.meta?[Self.parentWorktreeIDMetaKey] else { return nil }
        guard let parentID = UUID(uuidString: raw) else {
            adoptionLogger.debug(
                "\(provider, privacy: .public)/\(session.id, privacy: .public) carries an unparseable \(Self.parentWorktreeIDMetaKey, privacy: .public)=\(raw, privacy: .public); adopting at top level"
            )
            return nil
        }
        guard let parent = try await db.worktrees.get(id: parentID) else {
            adoptionLogger.debug(
                "\(provider, privacy: .public)/\(session.id, privacy: .public) names unknown parent \(raw, privacy: .public); adopting at top level"
            )
            return nil
        }
        guard parent.status != .archived, parent.status != .main else {
            adoptionLogger.debug(
                "\(provider, privacy: .public)/\(session.id, privacy: .public) names \(parent.status.rawValue, privacy: .public) parent \(raw, privacy: .public); adopting at top level"
            )
            return nil
        }
        return parentID
    }

    // MARK: - Row fields

    /// `worktree.name` for an adopted row.
    ///
    /// Nothing generates a name for a session TBD did not create, and the
    /// value has to be collision-free across every session of every provider
    /// in every repo — a name that repeats would make two lanes
    /// indistinguishable in search and in the CLI. The location's own
    /// synthetic URI is exactly that value: `WorktreeLocation.storagePath`
    /// percent-encodes each component, so distinct `(provider, sessionID)`
    /// pairs always yield distinct strings. Reusing it keeps one definition of
    /// "what identifies a remote row" instead of a second escaping scheme free
    /// to drift from the one the UNIQUE path constraint already relies on. It
    /// is also visibly synthetic, so it never reads as a name the user chose.
    static func rowName(provider: String, sessionID: String) -> String {
        WorktreeLocation.remote(provider: provider, sessionID: sessionID).storagePath ?? sessionID
    }

    /// What the sidebar shows. The provider's title when it has one; the
    /// session id otherwise, which is short and stable, rather than the
    /// synthetic name.
    static func displayName(session: RemoteSessionPayload) -> String {
        let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty { return title }
        return session.id
    }
}
