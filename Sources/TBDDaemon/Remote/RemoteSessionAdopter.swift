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
/// The row is created once and never re-derived: adoption never renames a row
/// it already made, never rewrites its branch, and never moves a row that has a
/// parent, because identity and tree position are the user's from that point
/// on. One edge is not a re-derivation and is therefore permitted — a row
/// adoption has never placed taking its first parent from a later sighting.
/// Nothing is overwritten there; a fact that was not knowable at adoption time
/// became knowable, and refusing it would strand the lane at top level forever.
/// "Never placed" is a recorded fact (`Worktree.remoteParentAssigned`) rather
/// than the current nil, because a lane the user un-nested reads as nil too and
/// filing it again would revert the gesture.
///
/// Where the parent comes from is normally the provider's stamp,
/// `meta["tbd_parent_worktree_id"]`. A TBD-initiated create is the exception:
/// `remote.create` carries the worktree whose nested `+` was clicked, and that
/// override is applied here instead. It is deliberately not a contract field —
/// nothing new reaches the provider's stdin — because the parent edge is TBD's
/// own policy and a round trip through the provider could only lose or
/// contradict it.
struct RemoteSessionAdopter: Sendable {
    /// What one adoption pass changed.
    ///
    /// Two lists, kept apart deliberately: a row that took its first parent is
    /// not a new lane, and a caller that folded it into `created` would
    /// announce a lane the user has been looking at for days.
    struct Outcome: Sendable {
        var created: [Worktree] = []
        var nested: [Nesting] = []
    }

    /// A row that took its first parent, with the position it landed in.
    struct Nesting: Sendable {
        let worktreeID: UUID
        let parentID: UUID
        let sortOrder: Int
    }

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

    /// Adopt every session in a full snapshot. Returns what changed, which is
    /// nothing on the overwhelmingly common poll where every sighted session
    /// already owns a row that is already where it belongs.
    ///
    /// The mirror is read once for the whole provider rather than once per
    /// session: the pin is what adoption needs from it, and a snapshot has
    /// already written every pin it is going to write.
    func adopt(sessions: [RemoteSessionPayload], provider: String) async -> Outcome {
        guard !sessions.isEmpty else { return Outcome() }
        let mirrorRows: [RemoteSessionRow]
        do {
            mirrorRows = try await db.remoteSessions.rows(provider: provider)
        } catch {
            adoptionLogger.error(
                "adoption skipped for \(provider, privacy: .public): mirror unreadable: \(String(describing: error), privacy: .public)"
            )
            return Outcome()
        }
        let pinByID = Dictionary(
            mirrorRows.map { ($0.sessionID, $0.resolvedRepoIDUUID) }, uniquingKeysWith: { first, _ in first })

        var outcome = Outcome()
        for session in sessions {
            guard let repoID = pinByID[session.id] ?? nil else { continue }
            let one = await adoptOne(session: session, provider: provider, repoID: repoID)
            outcome.created.append(contentsOf: one.created)
            outcome.nested.append(contentsOf: one.nested)
        }
        return outcome
    }

    /// Adopt one session sighted on the events stream. Same rules as the
    /// snapshot path — the events path is a convergence point too, and a
    /// session that first resolves there must not have to wait for the next
    /// full poll to get its row.
    ///
    /// `parentOverride` is where the user clicked, when this sighting is the
    /// direct result of a TBD-initiated create (`remote.create` from a nested
    /// `+`). It beats `meta["tbd_parent_worktree_id"]` — TBD knows what was
    /// clicked, and for a TBD-initiated create the provider stamp is normally
    /// absent anyway. Nil on every other path, which is all of them.
    func adopt(
        session: RemoteSessionPayload, provider: String, parentOverride: UUID? = nil
    ) async -> Outcome {
        let mirrorRow: RemoteSessionRow?
        do {
            mirrorRow = try await db.remoteSessions.row(provider: provider, sessionID: session.id)
        } catch {
            adoptionLogger.error(
                "adoption skipped for \(provider, privacy: .public)/\(session.id, privacy: .public): mirror unreadable: \(String(describing: error), privacy: .public)"
            )
            return Outcome()
        }
        guard let repoID = mirrorRow?.resolvedRepoIDUUID else { return Outcome() }
        return await adoptOne(
            session: session, provider: provider, repoID: repoID, parentOverride: parentOverride)
    }

    // MARK: - One session

    private func adoptOne(
        session: RemoteSessionPayload, provider: String, repoID: UUID,
        parentOverride: UUID? = nil
    ) async -> Outcome {
        do {
            // An existing binding ends the creation half of adoption for this
            // session, whatever the payload now says. The one thing a later
            // sighting can still do to a row that exists is give it a first
            // parent.
            if let existing = try await db.worktrees.findRemote(
                provider: provider, sessionID: session.id)
            {
                return await nestIfParentless(
                    existing: existing, session: session, provider: provider,
                    parentOverride: parentOverride)
            }
            // The pin outlives the repo it names — nothing clears it when a
            // repo is unregistered. Inserting against a dangling repoID would
            // trip the foreign key on every poll forever, so check first and
            // let the session fall back to being Provider-Desk-only.
            guard try await db.repos.get(id: repoID) != nil else {
                adoptionLogger.debug(
                    "not adopting \(provider, privacy: .public)/\(session.id, privacy: .public): pinned repo \(repoID.uuidString, privacy: .public) is no longer registered"
                )
                return Outcome()
            }

            let id = try await resolveRowID(session: session, provider: provider)
            let parentWorktreeID = try await resolveParentID(
                session: session, provider: provider, parentOverride: parentOverride, rowID: id)
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
            return Outcome(created: [created])
        } catch {
            adoptionLogger.error(
                "adoption failed for \(provider, privacy: .public)/\(session.id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return Outcome()
        }
    }

    /// Give a row adopted at top level the parent a later sighting names.
    ///
    /// The narrow case this exists for: the parent stamp was not readable when
    /// the row was minted — the session had not been stamped yet, or the
    /// spawning lane was not yet a row TBD had — so the lane landed at top
    /// level. Without this it would stay there for the rest of its life, since
    /// adoption runs on every convergence and every one of them would find the
    /// row already bound.
    ///
    /// Strictly nil→value, and **once per row**. A row that already has a
    /// parent keeps it, and a row adoption has already placed is left alone
    /// even after it comes back to nil, because the only thing that returns it
    /// there is the user un-nesting it (`tbd worktree move <lane> --root`).
    /// Nil-ness alone cannot tell that apart from "no parent was ever
    /// knowable", and the stamp cannot arbitrate either: it is static from
    /// create time, so it is present on every later poll and a nil-only guard
    /// would revert the user's gesture inside one poll interval — with a
    /// `.worktreeMoved` nobody asked for, so the lane visibly jumps back.
    /// `Worktree.remoteParentAssigned` is the fact that discriminates, written
    /// by whichever adoption write assigned the parent.
    ///
    /// `assignParentIfUnset` enforces both conditions again inside its write
    /// transaction, and holds the late edge to the full parent validation
    /// `move()` uses — including the two guards a fresh row could not need,
    /// since a brand-new row can be neither its own parent nor an ancestor of
    /// one. A refused edge assigns nothing and therefore marks nothing: the row
    /// can still be healed by a later stamp that does validate.
    private func nestIfParentless(
        existing: Worktree, session: RemoteSessionPayload, provider: String,
        parentOverride: UUID? = nil
    ) async -> Outcome {
        guard existing.parentWorktreeID == nil, !existing.remoteParentAssigned else {
            return Outcome()
        }
        do {
            guard let parentID = try await resolveParentID(
                session: session, provider: provider, parentOverride: parentOverride,
                rowID: existing.id)
            else { return Outcome() }
            guard let sortOrder = try await db.worktrees.assignParentIfUnset(
                worktreeID: existing.id, parentID: parentID)
            else { return Outcome() }
            adoptionLogger.debug(
                "nested \(provider, privacy: .public)/\(session.id, privacy: .public) (worktree \(existing.id.uuidString, privacy: .public)) under parent \(parentID.uuidString, privacy: .public) named by a later sighting"
            )
            return Outcome(
                nested: [
                    Nesting(worktreeID: existing.id, parentID: parentID, sortOrder: sortOrder)
                ])
        } catch {
            adoptionLogger.debug(
                "not nesting \(provider, privacy: .public)/\(session.id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return Outcome()
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

    /// The parent edge for this row: the caller's override when there is one,
    /// otherwise `meta["tbd_parent_worktree_id"]`, otherwise nil for a
    /// top-level row.
    ///
    /// **The override wins outright, and never falls back to the stamp.** TBD
    /// knows which `+` the user clicked; a stamp that disagrees is at best a
    /// provider's guess about a lane it did not place, and for a TBD-initiated
    /// create there is normally no stamp at all. An override that fails
    /// validation therefore yields a top-level row rather than quietly
    /// substituting a different parent the user never asked for.
    ///
    /// Nil for every degenerate stamp — absent, unparseable, or naming no row —
    /// because a lane with no known parent belongs at the top of its repo,
    /// where the user can see and reparent it.
    ///
    /// An **archived** parent is treated as unknown for the same reason: the
    /// sidebar never renders an archived row's subtree, so storing that edge
    /// would file a live lane somewhere it cannot be seen. A main-worktree
    /// parent is refused on the same grounds — `WorktreeMoveError.parentIsMain`
    /// already forbids it for local rows, and the main row has no subtree in
    /// the sidebar either.
    private func resolveParentID(
        session: RemoteSessionPayload, provider: String, parentOverride: UUID?, rowID: UUID
    ) async throws -> UUID? {
        if let parentOverride {
            do {
                try await db.worktrees.validateParent(
                    worktreeID: rowID, parentID: parentOverride)
                return parentOverride
            } catch {
                // Never fails the create: the session already exists on the
                // remote side by the time adoption runs, so losing the row
                // would cost far more than losing the edge.
                adoptionLogger.warning(
                    "\(provider, privacy: .public)/\(session.id, privacy: .public) was started under parent \(parentOverride.uuidString, privacy: .public), which the parent rules refuse (\(String(describing: error), privacy: .public)); the lane stays at top level"
                )
                return nil
            }
        }
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
