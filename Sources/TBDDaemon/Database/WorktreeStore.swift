import Foundation
import GRDB
import os
import TBDShared

private let decodeLogger = Logger(subsystem: "com.tbd.daemon", category: "database.decode")

/// GRDB Record type for the `worktree` table.
struct WorktreeRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "worktree"

    var id: String
    var repoID: String?
    var name: String
    var displayName: String
    var branch: String
    var path: String
    var status: String
    var hasConflicts: Bool
    var createdAt: Date
    var archivedAt: Date?
    var tmuxServer: String
    var archivedClaudeSessions: String?
    var sortOrder: Int
    var archivedHeadSHA: String?
    var tabOrder: String  // JSON array of UUID strings, e.g. "[]" or "[\"...\",\"...\"]"
    var activeTabID: String?
    var parentWorktreeID: String?
    var autoArchiveOnMerge: Bool?
    var autoHibernateOnMerge: Bool?
    var prStatus: String?  // JSON-encoded PRStatus, nil when never observed
    var promotedToRepoID: String?  // set only on promoted scratch rows
    var pr_number: Int?  // number of the PR this worktree was created from, nil otherwise
    // Contents checked out from an unvetted ref (fork PR head); nil on rows
    // written before v67, which read as false.
    var foreign_head: Bool?
    var panel_surface_imported_at: Date?  // stamped once the legacy layout is imported; nil = never imported
    var pinnedAt: Date?  // sidebar dock pin; nil = unpinned
    var pinSortOrder: Int?  // sidebar dock ordering; nil = falls back to pinnedAt
    var location: String?  // "local" | "remote"; nil reads as local
    // The provider session behind this row, PAST OR PRESENT. Set whenever the
    // row has one — a landed lane keeps both while its `location` says
    // "local". `idx_worktree_provider_session` (v72) indexes the pair, which is
    // what lets `findRemote` keep matching a landed row and stops adoption from
    // minting a second lane for a session that already has one.
    var providerName: String?
    var providerSessionID: String?
    // Prompt parked at creation time, delivered when the primary agent turns up
    // (v71). nil = nothing parked.
    var pending_prompt: String?
    // Whether delivery ends with Enter. Carries a SQL default (unlike the
    // `queued_prompt_enabled` flag) because it is data, not a gate; nil only on
    // rows the record type wrote explicitly, and resolves to true.
    var pending_prompt_submit: Bool?
    // JSON-encoded PRObservation: the OUTCOME of the last attempt to learn this
    // worktree's PR state, as opposed to `prStatus`, the value it found. nil =
    // no attempt on record, which is a third thing again from a recorded
    // `.none` ("the forge answered; no PR") or `.undetermined`.
    var prObservation: String?

    init(from wt: Worktree) {
        self.id = wt.id.uuidString
        self.repoID = wt.repoID?.uuidString
        self.name = wt.name
        self.displayName = wt.displayName
        self.branch = wt.branch
        self.path = wt.localPath
        self.status = wt.status.rawValue
        self.hasConflicts = wt.hasConflicts
        self.createdAt = wt.createdAt
        self.archivedAt = wt.archivedAt
        self.tmuxServer = wt.tmuxServer
        self.sortOrder = wt.sortOrder
        self.archivedHeadSHA = wt.archivedHeadSHA
        if let sessions = wt.archivedClaudeSessions {
            self.archivedClaudeSessions = try? String(
                data: JSONEncoder().encode(sessions), encoding: .utf8)
        }
        self.tabOrder = "[]"  // overwritten by GRDB when fetched; only "new worktree" path uses this initializer
        self.activeTabID = nil  // new worktrees start with no stored selection
        self.parentWorktreeID = wt.parentWorktreeID?.uuidString
        self.autoArchiveOnMerge = wt.autoArchiveOnMerge
        self.autoHibernateOnMerge = wt.autoHibernateOnMerge
        self.prStatus = wt.prStatus.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
        self.promotedToRepoID = wt.promotedToRepoID?.uuidString
        self.pr_number = wt.prNumber
        self.foreign_head = wt.foreignHead
        self.panel_surface_imported_at = nil  // new worktrees start unimported; stamped via stampPanelSurfaceImported
        self.pinnedAt = wt.pinnedAt
        self.pinSortOrder = wt.pinSortOrder
        // Symmetric with `toModel()`: the location string says where the files
        // are, the two provider columns say where the lane came from. Writing
        // them from `wt.origin` rather than from `wt.location` is what stops a
        // landed row's provenance being erased on save.
        self.location = wt.location.isLocal ? "local" : "remote"
        self.providerName = wt.origin?.provider
        self.providerSessionID = wt.origin?.sessionID
        self.pending_prompt = wt.pendingPrompt
        self.pending_prompt_submit = wt.pendingPromptSubmit
        self.prObservation = FactColumnJSON.encode(wt.prObservation)
    }

    /// Failable decode: skips (returns nil after a logged warning) only when the
    /// primary key UUID fails to parse — that row is unrecoverable. An unknown
    /// `status` rawValue instead falls back to `.active` (see below) so the
    /// worktree is preserved rather than dropped. `worktrees.list` runs
    /// constantly and on every reconcile, so one row written by a branch build
    /// whose `WorktreeStatus` enum has a case this build lacks must not crash the
    /// fetch. `repoID` already decodes safely via `flatMap` and is intentionally
    /// left as-is.
    func toModel() -> Worktree? {
        var sessions: [String]?
        if let json = archivedClaudeSessions,
           let data = json.data(using: .utf8) {
            sessions = try? JSONDecoder().decode([String].self, from: data)
        }
        var pr: PRStatus?
        if let json = prStatus, let data = json.data(using: .utf8) {
            pr = try? JSONDecoder().decode(PRStatus.self, from: data)
        }
        guard let uuid = UUID(uuidString: id) else {
            decodeLogger.warning("Skipping worktree row \(id, privacy: .public): malformed id")
            return nil
        }
        // Unlike a malformed primary-key UUID (genuinely unrecoverable → drop the
        // row), an unknown status is recoverable: dropping the whole worktree
        // mid-reconcile could orphan its terminals/tmux, which is worse than the
        // startup crash we're fixing. Fall back to `.active` (the safe visible/
        // normal default) — matching sibling stores' `RepoStatus(rawValue:) ?? .ok`.
        let worktreeStatus: WorktreeStatus
        if let parsed = WorktreeStatus(rawValue: status) {
            worktreeStatus = parsed
        } else {
            decodeLogger.warning("worktree row \(id, privacy: .public): unknown status \(status, privacy: .public); defaulting to .active")
            worktreeStatus = .active
        }
        // Mirrors `Worktree.init(from:)`. The two provider columns are the
        // ORIGIN and are read whenever both are present; the location string
        // decides only whether the files are also over there. A "remote" string
        // missing either column, an unknown kind, or a null column (pre-v70)
        // all read as local rather than dropping the row.
        let worktreeOrigin: WorktreeOrigin?
        if let providerName, let providerSessionID {
            worktreeOrigin = WorktreeOrigin(provider: providerName, sessionID: providerSessionID)
        } else {
            worktreeOrigin = nil
        }
        let worktreeLocation: WorktreeLocation
        if location == "remote", let providerName, let providerSessionID {
            worktreeLocation = .remote(provider: providerName, sessionID: providerSessionID)
        } else {
            worktreeLocation = .local
        }
        return Worktree(
            id: uuid,
            repoID: repoID.flatMap { UUID(uuidString: $0) },
            name: name,
            displayName: displayName,
            branch: branch,
            path: path,
            status: worktreeStatus,
            hasConflicts: hasConflicts,
            createdAt: createdAt,
            archivedAt: archivedAt,
            tmuxServer: tmuxServer,
            archivedClaudeSessions: sessions,
            sortOrder: sortOrder,
            archivedHeadSHA: archivedHeadSHA,
            parentWorktreeID: parentWorktreeID.flatMap { UUID(uuidString: $0) },
            autoArchiveOnMerge: autoArchiveOnMerge,
            autoHibernateOnMerge: autoHibernateOnMerge,
            promotedToRepoID: promotedToRepoID.flatMap { UUID(uuidString: $0) },
            prStatus: pr,
            prNumber: pr_number,
            foreignHead: foreign_head ?? false,
            pinnedAt: pinnedAt,
            pinSortOrder: pinSortOrder,
            location: worktreeLocation,
            origin: worktreeOrigin,
            pendingPrompt: pending_prompt,
            pendingPromptSubmit: pending_prompt_submit,
            prObservation: Self.decodePRObservation(prObservation)
        )
    }

    /// Decode the recorded PR-attempt outcome, keeping "no attempt was ever
    /// made" apart from "an attempt was recorded and the record is unreadable".
    ///
    /// `FactColumnJSON.decode` collapses both into nil, which is right for the
    /// provenance columns — there, nil means "no fact", and a fact that will not
    /// decode is no fact. It is wrong here. nil on this column is a **third**
    /// value, distinct from `.none` and `.undetermined`, and it asserts that the
    /// forge was never asked about this worktree. A truncated blob asserts that
    /// too, and it has no business doing so: bytes are on the row, so an attempt
    /// happened, and the only thing lost is what it concluded — which is exactly
    /// what `.undetermined` says.
    ///
    /// The stamp is `.distantPast` because nothing on hand says when the attempt
    /// was, and that is the safe direction to be wrong in: it can only make the
    /// record read as older than it is. A stamp of "now" would present a reading
    /// nobody took as the freshest one anybody has.
    private static func decodePRObservation(_ json: String?) -> PRObservation? {
        guard let json, !json.isEmpty else { return nil }
        if let decoded = FactColumnJSON.decode(PRObservation.self, from: json) { return decoded }
        return PRObservation(
            outcome: .undetermined(cause: PRUndeterminedCause.unreadableRecord),
            observedAt: .distantPast)
    }
}

/// Errors raised when validating a worktree's parent relationship. Named
/// `WorktreeMoveError` for historical reasons (introduced with `move()`) but
/// also raised by `ParentResolver` during worktree *creation* — the parent
/// validation rules (`parentNotFound`, `parentIsMain`, `parentIsArchived`)
/// apply identically at both call sites. The `selfReference` and `cycle`
/// cases are move-only by construction (a brand-new row has no descendants).
public enum WorktreeMoveError: LocalizedError, CustomStringConvertible {
    case selfReference
    case cycle
    case parentNotFound
    case parentIsMain
    case parentIsArchived
    case worktreeNotFound

    public var description: String {
        switch self {
        case .selfReference: return "A worktree cannot be its own parent."
        case .cycle: return "This move would create a cycle in the worktree tree."
        case .parentNotFound: return "Parent worktree not found."
        case .parentIsMain: return "Cannot nest under the main worktree."
        case .parentIsArchived: return "Cannot nest under an archived worktree."
        case .worktreeNotFound: return "Worktree not found."
        }
    }

    public var errorDescription: String? { description }
}

public enum WorktreeArchiveError: LocalizedError, CustomStringConvertible {
    case hasActiveChildren

    public var description: String {
        "Archive nested worktrees first."
    }

    public var errorDescription: String? { description }
}

/// Provides CRUD operations for worktrees.
public struct WorktreeStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Create a new worktree. The displayName defaults to the name.
    /// Automatically assigns sortOrder = max(sortOrder) + 1 scoped to the
    /// new worktree's sibling group (same parentWorktreeID), so nested
    /// children get their own contiguous ordering separate from top-level
    /// worktrees in the same repo.
    ///
    /// `path` is used verbatim for a local worktree and **ignored** for a
    /// remote one, whose path is derived from `location` — see
    /// `WorktreeLocation.storagePath` for why a remote row cannot store the
    /// caller's value (or an empty placeholder). Deriving here rather than at
    /// the call site means no future caller can forget and collide with an
    /// existing remote row on the column's UNIQUE constraint. Prefer
    /// `createRemote` for remote rows, which does not ask for a path at all.
    ///
    /// `id` is minted here unless the caller supplies one. Adoption of a
    /// remote session supplies it, so a row lost after a successful provider
    /// create can be re-minted with the identity the box already exported as
    /// `TBD_WORKTREE_ID` (see `RemoteSessionAdopter`).
    public func create(
        id: UUID = UUID(),
        repoID: UUID,
        name: String,
        displayName: String? = nil,
        branch: String,
        path: String,
        tmuxServer: String,
        status: WorktreeStatus = .active,
        parentWorktreeID: UUID? = nil,
        prNumber: Int? = nil,
        location: WorktreeLocation = .local
    ) async throws -> Worktree {
        try await writer.write { db in
            let maxOrder: Int
            if let pid = parentWorktreeID {
                maxOrder = try Int.fetchOne(
                    db,
                    sql: "SELECT MAX(sortOrder) FROM worktree WHERE parentWorktreeID = ?",
                    arguments: [pid.uuidString]
                ) ?? 0
            } else {
                maxOrder = try Int.fetchOne(
                    db,
                    sql: "SELECT MAX(sortOrder) FROM worktree WHERE repoID = ? AND parentWorktreeID IS NULL",
                    arguments: [repoID.uuidString]
                ) ?? 0
            }
            let wt = Worktree(
                id: id,
                repoID: repoID,
                name: name,
                displayName: displayName ?? name,
                branch: branch,
                path: location.storagePath ?? path,
                status: status,
                tmuxServer: tmuxServer,
                sortOrder: maxOrder + 1,
                parentWorktreeID: parentWorktreeID,
                prNumber: prNumber,
                location: location
            )
            let record = WorktreeRecord(from: wt)
            try record.insert(db)
            return wt
        }
    }

    /// Create a row for an agent session on a machine TBD does not manage.
    ///
    /// There is no path and no tmux server to pass: the path is derived from
    /// the provider binding (`WorktreeLocation.storagePath`) and `tmuxServer`
    /// is empty, since a remote lane has no tmux server of its own. Both facts
    /// live here rather than at every call site so that "what does a remote
    /// row store in the local-only columns" has exactly one answer.
    public func createRemote(
        id: UUID = UUID(),
        repoID: UUID,
        name: String,
        displayName: String? = nil,
        branch: String,
        provider: String,
        sessionID: String,
        status: WorktreeStatus = .active,
        parentWorktreeID: UUID? = nil
    ) async throws -> Worktree {
        try await create(
            id: id,
            repoID: repoID,
            name: name,
            displayName: displayName,
            branch: branch,
            path: "",
            tmuxServer: "",
            status: status,
            parentWorktreeID: parentWorktreeID,
            location: .remote(provider: provider, sessionID: sessionID)
        )
    }

    /// Create a repo-less "scratch" worktree row (repoID == nil). branch is "".
    public func createScratch(
        name: String, displayName: String, path: String, tmuxServer: String
    ) async throws -> Worktree {
        try await writer.write { db in
            let maxOrder = try Int.fetchOne(
                db, sql: "SELECT MAX(sortOrder) FROM worktree WHERE repoID IS NULL"
            ) ?? 0
            let wt = Worktree(
                repoID: nil, name: name, displayName: displayName, branch: "",
                path: path, status: .active, tmuxServer: tmuxServer, sortOrder: maxOrder + 1)
            try WorktreeRecord(from: wt).insert(db)
            return wt
        }
    }

    /// Set (or clear) the promotion pointer for a scratch row.
    public func setPromotedToRepoID(id: UUID, repoID: UUID?) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE worktree SET promotedToRepoID = ? WHERE id = ?",
                           arguments: [repoID?.uuidString, id.uuidString])
        }
    }

    /// All repo-less scratch worktree rows.
    public func listScratch() async throws -> [Worktree] {
        try await writer.read { db in
            try WorktreeRecord
                .filter(Column("repoID") == nil)
                .order(Column("sortOrder").asc)
                .fetchAll(db).compactMap { $0.toModel() }
        }
    }

    /// Update a worktree's status.
    public func updateStatus(id: UUID, status: WorktreeStatus) async throws {
        try await writer.write { db in
            guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Worktree not found")
            }
            record.status = status.rawValue
            try record.update(db)
        }
    }

    /// Delete a worktree by ID.
    public func delete(id: UUID) async throws {
        _ = try await writer.write { db in
            try WorktreeRecord.deleteOne(db, key: id.uuidString)
        }
    }

    /// NULL out `parentWorktreeID` for rows whose parent is either missing or
    /// archived. Both cases would leave the child unreachable in the sidebar:
    /// 1. **Missing parent** — deleted out-of-band (manual sqlite edit / future
    ///    regression).
    /// 2. **Archived parent** — `assertArchivable` allows archiving a parent
    ///    once all its children are archived; if the user later revives the
    ///    child but not the parent, the child's `parentWorktreeID` still points
    ///    at an archived row. The sidebar's `topLevelWorktrees` filter excludes
    ///    children-of-anything, and `WorktreeSubtreeView` never visits an
    ///    archived parent's subtree — so the revived child becomes invisible.
    ///    Promoting it to top-level here matches the "if parent disappears,
    ///    null the pointer" pattern.
    /// Safe to call on every reconcile — single UPDATE with a NOT IN subquery.
    public func nullOrphanedParents() async throws {
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE worktree
                SET parentWorktreeID = NULL
                WHERE parentWorktreeID IS NOT NULL
                  AND parentWorktreeID NOT IN (
                    SELECT id FROM worktree WHERE status NOT IN ('archived')
                  )
            """)
        }
    }

    /// Walk every row with a non-null `parentWorktreeID` and break any cycles
    /// found (A.parent=B, B.parent=A) by NULLing the parent on the row we
    /// started from. `WorktreeStore.move()`'s cycle guard prevents new cycles
    /// through normal operations, so this only catches DB damage from manual
    /// sqlite edits or regressions — call it at daemon startup, NOT on every
    /// reconcile. (Reconcile fires from cleanup RPCs and periodic git sweeps;
    /// running this O(N) walk every time is wasted work for the common case
    /// of a healthy DB.)
    public func breakCyclicParents() async throws {
        try await writer.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, parentWorktreeID FROM worktree
                WHERE parentWorktreeID IS NOT NULL
            """)
            for row in rows {
                guard let rowID = row["id"] as String? else { continue }
                var cursor: String? = row["parentWorktreeID"] as String?
                var visited: Set<String> = [rowID]
                while let curID = cursor {
                    if !visited.insert(curID).inserted {
                        try db.execute(
                            sql: "UPDATE worktree SET parentWorktreeID = NULL WHERE id = ?",
                            arguments: [rowID]
                        )
                        break
                    }
                    cursor = try Row.fetchOne(
                        db,
                        sql: "SELECT parentWorktreeID FROM worktree WHERE id = ?",
                        arguments: [curID]
                    )?["parentWorktreeID"] as String?
                }
            }
        }
    }

    /// Create a synthetic "main" worktree entry pointing at the repo root.
    public func createMain(
        repoID: UUID,
        name: String,
        branch: String,
        path: String,
        tmuxServer: String
    ) async throws -> Worktree {
        let wt = Worktree(
            repoID: repoID,
            name: name,
            displayName: name,
            branch: branch,
            path: path,
            status: .main,
            tmuxServer: tmuxServer
        )
        let record = WorktreeRecord(from: wt)
        try await writer.write { db in
            try record.insert(db)
        }
        return wt
    }

    /// List worktrees, optionally filtered by repo and/or status, with optional pagination.
    /// When `excludeArchived` is true, archived rows are excluded from the result.
    /// When `scratchOnly` is true, restricts to repo-less (scratch) worktrees —
    /// note `repoID: nil` alone means "no repo filter" (every repo plus
    /// scratch), not "scratch only"; `scratchOnly` is the only way to get
    /// scratch-only rows.
    /// When `nameQuery` is non-nil and not whitespace-only, restricts to rows
    /// whose folder `name` OR `displayName` *contains* the query
    /// (case-insensitive substring, not a prefix match). A blank or
    /// whitespace-only query means "no filter". LIKE metacharacters (`%`, `_`)
    /// and the escape character in the query are escaped, so they match
    /// literally rather than acting as wildcards.
    ///
    /// Case-insensitivity comes from SQLite's built-in `LIKE`, which folds
    /// **ASCII only** — a non-ASCII query matches case-sensitively. Accepted:
    /// worktree names are generated ASCII slugs.
    ///
    /// This composes with `status`: all filters are applied when given
    /// together, and all of them are applied *before* `limit`/`offset` so
    /// pagination pages over the matching set.
    public func list(
        repoID: UUID? = nil,
        status: WorktreeStatus? = nil,
        excludeArchived: Bool = false,
        scratchOnly: Bool = false,
        limit: Int? = nil,
        offset: Int? = nil,
        nameQuery: String? = nil
    ) async throws -> [Worktree] {
        try await writer.read { db in
            var request = WorktreeRecord.all()
            if let repoID {
                request = request.filter(Column("repoID") == repoID.uuidString)
            }
            if scratchOnly {
                request = request.filter(Column("repoID") == nil)
            }
            if let status {
                request = request.filter(Column("status") == status.rawValue)
            }
            if excludeArchived {
                request = request.filter(Column("status") != WorktreeStatus.archived.rawValue)
            }
            if let pattern = Self.likePattern(for: nameQuery) {
                // GRDB's `.like()` operator has no escape-character overload,
                // so the ESCAPE clause is spelled out as raw SQL. Arguments
                // stay bound (no interpolation of user text into SQL).
                request = request.filter(sql: """
                    (name LIKE ? ESCAPE '\\' OR displayName LIKE ? ESCAPE '\\')
                    """, arguments: [pattern, pattern])
            }
            if status == .archived {
                request = request.order(Column("archivedAt").desc)
            } else {
                request = request.order(Column("sortOrder").asc)
            }
            if let limit {
                request = request.limit(limit, offset: offset ?? 0)
            }
            return try request.fetchAll(db).compactMap { $0.toModel() }
        }
    }

    /// Build the `%…%` LIKE pattern for a user-typed name query, or nil when
    /// the query is absent/blank (== no filter).
    ///
    /// The escaping is the load-bearing part: without it a typed `%` is a
    /// wildcard that matches every row, and `_` matches any single character.
    /// The escape character itself must be escaped first, otherwise a trailing
    /// `\` would escape the closing `%` we append. `internal` so it is directly
    /// unit-testable.
    static func likePattern(for nameQuery: String?) -> String? {
        guard let raw = nameQuery else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    /// Get a worktree by ID.
    public func get(id: UUID) async throws -> Worktree? {
        try await writer.read { db in
            try WorktreeRecord.fetchOne(db, key: id.uuidString)?.toModel()
        }
    }

    /// The row bound to one provider session, or nil when no row has been
    /// minted for it yet.
    ///
    /// This is adoption's idempotence check: a session that already owns a row
    /// is never adopted again, so the row is created once and never
    /// re-derived. Backed by `idx_worktree_provider_session` so the check
    /// costs an index probe per session per poll rather than a table scan.
    public func findRemote(provider: String, sessionID: String) async throws -> Worktree? {
        try await writer.read { db in
            try WorktreeRecord
                .filter(Column("providerName") == provider)
                .filter(Column("providerSessionID") == sessionID)
                .fetchOne(db)?
                .toModel()
        }
    }

    /// `get(id:)` restricted to worktrees with files on this machine.
    ///
    /// Local-only callers use this so a remote row cannot reach code that
    /// would operate on a directory that does not exist. Returning nil for a
    /// remote id is deliberate and is **not** an error: the caller's existing
    /// not-found branch is the correct response to "this worktree has nothing
    /// local to act on".
    public func getLocal(id: UUID) async throws -> LocalWorktree? {
        try await get(id: id).flatMap(LocalWorktree.init)
    }

    /// `list(...)` restricted to worktrees with files on this machine. Takes
    /// the same filters as `list(...)` and forwards them unchanged.
    ///
    /// The filtering happens in Swift rather than SQL so that
    /// `LocalWorktree.init?` stays the single definition of "local" — a WHERE
    /// clause would be a second one, free to drift from the empty-path rule.
    ///
    /// Consequence: `limit`/`offset` are applied by SQL *before* the filter, so
    /// a page containing remote rows yields fewer than `limit` locals.
    /// Acceptable because no local-only caller paginates — the only caller that
    /// passes `limit`/`offset` is the location-neutral `worktree.list` RPC,
    /// which stays on `list(...)`.
    public func listLocal(
        repoID: UUID? = nil,
        status: WorktreeStatus? = nil,
        excludeArchived: Bool = false,
        scratchOnly: Bool = false,
        limit: Int? = nil,
        offset: Int? = nil,
        nameQuery: String? = nil
    ) async throws -> [LocalWorktree] {
        try await list(
            repoID: repoID,
            status: status,
            excludeArchived: excludeArchived,
            scratchOnly: scratchOnly,
            limit: limit,
            offset: offset,
            nameQuery: nameQuery
        ).compactMap(LocalWorktree.init)
    }

    /// Archive a worktree (set status to archived and record the timestamp).
    /// Optionally saves Claude session IDs and the captured HEAD SHA in the
    /// same transaction so they survive terminal deletion and crashes.
    /// Refuses to archive worktrees with `.main` status.
    public func archive(
        id: UUID,
        claudeSessionIDs: [String]? = nil,
        archivedHeadSHA: String? = nil
    ) async throws {
        try await writer.write { db in
            guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Worktree not found")
            }
            if record.status == WorktreeStatus.main.rawValue {
                throw DatabaseError(message: "Cannot archive the main branch worktree")
            }
            if record.status == WorktreeStatus.creating.rawValue {
                throw DatabaseError(message: "Cannot archive a worktree that is still being created")
            }
            record.status = WorktreeStatus.archived.rawValue
            record.archivedAt = Date()
            if let sessions = claudeSessionIDs, !sessions.isEmpty {
                record.archivedClaudeSessions = try String(
                    data: JSONEncoder().encode(sessions), encoding: .utf8)
            }
            if let sha = archivedHeadSHA {
                record.archivedHeadSHA = sha
            }
            try record.update(db)
        }
    }

    /// Throws `WorktreeArchiveError.hasActiveChildren` if the worktree has any
    /// **direct** children with status `.active` or `.creating`. Used as a precheck
    /// by the archive RPC handler so app and CLI surface the same error.
    ///
    /// Note: only depth-1 children are checked here. A tree shape like
    /// `A → B(archived) → C(active)` would let `A` be archived because its
    /// only direct child `B` is already archived; `C` then briefly points at
    /// an archived ancestor. That window is closed by `nullOrphanedParents`
    /// on the next reconcile (which now treats archived parents the same as
    /// missing ones), so `C` self-promotes to top-level rather than going
    /// invisible. Deepening the check to "any active descendant" would block
    /// legitimate archive cascades, so the current depth-1 scope is intentional.
    public func assertArchivable(id: UUID) async throws {
        try await writer.read { db in
            let activeRaw = WorktreeStatus.active.rawValue
            let creatingRaw = WorktreeStatus.creating.rawValue
            let count = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM worktree
                WHERE parentWorktreeID = ?
                  AND status IN (?, ?)
                """,
                arguments: [id.uuidString, activeRaw, creatingRaw]
            ) ?? 0
            if count > 0 {
                throw WorktreeArchiveError.hasActiveChildren
            }
        }
    }

    /// Revive an archived worktree (set status back to active, clear archivedAt).
    /// When `clearSessions` is true (default), also clears archived Claude
    /// sessions. Pass false to preserve them when the primary agent wasn't
    /// restored (e.g. skipClaude).
    public func revive(id: UUID, clearSessions: Bool = true) async throws {
        try await writer.write { db in
            guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Worktree not found")
            }
            record.status = WorktreeStatus.active.rawValue
            record.archivedAt = nil
            if clearSessions {
                record.archivedClaudeSessions = nil
            }
            try record.update(db)
        }
    }

    /// Replace the archivedClaudeSessions list with `sessions` (re-encoded as JSON).
    /// Used by the revive path when a `preferredSessionID` is supplied so the
    /// last-resumed-first ordering is persisted across re-archive.
    public func setArchivedClaudeSessions(id: UUID, sessions: [String]) async throws {
        try await writer.write { db in
            guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else { return }
            let json = try String(data: JSONEncoder().encode(sessions), encoding: .utf8) ?? "[]"
            record.archivedClaudeSessions = json
            try record.update(db)
        }
    }

    /// Rename a worktree's display name.
    public func rename(id: UUID, displayName: String) async throws {
        try await writer.write { db in
            guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Worktree not found")
            }
            record.displayName = displayName
            try record.update(db)
        }
    }

    /// Update a worktree's hasConflicts flag.
    public func updateHasConflicts(id: UUID, hasConflicts: Bool) async throws {
        try await writer.write { db in
            guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Worktree not found")
            }
            record.hasConflicts = hasConflicts
            try record.update(db)
        }
    }

    /// Update the filesystem path for a worktree.
    public func updatePath(id: UUID, path: String) async throws {
        try await writer.write { db in
            guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Worktree not found")
            }
            record.path = path
            try record.update(db)
        }
    }

    /// Update the archived HEAD SHA for a worktree (captured at archive time).
    public func updateArchivedHeadSHA(id: UUID, sha: String?) async throws {
        try await writer.write { db in
            guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Worktree not found")
            }
            record.archivedHeadSHA = sha
            try record.update(db)
        }
    }

    /// Update the branch name for a worktree.
    public func updateBranch(id: UUID, branch: String) async throws {
        try await writer.write { db in
            guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Worktree not found")
            }
            record.branch = branch
            try record.update(db)
        }
    }

    /// Record that this worktree's contents were checked out from an unvetted
    /// ref (a PR head, whose commits may come from a third-party fork).
    /// One-way: only ever sets the flag to `true`. Nothing clears it, because
    /// the contents never stop being foreign-authored.
    public func markForeignHead(id: UUID) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE worktree SET foreign_head = ? WHERE id = ?",
                arguments: [true, id.uuidString]
            )
        }
    }

    /// Update the tmux server name for a worktree.
    public func updateTmuxServer(id: UUID, tmuxServer: String) async throws {
        try await writer.write { db in
            guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Worktree not found")
            }
            record.tmuxServer = tmuxServer
            try record.update(db)
        }
    }

    /// Find a worktree by its filesystem path.
    public func findByPath(path: String) async throws -> Worktree? {
        try await writer.read { db in
            try WorktreeRecord
                .filter(Column("path") == path)
                .fetchOne(db)?
                .toModel()
        }
    }

    /// Move a worktree to a new parent (or top-level) and a new sort-order
    /// position within its destination sibling group.
    /// Validates: not-self, parent exists, parent is not `main`, no cycle.
    /// Renumbers siblings in the destination group so the moved row lands at
    /// the requested sortOrder.
    public func move(worktreeID: UUID, newParentID: UUID?, newSortOrder: Int) async throws {
        try await writer.write { db in
            guard let movingRecord = try WorktreeRecord.fetchOne(db, key: worktreeID.uuidString) else {
                throw WorktreeMoveError.worktreeNotFound
            }

            if let pid = newParentID {
                try Self.validateParent(db, worktreeID: worktreeID, parentID: pid)
            }

            // Renumber destination siblings: shift sortOrder of siblings >= newSortOrder by +1,
            // then set moving to newSortOrder.
            let parentArg = newParentID?.uuidString
            if let p = parentArg {
                try db.execute(
                    sql: "UPDATE worktree SET sortOrder = sortOrder + 1 WHERE parentWorktreeID = ? AND sortOrder >= ? AND id != ?",
                    arguments: [p, newSortOrder, worktreeID.uuidString]
                )
            } else {
                // Top-level siblings = same repo, parent null, NOT main. The UI
                // renders main via a status-filtered path (so an updated sortOrder
                // on a main row is invisible), but excluding it here keeps the
                // sibling group consistent with how the UI orders top-level rows.
                try db.execute(
                    sql: "UPDATE worktree SET sortOrder = sortOrder + 1 WHERE repoID = ? AND parentWorktreeID IS NULL AND status != 'main' AND sortOrder >= ? AND id != ?",
                    arguments: [movingRecord.repoID, newSortOrder, worktreeID.uuidString]
                )
            }

            try db.execute(
                sql: "UPDATE worktree SET parentWorktreeID = ?, sortOrder = ? WHERE id = ?",
                arguments: [parentArg, newSortOrder, worktreeID.uuidString]
            )
        }
    }

    /// Every rule about who may be whose parent, in one place: not-self, the
    /// parent exists, it is neither `main` nor archived, and the edge closes no
    /// cycle. `move()` and `assignParentIfUnset()` both go through it so a
    /// second copy cannot drift from the first.
    ///
    /// Runs inside the caller's write transaction, since the answer is only
    /// true for as long as the rows it read stay put.
    private static func validateParent(_ db: Database, worktreeID: UUID, parentID: UUID) throws {
        if parentID == worktreeID {
            throw WorktreeMoveError.selfReference
        }
        guard let parent = try WorktreeRecord.fetchOne(db, key: parentID.uuidString) else {
            throw WorktreeMoveError.parentNotFound
        }
        if parent.status == WorktreeStatus.main.rawValue {
            throw WorktreeMoveError.parentIsMain
        }
        if parent.status == WorktreeStatus.archived.rawValue {
            // Symmetric to ParentResolver's create-time check: nesting a
            // worktree under an archived parent would produce an
            // invisible row until reconcile clears the pointer.
            throw WorktreeMoveError.parentIsArchived
        }
        // Cycle check: walk up from parent; if we ever hit `worktreeID`, cycle.
        // The `visited` set defends against a pre-existing cycle in the DB
        // (manual edit or future regression) by treating any revisit as a
        // cycle too — otherwise the loop would spin forever inside the
        // write transaction and block the database.
        var cursor: String? = parent.parentWorktreeID
        var visited: Set<String> = [parentID.uuidString]
        while let curID = cursor {
            if curID == worktreeID.uuidString {
                throw WorktreeMoveError.cycle
            }
            if !visited.insert(curID).inserted {
                throw WorktreeMoveError.cycle
            }
            cursor = try WorktreeRecord.fetchOne(db, key: curID)?.parentWorktreeID
        }
    }

    /// Ask the parent rules about an edge that does not exist yet, throwing the
    /// same `WorktreeMoveError` a `move()` would.
    ///
    /// For the one caller that decides a parent BEFORE the row exists: a remote
    /// lane the user started from a worktree's nested `+`, whose parent is
    /// chosen at create time and written by the very insert that mints the row
    /// (`RemoteSessionAdopter`). Everything else either moves an existing row
    /// (`move`) or fills a nil on one (`assignParentIfUnset`), and both of those
    /// validate inside their own write transaction.
    ///
    /// `worktreeID` may therefore name a row that is not in the table yet. That
    /// is sound for every rule: a row nothing points at can close no cycle, and
    /// the self-check still catches a parent id equal to the id about to be
    /// minted. The answer is a read, so it can go stale before the insert —
    /// acceptable because the caller's fallback is a top-level row, not a
    /// failed create, and the parent's own deletion cascades that edge away.
    public func validateParent(worktreeID: UUID, parentID: UUID) async throws {
        try await writer.read { db in
            try Self.validateParent(db, worktreeID: worktreeID, parentID: parentID)
        }
    }

    /// Give a row that has no parent its FIRST one, appended to the end of the
    /// destination's child group. Returns the assigned sortOrder, or nil when
    /// the row already had a parent.
    ///
    /// Deliberately narrower than `move()`: it can only ever fill a nil, so it
    /// cannot reparent a row the user has already placed, and it never asks the
    /// caller for a position. It exists for a row adopted before its parent was
    /// knowable — a remote session whose spawning lane became visible only on a
    /// later sighting (`RemoteSessionAdopter`). Validation is `move()`'s, not a
    /// relaxed copy of it, so a late edge is held to the same rules as one the
    /// user drags into place.
    ///
    /// The nil-check and the write share one transaction: two concurrent
    /// callers must not both read "no parent" and both assign one.
    @discardableResult
    public func assignParentIfUnset(worktreeID: UUID, parentID: UUID) async throws -> Int? {
        try await writer.write { db in
            guard let record = try WorktreeRecord.fetchOne(db, key: worktreeID.uuidString) else {
                throw WorktreeMoveError.worktreeNotFound
            }
            guard record.parentWorktreeID == nil else { return nil }
            try Self.validateParent(db, worktreeID: worktreeID, parentID: parentID)

            let maxOrder = try Int.fetchOne(
                db,
                sql: "SELECT MAX(sortOrder) FROM worktree WHERE parentWorktreeID = ?",
                arguments: [parentID.uuidString]
            ) ?? 0
            let sortOrder = maxOrder + 1
            try db.execute(
                sql: "UPDATE worktree SET parentWorktreeID = ?, sortOrder = ? WHERE id = ?",
                arguments: [parentID.uuidString, sortOrder, worktreeID.uuidString]
            )
            return sortOrder
        }
    }

    /// Reorder worktrees within a repo. The worktreeIDs array defines the new order.
    /// Only affects worktrees in the provided list (typically top-level). Any other
    /// top-level worktrees not in the list are pushed to sortOrder values after the
    /// reordered ones. Nested children (parentWorktreeID IS NOT NULL) are left alone
    /// — their sortOrder is scoped to their parent group.
    public func reorder(repoID: UUID, worktreeIDs: [UUID]) async throws {
        try await writer.write { db in
            for (index, wtID) in worktreeIDs.enumerated() {
                try db.execute(
                    sql: "UPDATE worktree SET sortOrder = ? WHERE id = ? AND repoID = ?",
                    arguments: [index, wtID.uuidString, repoID.uuidString]
                )
            }
            // Push any TOP-LEVEL worktrees not in the provided list to after the
            // reordered ones. Children are scoped per parent and untouched.
            let idStrings = worktreeIDs.map(\.uuidString)
            let placeholders = idStrings.map { _ in "?" }.joined(separator: ",")
            let args: [any DatabaseValueConvertible] = [worktreeIDs.count, repoID.uuidString] + idStrings
            try db.execute(
                sql: """
                    UPDATE worktree SET sortOrder = ? + rowid
                    WHERE repoID = ?
                      AND status IN ('active', 'creating')
                      AND parentWorktreeID IS NULL
                      AND id NOT IN (\(placeholders))
                    """,
                arguments: StatementArguments(args)
            )
        }
    }

    /// Delete all worktrees for a given repo.
    public func deleteForRepo(repoID: UUID) async throws {
        _ = try await writer.write { db in
            try WorktreeRecord
                .filter(Column("repoID") == repoID.uuidString)
                .deleteAll(db)
        }
    }

    /// Read the `tabOrder` JSON column for a worktree, decoded into UUIDs.
    /// Returns an empty array if the worktree has no stored order yet.
    public func getTabOrder(worktreeID: UUID) async throws -> [UUID] {
        try await writer.read { db in
            guard let record = try WorktreeRecord.fetchOne(db, key: worktreeID.uuidString) else {
                return []
            }
            return Self.decodeTabOrder(record.tabOrder)
        }
    }

    /// Replace the `tabOrder` JSON column for a worktree.
    public func setTabOrder(worktreeID: UUID, tabIDs: [UUID]) async throws {
        let json = Self.encodeTabOrder(tabIDs)
        _ = try await writer.write { db in
            try db.execute(
                sql: "UPDATE worktree SET tabOrder = ? WHERE id = ?",
                arguments: [json, worktreeID.uuidString]
            )
        }
    }

    /// Read the `activeTabID` column for a worktree. Returns nil for missing
    /// worktrees, NULL columns, or strings that don't decode as a UUID.
    public func getActiveTabID(worktreeID: UUID) async throws -> UUID? {
        try await writer.read { db in
            guard let record = try WorktreeRecord.fetchOne(db, key: worktreeID.uuidString),
                  let raw = record.activeTabID else {
                return nil
            }
            return UUID(uuidString: raw)
        }
    }

    /// Set or clear (`nil`) the persisted active tab UUID for a worktree.
    public func setActiveTabID(worktreeID: UUID, tabID: UUID?) async throws {
        _ = try await writer.write { db in
            try db.execute(
                sql: "UPDATE worktree SET activeTabID = ? WHERE id = ?",
                arguments: [tabID?.uuidString, worktreeID.uuidString]
            )
        }
    }

    /// Read the `panel_surface_imported_at` column for a worktree. `nil`
    /// distinguishes "never imported" from "imported an empty layout"
    /// (spec C Phase 2 §8). Returns nil for missing worktrees too.
    public func panelSurfaceImportedAt(worktreeID: UUID) async throws -> Date? {
        try await writer.read { db in
            try WorktreeRecord.fetchOne(db, key: worktreeID.uuidString)?.panel_surface_imported_at
        }
    }

    /// Stamp the legacy-layout-import timestamp for a worktree.
    public func stampPanelSurfaceImported(worktreeID: UUID, at date: Date) async throws {
        _ = try await writer.write { db in
            try db.execute(
                sql: "UPDATE worktree SET panel_surface_imported_at = ? WHERE id = ?",
                arguments: [date, worktreeID.uuidString]
            )
        }
    }

    /// The entire scratch-promote row migration in ONE write transaction:
    /// terminals re-parented, tab rows re-pointed, the main worktree inherits
    /// the scratch tmux server + tab order/selection, and the scratch row is
    /// retired (archived + `promotedToRepoID`). Any failure rolls the whole
    /// thing back, leaving the pre-promote state intact — in particular the
    /// scratch row stays un-promoted (retryable) and its terminals stay
    /// parented to it, so a later `scratch.delete` can never tmux-kill live
    /// windows that a half-migration left behind. DB-only: tmux windows and
    /// the processes inside them are never touched — live sessions keep
    /// running throughout. File copies (Claude project-dir snapshot) are the
    /// caller's job, outside this transaction (idempotent copy-if-newer).
    public func promoteScratchMigration(
        scratchID: UUID,
        mainWorktreeID: UUID,
        repoID: UUID,
        tmuxServer: String
    ) async throws {
        try await writer.write { db in
            // Re-parent terminal + tab rows first, guards after: a missing row
            // then exercises the rollback of these UPDATEs (and tests assert
            // exactly that), rather than short-circuiting before any mutation.
            try db.execute(
                sql: "UPDATE terminal SET worktreeID = ? WHERE worktreeID = ?",
                arguments: [mainWorktreeID.uuidString, scratchID.uuidString]
            )
            try db.execute(
                sql: "UPDATE tab SET worktreeID = ? WHERE worktreeID = ?",
                arguments: [mainWorktreeID.uuidString, scratchID.uuidString]
            )
            guard let scratch = try WorktreeRecord.fetchOne(db, key: scratchID.uuidString) else {
                throw DatabaseError(message: "Scratch worktree not found: \(scratchID)")
            }
            guard var main = try WorktreeRecord.fetchOne(db, key: mainWorktreeID.uuidString) else {
                throw DatabaseError(message: "Main worktree not found: \(mainWorktreeID)")
            }
            // Main worktree inherits the tmux server the live panes run on,
            // plus the scratch row's tab order and selection.
            main.tmuxServer = tmuxServer
            main.tabOrder = scratch.tabOrder
            main.activeTabID = scratch.activeTabID
            try main.update(db)
            // Retire the scratch row: archived + promotion pointer together,
            // so nothing can resolve its stale path as active again and the
            // skip-trash guard in scratch.delete sees the pointer atomically.
            var retired = scratch
            retired.status = WorktreeStatus.archived.rawValue
            retired.archivedAt = Date()
            retired.promotedToRepoID = repoID.uuidString
            try retired.update(db)
        }
    }

    private static func decodeTabOrder(_ json: String) -> [UUID] {
        guard let data = json.data(using: .utf8) else { return [] }
        guard let strings = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return strings.compactMap(UUID.init(uuidString:))
    }

    private static func encodeTabOrder(_ ids: [UUID]) -> String {
        let strings = ids.map(\.uuidString)
        guard let data = try? JSONEncoder().encode(strings),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    /// Set or clear the per-worktree auto-archive-on-merge override.
    /// `nil` means follow the global default; `true`/`false` override it.
    public func setAutoArchiveOnMerge(id: UUID, value: Bool?) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE worktree SET autoArchiveOnMerge = ? WHERE id = ?",
                arguments: [value, id.uuidString]
            )
        }
    }

    /// Set or clear the per-worktree auto-hibernate-on-merge override.
    /// `nil` means follow the global default; `true`/`false` override it.
    public func setAutoHibernateOnMerge(id: UUID, value: Bool?) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE worktree SET autoHibernateOnMerge = ? WHERE id = ?",
                arguments: [value, id.uuidString]
            )
        }
    }

    /// Pin or unpin a worktree for the sidebar dock. `nil` clears the pin.
    /// Purely presentational — nothing in the daemon reads this value.
    ///
    /// Pinning appends to the end of the dock; unpinning clears both fields so a
    /// re-pin appends again rather than reclaiming its old slot.
    public func setPinned(id: UUID, pinnedAt: Date?) async throws {
        let order: Int? = pinnedAt == nil ? nil : try await nextPinSortOrder()
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE worktree SET pinnedAt = ?, pinSortOrder = ? WHERE id = ?",
                arguments: [pinnedAt, order, id.uuidString]
            )
        }
    }

    /// Reorder the sidebar dock's pinned worktrees. Only affects the worktrees
    /// in the provided list; any other PINNED worktree is pushed to values after
    /// the reordered ones. Modelled on `ModelProfileStore.reorder` — the dock is
    /// one flat cross-repo list, so there is no repo scoping.
    public func reorderPins(worktreeIDs: [UUID]) async throws {
        try await writer.write { db in
            for (index, worktreeID) in worktreeIDs.enumerated() {
                try db.execute(
                    sql: "UPDATE worktree SET pinSortOrder = ? WHERE id = ?",
                    arguments: [index, worktreeID.uuidString]
                )
            }
            // Push any PIN not in the list to after the reordered ones, so pins
            // the client did not know about never collide at one value.
            //
            // The `pinnedAt IS NOT NULL` scoping is where this deliberately
            // diverges from `ModelProfileStore.reorder`, which sweeps its whole
            // table: every row in `model_profiles` IS a profile, but most rows in
            // `worktree` are not pins. Sweeping unconditionally would stamp an
            // order onto unpinned rows and destroy the invariant the no-backfill
            // design rests on — `pinSortOrder IS NULL` means "never explicitly
            // ordered", which is exactly what the dock's fallback sort reads.
            // Do not "re-sync" this clause with the profile version.
            let idStrings = worktreeIDs.map(\.uuidString)
            let placeholders = idStrings.map { _ in "?" }.joined(separator: ",")
            let args: [any DatabaseValueConvertible] = [worktreeIDs.count] + idStrings
            try db.execute(
                sql: """
                    UPDATE worktree SET pinSortOrder = ? + rowid
                    WHERE pinnedAt IS NOT NULL AND id NOT IN (\(placeholders))
                    """,
                arguments: StatementArguments(args)
            )
        }
    }

    /// One past the highest assigned `pinSortOrder`, so a new pin appends to the
    /// end of the dock and never disturbs a curated order. Returns 0 when
    /// nothing has one yet.
    ///
    /// Only pins ever carry a non-NULL `pinSortOrder` (`reorderPins` scopes its
    /// sweep, `setPinned` clears the field on unpin), so this MAX really is the
    /// last pin's position rather than a number derived from unrelated rows.
    public func nextPinSortOrder() async throws -> Int {
        try await writer.read { db in
            let maxOrder = try Int.fetchOne(db, sql: "SELECT MAX(pinSortOrder) FROM worktree")
            return (maxOrder ?? -1) + 1
        }
    }

    /// Persist (or clear with nil) the last-known GitHub PR status for a worktree.
    public func setPRStatus(id: UUID, status: PRStatus?) async throws {
        let json: String?
        if let status {
            json = String(data: try JSONEncoder().encode(status), encoding: .utf8)
        } else {
            json = nil
        }
        try await writer.write { db in
            try db.execute(sql: "UPDATE worktree SET prStatus = ? WHERE id = ?",
                           arguments: [json, id.uuidString])
        }
    }

    /// Park a prompt for this worktree's primary agent, replacing whatever was
    /// parked before — the feature holds one prompt per worktree, not a queue.
    /// `text: nil` unparks without delivering.
    public func setPendingPrompt(worktreeID: UUID, text: String?, submit: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE worktree SET pending_prompt = ?, pending_prompt_submit = ? WHERE id = ?",
                arguments: [text, submit, worktreeID.uuidString]
            )
        }
    }

    /// Clear the parked prompt **only if the column still holds `text` with
    /// `submit`**. Answers whether it did.
    ///
    /// The submit bit is part of the identity, not decoration: re-parking the
    /// same words with the box unticked is a different prompt — staged in the
    /// composer rather than sent — and a clear that ignored the bit would
    /// consume it as though it had already been delivered.
    ///
    /// The compare-and-swap is the contract. Delivery reads the text, settles,
    /// hands it to a pane, and comes back to clear — and both of those suspend,
    /// so a second park can land in between. An unconditional clear would
    /// destroy that newer prompt: it would vanish from the recovery store
    /// having never been delivered, while its own cycle read an empty column
    /// and returned silently. Clearing only what was actually delivered leaves
    /// the newcomer where its own cycle can find it.
    ///
    /// **`PendingPromptCoordinator.deliverParkedPrompt` is the only caller, and
    /// the only writer that clears this column after a delivery.** The spawn
    /// path does not touch it at all.
    public func clearPendingPrompt(
        worktreeID: UUID, ifTextIs text: String, submit: Bool
    ) async throws -> Bool {
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE worktree SET pending_prompt = NULL \
                    WHERE id = ? AND pending_prompt = ? AND pending_prompt_submit = ?
                    """,
                arguments: [worktreeID.uuidString, text, submit]
            )
            return db.changesCount > 0
        }
    }

    /// Persist (or clear with nil) the outcome of the last attempt to learn
    /// this worktree's PR state.
    ///
    /// Separate from `setPRStatus` because the two answer different questions
    /// and can disagree: a failed query leaves the previous `prStatus` in place
    /// (it is the newest value anyone has) while recording `.undetermined`
    /// here, so a reader can see that the value it is holding is not confirmed.
    public func setPRObservation(id: UUID, observation: PRObservation?) async throws {
        let json = FactColumnJSON.encode(observation)
        try await writer.write { db in
            try db.execute(sql: "UPDATE worktree SET prObservation = ? WHERE id = ?",
                           arguments: [json, id.uuidString])
        }
    }

    /// Persisted PR observations for every **unarchived** worktree, keyed by
    /// worktree id. Used to hydrate the in-memory observation map at daemon
    /// startup, so an `.undetermined` recorded before a restart is not
    /// downgraded to "no attempt on record".
    ///
    /// Archived rows are excluded because the map is handed out whole in every
    /// `pr.list` — a payload on a thirty-second cadence — and "every worktree
    /// ever created" is not a set that stops growing. An archived worktree has
    /// no pull request anyone is watching: the poller enumerates
    /// `list(status: .active)` and would never refresh those entries anyway, so
    /// carrying them is carrying a value nothing can correct. A revived
    /// worktree starts from "no attempt on record", which is the truth about it.
    ///
    /// **Only archived rows, not "active rows only".** `.main`, `.creating` and
    /// `.failed` are outside the poller's scope too, but they are bounded (one
    /// main checkout per repo, the others transient) and `pr.refresh` accepts
    /// any worktree id, so a status or outcome recorded directly on one of them
    /// is a real value that must survive a restart. Narrowing to `.active`
    /// silently dropped those at startup.
    public func allPRObservations() async throws -> [UUID: PRObservation] {
        try await unarchivedWorktreeRecords { $0.prObservation }
    }

    /// Persisted PR statuses for every **unarchived** worktree, keyed by
    /// worktree id. Used to hydrate the in-memory PR cache at daemon startup so
    /// icons survive restart. Scoped for the same reason `allPRObservations` is.
    public func allPRStatuses() async throws -> [UUID: PRStatus] {
        try await unarchivedWorktreeRecords { $0.prStatus }
    }

    /// One field of every unarchived worktree, keyed by id, skipping the rows
    /// where it is absent.
    private func unarchivedWorktreeRecords<Value: Sendable>(
        _ field: @Sendable @escaping (Worktree) -> Value?
    ) async throws -> [UUID: Value] {
        try await writer.read { db in
            var result: [UUID: Value] = [:]
            let records = try WorktreeRecord
                .filter(Column("status") != WorktreeStatus.archived.rawValue)
                .fetchAll(db)
            for record in records {
                guard let wtID = UUID(uuidString: record.id),
                      let model = record.toModel().flatMap(field) else { continue }
                result[wtID] = model
            }
            return result
        }
    }
}
