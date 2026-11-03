import Foundation
import TBDShared

/// Where the sidebar places each remote session: under the repository it
/// resolved to, after that repository's local worktrees, or under its
/// provider's header when no shown repository claims it. Pure, so
/// `AppState`'s sidebar projections, `SidebarTreeBuilder` and the Provider
/// Desk share one rule, and a test can call it without an `AppState` or a
/// view hierarchy.
enum SidebarSessionPlacement {
    // MARK: Sessions under a repository

    /// The remote locations a section's worktree rows already stand for. The
    /// adopted-lane half of the filter in `matchedRemoteSessionIndices`, split
    /// out so a caller can compare it across renders without re-deriving it.
    static func adoptedLocations(_ worktrees: [Worktree]) -> Set<WorktreeLocation> {
        Set(worktrees.map(\.location).filter { !$0.isLocal })
    }

    /// The positions in `all` of the sessions a repo section shows: sessions
    /// resolved to `repoID`, dismissed tombstones excluded, sorted oldest-first
    /// by reported creation time. `AppState.sidebarMatchedRemoteSessions(repoID:)`
    /// maps them back to sessions and memoizes the result.
    ///
    /// `adopted` is `adoptedLocations` of the section's own worktree rows, and
    /// a session that one of those rows already stands for is dropped here: a
    /// remote lane that has been adopted into a `Worktree` row renders as that
    /// row, and would otherwise appear a second time as a session row under
    /// the same repo. The join is on the `(provider, sessionID)` pair both
    /// sides carry — `Worktree.location` for the row, `provider`/`payload.id`
    /// for the session — never on display name or branch, which adoption
    /// seeds once and the user is then free to change. The parameter is
    /// required rather than defaulted so a new call site cannot silently
    /// reintroduce the duplicate.
    ///
    /// A currently remote adopted lane therefore has exactly one sidebar row.
    /// A local row's retained `origin` is provenance, not evidence that it
    /// replaces the remote session: landing may fork independent local work.
    /// Keep the mirror visible unless a currently remote row represents it.
    ///
    /// A session the provider reports as `archived` gets NO surface here: it is
    /// filtered out outright. The contract requires a provider to keep archived
    /// sessions in `list` (`docs/remote-provider-contract.md` § "Archived
    /// sessions stay in the inventory") and assigns the CALLER the display
    /// policy for them — showing active sessions and hiding archived ones is a
    /// decision applied to a complete inventory, and this filter is where TBD
    /// makes it. Without it, archiving an adopted lane creates a row nothing
    /// can remove: `AppState.visibleWorktrees` drops the archived worktree row,
    /// the session falls back to rendering as a plain session row underneath
    /// it, and no gesture retires that row while the provider keeps reporting
    /// the session. Archived sessions stay reachable in the repo's Archived tab
    /// (for an adopted lane) and in the Provider Desk's session ledger, which
    /// lists every non-dismissed session the provider reports.
    ///
    /// Each surviving session's `created_at` is parsed exactly once, here, and
    /// the sort runs over those pre-parsed keys: the comparator runs
    /// O(n log n) times, and parsing inside it was the measured main-thread
    /// stall while typing. `parse` is the test seam for counting those parses;
    /// production always takes the default.
    static func matchedRemoteSessionIndices(
        _ all: [RemoteSessionInfo],
        repoID: UUID,
        adopted: Set<WorktreeLocation>,
        parse: (String?) -> Date? = SidebarSessionPlacement.parsedCreatedAt
    ) -> [Int] {
        var keyed: [(index: Int, key: CreationKey)] = []
        for (index, session) in all.enumerated()
        where session.resolvedRepoID == repoID && !session.dismissed && !session.payload.isArchived
            && !adopted.contains(.remote(provider: session.provider, sessionID: session.payload.id)) {
            keyed.append((index, CreationKey(
                createdAt: parse(session.payload.createdAt),
                uuid: session.id.uuidString)))
        }
        keyed.sort { isOrderedByCreation($0.key, $1.key) }
        return keyed.map(\.index)
    }

    /// The pre-parsed sort key for one session: its `created_at` (nil when
    /// absent or unparseable) and its `id.uuidString`, the tie-break.
    struct CreationKey {
        let createdAt: Date?
        let uuid: String
    }

    /// Ascending creation-time ordering on pre-parsed keys. A session
    /// with a missing/unparseable `created_at` (allowed by the contract —
    /// `docs/remote-provider-contract.md` doesn't require it) sorts after
    /// every dated session; any remaining tie (including two undated
    /// sessions) breaks on the row's own stable `id` so ordering is fully
    /// deterministic across renders regardless of source-array order.
    /// Keys are parsed once before sorting because this comparator runs
    /// O(n log n) times.
    static func isOrderedByCreation(_ a: CreationKey, _ b: CreationKey) -> Bool {
        switch (a.createdAt, b.createdAt) {
        case let (x?, y?) where x != y: return x < y
        case (nil, .some): return false
        case (.some, nil): return true
        default: return a.uuid < b.uuid
        }
    }

    /// Whether two mirror rows agree on every field `matchedRemoteSessionIndices`
    /// reads: the provider and `payload.id` (which fix `id`, the tie-break
    /// key), `payload.createdAt` (the sort key), and the three filter gates.
    /// `AppState` clears its match memo only when this is false for some
    /// position, so this list must equal what the filter and the sort read;
    /// the sync-fence test in `SidebarSessionPlacementMatchOrderTests` pins
    /// it. Fields that change on every sighting or drive row state
    /// (`lastSeen`, `gone`, `payload.state`, `agentState`) are deliberately
    /// absent, so a sighting that changes only those does not force a
    /// re-sort.
    static func sameMatchInputs(_ a: RemoteSessionInfo, _ b: RemoteSessionInfo) -> Bool {
        a.provider == b.provider
            && a.payload.id == b.payload.id
            && a.payload.createdAt == b.payload.createdAt
            && a.payload.isArchived == b.payload.isArchived
            && a.dismissed == b.dismissed
            && a.resolvedRepoID == b.resolvedRepoID
    }

    /// A session's `created_at`, in either ISO 8601 profile a conforming
    /// provider may legally emit. `docs/remote-provider-contract.md` shows a
    /// whole-second example but never pins a profile, and a default-options
    /// formatter rejects the fractional form outright — which sorted every
    /// such row as undated.
    ///
    /// The parsing (and the shared, lock-guarded formatters that make it
    /// cheap enough to call from a sort comparator) lives in
    /// `RemoteTimestamp`, alongside the ordering rule that reads the
    /// contract's other timestamp. Two parsers for one wire format is one
    /// too many.
    static func parsedCreatedAt(_ raw: String?) -> Date? {
        RemoteTimestamp.parse(raw)
    }

    // MARK: Sessions under a provider

    /// Repo ids treated as "has its own rendered section" when deciding
    /// whether a MATCHED remote session (non-nil `resolvedRepoID`) has
    /// somewhere else to render. The sidebar does not render every repo in
    /// `appState.repos`: `AppState.sidebarShownRepos(showHiddenRepos:)`
    /// narrows them by the repo filter and the filter menu's Show Hidden
    /// Repos toggle, and a repo chosen in the filter shows whatever the
    /// toggle says. A session whose `resolvedRepoID` names a repo left out
    /// has no repo section to render under, and would render nowhere if this
    /// set still counted that repo as known.
    ///
    /// The filter and the hidden flag get a deliberately different answer
    /// here, reasoned about separately (see
    /// `SidebarSessionPlacementProviderTests` for both halves pinned down):
    ///
    /// - A repo FILTER never narrows this set: only the filtered repo (if
    ///   any) counts as "known", so every OTHER repo's matched sessions
    ///   become "unmatched" for the duration of the filter and fall through
    ///   to render under their provider instead. A repo filter is transient
    ///   view state — the sidebar's search-style "scope to one repo", not a
    ///   durable "I don't want to see this" decision — so silently
    ///   swallowing every other repo's remote sessions while it's active
    ///   would be far harder to defend than showing them somewhere. The
    ///   filtered repo's section shows even when the repo is hidden, so its
    ///   own sessions render there.
    /// - Hidden repos are NOT excluded here (this function doesn't consult
    ///   the Show Hidden Repos toggle at all) — a hidden repo's id always
    ///   counts as "known", so while no filter chooses it and the toggle is
    ///   off its matched sessions stay out of the provider sections and
    ///   render nowhere, by analogy with hidden WORKTREES, which already
    ///   vanish from the sidebar entirely once their repo is hidden. Hiding
    ///   a repo is a durable choice; its remote sessions disappearing along
    ///   with it is the deliberate consequence, not a bug to route around.
    static func knownRepoIDs(repos: [Repo], repoFilter: UUID?) -> Set<UUID> {
        if let repoFilter {
            return [repoFilter]
        }
        return Set(repos.map(\.id))
    }

    /// UNMATCHED sessions belonging to one provider, with dismissed
    /// tombstones excluded. "Unmatched" is `resolvedRepoID == nil` (never
    /// pinned) OR a `resolvedRepoID` that no longer names any repo in
    /// `knownRepoIDs` — `resolvedRepoID` is a plain pinned value the daemon
    /// never re-resolves or clears once a repo is removed from TBD (see
    /// `RemoteSessionStore.upsert`'s pinning doc comment), so without this
    /// second condition a pinned row whose repo is later removed would
    /// render NOWHERE: excluded here because the column is non-nil, and
    /// excluded from the repo sections because that repo's section no longer
    /// exists. Re-checking membership on every build (rather than trusting
    /// the stored value) also means this self-heals for free the moment the
    /// repo reappears in `knownRepoIDs` — no new pinning event required.
    /// Resolved (matched-to-a-known-repo) sessions render inside their repo's
    /// section instead (`matchedRemoteSessionIndices`).
    ///
    /// Sessions the provider reports as `archived` are excluded too, for the
    /// same reason `matchedRemoteSessionIndices` excludes them: the contract keeps
    /// archived sessions in `list` and assigns the caller the display policy
    /// for them, and these two filters are where TBD applies it. They stay
    /// reachable in the Provider Desk's session ledger.
    static func sessions(
        in all: [RemoteSessionInfo], forProvider provider: String, knownRepoIDs: Set<UUID>
    ) -> [RemoteSessionInfo] {
        all.filter {
            $0.provider == provider && !$0.dismissed && !$0.payload.isArchived
                && ($0.resolvedRepoID == nil || !knownRepoIDs.contains($0.resolvedRepoID!))
        }
    }
}
