import AppKit
import Combine
import Foundation
import SwiftUI
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState")
private let tmuxResolutionLogger = Logger(
    subsystem: "com.tbd.app",
    category: "tmux"
)
/// Spec C §11.3 — log-only shadow-compare diagnostic. Dedicated category so
/// it can be streamed/filtered independently of the rest of AppState.
private let shadowCompareLogger = Logger(subsystem: "com.tbd.app", category: "panelShadow")
/// Dedicated channel for RPC/poll-cadence observability (storm diagnostics).
/// Silent by default; activate with `log stream --level debug`.
private let perfRPCLogger = Logger(subsystem: "com.tbd.app", category: "perf-rpc")
private let perfRPCSignposter = OSSignposter(subsystem: "com.tbd.app", category: "perf-rpc")

/// Transition state for a worktree being revived from the archived view.
/// Holds a snapshot of the `Worktree` so the row can keep rendering even
/// after the daemon removes it from `archivedWorktrees`.
enum ReviveState: Equatable {
    case inFlight(snapshot: Worktree)
    case done(snapshot: Worktree)

    var snapshot: Worktree {
        switch self {
        case .inFlight(let s), .done(let s): return s
        }
    }
}

struct TabCloseContext: Equatable {
    let worktreeID: UUID
    let tabID: UUID
}

/// Identifies one control-mode pane app-side. `paneID` (tmux `%N`) is only
/// unique within one server, so it is always paired with `worktreeID` — the
/// same keying as the daemon router and `SidecarInputHeader`.
struct ControlModePaneKey: Hashable {
    let worktreeID: UUID
    let paneID: String
}

enum TmuxStartupResolutionDiagnostic: Equatable {
    case path(String)
    case savedFallback(String)
    case unavailable

    init(resolution: TmuxExecutableResolution?) {
        switch resolution {
        case .some(let resolution):
            switch resolution.source {
            case .path:
                self = .path(resolution.path)
            case .savedFallback:
                self = .savedFallback(resolution.path)
            }
        case .none:
            self = .unavailable
        }
    }

    func log() {
        switch self {
        case .path(let path):
            tmuxResolutionLogger.notice(
                "startup resolution source=PATH path=\(path, privacy: .public)"
            )
        case .savedFallback(let path):
            tmuxResolutionLogger.notice(
                "startup resolution source=saved-fallback path=\(path, privacy: .public)"
            )
        case .unavailable:
            tmuxResolutionLogger.error("startup resolution source=unavailable")
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    /// Reference to the global appearance settings, wired by `TBDAppMain`
    /// after both StateObjects are constructed. Used by
    /// `mainAreaTerminalSize()` to compute initial tmux pane dimensions
    /// from the user's current font, before any `TBDTerminalView` exists.
    /// Plain (non-weak) optional — `AppState` and `AppearanceSettings` share
    /// the app's lifetime, so this reference cannot outlive its target.
    var appearance: AppearanceSettings? {
        didSet {
            if let appearance {
                appearance.themeStore = themeStore
                setupAppearanceSubscriptions(appearance)
            }
        }
    }
    /// Subscription to appearance.$schemeID changes for pushing COLORFGBG updates to running tmux servers.
    private var appearanceSubscription: AnyCancellable?
    /// Owns the trailing-edge quiet window in front of that subscription.
    private let appearanceDebouncer = AppearanceBroadcastDebouncer()
    /// Subscription to themeStore.$userThemes changes for reconciling the active scheme.
    private var themeStoreSubscription: AnyCancellable?

    @Published var repos: [Repo] = []
    @Published var worktrees: [UUID: [Worktree]] = [:]
    /// Repo-less scratch spaces (`Worktree.isScratch`), surfaced separately
    /// in the sidebar's Scratch section rather than under any repo group.
    @Published var scratchWorktrees: [Worktree] = []
    @Published var terminals: [UUID: [Terminal]] = [:]
    @Published var notes: [UUID: [Note]] = [:]
    @Published var focusedTabCloseContext: TabCloseContext?
    /// Unread notification summaries keyed by worktree ID. The cmd-K jump
    /// menu sorts by `mostRecentAt`; the sidebar consumes `.type` for the
    /// severity dot. Worktrees the user is currently viewing are excluded
    /// from this dictionary because `refreshNotifications` auto-marks them
    /// read on every poll.
    @Published var unreadByWorktree: [UUID: UnreadSummary] = [:]
    /// Unread notification summaries for remote sessions, keyed by
    /// `RemoteSessionSelection` (provider + provider-minted session id —
    /// remote sessions have no UUID). Mirrors `unreadByWorktree`: written by
    /// `handleRemoteSessionAttentionDelta` when an attention delta arrives,
    /// cleared by `selectRemoteSession`. App-local and in-memory only, same
    /// as `unreadByWorktree` — not persisted across restarts.
    @Published var unreadByRemoteSession: [RemoteSessionSelection: UnreadSummary] = [:]
    /// Terminal IDs that fired a `.responseComplete` notification while their
    /// tab was NOT the active tab of a focused worktree. Drives the bold tab
    /// label in `TabBar`, mirroring the worktree-row bold. App-local and
    /// in-memory only — cleared when the user activates the tab (or focuses the
    /// worktree on that tab); intentionally not persisted across app restarts.
    @Published var unreadTerminals: Set<UUID> = []
    @Published var selectedWorktreeIDs: Set<UUID> = [] {
        didSet {
            // If the List selected a repo header tag (not a worktree), treat it
            // as a repo selection and remove the ID from the worktree set.
            let repoIDs = Set(repos.map(\.id))
            let selectedRepoIDs = selectedWorktreeIDs.intersection(repoIDs)
            if !selectedRepoIDs.isEmpty {
                selectedWorktreeIDs.subtract(selectedRepoIDs)
                // selectRepo() already handles this; avoid overriding it
                return
            }

            // Remote session rows are tagged into this same List (and thus
            // this same Set) purely so they're List-native keyboard
            // reachable — arrow-key traversal and the focus ring — the same
            // reason repo header tags are handled just above. UNLIKE the
            // repo-header case, a PURE remote selection (the remote tag(s)
            // were the entire selection) routes the stripped id through
            // `selectRemoteSession` (not just discard) so keyboard-only
            // navigation — which never fires `RemoteSessionRowView`'s
            // `.onTapGesture` — still ends up setting `selectedRemoteSession`
            // and the row's own highlight engages. Every other consumer of
            // `selectedWorktreeIDs` in this codebase assumes every member is
            // a real `Worktree.id` (keyboard shortcuts, the jump menu,
            // navigation history, persisted restore); stripping here before
            // any of that runs keeps that invariant exactly as it was.
            //
            // A MIXED selection (real worktree ids survive after stripping
            // the remote tag(s) — e.g. shift+↓ extending from a local
            // worktree row onto a remote row, or a shift-range crossing a
            // repo section's appended remote rows) must NOT route through
            // `selectRemoteSession`: that call unconditionally sets
            // `selectedWorktreeIDs = []`, which would silently wipe every
            // local id this same gesture just selected. The `subtract` call
            // below is itself an assignment to `selectedWorktreeIDs`, so it
            // re-invokes this same `didSet` (nested, synchronously, before
            // `subtract` returns) with the remote tag(s) already gone — that
            // nested invocation runs the ordinary worktree-selection
            // bookkeeping below for whatever local ids survived (or, if
            // none survived, is a no-op, since the bottom bookkeeping is
            // itself gated on `!selectedWorktreeIDs.isEmpty`). This
            // invocation must therefore `return` unconditionally right
            // after, exactly like the repo-header branch above — falling
            // through here as well would re-run that bookkeeping a SECOND
            // time (double `recordNavigation`/`recentWorktreeIDs` entries).
            //
            // Known cost of stripping the remote tag back out rather than
            // letting it live in the set at rest: the AppKit table backing
            // this List has no selection anchor on a remote row once this
            // `didSet` returns, since the row's tag no longer appears in the
            // bound Set. Arrow-key traversal starting FROM a remote row, and
            // the List-native focus ring, are therefore not guaranteed to
            // work — only the row's own highlight (driven by
            // `selectedRemoteSession`/`unreadByRemoteSession`) is guaranteed
            // to reflect the selection correctly. See the Task 9d fix-pass
            // report for why letting the tag persist at rest was rejected
            // (multiple consumers of `selectedWorktreeIDs` — e.g.
            // `newTerminalTab()` — read `.first` unguarded and would act on
            // a non-worktree id; `ContentView`'s detail-pane routing checks
            // `selectedWorktreeIDs.isEmpty` to decide whether to show the
            // empty state).
            let remoteIDs = Set(remoteSessions.map(\.id))
            let selectedRemoteIDs = selectedWorktreeIDs.intersection(remoteIDs)
            if !selectedRemoteIDs.isEmpty {
                selectedWorktreeIDs.subtract(selectedRemoteIDs)
                // Only a PURE remote selection (nothing local survived the
                // subtract) routes through `selectRemoteSession` — a mixed
                // selection already got its local-id bookkeeping from the
                // nested `didSet` triggered by the subtract above.
                if selectedWorktreeIDs.isEmpty,
                   let remoteID = selectedRemoteIDs.first,
                   let session = remoteSessions.first(where: { $0.id == remoteID }) {
                    selectRemoteSession(provider: session.provider, sessionID: session.payload.id)
                }
                return
            }

            // Remove deselected items from order
            selectionOrder.removeAll { !selectedWorktreeIDs.contains($0) }
            // Append newly selected items (maintains insertion order for cmd+click)
            for id in selectedWorktreeIDs where !selectionOrder.contains(id) {
                selectionOrder.append(id)
            }
            // When a single worktree becomes the focused selection, the user is
            // now viewing its active tab — clear that tab's unread-completion
            // bold. Single-select only: tab bars only render in single-select.
            if selectedWorktreeIDs.count == 1, let only = selectedWorktreeIDs.first {
                clearUnreadForActiveTab(worktreeID: only)
            }

            // Clear repo selection when a worktree is selected
            if !selectedWorktreeIDs.isEmpty {
                if let leaving = selectedRepoID { clearRevivingArchived(repoID: leaving) }
                selectedRepoID = nil
                selectedScratchSection = false
                selectedRemoteProvider = nil
                selectedRemoteSession = nil
                recordNavigation(.worktrees(selectionOrder))
                // Feed the jump menu's Recent section. Insertion-order LRU,
                // most-recent-first; capped at 32 to bound memory. Only the
                // most-recently-added worktree ID is recorded per selection
                // event — multi-select doesn't make sense for "the worktree
                // I just looked at". Intentionally not gated on
                // `isNavigating`: cmd+[ / cmd+] are real visits and should
                // reorder the jump menu Recents (Slack-style).
                if let id = selectionOrder.last {
                    recentWorktreeIDs.removeAll { $0 == id }
                    recentWorktreeIDs.insert(id, at: 0)
                    if recentWorktreeIDs.count > Self.recentWorktreeCap {
                        recentWorktreeIDs.removeLast(recentWorktreeIDs.count - Self.recentWorktreeCap)
                    }
                }
            }
        }
    }
    /// Tracks the order of selected worktrees for split view rendering (cmd+click order).
    /// Persists to UserDefaults on every change (gated on `isInitialStateLoaded`) so the
    /// final, correctly-ordered value is always what gets saved — regardless of whether
    /// the change came from a user selection, back/forward navigation, or startup restore.
    @Published var selectionOrder: [UUID] = [] {
        didSet { persistSelectionOrder() }
    }
    /// A one-shot request to reveal a specific section of a repo's detail pane.
    /// Set by `revealPreSessionHookEditor`, cleared by `RepoDetailView` once
    /// applied so navigating back does not replay it.
    enum RepoDetailReveal: Equatable {
        case preSessionHook(repoID: UUID)
    }

    @Published var repoDetailReveal: RepoDetailReveal?

    /// Selected repo ID — set when a repo header is clicked, shows archived worktrees in content pane.
    @Published var selectedRepoID: UUID? = nil {
        didSet {
            if let old = oldValue, old != selectedRepoID {
                clearRevivingArchived(repoID: old)
            }
            guard selectedRepoID != oldValue, let id = selectedRepoID else { return }
            recordNavigation(.repo(id))
        }
    }
    /// When set, the next `RepoDetailView` to appear selects this tab instead
    /// of its default (`.archived`). Consumed (cleared) by the view on apply.
    /// Drives the toolbar repo-name dropdown → repo detail tab navigation.
    @Published var pendingRepoDetailTab: RepoDetailTab?
    /// Selected — set when the "Scratch" sidebar section header is clicked,
    /// shows `ScratchDetailView` (Archived/Instructions/Settings tabs) in the
    /// content pane. Parallel to `selectedRepoID` but with no `NavigationEntry`
    /// integration for v1 (documented scope cut — see `selectScratchSection()`).
    @Published var selectedScratchSection: Bool = false
    /// Selected provider header, showing its read-only Provider Desk. This is
    /// mutually exclusive with worktree, repo, scratch, and remote-session
    /// selection, but intentionally stays out of back/forward history for the
    /// first desk slice.
    @Published var selectedRemoteProvider: String?
    /// Selected — set when a `RemoteSectionView` session row is clicked, shows
    /// `RemoteSessionDetailView` (Task 10) in the content pane. Parallel to
    /// `selectedScratchSection` but keyed by the provider/session composite id
    /// rather than a UUID (see `RemoteSessionSelection` in
    /// `AppState+Navigation.swift`). UNLIKE `selectedScratchSection`, this one
    /// DOES participate in back/forward history — `selectRemoteSession`
    /// records a `.remoteSession` `NavigationEntry` — since remote sessions
    /// now sit inside a repo's own sidebar section beside local worktrees
    /// (see `selectRemoteSession`'s doc comment).
    @Published var selectedRemoteSession: RemoteSessionSelection? = nil
    /// One-shot hint for which tab `RemoteSessionDetailView` should land on,
    /// set when a sidebar context-menu action (e.g. "View Log") jumps
    /// straight to a specific tab instead of the default. Consumed (read AND
    /// cleared) by the detail view on appear/selection-change — mirrors the
    /// reveal-nonce discipline documented for `RepoDetailView`'s persistent
    /// `@State`: a reveal must be a one-shot consumed by the acting child,
    /// checked in BOTH onAppear and onChange, or a stale hint replays on an
    /// unrelated later selection. `selectRemoteSession(provider:sessionID:tab:)`
    /// sets this alongside `selectedRemoteSession`; nil means "default tab".
    @Published var remoteSessionRequestedTab: RemoteSessionDetailTab?

    // MARK: - Navigation history (back/forward)

    /// Back/forward state. Mutated only by the helpers in `AppState+Navigation.swift` —
    /// any change to `navigationIndex` or `navigationEntries` must be followed by
    /// `updateNavigationFlags()` to keep the published toolbar flags in sync.

    /// Published flags driving the toolbar back/forward buttons.
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false
    /// Recorded navigation entries (most recent at the end).
    var navigationEntries: [NavigationEntry] = []
    /// Index into `navigationEntries` of the currently-displayed view state, or -1 if none.
    var navigationIndex: Int = -1
    /// True while applying a back/forward entry, to suppress recording the resulting selection change.
    var isNavigating: Bool = false

    /// Refresh the @Published `canGoBack` / `canGoForward` flags from the index.
    /// Usability-aware: a flag is only true when an actually-usable entry exists
    /// in that direction, so the toolbar buttons don't render enabled when
    /// back/forward would skip-walk past every remaining entry and no-op.
    /// Lives in the same file as the @Published properties so the `private(set)`
    /// setters are reachable.
    func updateNavigationFlags() {
        let back = usableEntryIndex(from: navigationIndex - 1, step: -1) != nil
        let forward = navigationIndex >= 0
            && usableEntryIndex(from: navigationIndex + 1, step: 1) != nil
        if back != canGoBack { canGoBack = back }
        if forward != canGoForward { canGoForward = forward }
    }
    /// Archived worktrees keyed by repo ID, fetched on demand.
    @Published var archivedWorktrees: [UUID: [Worktree]] = [:]

    /// Archived scratch spaces (repo-less), fetched on demand by
    /// `ScratchArchivedView`. Unlike `archivedWorktrees`, this is a flat list —
    /// scratch archive volume is expected to be low, so no pagination for v1.
    @Published var archivedScratchWorktrees: [Worktree] = []

    /// Whether there are more archived worktrees to load beyond what's in `archivedWorktrees`.
    @Published var archivedWorktreesHasMore: [UUID: Bool] = [:]
    /// Guards against concurrent loadMoreArchivedWorktrees calls (double-tap, race with refresh).
    @Published var isLoadingMoreArchived: [UUID: Bool] = [:]

    // MARK: Archived-worktree search
    //
    // The archived list is paginated (50/page), so a purely client-side filter
    // would silently miss older, unloaded archives — and fetching every
    // remaining page is unaffordable (`handleWorktreeList` enriches each
    // archived row with a `~/.claude/projects` scan; full enrichment measured
    // ~19 s). So search is a daemon-side SQL filter with its OWN paginated
    // result set, held separately from the unsearched `archivedWorktrees`
    // pages so clearing the query restores them without a refetch.

    /// The query whose search RPC is currently IN FLIGHT for a repo, stamped
    /// before the await so a superseded response can be dropped.
    ///
    /// This is deliberately NOT the query the stored rows answer — that lives
    /// inside `ArchivedSearchResults`. Deciding what to *display* from this
    /// value would render the previous query's rows as if they were the answer
    /// for the new one during the whole in-flight window.
    @Published var archivedSearchQuery: [UUID: String] = [:]
    /// Daemon-side search results (page-accumulated) and the query they answer,
    /// keyed by repo ID. Absent until some response has landed.
    @Published var archivedSearchResults: [UUID: ArchivedSearchResults] = [:]
    /// Repos whose most recent archived-search RPC failed. Set only for the
    /// query that was in flight, cleared when the next search starts or the
    /// search is cleared. The rail reads it so a failed search degrades to a
    /// *labelled* client-side view rather than silently claiming the loaded
    /// rows are the whole answer.
    @Published var archivedSearchFailed: [UUID: Bool] = [:]
    /// Guards against concurrent `loadMoreArchivedSearchResults` calls.
    @Published var isLoadingMoreArchivedSearch: [UUID: Bool] = [:]

    /// Orphan-GC reap records (History → Reclaimed), keyed by repo ID and
    /// fetched on demand alongside `archivedWorktrees`.
    @Published var reapRecords: [UUID: [ReapRecord]] = [:]

    /// Every registered remote-agent provider's negotiated contract + health,
    /// fetched by `refreshRemote()`. See `AppState+Remote.swift`.
    @Published var remoteProviders: [RemoteProviderStatus] = []
    /// The daemon's remote-session mirror across all providers, fetched by
    /// `refreshRemote()`. See `AppState+Remote.swift`.
    @Published var remoteSessions: [RemoteSessionInfo] = []
    /// TBD-owned display-name overrides for remote sessions, keyed by
    /// `AppState.remoteSessionKey(provider:sessionID:)`. Mirrors the
    /// worktree pattern (`Worktree.displayName` living in TBD's own DB
    /// rather than being derived from git) — except a remote session has no
    /// TBD-owned DB row of its own (the daemon's `remote_session` table is
    /// explicitly a drift-tracking mirror of provider-owned state, never
    /// authoritative — see `docs/remote-provider-contract.md` § Identity &
    /// drift), so this lives client-side in UserDefaults instead of a new
    /// daemon column. Emoji has no separate field, same as `Worktree` — the
    /// user types `:emoji:` inline via `RenameableLabel` and it ends up as
    /// plain leading characters in the stored string. This map is the
    /// source of truth even for a provider that declares the `rename`
    /// capability (contract v1 amendment): `renameRemoteSession(provider:
    /// sessionID:displayName:)` writes here first, then fires the provider
    /// push (`pushRemoteRenameIfSupported`) fire-and-forget, so a rename is
    /// never gated on — or rolled back by — whether that push lands.
    @Published var remoteSessionDisplayNames: [String: String] = [:] {
        didSet { persistRemoteSessionDisplayNames() }
    }

    /// Set briefly when a deep link lands on an archived worktree. The
    /// ArchivedWorktreesView observes this and scrolls/flashes the matching
    /// row, then clears the value after the flash animation completes.
    @Published var highlightedArchivedWorktreeID: UUID?

    // MARK: - Toast (deep-link feedback)

    /// The single visible in-app toast; nil when hidden. See AppState+Toast.swift.
    @Published var activeToast: Toast?
    /// One auto-dismiss tick. Tests shrink this to milliseconds.
    var toastTickDuration: Duration = .seconds(1)
    /// In-flight auto-dismiss task for `activeToast`.
    var toastDismissTask: Task<Void, Never>?

    /// Request-generation token for archived deep-link lookups. Stamped fresh
    /// at the start of every `navigateToArchivedWorktree(_:)`; a lookup that
    /// resolves after a newer deep link superseded it is dropped. Guards
    /// out-of-order RPC resolution (deep link A then B, A resolves late).
    var deepLinkRequestID: UUID?

    /// Set briefly when external navigation (notification click, deep link,
    /// jump menu) lands on an active worktree. `SidebarView` observes this
    /// to scroll the worktree row into view, then clears the value.
    @Published var pendingScrollToWorktreeID: UUID?

    /// Test seam: when set, replaces the daemon roundtrip for archived
    /// lookups in `navigateToArchivedWorktree(_:)`. Production code leaves
    /// this nil; tests assign a closure returning a deterministic worktree
    /// list — or one that throws, to exercise the RPC-failure toast branch.
    var archivedLookupOverride: ((UUID) async throws -> [Worktree])?

    /// Test seam: when set, replaces the daemon rename RPC in
    /// `renameWorktree(id:displayName:)`. Production code leaves this nil;
    /// tests assign a closure to observe the RPC path (or throw from it to
    /// exercise the rollback branch) without a live daemon.
    var renameRPCOverride: (@MainActor (UUID, String) async throws -> Void)?

    /// True once `connectAndLoadInitialState()` has finished its initial
    /// `refreshAll()` and the worktree list is populated. Used by
    /// `navigateToWorktree(_:)` to detect cold-start clicks that arrive
    /// before the daemon RPC has returned.
    @Published var isInitialStateLoaded: Bool = false

    /// Buffers a deep-link target UUID when `.onOpenURL` fires before the
    /// initial state load completes. Drained at the end of
    /// `connectAndLoadInitialState()`. Internal-only — never written from
    /// outside the AppState extension that consumes it.
    var pendingDeepLinkID: UUID?

    /// Companion to `pendingDeepLinkID`: buffers the originating terminal so
    /// cold-start clicks land on the right tab after the drain. Drained
    /// alongside `pendingDeepLinkID` at the end of
    /// `connectAndLoadInitialState()`. Internal-only — never written from
    /// outside the AppState extension that consumes it.
    var pendingDeepLinkTerminalID: UUID?

    /// Profile IDs with an "Open login session" spawn currently in flight.
    /// Guards rapid repeat clicks: the first click spawns, subsequent clicks
    /// during the RPC are dropped, and once the terminal lands in state the
    /// dedupe path in `openLoginSession` focuses it instead of spawning again.
    var loginSessionSpawnsInFlight: Set<UUID> = []

    /// Terminal IDs with a wake RPC in flight, so a rapid re-focus (or a menu
    /// "Wake" racing the auto-wake-on-focus) doesn't fire a second `terminal.wake`
    /// while the first is still respawning. The daemon singleflights too; this
    /// is the app-side first line so we don't even round-trip twice.
    var wakeInFlight: Set<UUID> = []

    /// The first selected worktree, if any.
    var selectedWorktree: Worktree? {
        guard let id = selectedWorktreeIDs.first else { return nil }
        return findWorktree(id: id)
    }

    /// The current selection, when it has files on this machine. Views that
    /// operate on a directory bind to this instead of `selectedWorktree`, so
    /// they cannot render against a worktree with no local checkout — the
    /// optimistic `.creating` placeholder (`path: ""`) included.
    var selectedLocalWorktree: LocalWorktree? {
        selectedWorktree.flatMap(LocalWorktree.init)
    }

    /// All pinned terminals across all worktrees, sorted by pinnedAt.
    var pinnedTerminals: [Terminal] {
        terminals.values.flatMap { $0 }
            .filter { $0.pinnedAt != nil }
            .sorted { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
    }

    /// Worktree IDs that have at least one terminal currently visible on screen.
    /// Includes selected worktrees (active tab visible) and worktrees with pinned terminals
    /// (always visible in either the active tab or the pinned dock).
    var visibleWorktreeIDs: Set<UUID> {
        var ids = selectedWorktreeIDs
        for terminal in pinnedTerminals {
            ids.insert(terminal.worktreeID)
        }
        return ids
    }

    /// Worktree IDs with at least one terminal currently in the `.working`
    /// activity state (an agent is actively running). These must not have their
    /// view trees torn down by keep-alive eviction — unmounting kills the
    /// on-screen tmux viewer mid-run and shows a spurious detach message.
    var workingWorktreeIDs: Set<UUID> {
        var ids = Set<UUID>()
        for (worktreeID, terminalList) in terminals
        where terminalList.contains(where: { $0.activityState == .working }) {
            ids.insert(worktreeID)
        }
        return ids
    }

    /// Worktrees that must never be evicted from the keep-alive mount set:
    /// open (selected) plus actively working. Consumed by `keepAliveWorktreeIDs`.
    ///
    /// Pinned terminals are deliberately NOT force-protected here: `PinnedTerminalDock`
    /// already keeps a pinned terminal's view alive independently. A worktree can
    /// still be protected here for being selected or working even when its
    /// active-tab terminal is pinned — the would-be double-mount of that terminal
    /// (dock cell + kept-alive pager) is prevented structurally by the
    /// `dockedTerminalIDs` dedup in `PanePlaceholder`, so the two viewers never
    /// collide on the shared `tbd-view-<id>` tmux session.
    var protectedWorktreeIDs: Set<UUID> {
        selectedWorktreeIDs.union(workingWorktreeIDs)
    }

    /// Terminal IDs rendered in the active-tab layouts of the currently selected
    /// worktree(s) — the terminals showing in the main content area. Single
    /// source of truth shared by the dock filter (`dockedTerminalIDs`) and the
    /// pager dedup. (Moved off `TerminalContainerView` so both consumers agree.)
    var visibleTerminalIDs: Set<UUID> {
        var ids = Set<UUID>()
        for worktreeID in selectedWorktreeIDs {
            guard let tab = resolvedActiveTab(worktreeID: worktreeID) else { continue }
            let layout = layouts[tab.id] ?? .pane(tab.content)
            for id in layout.allTerminalIDs() {
                ids.insert(id)
            }
        }
        return ids
    }

    /// Pinned terminal IDs that are NOT already visible in the main content area
    /// — i.e. exactly the terminals `PinnedTerminalDock` renders. The keep-alive
    /// pager must skip these (see `AppState.shouldSuppressTerminalInLayout` /
    /// `PanePlaceholder`) so a docked terminal is never mounted a second time;
    /// two `TerminalPanelView`s for one terminal would collide on the shared
    /// `tbd-view-<id>` tmux session and thrash it.
    var dockedTerminalIDs: Set<UUID> {
        let visible = visibleTerminalIDs
        return Set(pinnedTerminals.map(\.id).filter { !visible.contains($0) })
    }

    /// Whether a terminal rendered in a worktree-layout pane should be
    /// suppressed (replaced by a lightweight placeholder) because it is already
    /// owned by `PinnedTerminalDock`. Pure so the dedup decision is testable
    /// without a view tree. Applies ONLY to the layout/pager path — the dock
    /// cell renders `TerminalPanelView` directly and never routes through here.
    static func shouldSuppressTerminalInLayout(
        terminalID: UUID,
        dockedTerminalIDs: Set<UUID>
    ) -> Bool {
        dockedTerminalIDs.contains(terminalID)
    }

    @Published var dockRatio: CGFloat = 0.3 {
        didSet { userDefaults.set(Double(dockRatio), forKey: Self.dockRatioKey) }
    }
    /// "Use default without asking": when true, the plain "Claude" action
    /// spawns silently on the global default profile instead of opening the
    /// spawn-time account picker. Toggleable from the picker itself and
    /// Settings → Model Profiles. Persisted per-user.
    @Published var skipAccountPicker: Bool = false {
        didSet { userDefaults.set(skipAccountPicker, forKey: Self.skipAccountPickerKey) }
    }
    /// Pixel size of the main terminal area (the SingleWorktreeView slot
    /// inside DockSplitView, excluding the pinned dock and file panel).
    /// Default matches the typical window: 1200 wide window − sidebar (~280) ≈ 920;
    /// 800 tall window − toolbar (~24) ≈ 776. Conservative fallback for the
    /// first RPC before the GeometryReader publishes a real value.
    @Published var mainAreaSize: CGSize = CGSize(width: 1120, height: 776) {
        didSet {
            guard mainAreaSize != oldValue else { return }
            scheduleMainAreaSizeBroadcast()
        }
    }
    /// Debounce token for broadcasting `mainAreaSize` changes to the daemon.
    /// Cancelled and re-scheduled on every change so we send one RPC per
    /// resize gesture rather than per AppKit layout pass.
    private var mainAreaSizeBroadcastTask: Task<Void, Never>?
    private var lastBroadcastCols: Int = 0
    private var lastBroadcastRows: Int = 0
    @Published var isConnected: Bool = false
    @Published var layouts: [UUID: LayoutNode] = [:] {
        didSet { persistLayouts() }
    }
    /// Multi-worktree grid layouts, keyed by WORKTREE ID. Presentation-only
    /// (spec C §3.12): never persisted, never mirrored, never part of the
    /// panel surface. Kept separate from `layouts` (tab-ID-keyed) so the two
    /// keying schemes can't collide in one dictionary.
    @Published var gridLayouts: [UUID: LayoutNode] = [:]
    /// Back/forward history per viewer-class slot pane, keyed by the slot's
    /// paneID (stable across in-place content replacements).
    @Published var paneHistories: [UUID: PaneHistory] = [:] {
        didSet { persistPaneHistories() }
    }
    @Published var tabs: [UUID: [TBDShared.Tab]] = [:]
    /// EXPLICIT per-worktree tab selection. Absent (or out of range) means "no
    /// deliberate selection" — read it through `resolvedActiveTabIndex` rather
    /// than defaulting to 0 or clamping at the call site.
    @Published var activeTabIndices: [UUID: Int] = [:]
    @Published var worktreeTabOrders: [UUID: [UUID]] = [:]
    /// Worktrees whose persisted tab order / active tab has been hydrated from
    /// the daemon with actual content. Distinct from `worktreeTabOrders[id] != nil`,
    /// which is also true for the empty response a poll gets while the daemon is
    /// still mid-create — treating that as loaded stranded the worktree without
    /// its persisted "active = agent" selection for the rest of the session.
    var tabStateHydratedWorktreeIDs: Set<UUID> = []
    /// `listTabs` fetches already spent trying to hydrate a worktree, capped at
    /// `maxTabStateHydrationAttempts`. Without a cap, a worktree whose tab state
    /// is legitimately and permanently empty re-fires the RPC on every
    /// `reconcileTabs` — which is every terminal-list change — forever.
    var tabStateFetchAttempts: [UUID: Int] = [:]
    /// The in-flight hydration `Task` per worktree, so overlapping reconciles
    /// can't stack `Task`s for the same worktree. Holding the handle rather than
    /// a bare `Set<UUID>` marker means the completion of that work is directly
    /// awaitable — tests observe it with `await task.value` instead of polling
    /// wall time for the flag to clear, and only the scheduler's own `Task`
    /// clears the entry, so a direct `loadTabStates(worktreeID:)` call can no
    /// longer clear an in-flight marker it does not own.
    var tabStateFetchTasks: [UUID: Task<Void, Never>] = [:]
    /// Hydration attempt budget. The gap this covers is one poll wide — the
    /// daemon persists tab order milliseconds after inserting the terminal
    /// rows — so a single retry is always enough; the extra one is slack.
    static let maxTabStateHydrationAttempts = 3
    @Published var draggingTabID: UUID? = nil
    @Published var repoFilter: UUID? = nil
    @Published var pendingWorktreeIDs: Set<UUID> = []
    /// Worktree IDs optimistically removed by an archive that has not yet been
    /// confirmed by daemon data. `refreshWorktrees` filters these out so a
    /// `listWorktrees` poll issued before the daemon flipped the status cannot
    /// resurrect the row. Value is the time the tombstone was created, used for
    /// TTL-based eviction when an archive fails or stalls.
    var recentlyArchivedWorktreeIDs: [UUID: Date] = [:]
    @Published var suspendingTerminalIDs: Set<UUID> = []
    /// Closures registered by live TerminalPanelView instances to capture a screenshot.
    /// Keyed by terminal UUID. Populated in makeNSView, cleared on view disappear.
    var snapshotProviders: [UUID: () -> NSImage?] = [:]
    /// Weak terminal views keyed by terminal UUID, used to restore AppKit first
    /// responder after worktree navigation.
    var terminalFocusTargets: [UUID: TerminalFocusTarget] = [:]
    /// Tab-close ownership keyed by terminal UUID for views that belong to a
    /// visible tab, used to resolve the currently focused closable tab.
    var terminalTabCloseContexts: [UUID: TabCloseContext] = [:]
    /// Visual screenshots taken at suspend-click time, shown while daemon works.
    /// Keyed by terminal UUID. Cleared when suspend completes.
    @Published var suspendingSnapshots: [UUID: NSImage] = [:]

    func setSuspendingSnapshot(_ image: NSImage, for id: UUID) {
        suspendingSnapshots[id] = image
    }

    func removeSuspendingSnapshot(for id: UUID) {
        suspendingSnapshots.removeValue(forKey: id)
    }
    @Published var editingWorktreeID: UUID? = nil
    @Published var isRenamingWorktree = false
    @Published var prStatuses: [UUID: PRStatus] = [:]
    /// Every live PR bound to each worktree, in bind order — the multi-PR
    /// surface behind the toolbar dropdown. `prStatuses` remains the single
    /// worst-of summary the daemon writes to `Worktree.prStatus`; this is the
    /// full set, and the two are refreshed together.
    @Published var prBindings: [UUID: [PRBinding]] = [:]
    /// How many of each worktree's bindings are tombstoned, for the worktrees
    /// that have any (a worktree with none is absent, not zero). Refreshed in
    /// the same call as `prBindings` and kept separately because it outlives
    /// them: detaching a worktree's last PR empties `prBindings` and leaves this
    /// non-zero, which is precisely the signal that suppresses the
    /// legacy-status fallback below.
    @Published var prDetachedCounts: [UUID: Int] = [:]
    /// What every PR surface — toolbar split button, sidebar row indicator,
    /// status-bar chips — must read, so they cannot disagree about a worktree.
    /// Bindings when there are any; otherwise the legacy single `prStatuses`
    /// entry lifted into one synthetic binding, which is what keeps the control
    /// on screen when `gh` cannot resolve a repo (offline or unauthenticated)
    /// or before the first successful poll after upgrade — unless the worktree
    /// has tombstones, in which case the empty list is the user's own decision
    /// and the fallback would resurrect what they detached. See
    /// `PRBindingPresentation.effectiveBindings`.
    func effectivePRBindings(worktreeID: UUID) -> [PRBinding] {
        PRBindingPresentation.effectiveBindings(
            prBindings[worktreeID] ?? [],
            legacyStatus: prStatuses[worktreeID],
            worktreeID: worktreeID,
            detachedCount: prDetachedCounts[worktreeID] ?? 0
        )
    }
    @Published var modelProfiles: [ModelProfileWithUsage] = []
    @Published var defaultProfileID: UUID? = nil
    /// Ephemeral one-shot Codex account/usage snapshot loaded when the
    /// worktree picker opens. It is intentionally neither polled nor persisted.
    @Published var codexUsage: CodexUsageResult?
    @Published var isLoadingCodexUsage = false
    @Published var primaryAgentPreference: PrimaryAgentPreference = .defaultValue
    /// Global free-form env overrides (config scope). Loaded from the daemon
    /// alongside `defaultProfileID` via `loadModelProfiles()`.
    @Published var globalEnvOverrides: [String: String] = [:]
    /// Global default for auto-archive-on-PR-merge. Loaded from the daemon
    /// alongside `globalEnvOverrides` via `loadModelProfiles()`.
    @Published var autoArchiveOnMergeDefault: Bool = false
    /// Global default for auto-hibernate-on-PR-merge. Loaded from the daemon
    /// alongside `autoArchiveOnMergeDefault` via `loadModelProfiles()`.
    @Published var autoHibernateOnMergeDefault: Bool = false
    /// Orphan-GC master switch (Config mirror, default true to match
    /// `Config.gcEnabled`). Loaded from the daemon alongside
    /// `autoArchiveOnMergeDefault` via `loadModelProfiles()`.
    @Published var gcEnabled: Bool = true
    @Published var nightwatchMode: NightwatchMode = .off
    /// Auto-hibernate master switch. Loaded from the daemon `Config` via
    /// `loadHibernationConfig()`.
    @Published var autoHibernateEnabled: Bool = false
    /// Auto-hibernate idle timeout in minutes. Loaded from `Config`.
    @Published var hibernateIdleMinutes: Int = Config.defaultHibernateIdleMinutes
    /// Daemon-persisted gate for session-limit auto-resume (default OFF).
    /// Daemon-side (not @AppStorage) because the daemon must act while the
    /// app is closed.
    @Published var autoResumeOnLimitReset: Bool = false
    /// Daemon-persisted gate for transient-API-error auto-continue (default
    /// OFF). Daemon-side (not @AppStorage) because the daemon must act while
    /// the app is closed.
    @Published var autoResumeOnApiError: Bool = false
    /// Terminals where the user has dismissed the proxy-unreachable banner.
    /// Cleared on app relaunch (in-memory only — banners are advisory).
    @Published var dismissedProxyWarnings: Set<UUID> = []
    /// Non-nil when the connected daemon reports an executable path that
    /// doesn't belong to this app's build (another worktree's restart.sh won
    /// the shared daemon). Rendered as a persistent, non-blocking banner in
    /// ContentView. Set by `checkDaemonBuildIdentity()` on every connect, so
    /// it self-clears once a matching daemon is connected.
    @Published var daemonBuildMismatchMessage: String?
    /// User dismissed the build-mismatch banner. In-memory only (advisory);
    /// reset whenever the mismatch message changes.
    @Published var daemonBuildMismatchDismissed = false
    /// Panes currently rendered through a live control-mode attach, mapped to
    /// the attach GENERATION the record belongs to (`nil` when the daemon
    /// vended none). Maintained by `TerminalPanelRepresentable.Coordinator`
    /// (attach success inserts; detach/fallback removes). Gates the
    /// input-health indicator: it must NEVER show on a pane that isn't
    /// control-mode attached (#318 polish), whatever health deltas arrive.
    /// Generation-scoped (M3 review fix) so a closing pane's stale clear —
    /// landing after a fresh attach's set for the same pane under adverse
    /// MainActor scheduling — cannot drop a healthy pane's attached state
    /// (the app-side twin of the daemon's generation-checked detach).
    @Published private(set) var controlModeAttachedPanes: [ControlModePaneKey: UInt64?] = [:]
    /// Panes the daemon has flagged input-failing via edge-triggered
    /// `controlModeInputHealthChanged` deltas. A `healthy: true` delta or a
    /// detach clears the flag. Read through `isInputDeliveryFailing(_:)`,
    /// which applies the attached-pane gate.
    @Published private(set) var controlModeFailingInputPanes: Set<ControlModePaneKey> = []
    @Published var historyActiveWorktrees: Set<UUID> = []
    @Published var historyLoadStates: [UUID: HistoryLoadState] = [:]
    @Published var selectedSessionIDs: [UUID: String] = [:]       // worktreeID → sessionId
    @Published var sessionTranscripts: [String: [TranscriptItem]] = [:]  // sessionId → items
    @Published var sessionTranscriptLoading: Set<String> = []
    // Closed-terminal history (Session History → Closed Terminals).
    @Published var closedTerminalHistories: [UUID: [TerminalHistoryEntry]] = [:]  // worktreeID → entries
    @Published var selectedClosedTerminalIDs: [UUID: UUID] = [:]                  // worktreeID → entry id
    /// Captured text of the currently selected closed terminal only —
    /// deliberately a one-entry cache so large scrollbacks never accumulate.
    @Published var closedTerminalContents: [UUID: String] = [:]                   // entry id → text

    /// Raw most-recent-first log of recently-visited worktrees, the recency
    /// input to the keep-alive policy. Bounded by `touchVisitedWorktree`, which
    /// drops the oldest NON-protected entries past `keepAliveLimit`. The actual
    /// mount set the view consumes is the computed `keepAliveWorktreeIDs`, which
    /// re-merges the live protection set; do not feed this raw log to the pager
    /// directly.
    @Published private(set) var recentlyVisitedWorktreeIDs: [UUID] = []

    /// LRU of recently-selected worktrees consumed by the cmd-K jump menu.
    /// Distinct from `recentlyVisitedWorktreeIDs` (which has a much smaller
    /// cap and drives the SingleWorktreeView keep-alive cache). In-memory
    /// only — resets on app relaunch, matching Slack's "Recent" semantics.
    @Published private(set) var recentWorktreeIDs: [UUID] = []

    private static let recentWorktreeCap = 32

    private let keepAliveLimit = 8

    // MARK: - Remote attach lifecycle (see `AppState+RemoteAttach.swift`)

    /// Raw most-recent-first log of recently-VIEWED remote sessions, the
    /// recency input to `RemoteAttachLifecycle.attachedSelections`. Mirrors
    /// `recentlyVisitedWorktreeIDs`'s split from the computed mount set —
    /// `attachedRemoteSelections` re-merges the current selection (protected)
    /// and eligibility/detach state on every read, so this log alone doesn't
    /// say what's actually attached right now.
    @Published private(set) var recentlyAttachedRemoteSessions: [RemoteSessionSelection] = []

    /// Sessions whose attach terminal ended (pty exit — clean or not; the
    /// pane exiting never means the remote session died, only that the
    /// LOCAL viewer process stopped) and must NOT be silently re-attached
    /// merely by staying the current selection. Cleared only by an explicit
    /// user gesture — see `activateRemoteSession`'s doc comment for exactly
    /// which gestures qualify, and `reattachRemoteSession` for the Reattach
    /// button's path. This is the state that makes "select = auto-attach"
    /// safe: without it, a pty exiting while its row is still selected would
    /// re-enter `attachedRemoteSelections` (still protected) and the pager
    /// would spawn a fresh process every render, an unbounded respawn loop
    /// against a resource this codebase must not spam (SSM/ssh concurrency
    /// and cost — see `RemoteAttachLifecycle`'s doc comment).
    @Published private(set) var explicitlyDetachedRemoteSessions: [RemoteSessionSelection: RemoteAttachDetachInfo] = [:]

    /// Sessions whose attach terminal ended UNEXPECTEDLY (nonzero/unreadable
    /// exit — `RemoteAttachTerminalView.isUnexpectedExit`) — the transport's
    /// fault, not a user detach. Distinct from `explicitlyDetachedRemoteSessions`
    /// in how it clears: instead of requiring a user gesture, entries here
    /// clear THEMSELVES the moment `RemoteReconnectPolicy.isBlocked` stops
    /// excluding them — i.e. once their provider reports healthy again and
    /// this entry's own backoff window has elapsed (see that type's doc
    /// comment). `AppState.attachedRemoteSelections` recomputes this
    /// evaluation on every read, driven by the app's existing provider-health
    /// poll cycle — no dedicated timer. Still respects every other
    /// constraint `explicitlyDetached` does (capability gating, `gone`/
    /// `dismissed` exclusion, and above all `remoteAttachKeepAliveLimit`),
    /// so a laptop waking from a long outage can't reattach more than the
    /// cap at once even with many pending entries at once.
    @Published private(set) var pendingReconnectRemoteSessions: [RemoteSessionSelection: RemotePendingReconnect] = [:]

    /// Cap on how many WARM BACKGROUND remote sessions may keep a live
    /// attach terminal around at once. The current selection is separately
    /// force-protected (see `RemoteAttachLifecycle`) and does NOT consume
    /// this budget, so the real ceiling on concurrent provider `attach`
    /// processes is `remoteAttachKeepAliveLimit + 1` — 4 at the constant's
    /// current value of 3 — which matters because this is exactly the
    /// billed, concurrency-limited resource the rest of this comment is
    /// about. Deliberately SMALLER than `keepAliveLimit` (the local
    /// worktree cap, 8) even though both share the same protected-selection
    /// + capped-recency shape: a warm LOCAL tmux attach is free (the daemon
    /// already keeps the tmux session running regardless), but a warm
    /// REMOTE attach is a real, live connection to another machine — for an
    /// SSM- or ssh-backed provider, a billed and concurrency-limited
    /// resource — that buys nothing the user can see, since awareness of a
    /// remote session's state rides the provider's shared events/poll
    /// channel, not its per-session attach. A smaller cap only costs
    /// reattach latency (a fresh spawn instead of an already-warm one) when
    /// switching back to a session evicted past the cap. Easy
    /// single-constant tuning point if the maintainer wants it different
    /// after soaking — but remember any change moves the REAL ceiling by
    /// the same amount, one more than this constant's value.
    let remoteAttachKeepAliveLimit = 3

    /// Move `selection` to the front of the attach-recency log, trimming it
    /// so it never grows unbounded over a long-running app session. Mirrors
    /// `touchVisitedWorktree`'s shape; unlike that function this trim is
    /// purely a bound on the stored log's length (there's no "working"-style
    /// force-protection budget to interact with here — only the current
    /// selection is ever force-protected by `RemoteAttachLifecycle`, and it
    /// doesn't consume this log's slots any more than a worktree's
    /// protection consumes `recentlyVisitedWorktreeIDs`'s).
    func touchAttachedRemoteSession(_ selection: RemoteSessionSelection) {
        recentlyAttachedRemoteSessions.removeAll { $0 == selection }
        recentlyAttachedRemoteSessions.insert(selection, at: 0)
        let cap = remoteAttachKeepAliveLimit + 1 // +1 headroom for "selected but not yet re-touched"
        if recentlyAttachedRemoteSessions.count > cap {
            recentlyAttachedRemoteSessions.removeLast(recentlyAttachedRemoteSessions.count - cap)
        }
    }

    /// Records that `selection`'s attach terminal ended — called from the
    /// pager's `onDetached` bridge. Per the contract
    /// (`docs/remote-provider-contract.md` § `attach`), this NEVER means the
    /// remote session died, only that the local viewer process stopped;
    /// `remoteSessions`/`gone` remain the only authoritative source for the
    /// session's actual fate.
    ///
    /// Branches on `RemoteAttachExitClass.classify(exitCode:)` — the
    /// three-way split of the contract's error model — to decide which
    /// "don't respawn yet" mechanism applies:
    ///
    /// - **Clean exit** (0 or unreadable, the user deliberately detached) →
    ///   `explicitlyDetachedRemoteSessions`, cleared only by an explicit
    ///   gesture (see `activateRemoteSession` in `AppState+Navigation.swift`,
    ///   and `reattachRemoteSession` below).
    /// - **Unexpected exit** (a network drop or crashed shim, not a user
    ///   choice) → `pendingReconnectRemoteSessions`, which clears ITSELF once
    ///   the provider is healthy again and this entry's backoff window has
    ///   elapsed (`RemoteReconnectPolicy`) — no Reattach click required. Any
    ///   pre-existing pending entry for this selection has its `attempts`
    ///   incremented (a session that keeps failing immediately after each
    ///   automatic retry backs off further each time).
    /// - **Auth-needed exit** (exit class 4 — the provider can't
    ///   authenticate) → the SAME escalating `pendingReconnectRemoteSessions`
    ///   entry as an unexpected exit, so it self-clears once health recovers
    ///   with no user gesture. In the normal flow the escalation never
    ///   actually bites: there is exactly one auth exit, because
    ///   `RemoteReconnectPolicy.isBlocked` then refuses every retry while
    ///   health is `.needsAuth`, so `attempts` stays 1 and re-authentication
    ///   is followed by a prompt reattach. It only climbs in the
    ///   pathological case where `list` authenticates but `attach` doesn't —
    ///   which is exactly the respawn loop that needs a bound. See
    ///   `RemoteReconnectPolicy.nextPending`.
    ///
    ///   Only this class additionally reports the exit to the daemon
    ///   (fire-and-forget) so provider health picks up the auth state
    ///   without waiting for the next 60s poll. The two classes stay
    ///   distinct in every OTHER respect — an auth exit is never worded as
    ///   an unexpected session exit (see
    ///   `RemoteAttachTerminalView.isUnexpectedExit`).
    ///
    /// Either way `selection` is excluded from `attachedRemoteSelections`
    /// until its respective clearing condition is met — the rule that
    /// prevents a respawn loop while the row stays selected.
    func markRemoteSessionDetached(_ selection: RemoteSessionSelection, exitCode: Int32?) {
        switch RemoteAttachExitClass.classify(exitCode: exitCode) {
        case .unexpected:
            pendingReconnectRemoteSessions[selection] = RemoteReconnectPolicy.nextPending(
                exitCode: exitCode, previous: pendingReconnectRemoteSessions[selection], now: Date()
            )
        case .authNeeded:
            pendingReconnectRemoteSessions[selection] = RemoteReconnectPolicy.nextPending(
                exitCode: exitCode, previous: pendingReconnectRemoteSessions[selection], now: Date()
            )
            reportRemoteAttachExit(selection, exitCode: exitCode)
        case .clean:
            explicitlyDetachedRemoteSessions[selection] = RemoteAttachDetachInfo(exitCode: exitCode)
            // A clean detach always wins over any stale pending-reconnect
            // bookkeeping from an earlier flapping run — the user's clean
            // exit is the more recent, more authoritative signal.
            pendingReconnectRemoteSessions.removeValue(forKey: selection)
        }
    }

    /// The explicit "Reattach" affordance shown by `RemoteSessionDetailView`
    /// once a session has detached. Clears BOTH detach flags AND re-touches
    /// recency (so a session that had aged toward eviction gets a fresh
    /// position at the front) — an unambiguous user gesture, always allowed
    /// to re-attach immediately regardless of the transition/`.attach`-tab
    /// rule `activateRemoteSession` applies to selection itself, and
    /// regardless of any still-pending reconnect backoff window.
    func reattachRemoteSession(_ selection: RemoteSessionSelection) {
        explicitlyDetachedRemoteSessions.removeValue(forKey: selection)
        pendingReconnectRemoteSessions.removeValue(forKey: selection)
        touchAttachedRemoteSession(selection)
    }

    /// Clears a stale explicit-detach flag for `selection`, if present —
    /// the narrow write `activateRemoteSession` (in
    /// `AppState+Navigation.swift`) needs for its transition/`.attach`-tab
    /// rule, kept here (not duplicated) so `explicitlyDetachedRemoteSessions`
    /// has exactly one file's worth of direct mutators. Deliberately does
    /// NOT touch `pendingReconnectRemoteSessions` — re-selecting (even via a
    /// genuine transition) must not bypass provider-health/backoff gating
    /// the way an explicit Reattach click does; see `reattachRemoteSession`.
    func clearRemoteSessionDetachedFlag(_ selection: RemoteSessionSelection) {
        explicitlyDetachedRemoteSessions.removeValue(forKey: selection)
    }

    /// Drops attach-lifecycle bookkeeping for sessions the daemon no longer
    /// reports — called from `pruneRemoteSessionState` alongside its other
    /// maps, for the same reason: without this, `explicitlyDetachedRemoteSessions`,
    /// `pendingReconnectRemoteSessions`, and `recentlyAttachedRemoteSessions`
    /// would accumulate dead entries for the lifetime of the app.
    func pruneRemoteAttachState(toKnownSelections selections: Set<RemoteSessionSelection>) {
        explicitlyDetachedRemoteSessions = explicitlyDetachedRemoteSessions.filter { selections.contains($0.key) }
        pendingReconnectRemoteSessions = pendingReconnectRemoteSessions.filter { selections.contains($0.key) }
        recentlyAttachedRemoteSessions = recentlyAttachedRemoteSessions.filter { selections.contains($0) }
    }

    /// Move `id` to the front of `recentlyVisitedWorktreeIDs`, then trim the LRU
    /// so it never grows unbounded. Protected worktrees (`protectedWorktreeIDs`)
    /// are never evicted here — only the oldest NON-protected entries past
    /// `keepAliveLimit` are dropped. The live mount set is computed separately
    /// by `keepAliveWorktreeIDs` (which re-merges the protection set), so this
    /// trim only bounds the stored recency log. Idempotent.
    func touchVisitedWorktree(_ id: UUID) {
        recentlyVisitedWorktreeIDs.removeAll { $0 == id }
        recentlyVisitedWorktreeIDs.insert(id, at: 0)
        let protected = protectedWorktreeIDs
        var nonProtectedKept = 0
        recentlyVisitedWorktreeIDs.removeAll { entry in
            if protected.contains(entry) { return false }
            nonProtectedKept += 1
            return nonProtectedKept > keepAliveLimit
        }
    }

    /// The worktree IDs whose view trees should be kept mounted, most-recent
    /// first. This is what `WorktreePager` consumes.
    ///
    /// Semantics: protected worktrees (`protectedWorktreeIDs` — open/selected
    /// or actively working) are ALWAYS kept, regardless of age, and do NOT
    /// consume the non-protected budget. In addition, up to `keepAliveLimit`
    /// most-recently-visited NON-protected worktrees are kept as a warm cache.
    /// Decoupling the budgets means a burst of working background worktrees can
    /// never starve the recency cache, and a freshly-protected worktree that had
    /// aged out of the recency log is re-mounted. Because this is a computed
    /// property, it is re-evaluated on every render, so eviction always reflects
    /// the live protection set (a worktree that starts/stops working, or is
    /// selected/deselected, is re-protected/released without needing an explicit
    /// visit). Pinned-only worktrees are intentionally NOT protected here — see
    /// `protectedWorktreeIDs` for why.
    var keepAliveWorktreeIDs: [UUID] {
        Self.keepAliveWorktreeIDs(
            recentlyVisited: recentlyVisitedWorktreeIDs,
            protected: protectedWorktreeIDs,
            limit: keepAliveLimit
        )
    }

    /// Pure keep-alive policy (see `keepAliveWorktreeIDs`). Extracted as a
    /// static function so the eviction decision is unit-testable without an
    /// AppKit/SwiftUI view tree.
    static func keepAliveWorktreeIDs(
        recentlyVisited: [UUID],
        protected: Set<UUID>,
        limit: Int
    ) -> [UUID] {
        var result: [UUID] = []
        var seen = Set<UUID>()
        var nonProtectedKept = 0
        for id in recentlyVisited {
            guard !seen.contains(id) else { continue }
            if protected.contains(id) {
                result.append(id)
                seen.insert(id)
            } else if nonProtectedKept < limit {
                result.append(id)
                seen.insert(id)
                nonProtectedKept += 1
            }
            // Older non-protected entries beyond the cap are dropped (evicted).
        }
        // Protected worktrees that were never visited (or aged out of the
        // recency log before becoming protected) must still be mounted.
        for id in protected where !seen.contains(id) {
            result.append(id)
            seen.insert(id)
        }
        return result
    }

    /// Insertion/access order for `sessionTranscripts`. The most recently
    /// touched sessionID is at the END. Evict from the FRONT when the cap
    /// is exceeded.
    private var sessionTranscriptOrder: [String] = []
    private let sessionTranscriptCap = 50

    /// Touch a sessionID — moves it to most-recently-used, evicts the LRU
    /// entry if we're over the cap. Call this whenever an entry in
    /// sessionTranscripts is added or updated.
    func touchSessionTranscript(_ sessionID: String) {
        if let existingIdx = sessionTranscriptOrder.firstIndex(of: sessionID) {
            sessionTranscriptOrder.remove(at: existingIdx)
        }
        sessionTranscriptOrder.append(sessionID)
        while sessionTranscriptOrder.count > sessionTranscriptCap {
            let evict = sessionTranscriptOrder.removeFirst()
            sessionTranscripts.removeValue(forKey: evict)
        }
    }

    /// Selected archived worktree per repo (left rail of the archived view's nested master-detail).
    @Published var selectedArchivedWorktreeIDs: [UUID: UUID] = [:]

    /// Selected "Reclaimed" (orphan-GC reap record) row per repo, in the same
    /// left rail as `selectedArchivedWorktreeIDs`. The two are mutually
    /// exclusive per repo — use `selectArchivedWorktree(_:repoID:)` /
    /// `selectReapRecord(_:repoID:)` (AppState+Worktrees.swift) to change
    /// either, which keep that invariant instead of mutating these
    /// dictionaries directly.
    @Published var selectedReapRecordIDs: [UUID: UUID] = [:]

    /// Worktrees the user just revived from the archived view. Keeps the row
    /// visible with a status indicator until the user navigates away from the
    /// archived section. Cleared by `AppState+Navigation` when the active
    /// sidebar selection moves elsewhere.
    @Published var revivingArchived: [UUID: ReviveState] = [:]

    /// Terminal IDs currently being recreated — prevents duplicate RPC calls.
    var recreatingTerminalIDs: Set<UUID> = []

    /// Terminal deletions waiting for an already-dispatched recreation RPC to
    /// finish. This set is bounded by `recreatingTerminalIDs` and is cleared
    /// when the matching recreation completes.
    var terminalDeletionsAwaitingRecreationCompletion: Set<UUID> = []

    /// Short-lived guard against daemon responses that were already in flight
    /// when a terminal was deleted. Pruned on every mutation and adoption.
    var recentlyDeletedTerminalIDs: [UUID: Date] = [:]

    /// App-lifetime automatic recovery attempts, keyed by stable terminal UUID.
    /// View/coordinator reconstruction must not reset this budget.
    var terminalRecoveryBudget = TerminalRecoveryBudget()

    // Alert state for user feedback
    @Published var alertMessage: String? = nil
    @Published var alertIsError: Bool = false

    @Published private(set) var tmuxExecutableResolution: TmuxExecutableResolution?
    @Published private(set) var savedTmuxExecutablePath: String?
    @Published private(set) var isTmuxLocationPromptPresented = false
    private var hasCheckedTmuxAvailabilityAtStartup = false

    let themeStore = ThemeStore()

    let daemonClient = DaemonClient()
    let tmuxExecutableResolver: TmuxExecutableResolver
    let tmuxBridge: TmuxBridge
    /// App-scoped owner of control-mode stream readers (Phase 2 FD vending).
    /// Lives here — not on any view — so SwiftUI view destruction cannot tear
    /// down an active reader. Keyed by `FDVendHeader.routingKey`.
    let controlModeReaders = ControlModeReaderRegistry()
    /// Feature flags fetched from the daemon at connect time. Nil until the
    /// first successful fetch — treated as "control mode off". The app cannot
    /// derive these locally: it is launched via `open`, which drops shell env.
    /// Published so the Settings control-mode toggle re-renders after
    /// `setControlModeEnabled` refreshes it.
    @Published var daemonCapabilities: DaemonCapabilitiesResult?
    /// How `refreshDaemonCapabilities()` fetches — injectable because
    /// `DaemonClient` is concrete (no protocol), so state-level tests stub the
    /// RPC here. Production default asks the daemon; nil result = fetch failed.
    lazy var daemonCapabilitiesFetcher: @MainActor () async -> DaemonCapabilitiesResult? =
        { [daemonClient] in try? await daemonClient.daemonCapabilities() }
    /// How `reviveConversationOnFreshBranch` asks the daemon to create the
    /// destination worktree and resume its selected session. Injectable so
    /// AppState tests can exercise the action without a live daemon.
    lazy var freshConversationReviver:
        @MainActor (UUID, String, Int?, Int?) async throws
            -> WorktreeReviveConversationFreshResult = { [daemonClient] worktreeID, sessionID, cols, rows in
                try await daemonClient.reviveConversationOnFreshBranch(
                    worktreeID: worktreeID,
                    sessionID: sessionID,
                    cols: cols,
                    rows: rows
                )
            }
    /// How `setControlModeEnabled` persists the flag — injectable for the same
    /// reason as `daemonCapabilitiesFetcher` (`DaemonClient` is concrete, no
    /// protocol), so the Settings-toggle tests can exercise the success branch.
    lazy var controlModeSetter: @MainActor (Bool) async throws -> Void =
        { [daemonClient] enabled in try await daemonClient.setControlMode(enabled: enabled) }
    /// How `setHibernateInputVetoEnabled` persists the flag — injectable for
    /// the same reason as `controlModeSetter`.
    lazy var hibernateInputVetoSetter: @MainActor (Bool) async throws -> Void =
        { [daemonClient] enabled in try await daemonClient.setHibernateInputVeto(enabled: enabled) }
    /// How `setAutoCloseSetupEnabled` persists the flag — injectable for the
    /// same reason as `controlModeSetter`.
    lazy var autoCloseSetupSetter: @MainActor (Bool) async throws -> Void =
        { [daemonClient] enabled in try await daemonClient.setAutoCloseSetup(enabled: enabled) }
    /// How `setAutoTrustWorktrees` persists the flag — injectable for the
    /// same reason as `controlModeSetter`.
    lazy var autoTrustWorktreesSetter: @MainActor (Bool) async throws -> Void =
        { [daemonClient] enabled in try await daemonClient.setAutoTrustWorktrees(enabled: enabled) }
    /// How `setQueuedPromptEnabled` persists the queued-prompt soak flag —
    /// injectable for the same reason as `controlModeSetter`.
    lazy var queuedPromptFlagSetter: @MainActor (Bool) async throws -> Void =
        { [daemonClient] enabled in try await daemonClient.setQueuedPrompt(enabled: enabled) }
    /// The worktree a queued prompt is being composed for, driving
    /// `ContentView`'s `.sheet(item:)`. Non-nil only while the modal is up, and
    /// only ever set when the daemon reports `queuedPromptEnabled`
    /// (design 2026-08-10). Setting it to nil is what Escape does — and parks
    /// nothing.
    ///
    /// Never assigned directly by a creation path: `presentQueuedPrompt` owns
    /// it, so a second Cmd+N cannot replace a modal the operator is typing in.
    /// The observer is on the *property* rather than on a dismissal method
    /// because `.sheet(item:)` writes the nil itself when the sheet closes —
    /// submit, Cancel and Escape all arrive that way and none of them can be
    /// asked to call something first.
    @Published var queuedPromptTarget: QueuedPromptTarget? {
        didSet {
            if queuedPromptTarget == nil { advanceQueuedPromptBacklog() }
        }
    }
    /// Creation targets waiting for the presented modal to close, oldest first.
    ///
    /// Two rapid Cmd+N presses create two worktrees, and each deserves its own
    /// first message. Replacing `queuedPromptTarget` in place would orphan the
    /// first — `.sheet(item:)` swapping a live item is unreliable on macOS, so
    /// the operator can be left typing into a modal bound to the *previous*
    /// target. They queue instead.
    var queuedPromptBacklog: [QueuedPromptTarget] = []
    /// The parked prompt being read back, sharing `ContentView`'s single
    /// prompt `.sheet(item:)` with the compose modal. A prompt that could not
    /// be delivered stays in the `worktree.pending_prompt` column; this is how
    /// the operator gets it back (design 2026-08-10, "Undeliverable prompts").
    ///
    /// Closing it frees the shared sheet slot, so a creation that queued behind
    /// it can open — the same observer `queuedPromptTarget` carries, for the
    /// same reason.
    @Published var parkedPromptReadback: ParkedPromptReadback? {
        didSet {
            if parkedPromptReadback == nil { advanceQueuedPromptBacklog() }
        }
    }
    /// True while a Deliver-now RPC is outstanding, disabling the button.
    /// Parking is not idempotent from the agent's point of view — a second
    /// click parks the same text again, and the daemon delivers what it is
    /// told, so the operator's message arrives twice.
    @Published var parkedPromptDeliveryInFlight = false
    /// How the read-back's Copy button reaches the pasteboard. Injectable so
    /// tests never write to the developer's real pasteboard.
    lazy var pasteboardWriter: @MainActor (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    /// How `createWorktree` dispatches `worktree.create` — injectable for the
    /// same reason as `daemonCapabilitiesFetcher` (`DaemonClient` is concrete,
    /// no protocol), so the queued-prompt tests can pin the RPC ordering
    /// without a live daemon.
    lazy var worktreeCreator: @MainActor (WorktreeCreateRequest) async throws -> Worktree =
        { [daemonClient] request in
            try await daemonClient.createWorktree(
                repoID: request.repoID,
                branch: request.branch,
                displayName: request.displayName,
                cols: request.cols,
                rows: request.rows,
                parentWorktreeID: request.parentWorktreeID,
                useExistingBranch: request.useExistingBranch,
                profileID: request.profileID,
                model: request.model,
                primaryAgentPreference: request.primaryAgentPreference,
                prNumber: request.prNumber,
                checkoutPRHead: request.checkoutPRHead
            )
        }
    /// How `submitQueuedPrompt` parks the composed text — injectable for the
    /// same reason as `worktreeCreator`.
    /// A `nil` text unparks — the daemon clears the column and disarms any
    /// wait — which is how the composer's Discard reaches the store without a
    /// verb of its own.
    lazy var pendingPromptSetter:
        @MainActor (UUID, String?, Bool) async throws -> WorktreeSetPendingPromptResult =
            { [daemonClient] worktreeID, text, submit in
                try await daemonClient.setPendingPrompt(
                    worktreeID: worktreeID, text: text, submit: submit)
            }
    /// Asks the user to confirm closing a note tab whose note has content —
    /// closing a note tab hard-deletes the note row (`closeTab` →
    /// `deleteNote`). Injectable so tests can exercise both branches without
    /// a real modal NSAlert.
    lazy var noteCloseConfirmer: @MainActor (Note) -> Bool = { note in
        let filePath = TBDConstants.noteContentPath(worktreeID: note.worktreeID, noteID: note.id)
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close note \u{201C}\(note.title)\u{201D}?"
        alert.informativeText = "Closing this tab removes the note from TBD. Its contents are kept on disk at \(filePath)."
        alert.addButton(withTitle: "Close Note")
        alert.addButton(withTitle: "Cancel")
        // HIG: destructive action shouldn't be the Return-key default (same
        // pattern as LegacyHooksCoordinator's migrate dialog).
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// How `refreshPRBindings` fetches the whole fleet's PR bindings —
    /// injectable for the same reason as `daemonCapabilitiesFetcher`
    /// (`DaemonClient` is concrete, no protocol), so a poll can be driven
    /// without a daemon.
    lazy var prBindingsFetcher: @MainActor () async throws -> PRBindingsAllResult =
        { [daemonClient] in try await daemonClient.listAllPRBindings() }
    /// How `loadTabStates` fetches a worktree's persisted tab order / labels /
    /// active tab — injectable for the same reason as `daemonCapabilitiesFetcher`
    /// (`DaemonClient` is concrete, no protocol), so hydration tests can drive
    /// the sequence of responses without a daemon.
    lazy var tabStatesFetcher: @MainActor (UUID) async throws -> TabListResponse =
        { [daemonClient] worktreeID in try await daemonClient.listTabs(worktreeID: worktreeID) }
    /// How the one-shot legacy panel import fires its RPC — injectable for the
    /// same reason as `daemonCapabilitiesFetcher` (`DaemonClient` is concrete,
    /// no protocol), so trigger tests can record calls without a real daemon.
    lazy var panelImportTrigger: @MainActor (PanelImportParams) async throws -> PanelImportResult =
        { [daemonClient] params in try await daemonClient.panelImportLegacy(params) }
    /// How the shadow-compare diagnostic (spec C §11.3) fetches the daemon's
    /// imported surface — injectable for the same reason as `panelImportTrigger`.
    lazy var panelGetFetcher: @MainActor (UUID) async throws -> PanelGetResult =
        { [daemonClient] worktreeID in try await daemonClient.panelGet(worktreeID: worktreeID) }
    /// Guards the one-shot legacy panel import to at most once per launch.
    /// Deliberately NOT persisted — the daemon's create-if-absent import guard
    /// (spec C §11.2) is the real idempotence boundary; this only avoids
    /// redundant RPC fan-out as `loadTabStates` runs per worktree.
    private var hasAttemptedPanelImport = false
    /// How `refreshRemote()` fetches the provider roster — injectable for the
    /// same reason as `daemonCapabilitiesFetcher` (`DaemonClient` is concrete,
    /// no protocol), so tests can exercise the disabled-refusal and
    /// genuine-error branches without a real daemon.
    lazy var remoteProvidersFetcher: @MainActor () async throws -> RemoteProvidersResult =
        { [daemonClient] in try await daemonClient.remoteProviders() }
    /// How `refreshRemote()` fetches the session mirror — injectable for the
    /// same reason as `remoteProvidersFetcher`.
    lazy var remoteSessionsFetcher: @MainActor () async throws -> RemoteSessionsResult =
        { [daemonClient] in try await daemonClient.remoteSessions() }
    /// How `pushRemoteRenameIfSupported` pushes a rename to the provider —
    /// injectable for the same reason as `remoteProvidersFetcher` (`DaemonClient`
    /// is concrete, no protocol), so tests can assert whether it fires per
    /// capability without a real daemon.
    lazy var remoteRenamePusher: @MainActor (String, String, String) async throws -> Void =
        { [daemonClient] provider, sessionID, title in
            try await daemonClient.remoteRename(provider: provider, sessionID: sessionID, title: title)
        }
    /// How `setRemoteBackendsEnabled` persists the remote-backends master
    /// switch — injectable for the same reason as `controlModeSetter`
    /// (`DaemonClient` is concrete, no protocol), so the Settings toggle
    /// tests can exercise the success branch without a real daemon.
    lazy var remoteBackendsSetter: @MainActor (Bool) async throws -> Void =
        { [daemonClient] enabled in try await daemonClient.setRemoteBackends(enabled: enabled) }
    /// How `setRemoteSessionPinned` pins/unpins a remote session for the
    /// sidebar dock — injectable for the same reason as `remoteRenamePusher`,
    /// so the pin action's success and failure branches are testable without
    /// a real daemon.
    lazy var remoteSessionPinSetter: @MainActor (String, String, Bool) async throws -> Void =
        { [daemonClient] provider, sessionID, pinned in
            try await daemonClient.setRemoteSessionPin(
                provider: provider, sessionID: sessionID, pinned: pinned)
        }

    /// How `reportRemoteAttachExit` tells the daemon an app-spawned `attach`
    /// exited — injectable for the same reason as `remoteSessionPinSetter`
    /// (`DaemonClient` is concrete, no protocol), so the auth-exit routing
    /// tests can assert the report fires without a real daemon (tests must
    /// never touch `~/tbd`).
    lazy var remoteAttachExitReporter: @MainActor (String, String, Int32) async throws -> Void =
        { [daemonClient] provider, sessionID, exitCode in
            try await daemonClient.reportRemoteAttachExit(
                provider: provider, sessionID: sessionID, exitCode: exitCode)
        }

    /// Best-effort re-fetch of `daemonCapabilities` (R7-minor). Used by the
    /// `.modelProfilesChanged` delta handler so a control-mode toggle from
    /// ANOTHER client propagates here without waiting for a reconnect. Keeps
    /// the last known value on failure: the delta fires for many config
    /// changes, and a transient RPC hiccup must not nil out good capabilities
    /// (new panes would silently fall back to grouped sessions).
    func refreshDaemonCapabilities() async {
        if let capabilities = await daemonCapabilitiesFetcher() {
            daemonCapabilities = capabilities
        }
    }
    lazy var cliInstallerCoordinator = CLIInstallerCoordinator(daemonClient: daemonClient, userDefaults: userDefaults)
    lazy var legacyHooksCoordinator = LegacyHooksCoordinator(daemonClient: daemonClient, userDefaults: userDefaults)
    private var pollTimer: Timer?
    private var pollCycle = 0
    /// True while a poll refresh cycle (the list RPCs) is running. The 2s poll
    /// timer skips its refresh when this is set, so overlapping cycles can't
    /// stack into an RPC storm when the daemon is slow (Layer A guard).
    private var pollCycleInFlight = false
    /// Count of poll ticks skipped because a previous cycle was still in flight.
    /// Storm indicator for observability and tests.
    private(set) var skippedPollCycles = 0
    private var subscriptionTask: Task<Void, Never>?
    let notificationSoundPlayer = NotificationSoundPlayer()
    let macNotificationManager = MacNotificationManager()

    private static let layoutsKey = "com.tbd.app.layouts"
    private static let paneHistoriesKey = "com.tbd.app.paneHistories"
    private static let dockRatioKey = "com.tbd.app.dockRatio"
    private static let selectionOrderKey = "com.tbd.app.selectionOrder"
    private static let skipAccountPickerKey = "com.tbd.app.accountPicker.useDefaultWithoutAsking"
    private static let remoteSessionDisplayNamesKey = "com.tbd.app.remoteSessionDisplayNames"

    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var focusObservers: [NSObjectProtocol] = []

    /// UserDefaults domain this AppState reads instance-level preferences from.
    /// Production uses `.standard`; tests inject a per-suite `UserDefaults(suiteName:)`
    /// so they never clobber the developer's running app preferences.
    let userDefaults: UserDefaults

    init(
        userDefaults: UserDefaults = .standard,
        tmuxExecutableResolver: TmuxExecutableResolver = TmuxExecutableResolver()
    ) {
        self.userDefaults = userDefaults
        self.tmuxExecutableResolver = tmuxExecutableResolver
        self.tmuxBridge = TmuxBridge(tmuxExecutableResolver: tmuxExecutableResolver)
        self.tmuxExecutableResolution = tmuxExecutableResolver.resolve()
        self.savedTmuxExecutablePath = tmuxExecutableResolver.savedPath
        restoreLayouts()
        restorePaneHistories()
        restoreRemoteSessionDisplayNames()
        if let saved = userDefaults.object(forKey: Self.dockRatioKey) as? Double {
            dockRatio = max(0.1, min(0.6, CGFloat(saved)))
        }
        skipAccountPicker = userDefaults.bool(forKey: Self.skipAccountPickerKey)
        startMemoryPressureMonitor()
        registerFocusObservers()
        // Give the notification manager a back-reference so banner clicks
        // can call navigateToWorktree. All stored properties are now
        // initialized, so `self` is fully usable here.
        macNotificationManager.configure(appState: self)
        themeStore.reloadFromDisk()
        themeStore.startWatching()
        // Under `swift test`, the per-test `AppState()` instances would each
        // spawn a subscription Task that blocks indefinitely in `recv()` on
        // the daemon socket. With enough tests the Swift cooperative thread
        // pool saturates and the test runner deadlocks. Production is
        // unbundled (no .xctest in args), so this guard is a no-op there.
        if !Self.isRunningUnderTests {
            Task {
                await connectAndLoadInitialState()
                // Eager ensure: a macOS-driven relaunch (reboot + Spotlight, OS
                // "quit and reopen") often finds the daemon dead with stale
                // socket/pid files. `connectAndLoadInitialState`'s plain connect
                // can't clear those, so recovery would otherwise wait for the
                // 2s poll to route to the cleanup-aware spawn. Run it now.
                if !isConnected {
                    await startDaemonAndConnect()
                }
                startPolling()
            }
        }
    }

    func refreshTmuxExecutableState() {
        savedTmuxExecutablePath = tmuxExecutableResolver.savedPath
        tmuxExecutableResolution = tmuxExecutableResolver.resolve()
    }

    func checkTmuxAvailabilityAtStartup() {
        guard !hasCheckedTmuxAvailabilityAtStartup else { return }
        hasCheckedTmuxAvailabilityAtStartup = true
        refreshTmuxExecutableState()
        TmuxStartupResolutionDiagnostic(resolution: tmuxExecutableResolution).log()
        isTmuxLocationPromptPresented = tmuxExecutableResolution == nil
    }

    func dismissTmuxLocationPrompt() {
        isTmuxLocationPromptPresented = false
    }

    func saveTmuxExecutableFallback(_ path: String) throws {
        try tmuxExecutableResolver.save(path)
        refreshTmuxExecutableState()
        isTmuxLocationPromptPresented = false
    }

    func clearTmuxExecutableFallback() throws {
        try tmuxExecutableResolver.clear()
        refreshTmuxExecutableState()
    }

    /// True when this process is a SwiftPM / XCTest test harness. Detected by
    /// looking for a `.xctest` bundle path in the process arguments, which
    /// both XCTest and Swift Testing (via `swiftpm-testing-helper`) pass.
    private static let isRunningUnderTests: Bool = {
        ProcessInfo.processInfo.arguments.contains { $0.contains(".xctest") }
    }()

    // Note: AppState is singleton-lifetime in this app, so we deliberately
    // omit a deinit that removes the focus observers — Swift 6 concurrency
    // would require Sendable on the observer tokens to touch them from a
    // nonisolated deinit, and the leak is bounded by app lifetime.

    /// Forward macOS app focus changes to the daemon. The daemon uses this to
    /// pause/resume the Claude usage poller and to pick the git polling
    /// cadence (fast foreground / slow background) while the app is inactive.
    /// `NotificationCenter.addObserver` does not require a bundle ID, so this
    /// is safe to call from an unbundled SPM executable.
    private func registerFocusObservers() {
        let center = NotificationCenter.default
        let active = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Dismiss banners for any worktree that is already visible so
            // stale Notification Center entries are cleared when TBD comes
            // to the foreground. The observer runs on .main, but the closure
            // is Sendable from Swift 6's view — hop via assumeIsolated.
            MainActor.assumeIsolated {
                self.macNotificationManager.dismissDelivered(worktreeIDs: self.visibleWorktreeIDs)
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.daemonClient.setAppForegroundState(isForeground: true)
                } catch {
                    logger.warning("setAppForegroundState(true) failed: \(error)")
                }
            }
        }
        let resigned = center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.daemonClient.setAppForegroundState(isForeground: false)
                } catch {
                    logger.warning("setAppForegroundState(false) failed: \(error)")
                }
            }
        }
        focusObservers = [active, resigned]
    }

    /// Observe system memory pressure. Currently only flushes window bitmap
    /// caches and drains the autorelease pool — it deliberately does NOT tear
    /// down terminal sessions or app caches.
    private nonisolated func startMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard self != nil else { return }
            Task { @MainActor in
                logger.notice("Memory pressure detected — flushing window bitmap caches; terminal sessions left intact")
                // Flush bitmap caches on all windows
                for window in NSApp.windows {
                    window.displaysWhenScreenProfileChanges = true
                }
                // Trigger a GC pass on ObjC autoreleased objects
                autoreleasepool {}
            }
        }
        source.activate()
        // Store must happen on MainActor
        Task { @MainActor in
            self.memoryPressureSource = source
        }
    }

    // MARK: - Appearance Subscriptions

    /// Subscribe to appearance setting changes and push updates to running tmux servers.
    /// Called when `appearance` is set via didSet.
    @MainActor
    private func setupAppearanceSubscriptions(_ appearance: AppearanceSettings) {
        // Subscribe to schemeID changes to push COLORFGBG updates to all running tmux servers.
        // When the user changes the color scheme, this notifies all shells so tools like vim,
        // less, fzf can auto-adjust to the new scheme.
        // Debounce rapid changes (e.g., scrubbing through the scheme picker) to coalesce
        // multiple RPCs into a single request. The 200ms window is long enough to capture
        // rapid picker changes but short enough to feel responsive.
        // The debounce lives in `AppearanceBroadcastDebouncer` rather than in a
        // Combine `.debounce` operator: that operator takes a `Scheduler`, which
        // cannot be an `any Clock<Duration>`, so the delay was untestable except
        // by reconstructing the whole chain in the test and waiting on a real
        // 200ms timer. The debouncer keeps `dropFirst()`/`removeDuplicates()`
        // (pure, no time) in Combine and replaces only the timed stage with
        // cancel-and-replace on the injected clock. Run-loop-mode independence
        // is unchanged, not new: the operator being replaced was already
        // `DispatchQueue.main` for exactly that reason (a picker scrub puts the
        // run loop in `.eventTracking`, which stalls a `RunLoop.main` timer).
        //
        // Drop any fire still pending from a previous `appearance`: this runs
        // from that property's `didSet`, and releasing the old subscription no
        // longer kills an armed timer the way tearing down a Combine chain did.
        appearanceDebouncer.cancel()
        appearanceSubscription = appearanceDebouncer.start(observing: appearance) { [weak self] _ in
            self?.broadcastAppearanceColorFgBg(appearance)
        }

        // When the theme store reloads (external file add/delete/edit), reconcile
        // the active schemeID so a deleted theme falls back to the default rather
        // than leaving the UI pointing at an unknown id.
        themeStoreSubscription = themeStore.$userThemes
            .dropFirst()  // skip subscriber-time emission, match appearanceSubscription pattern
            .sink { [weak appearance] _ in
                appearance?.reconcileWithStore()
            }
    }

    /// Compute the new COLORFGBG value and push it to all running tmux servers.
    @MainActor
    private func broadcastAppearanceColorFgBg(_ appearance: AppearanceSettings) {
        let newValue = appearance.currentColorFgBg
        Task {
            do {
                try await daemonClient.updateAppearanceColorFgBg(value: newValue)
            } catch {
                logger.error("Failed to broadcast COLORFGBG update: \(error, privacy: .public)")
                // Fire-and-forget: don't block on RPC failure
            }
        }
    }

    // MARK: - Layout Persistence

    private func persistLayouts() {
        guard let data = try? JSONEncoder().encode(layouts) else { return }
        userDefaults.set(data, forKey: Self.layoutsKey)
    }

    private func restoreLayouts() {
        guard let data = userDefaults.data(forKey: Self.layoutsKey),
              let restored = try? JSONDecoder().decode([UUID: LayoutNode].self, from: data) else { return }
        layouts = restored
    }

    private func persistPaneHistories() {
        guard let data = try? JSONEncoder().encode(paneHistories) else { return }
        userDefaults.set(data, forKey: Self.paneHistoriesKey)
    }

    private func restorePaneHistories() {
        guard let data = userDefaults.data(forKey: Self.paneHistoriesKey),
              let restored = try? JSONDecoder().decode([UUID: PaneHistory].self, from: data) else { return }
        // Corrupt/skewed persisted data with an out-of-range cursor would
        // crash entries[cursor] lookups in the pane header's view body.
        paneHistories = restored.filter { $0.value.isWellFormed }
    }

    private func persistRemoteSessionDisplayNames() {
        guard let data = try? JSONEncoder().encode(remoteSessionDisplayNames) else { return }
        userDefaults.set(data, forKey: Self.remoteSessionDisplayNamesKey)
    }

    private func restoreRemoteSessionDisplayNames() {
        guard let data = userDefaults.data(forKey: Self.remoteSessionDisplayNamesKey),
              let restored = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        remoteSessionDisplayNames = restored
    }

    /// Composite key into `remoteSessionDisplayNames`. `\u{0}` separates the
    /// two components so a provider name/session id containing `::` (or any
    /// other printable separator) can't collide two distinct sessions onto
    /// the same key.
    nonisolated static func remoteSessionKey(provider: String, sessionID: String) -> String {
        "\(provider)\u{0}\(sessionID)"
    }

    /// The name a remote-session row should render: the local TBD-owned
    /// override when the user has renamed it, else the provider's reported
    /// `title`, else the raw session id. Mirrors `Worktree.displayName`
    /// falling back to git-derived `name` — a TBD-owned name always wins
    /// over an externally-sourced one.
    func remoteSessionDisplayName(provider: String, sessionID: String, providerTitle: String?) -> String {
        remoteSessionDisplayNames[Self.remoteSessionKey(provider: provider, sessionID: sessionID)]
            ?? providerTitle ?? sessionID
    }

    /// Rename a remote session. TBD-owned: the local override below is
    /// always the source of truth for this client, and is additionally
    /// pushed to the provider when it declares the `rename` capability (see
    /// `remoteSessionDisplayNames` doc comment and `pushRemoteRenameIfSupported`).
    /// A blank name
    /// (`RenameableLabel`'s `allowsEmptyCommit`) REMOVES the override rather
    /// than storing an empty string, so `remoteSessionDisplayName` falls back
    /// to the provider's `title` again — the same "clear to default"
    /// affordance a blank tab rename has (`AppState+Tabs.renameTab`).
    func renameRemoteSession(provider: String, sessionID: String, displayName: String) {
        let key = Self.remoteSessionKey(provider: provider, sessionID: sessionID)
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            remoteSessionDisplayNames.removeValue(forKey: key)
        } else {
            remoteSessionDisplayNames[key] = trimmed
        }
        // Fire-and-forget: the local override above is already the source of
        // truth for this client regardless of whether the provider push
        // lands (see `pushRemoteRenameIfSupported`'s doc comment). Wrapped in
        // a Task so the synchronous rename-commit path
        // (`RenameableLabel.onCommit`) never blocks on network I/O.
        Task { await pushRemoteRenameIfSupported(provider: provider, sessionID: sessionID, title: trimmed) }
    }

    /// Pushes the outgoing content of an in-place slot replacement onto that
    /// slot's history (see `ViewerRouteResult.replaced`).
    func recordPaneReplacement(_ replacement: ViewerRouteResult.Replacement) {
        paneHistories[replacement.paneID, default: PaneHistory()]
            .recordReplacement(outgoing: replacement.outgoing, incoming: replacement.incoming)
    }

    /// Resolves the removal side of a viewer route (transcript toggle-off).
    /// A reused slot keeps its pre-transcript content in history: jump the
    /// cursor to the nearest non-transcript entry (older side first — that's
    /// what the transcript replaced — then newer) and return it to restore in
    /// place. Skipping transcript entries means chained
    /// transcript-for-another-terminal swaps never resurrect another
    /// terminal's transcript. With no non-transcript entry the pane is
    /// really going away, so forget its history.
    func popHistoryForRemovedPane(_ paneID: UUID) -> PaneContent? {
        if var history = paneHistories[paneID] {
            let older = Array((history.cursor + 1)..<history.entries.count)
            let newer = Array(stride(from: history.cursor - 1, through: 0, by: -1))
            for index in older + newer {
                if case .liveTranscript = history.entries[index] { continue }
                guard let restored = history.go(to: index) else { continue }
                paneHistories[paneID] = history
                return restored
            }
        }
        paneHistories.removeValue(forKey: paneID)
        return nil
    }

    /// Drops histories for slot panes no longer present in any tab layout or
    /// tab root — closed panes and panes dropped by reconciliation. Keyed off
    /// live TAB IDs (mirrors the `visibleTerminalIDs` fix, #478) rather than
    /// `layouts.values` — the persisted `layouts` blob can carry stale
    /// worktree-keyed entries left over from pre-#478 installs, which are not
    /// tabs and must not keep their slot histories alive forever (#477).
    /// `gridLayouts` (presentation-only, never persisted) is scanned
    /// separately since its entries are legitimately live but not tab-keyed.
    func prunePaneHistories() {
        guard !paneHistories.isEmpty else { return }
        var liveIDs = Set<UUID>()
        for tabList in tabs.values {
            for tab in tabList {
                liveIDs.insert(tab.content.paneID)
                if let layout = layouts[tab.id] {
                    liveIDs.formUnion(layout.allPaneIDs())
                }
            }
        }
        for layout in gridLayouts.values { liveIDs.formUnion(layout.allPaneIDs()) }
        let pruned = paneHistories.filter { liveIDs.contains($0.key) }
        if pruned.count != paneHistories.count {
            paneHistories = pruned
        }
    }

    // MARK: - Legacy panel import (spec C §11.2)

    /// Builds the legacy-import payload for one worktree from AppState's
    /// current in-memory tab/layout/history state. Grid-layout entries — the
    /// persisted `layouts` blob's stale worktree-keyed rows from pre-#478
    /// installs — are excluded BY CONSTRUCTION: only `layouts[tab.id]` is
    /// ever consulted, never `layouts.values` (spec §11.2.2, "grid state is
    /// not imported"). `paneHistories` is filtered to pane IDs that actually
    /// appear in the included tabs' layouts, absorbing the #477
    /// over-retention concern at the import boundary rather than trusting
    /// the caller.
    func buildPanelImportParams(worktreeID: UUID) -> PanelImportParams {
        let wtTabs = tabs[worktreeID] ?? []
        var includedPaneIDs = Set<UUID>()
        let legacyTabs: [LegacyTabPayload] = wtTabs.map { tab in
            let layout = layouts[tab.id]
            includedPaneIDs.insert(tab.content.paneID)
            if let layout { includedPaneIDs.formUnion(layout.allPaneIDs()) }
            return LegacyTabPayload(tabID: tab.id, label: tab.label, content: tab.content, layout: layout)
        }
        let tabOrder = worktreeTabOrders[worktreeID] ?? wtTabs.map(\.id)
        let activeTabID: UUID? = activeTabIndices[worktreeID].flatMap { idx in
            wtTabs.indices.contains(idx) ? wtTabs[idx].id : nil
        }
        let includedPaneHistories = paneHistories.filter { includedPaneIDs.contains($0.key) }
        return PanelImportParams(
            worktreeID: worktreeID,
            tabs: legacyTabs,
            tabOrder: tabOrder,
            activeTabID: activeTabID,
            paneHistories: includedPaneHistories
        )
    }

    /// Fires the one-shot legacy panel import once per launch, once the
    /// daemon confirms panel-surface ownership is enabled (default OFF while
    /// the feature soaks — this whole path is inert until then). Called from
    /// the tail of `loadTabStates` for every worktree; imports every worktree
    /// whose tabs are already loaded at that point. Failures are logged and
    /// non-fatal — the daemon's create-if-absent guard means a skipped
    /// worktree simply retries on the next launch.
    func triggerPanelImportIfNeeded() {
        guard !hasAttemptedPanelImport, daemonCapabilities?.panelSurfaceEnabled == true else { return }
        hasAttemptedPanelImport = true
        let worktreeIDs = Array(tabs.keys)
        Task {
            for worktreeID in worktreeIDs {
                let params = buildPanelImportParams(worktreeID: worktreeID)
                do {
                    _ = try await panelImportTrigger(params)
                } catch {
                    logger.error("panelImportLegacy failed for \(worktreeID, privacy: .public): \(error, privacy: .public)")
                    continue
                }
                // Spec C §11.3 — shadow compare runs once, right after this
                // worktree's import call succeeds (whether it imported just
                // now or the daemon already had a surface from a prior
                // launch). Diagnostics only; never blocks/gates the import
                // above, which has already completed by this point.
                await runPanelShadowCompare(worktreeID: worktreeID)
            }
        }
    }

    /// Spec C §11.3 — migration-validation shadow compare. Log-only: never
    /// mutates state, never surfaces to the user, never throws in a way that
    /// affects the caller (all failures are logged and swallowed here).
    /// Re-converts the CURRENT live legacy state (not the params already sent
    /// to `panelImportTrigger` — state may have moved on since) via the same
    /// `LegacySurfaceImporter.convert` the daemon's import path used, fetches
    /// the daemon's imported surface, and logs any divergence.
    private func runPanelShadowCompare(worktreeID: UUID) async {
        let params = buildPanelImportParams(worktreeID: worktreeID)
        let local = LegacySurfaceImporter.convert(
            worktreeID: worktreeID, tabs: params.tabs, tabOrder: params.tabOrder,
            paneHistories: params.paneHistories)
        let daemon: PanelGetResult
        do {
            daemon = try await panelGetFetcher(worktreeID)
        } catch {
            shadowCompareLogger.error("panel.get failed for \(worktreeID, privacy: .public): \(error, privacy: .public)")
            return
        }
        let mismatches = PanelShadowCompare.mismatches(local: local, daemon: daemon)
        guard !mismatches.isEmpty else {
            shadowCompareLogger.debug("\(worktreeID, privacy: .public): no divergence")
            return
        }
        for mismatch in mismatches {
            shadowCompareLogger.error("\(worktreeID, privacy: .public): \(mismatch, privacy: .public)")
        }
        shadowCompareLogger.info("\(worktreeID, privacy: .public): \(mismatches.count, privacy: .public) mismatch(es)")
    }

    // MARK: - Selection Persistence

    /// Persist the current `selectionOrder` to UserDefaults.
    /// Gated on `isInitialStateLoaded` so startup does not clobber a
    /// previously-saved value before the restore has run.
    private func persistSelectionOrder() {
        guard isInitialStateLoaded else { return }
        let strings = selectionOrder.map(\.uuidString)
        guard let data = try? JSONEncoder().encode(strings) else { return }
        userDefaults.set(data, forKey: Self.selectionOrderKey)
    }

    /// Restore the persisted worktree selection, retaining only IDs that are
    /// still present in `validWorktreeIDs` and preserving their saved order.
    ///
    /// No-op when:
    /// - `pendingDeepLinkID` is set (deep links win over persisted selection)
    /// - the current selection is already non-empty
    /// - there are no valid IDs left after filtering stale ones
    ///
    /// Call this from `connectAndLoadInitialState()` after `refreshAll()` so
    /// the UI reflects the real restored selection.
    func restoreSavedSelection(validWorktreeIDs: [UUID]) {
        guard selectedWorktreeIDs.isEmpty, pendingDeepLinkID == nil else { return }
        guard let data = userDefaults.data(forKey: Self.selectionOrderKey),
              let savedStrings = try? JSONDecoder().decode([String].self, from: data) else { return }
        let savedIDs = savedStrings.compactMap { UUID(uuidString: $0) }
        let validSet = Set(validWorktreeIDs)
        let filteredIDs = savedIDs.filter { validSet.contains($0) }
        guard !filteredIDs.isEmpty else { return }
        // Suppress navigation recording while mutating state: the
        // selectedWorktreeIDs didSet would call recordNavigation with
        // Set-iteration order before we fix selectionOrder. Gate on
        // isNavigating to block that scrambled entry.
        isNavigating = true
        // Set the IDs — didSet rebuilds selectionOrder in Set-iteration order.
        selectedWorktreeIDs = Set(filteredIDs)
        // Explicitly restore the saved order, overriding the non-deterministic
        // Set-iteration order that the didSet produced.
        // The selectionOrder.didSet will persist this corrected order.
        selectionOrder = filteredIDs
        // Re-enable recording before the explicit recordNavigation call below.
        isNavigating = false
        // Record exactly one entry with the correct saved order so cmd+[ can
        // return to the restored selection after the user navigates elsewhere.
        recordNavigation(.worktrees(filteredIDs))
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        stopSubscription()
    }

    /// Start listening for real-time state deltas from the daemon.
    func startSubscription() {
        subscriptionTask?.cancel()
        subscriptionTask = Task { [weak self] in
            guard let self else { return }
            await self.daemonClient.subscribe { [weak self] delta in
                Task { @MainActor [weak self] in
                    self?.handleDelta(delta)
                }
            }
            // Subscription disconnected — nil out so poll loop restarts it
            await MainActor.run { self.subscriptionTask = nil }
        }
    }

    func stopSubscription() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
    }

    func handleDelta(_ delta: StateDelta) {
        switch delta {
        case .notificationReceived(let notification):
            handleNotificationDelta(notification)
        case .modelProfileUsageUpdated(let usage):
            applyModelProfileUsageDelta(usage)
        case .modelProfilesChanged:
            Task { [weak self] in
                await self?.loadModelProfiles()
                await self?.loadHibernationConfig()
                // The daemon reuses this delta for config changes including
                // the control-mode toggle (handleConfigSetControlMode), so
                // refresh capabilities too — a toggle from ANOTHER client
                // must reach this one without waiting for a reconnect
                // (R7-minor). Best-effort: failure keeps the last value.
                await self?.refreshDaemonCapabilities()
            }
        case .terminalSessionUpdated(let d):
            applyTerminalSessionDelta(d)
        case .terminalCreated(let d):
            applyTerminalCreatedDelta(d)
        case .terminalRemoved(let d):
            applyTerminalRemovedDelta(d)
        case .terminalActivityUpdated(let d):
            applyTerminalActivityDelta(d)
        case .terminalProfileChanged(let d):
            applyTerminalProfileDelta(d)
        case .watchDeskRolesChanged(let d):
            Task { [weak self] in await self?.refreshTerminals(worktreeID: d.worktreeID) }
        case .terminalHibernationChanged(let d):
            applyTerminalHibernationDelta(d)
        case .worktreeMoved(let d):
            applyWorktreeMovedDelta(d)
        case .worktreeArchived(let d):
            applyWorktreeArchivedDelta(d)
        case .worktreeRevived(let d):
            recentlyArchivedWorktreeIDs.removeValue(forKey: d.worktreeID)
            Task { [weak self] in await self?.refreshWorktrees() }
        case .controlModeInputHealthChanged(let d):
            applyControlModeInputHealthDelta(d)
        case .reapRecordsChanged:
            if let repoID = selectedRepoID {
                Task { [weak self] in await self?.refreshReapRecords(repoID: repoID) }
            }
        case .remoteSessionsChanged:
            Task { [weak self] in await self?.refreshRemote() }
        case .remoteSessionAttention(let d):
            handleRemoteSessionAttentionDelta(d)
        default:
            break
        }
    }

    // MARK: - Control-mode input-delivery health (#318 polish)

    /// Record that `paneID` is now rendered through a live control-mode
    /// attach owned by `generation` (from `openAttach`; nil when the daemon
    /// vended none). Called by the terminal coordinator once `attach.ready`
    /// is acked. A re-attach for the same pane overwrites the record with its
    /// own generation AND clears any stale failing flag — a fresh attach
    /// starts from a healthy baseline, mirroring the daemon router's
    /// `register()` reset. Without this, a failing flag from a previous
    /// generation could stick forever: the stale detach's generation guard
    /// (correctly) refuses to clear it, and the daemon's register-reset is
    /// silent — no recovery delta ever arrives to un-stick the indicator.
    func controlModePaneAttached(worktreeID: UUID, paneID: String, generation: UInt64?) {
        let key = ControlModePaneKey(worktreeID: worktreeID, paneID: paneID)
        controlModeAttachedPanes[key] = generation
        controlModeFailingInputPanes.remove(key)
    }

    /// Clear a pane's attach record AND any failing flag — the indicator must
    /// vanish on detach, and a later re-attach starts from a healthy baseline
    /// (mirrors the daemon router's unregister semantics). Idempotent; also
    /// safe to call from the attach-failure fallback path where the pane was
    /// never marked attached.
    ///
    /// Generation-scoped (M3 review fix): when `generation` is present, the
    /// clear applies ONLY if it matches the recorded attach's generation — a
    /// closing pane's stale clear landing after a fresh attach's set for the
    /// same pane must not drop the successor's attached state. `nil`
    /// (generation unknown — e.g. an openAttach that failed before vending
    /// one) clears unconditionally, as before. A record stored WITHOUT a
    /// generation can't be discriminated, so any detach clears it.
    func controlModePaneDetached(worktreeID: UUID, paneID: String, generation: UInt64? = nil) {
        let key = ControlModePaneKey(worktreeID: worktreeID, paneID: paneID)
        if let generation,
           let record = controlModeAttachedPanes[key], let recordedGeneration = record,
           recordedGeneration != generation {
            return
        }
        controlModeAttachedPanes.removeValue(forKey: key)
        controlModeFailingInputPanes.remove(key)
    }

    /// Whether the "input not being delivered" indicator should show for a
    /// pane: it must be BOTH control-mode attached and flagged failing. A
    /// failing delta for a non-attached pane (stale, or grouped-sessions
    /// fallback) never surfaces.
    func isInputDeliveryFailing(_ key: ControlModePaneKey) -> Bool {
        controlModeAttachedPanes.index(forKey: key) != nil
            && controlModeFailingInputPanes.contains(key)
    }

    private func applyControlModeInputHealthDelta(_ delta: ControlModeInputHealthDelta) {
        let key = ControlModePaneKey(worktreeID: delta.worktreeID, paneID: delta.paneID)
        if delta.healthy {
            // Recovery clears regardless of generation: clearing is always
            // safe (worst case the indicator re-fires on the next failure).
            controlModeFailingInputPanes.remove(key)
        } else {
            // A FAILING delta is generation-scoped (R6-M7): apply only if it
            // belongs to the attach this pane currently records — a stale
            // attach's failure surfacing after a re-attach must not flag the
            // fresh, healthy attach. Nil on either side (older daemon delta,
            // or a record vended without a generation) applies unchecked,
            // preserving pre-R6 behavior — same discrimination rule as
            // `controlModePaneDetached`.
            if let deltaGeneration = delta.generation,
               let record = controlModeAttachedPanes[key], let recordedGeneration = record,
               recordedGeneration != deltaGeneration {
                return
            }
            controlModeFailingInputPanes.insert(key)
        }
    }

    /// Apply a worktree move (new parent + sortOrder) directly to the in-memory
    /// model so the sidebar reflects the change without waiting for the next
    /// `worktree.list` poll. Searches all repos for the worktree — moves
    /// across repos aren't supported by the daemon today, so we mutate in
    /// place once we find it.
    private func applyWorktreeMovedDelta(_ delta: WorktreeMovedDelta) {
        for (repoID, rows) in worktrees {
            if let idx = rows.firstIndex(where: { $0.id == delta.worktreeID }) {
                var updated = rows
                updated[idx].parentWorktreeID = delta.newParentID
                updated[idx].sortOrder = delta.newSortOrder
                worktrees[repoID] = updated
                break
            }
        }
    }

    /// Daemon confirmed a worktree was archived (possibly from the CLI or another
    /// client). Tombstone it and drop the row so it cannot be resurrected by a
    /// poll snapshot that predates the archive.
    private func applyWorktreeArchivedDelta(_ delta: WorktreeIDDelta) {
        // Look the row up before it gets removed so we can name it in the alert.
        let worktree = findWorktree(id: delta.worktreeID)
        let failureMessage = Self.creationFailureMessage(worktree, creationFailed: delta.creationFailed)

        removeArchivedWorktreeFromState(id: delta.worktreeID)

        // The daemon tells us whether creation actually failed; we never infer
        // it from `.creating` status. A deliberate archive of a still-creating
        // row — e.g. `tbd worktree archive <id>` to bail out of a stuck
        // pre-session hook — arrives with creationFailed == false and must stay
        // silent, even though the row is `.creating` at this moment.
        if let message = failureMessage {
            showAlert(message, isError: true)
        }
    }

    /// Returns a failure alert message when the daemon reported that this
    /// worktree's *creation* failed, or nil otherwise (deliberate archive, or
    /// an unknown row we can't name).
    ///
    /// `creationFailed` comes from the daemon via `WorktreeIDDelta`; status is
    /// deliberately NOT consulted, because a `.creating` row can also be
    /// archived on purpose from the CLI and the two are indistinguishable by
    /// status alone.
    ///
    /// Pure static helper for testability — every branch is unit-testable
    /// without a daemon or SwiftUI, following the pattern of `archiveShortcutRoute`.
    nonisolated static func creationFailureMessage(
        _ worktree: Worktree?, creationFailed: Bool
    ) -> String? {
        guard creationFailed, let worktree else {
            return nil
        }
        return "Couldn't create worktree \"\(worktree.displayName)\" — the git worktree add failed. " +
               "See Console (log show --predicate 'subsystem == \"com.tbd.daemon\"') for details."
    }

    /// Apply a Claude session rollover (post-`/clear` / `/compact` / startup)
    /// directly to the in-memory Terminal so TableTranscriptPaneView re-targets
    /// without waiting for the next 2s `terminal.list` poll. Silently ignores
    /// terminals we don't know about — the next refresh will reconcile.
    private func applyTerminalSessionDelta(_ delta: TerminalSessionDelta) {
        guard let idx = terminals[delta.worktreeID]?.firstIndex(where: { $0.id == delta.terminalID }) else {
            return
        }
        terminals[delta.worktreeID]?[idx].claudeSessionID = delta.sessionID
        // Mirror TerminalStore.updateSession's preserve-on-nil: a delta with
        // nil transcriptPath means the SessionStart payload didn't carry a
        // path even though sessionID rolled. Keep the previous value so the
        // in-memory model doesn't drift from the DB.
        if let tp = delta.transcriptPath {
            terminals[delta.worktreeID]?[idx].transcriptPath = tp
        }
    }

    private func applyTerminalActivityDelta(_ delta: TerminalActivityDelta) {
        guard let idx = terminals[delta.worktreeID]?.firstIndex(where: { $0.id == delta.terminalID }) else {
            return
        }
        terminals[delta.worktreeID]?[idx].activityState = delta.activityState
    }

    /// Seamless in-place "Switch account": the terminal row is unchanged except
    /// its `profileID`, so update it in place and the account chip re-renders.
    private func applyTerminalProfileDelta(_ delta: TerminalProfileDelta) {
        guard let idx = terminals[delta.worktreeID]?.firstIndex(where: { $0.id == delta.terminalID }) else {
            return
        }
        terminals[delta.worktreeID]?[idx].profileID = delta.newProfileID
    }

    /// Hibernate / wake / keep-warm change: update `hibernatedAt`, `keepWarm`,
    /// `suspendedSnapshot`, and `hibernateReason` on the row in place so the
    /// whisper indicator and action menu re-render without a full terminal
    /// refetch. Snapshot and reason must land WITH the `hibernated` flip: the
    /// parked TerminalPanelView materializes the instant `isParked` flips
    /// (identity `id-tmuxWindowID-isParked`) and reads `initialSnapshot` from
    /// this cached row once at creation — a snapshot arriving only in the
    /// later refetch shows a blank parked pane — and wake-on-focus filters on
    /// the cached `hibernateReason`, so a focus event in the delta-to-refetch
    /// gap must not auto-wake a just-manually-parked session. On wake the
    /// reason is cleared but the snapshot is KEPT, matching the daemon's
    /// `clearHibernated` (the woken view shows the frozen pane while the live
    /// tmux client reconnects).
    func applyTerminalHibernationDelta(_ delta: TerminalHibernationDelta) {
        guard let idx = terminals[delta.worktreeID]?.firstIndex(where: { $0.id == delta.terminalID }) else {
            return
        }
        // Apply fresh tmux ids (carried on wake, especially after a window
        // RECREATE) together with the un-park flip. The terminal view keys on
        // `id-tmuxWindowID-isParked`; flipping isParked while the cached row
        // still points at the dead window would rebuild the view against that
        // dead window, and its failed attach re-parks the row (wake flap).
        if let windowID = delta.tmuxWindowID {
            terminals[delta.worktreeID]?[idx].tmuxWindowID = windowID
        }
        if let paneID = delta.tmuxPaneID {
            terminals[delta.worktreeID]?[idx].tmuxPaneID = paneID
        }
        terminals[delta.worktreeID]?[idx].hibernatedAt = delta.hibernated ? Date() : nil
        terminals[delta.worktreeID]?[idx].keepWarm = delta.keepWarm
        if delta.hibernated {
            // Parked: the delta carries the just-captured snapshot + reason
            // (nil from an older daemon — same blank-pane behavior as before).
            terminals[delta.worktreeID]?[idx].suspendedSnapshot = delta.suspendedSnapshot
            terminals[delta.worktreeID]?[idx].hibernateReason = delta.hibernateReason
            // Parking implies cancellation: the daemon's setHibernated cancels
            // any scheduled auto-resume in the same write, so nil the mirror
            // here too — otherwise the tab's ⏳ glyph / "Cancel Scheduled
            // Resume" item keep advertising a resume that won't happen for
            // the delta-to-refetch window. No delta field needed.
            terminals[delta.worktreeID]?[idx].pendingResumeAt = nil
        } else {
            // Woken: clear the reason, keep the snapshot (clearHibernated
            // semantics — reconnect backdrop, overwritten on the next park).
            terminals[delta.worktreeID]?[idx].hibernateReason = nil
            terminals[delta.worktreeID]?[idx].suspendedAt = nil
        }
    }

    /// Update the in-place usage entry for a single profile. If no match,
    /// silently ignore — the next full refresh will pick it up.
    private func applyModelProfileUsageDelta(_ usage: ModelProfileUsage) {
        guard let idx = modelProfiles.firstIndex(where: { $0.profile.id == usage.profileID }) else {
            return
        }
        let existing = modelProfiles[idx]
        modelProfiles[idx] = ModelProfileWithUsage(profile: existing.profile, usage: usage)
    }

    /// The terminal ID(s) a `Tab` renders. A tab with a stored split layout in
    /// `layouts[tab.id]` can render multiple terminals across its panes; a tab
    /// without one renders the single surface in `tab.content`. Both `.terminal`
    /// and `.liveTranscript` panes reference a terminal; everything else (notes,
    /// webviews, code viewers) has none.
    ///
    /// Consults the split layout first via the same resolution the close path
    /// uses (`layouts[tab.id] ?? .pane(tab.content)` then `allTerminalIDs()`),
    /// then unions the `tab.content` terminal so `.liveTranscript` tabs — whose
    /// IDs `allTerminalIDs()` does not enumerate — stay covered.
    func terminalIDs(in tab: TBDShared.Tab) -> Set<UUID> {
        let layout = layouts[tab.id] ?? .pane(tab.content)
        var ids = Set(layout.allTerminalIDs())
        switch tab.content {
        case .terminal(let tid):
            ids.insert(tid)
        case .liveTranscript(_, let tid):
            ids.insert(tid)
        default:
            break
        }
        return ids
    }

    /// True iff `worktreeID` is the single selection AND its active tab renders
    /// `terminalID`. Used to decide whether a `.responseComplete` arrival should
    /// be recorded as unread — a completion on the tab the user is already
    /// looking at must never bold.
    func isActiveTabTerminal(_ terminalID: UUID, inFocusedWorktree worktreeID: UUID) -> Bool {
        guard selectedWorktreeIDs == [worktreeID] else { return false }
        guard let tab = resolvedActiveTab(worktreeID: worktreeID) else { return false }
        return terminalIDs(in: tab).contains(terminalID)
    }

    /// Remove the active tab's terminal(s) from `unreadTerminals` for the given
    /// worktree. Called when the user activates a tab or focuses a worktree so
    /// the surface they're now looking at clears its bold.
    func clearUnreadForActiveTab(worktreeID: UUID) {
        guard let tab = resolvedActiveTab(worktreeID: worktreeID) else { return }
        let tids = terminalIDs(in: tab)
        guard !tids.isEmpty else { return }
        unreadTerminals.subtract(tids)
    }

    private func handleNotificationDelta(_ notification: NotificationDelta) {
        // Loud focus push: foreground + select the originating tab immediately,
        // regardless of what the user is currently looking at. Done before any
        // unread/bold bookkeeping (we're navigating there, so it's moot).
        if notification.activate {
            navigateToWorktree(notification.worktreeID, terminalID: notification.terminalID)
            return
        }

        // Record a background-tab arrival so its tab label bolds. Fires for any
        // terminal-stamped delta (any type — response completions, errors, focus
        // pushes, etc.), as long as it isn't the tab the user is already looking
        // at. Done BEFORE the visible-worktree early-return because a worktree
        // can be "visible" (selected) while the stamped terminal lives on a
        // background tab.
        if let tid = notification.terminalID,
           !isActiveTabTerminal(tid, inFocusedWorktree: notification.worktreeID) {
            unreadTerminals.insert(tid)
        }

        let visible = visibleWorktreeIDs
        guard !visible.contains(notification.worktreeID) else { return }

        // Update local unread summary state. The delta doesn't carry a
        // timestamp so we use "now" — close enough for the jump menu's
        // recency-based sort. Merge with any existing summary so a lower-
        // severity arrival (e.g. responseComplete) doesn't downgrade a
        // higher-severity unread (e.g. error) until the next DB poll.
        let incoming = UnreadSummary(type: notification.type, mostRecentAt: Date())
        if let existing = unreadByWorktree[notification.worktreeID] {
            let winnerType = incoming.type.severity > existing.type.severity
                ? incoming.type : existing.type
            unreadByWorktree[notification.worktreeID] = UnreadSummary(
                type: winnerType,
                mostRecentAt: incoming.mostRecentAt
            )
        } else {
            unreadByWorktree[notification.worktreeID] = incoming
        }

        // Fire sound + macOS notification
        notificationSoundPlayer.playIfEnabled(for: notification.type)
        macNotificationManager.postIfEnabled(
            worktreeID: notification.worktreeID,
            message: notification.message,
            // Resolve the name here (scratch-aware) instead of handing over
            // the whole materialized allWorktrees array for one lookup.
            worktreeName: findWorktree(id: notification.worktreeID)?.displayName,
            type: notification.type,
            terminalID: notification.terminalID
        )
    }

    /// Every worktree the app knows about: the repo-grouped dict flattened,
    /// plus repo-less scratch spaces (which live only in `scratchWorktrees`).
    /// Use this instead of re-flattening `worktrees.values` whenever a lookup
    /// must also resolve scratch spaces (e.g. notification banner titles,
    /// startup selection restore).
    var allWorktrees: [Worktree] {
        worktrees.values.flatMap { $0 } + scratchWorktrees
    }

    /// Runs `body` only if no poll cycle is currently in flight. Returns true if
    /// it ran, false if skipped because a previous cycle was still running.
    ///
    /// This is the Layer A storm guard: the 2s poll timer frees the main actor
    /// whenever its refresh `await`s a slow daemon RPC, so without this guard the
    /// next tick (and the next, and the next) would each spawn another overlapping
    /// refresh cycle — a positive-feedback RPC storm. Holding a single in-flight
    /// flag collapses every tick that fires mid-cycle into a cheap skip.
    @discardableResult
    func runPollCycleIfIdle(_ body: () async -> Void) async -> Bool {
        if pollCycleInFlight {
            skippedPollCycles += 1
            perfRPCLogger.debug(
                "poll cycle skipped (in-flight); totalSkipped=\(self.skippedPollCycles, privacy: .public)"
            )
            return false
        }
        pollCycleInFlight = true
        defer { pollCycleInFlight = false }
        let signpostID = perfRPCSignposter.makeSignpostID()
        let interval = perfRPCSignposter.beginInterval("rpc.pollCycle", id: signpostID)
        await body()
        perfRPCSignposter.endInterval("rpc.pollCycle", interval)
        return true
    }

    /// Poll daemon for state changes every 2 seconds.
    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Connection/reconnection stays OUTSIDE the in-flight guard so a
                // dropped socket is retried every tick even while a slow refresh
                // is still draining; only the refresh (the list RPCs) is guarded.
                if !self.isConnected {
                    // Try to start the daemon if socket doesn't exist
                    if !FileManager.default.fileExists(atPath: TBDConstants.socketPath) {
                        await self.startDaemonAndConnect()
                    } else {
                        let didConnect = await self.daemonClient.connect()
                        self.isConnected = didConnect
                        if didConnect {
                            self.pushClaudeSpawnPreferences()
                            self.pushForegroundState()
                        } else if !AppState.pidFilePointsAtLiveDaemon() {
                            // The socket file exists but nothing accepted the
                            // connection, and the pid file doesn't name a live
                            // TBDDaemon — stale leftovers (e.g. after a
                            // reboot). Let startDaemonAndConnect clean them up
                            // and respawn. A live daemon is never touched:
                            // transient connect failures with a healthy pid
                            // stay on the plain retry path above.
                            await self.startDaemonAndConnect()
                        }
                    }
                    if !self.isConnected { return }
                }
                // Guard the whole refresh cycle (refreshAll + the every-15th
                // pr.list) so a slow daemon can never stack overlapping cycles or
                // run them concurrently. pollCycle is advanced only when a cycle
                // actually RUNS — skipped ticks don't burn the PR counter, so the
                // expensive pr.list still lands ~every 15 executed cycles rather
                // than drifting earlier off wall-clock ticks that did no work.
                await self.runPollCycleIfIdle {
                    await self.refreshAll()
                    if self.subscriptionTask == nil || self.subscriptionTask?.isCancelled == true {
                        self.startSubscription()
                    }
                    self.pollCycle += 1
                    if self.pollCycle % 15 == 0 {
                        await self.refreshPRStatuses()
                    }
                }
            }
        }
    }

    // MARK: - Connection

    /// Connect to the daemon and fetch initial state.
    /// The daemon client will attempt to auto-start tbdd if not running.
    func connectAndLoadInitialState() async {
        let didConnect = await daemonClient.connect()
        isConnected = didConnect
        if didConnect {
            // Fetch capabilities BEFORE refreshAll: terminal views are created
            // as soon as worktree/terminal state lands, and each view decides
            // grouped-sessions vs control-mode at creation time. Fetching
            // afterwards would leave every initially-rendered pane on the
            // grouped path even when the control-mode gate is on.
            daemonCapabilities = try? await daemonClient.daemonCapabilities()
            await refreshAll()
            // Restore persisted selection before notifying the daemon — the RPC
            // below captures `selectedWorktreeIDs` so the daemon learns the real
            // selection from the previous session. `allWorktrees` includes
            // scratch spaces (populated by refreshAll() above), so a persisted
            // scratch selection survives relaunch instead of being filtered out.
            restoreSavedSelection(validWorktreeIDs: allWorktrees.map(\.id))
            // Expand any repo whose worktree is now selected but was collapsed,
            // so the restored row is visible in the sidebar.
            for id in selectedWorktreeIDs {
                expandRepoContaining(worktreeID: id)
            }
            await loadModelProfiles()
            await loadHibernationConfig()
            await refreshRemote()
            startSubscription()
            await refreshPRStatuses()
            pushClaudeSpawnPreferences()
            pushForegroundState()
        } else {
            logger.warning("Could not connect to daemon — is tbdd running?")
        }
        isInitialStateLoaded = true
        if let pendingID = pendingDeepLinkID {
            let pendingTerminalID = pendingDeepLinkTerminalID
            pendingDeepLinkID = nil
            pendingDeepLinkTerminalID = nil
            navigateToWorktree(pendingID, terminalID: pendingTerminalID)
        }
        if didConnect {
            Task { [weak self] in
                guard let self else { return }
                await self.checkDaemonBuildIdentity()
            }
            Task { [weak self] in
                guard let self else { return }
                await self.cliInstallerCoordinator.checkOnLaunch()
            }
            Task { [weak self] in
                guard let self else { return }
                await self.legacyHooksCoordinator.checkOnLaunch()
            }
        }
    }

    /// Menu entry point — install or refresh the `tbd` CLI symlink.
    func installCLITool() async {
        await cliInstallerCoordinator.runFromMenu()
    }

    /// Menu entry point — review and (optionally) remove TBD's legacy
    /// hook entries from the user's `~/.claude/settings.json`.
    func migrateClaudeHooks() async {
        await legacyHooksCoordinator.runFromMenu()
    }

    /// Launch the daemon process and connect.
    func startDaemonAndConnect() async {
        // Check if daemon is already running. The pid file alone can't be
        // trusted: it survives reboots and the recorded pid can be recycled
        // by an unrelated process, which made the app skip spawning and fail
        // to connect to a dead socket forever. Validate that the pid is a
        // live TBDDaemon before skipping the spawn.
        let pidPath = TBDConstants.pidFilePath
        if let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8),
           let pid = DaemonLiveness.pid(fromPidFileContents: pidStr) {
            if DaemonLiveness.isLiveTBDDaemon(pid: pid) {
                // Daemon is running, just connect
                await connectAndLoadInitialState()
                return
            }
            // Stale artifacts — dead pid, or pid recycled by another process
            // (e.g. after a reboot). Remove them so the spawn below starts
            // from a clean slate instead of tripping over a dead socket.
            logger.warning("""
            Stale daemon pid file: pid \(pid, privacy: .public) is not a live \
            TBDDaemon — removing pid file and socket before spawning
            """)
            try? FileManager.default.removeItem(atPath: pidPath)
            try? FileManager.default.removeItem(atPath: TBDConstants.socketPath)
        }

        // Find TBDDaemon binary using sibling and source-worktree candidates
        let sourceWorktreePath = SourceWorktreePathResolver.resolve(
            bundleURL: Bundle.main.bundleURL,
            executablePath: Bundle.main.executablePath
        )
        let candidates = DaemonCandidateFinder.daemonCandidatePaths(
            appExecutablePath: Bundle.main.executablePath,
            sourceWorktreePath: sourceWorktreePath
        )

        var tbddPath: String?
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                tbddPath = path
                break
            }
        }

        guard let path = tbddPath else {
            let candidateList = candidates.isEmpty
                ? "no candidates found"
                : "tried: " + candidates.joined(separator: ", ")
            let message = "Could not find TBDDaemon binary (\(candidateList)). "
                + "Try running scripts/restart.sh from your worktree."
            showAlert(message, isError: true)
            return
        }

        logger.info("Starting daemon from: \(path)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.standardOutput = FileHandle(forWritingAtPath: "/tmp/tbdd.log") ?? .nullDevice
        process.standardError = FileHandle(forWritingAtPath: "/tmp/tbdd.log") ?? .nullDevice
        do {
            try process.run()
        } catch {
            showAlert("Failed to start daemon: \(error)", isError: true)
            return
        }

        // Wait for socket
        for _ in 0..<20 {
            // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
            try? await Task.sleep(for: .milliseconds(200))
            if FileManager.default.fileExists(atPath: TBDConstants.socketPath) {
                break
            }
        }

        await connectAndLoadInitialState()
    }

    /// True when the daemon pid file exists and names a live TBDDaemon
    /// process. Used by the reconnect poll to distinguish "daemon busy /
    /// transient connect failure" (retry) from "stale socket + pid file left
    /// behind by a reboot or crash" (clean up and respawn).
    nonisolated static func pidFilePointsAtLiveDaemon(
        pidFilePath: String = TBDConstants.pidFilePath
    ) -> Bool {
        guard let contents = try? String(contentsOfFile: pidFilePath, encoding: .utf8),
              let pid = DaemonLiveness.pid(fromPidFileContents: contents)
        else { return false }
        return DaemonLiveness.isLiveTBDDaemon(pid: pid)
    }

    // MARK: - Refresh

    /// Refresh all state from the daemon.
    func refreshAll() async {
        await refreshRepos()
        await refreshWorktrees()
        await refreshNotifications()
    }

    /// Refresh the repo list. Only updates if data changed.
    func refreshRepos() async {
        do {
            let fetchedRepos = try await daemonClient.listRepos()
            if fetchedRepos != repos {
                repos = fetchedRepos
            }
        } catch {
            logger.error("Failed to list repos: \(error)")
            handleConnectionError(error)
        }
    }

    /// Refresh worktrees for all repos (or a specific repo).
    /// Fetches active and main worktrees; archived rows are excluded here because
    /// the archived view has its own paginated fetch (refreshArchivedWorktrees).
    func refreshWorktrees(repoID: UUID? = nil) async {
        do {
            // Single RPC — fetch non-archived worktrees only.
            // Absent rows satisfy reconcileTombstones identically to status==.archived
            // (both confirm the tombstone), so tombstone reconciliation is unaffected.
            let allWts = try await daemonClient.listWorktrees(repoID: repoID, excludeArchived: true)
            // Drop tombstones the daemon has confirmed (or that outlived the TTL) so a
            // stale poll predating an archive cannot resurrect the row.
            // Reconcile only on the unscoped path: a scoped allWts omits other repos'
            // worktrees, which would look absent and evict their tombstones prematurely.
            if repoID == nil {
                recentlyArchivedWorktreeIDs = AppState.reconcileTombstones(
                    recentlyArchivedWorktreeIDs,
                    daemonWorktrees: allWts,
                    now: Date()
                )
            }
            let fetched = AppState.visibleWorktrees(
                from: allWts,
                tombstones: Set(recentlyArchivedWorktreeIDs.keys)
            )

            // Seed PR status from the persisted value so the PR icon shows immediately
            // on cold start. Only fill gaps — never overwrite a fresher live entry
            // populated by refreshPRStatuses().
            for wt in fetched where prStatuses[wt.id] == nil {
                if let pr = wt.prStatus {
                    prStatuses[wt.id] = pr
                }
            }

            // A revive that was gated by a blocking preSession hook lingers
            // `.inFlight` until the daemon reports the row `.active` — this
            // periodic refresh is where that flip is observed.
            promoteRevivedWorktrees(observing: allWts)

            if let repoID {
                // Preserve optimistic placeholders the daemon doesn't know about yet
                let placeholders = (worktrees[repoID] ?? []).filter { pendingWorktreeIDs.contains($0.id) }
                let merged = fetched + placeholders
                if merged != worktrees[repoID] ?? [] {
                    worktrees[repoID] = merged
                }
            } else {
                var grouped: [UUID: [Worktree]] = [:]
                var scratch: [Worktree] = []
                for wt in fetched {
                    // Scratch spaces (repoID == nil) don't belong to any repo group;
                    // they're surfaced separately (see the Scratch sidebar section).
                    guard let rid = wt.repoID else {
                        scratch.append(wt)
                        continue
                    }
                    grouped[rid, default: []].append(wt)
                }
                // Preserve optimistic placeholders the daemon doesn't know about yet
                for (rid, wts) in worktrees {
                    for wt in wts where pendingWorktreeIDs.contains(wt.id) {
                        grouped[rid, default: []].append(wt)
                    }
                }
                if grouped != worktrees {
                    worktrees = grouped
                }
                let sortedScratch = scratch.sorted { $0.sortOrder < $1.sortOrder }
                if sortedScratch != scratchWorktrees {
                    scratchWorktrees = sortedScratch
                }
            }

            // Single RPC — fetch all terminals, group client-side
            let allTerminals = try await daemonClient.listTerminals()
            let terminalsByWorktree = Dictionary(grouping: allTerminals, by: { $0.worktreeID })
            let visibleWorktreeIDs = Set(fetched.map(\.id))
            for wtID in visibleWorktreeIDs {
                adoptTerminalSnapshot(
                    terminalsByWorktree[wtID] ?? [],
                    worktreeID: wtID
                )
            }

            // Fetch all notes, group client-side
            let allNotes = try await daemonClient.listNotes()
            let notesByWorktree = Dictionary(grouping: allNotes, by: { $0.worktreeID })
            for wtID in visibleWorktreeIDs {
                let fetched = notesByWorktree[wtID] ?? []
                let existing = notes[wtID] ?? []
                if fetched != existing {
                    notes[wtID] = fetched
                    reconcileNoteTabs(worktreeID: wtID, notes: fetched)
                }
            }

            // Prune slot histories only after every visible worktree's tabs
            // have been reconciled this cycle. Doing it inside the per-worktree
            // `reconcileTabs` loop above would run against a partially-populated
            // `tabs` on the first launch pass, deleting (and persisting as `[]`)
            // histories for worktrees not yet loaded — the pane back/forward
            // history was lost on every restart because of that.
            prunePaneHistories()
        } catch {
            logger.error("Failed to list worktrees: \(error)")
            handleConnectionError(error)
        }
    }

    /// Refresh terminals for a specific worktree. Only updates if data changed.
    func refreshTerminals(worktreeID: UUID) async {
        do {
            let fetched = try await daemonClient.listTerminals(worktreeID: worktreeID)
            adoptTerminalSnapshot(fetched, worktreeID: worktreeID)
        } catch {
            logger.error("Failed to list terminals for worktree \(worktreeID): \(error)")
            handleConnectionError(error)
        }
    }

    /// Reconcile tabs with the current terminal list for a worktree.
    /// Removes tabs whose root terminal no longer exists. Adds tabs for
    /// terminals that aren't already represented (either as a tab root or
    /// embedded in another tab's split layout).
    func reconcileTabs(worktreeID: UUID, terminals: [Terminal]) {
        // Capture the active tab's IDENTITY before touching the array: every
        // mutation below shifts indices, so a stored index re-binds to whatever
        // slid into its slot. The auto-close of the `setup` tab makes that a
        // routine event, not an edge case, and the note tab is always last.
        let previousActiveTabID = explicitActiveTabID(worktreeID: worktreeID)
        var currentTabs = tabs[worktreeID] ?? []
        let terminalIDs = Set(terminals.map(\.id))

        // 1. Remove tabs whose root terminal no longer exists,
        //    and clean up their persisted layouts.
        currentTabs.removeAll { tab in
            if case .terminal(let id) = tab.content, !terminalIDs.contains(id) {
                layouts.removeValue(forKey: tab.id)
                return true
            }
            return false
        }

        // 2. Now collect terminal IDs from surviving tabs' layouts.
        //    This must happen AFTER pruning so that dead tabs' children
        //    don't mask still-alive terminals that need new tabs.
        var terminalIDsInLayouts = Set<UUID>()
        for index in currentTabs.indices {
            let tab = currentTabs[index]
            if let layout = layouts[tab.id] {
                guard let scopedLayout = layout.removingTerminalPanes(notIn: terminalIDs) else {
                    layouts.removeValue(forKey: tab.id)
                    if case .terminal(let id) = tab.content, terminalIDs.contains(id) {
                        terminalIDsInLayouts.insert(id)
                    }
                    continue
                }
                if scopedLayout != layout {
                    layouts[tab.id] = scopedLayout
                    if case .pane(let content) = scopedLayout {
                        currentTabs[index].content = content
                    }
                }
                for id in scopedLayout.allTerminalIDs() {
                    terminalIDsInLayouts.insert(id)
                }
            } else {
                if case .terminal(let id) = tab.content, terminalIDs.contains(id) {
                    terminalIDsInLayouts.insert(id)
                }
            }
        }

        // 3. Add tabs for terminals not already in any surviving layout.
        for terminal in terminals where !terminalIDsInLayouts.contains(terminal.id) {
            currentTabs.append(TBDShared.Tab(
                id: terminal.id,
                content: .terminal(terminalID: terminal.id),
                label: initialTabLabel(for: terminal)
            ))
        }

        tabs[worktreeID] = currentTabs
        applyStoredOrder(worktreeID: worktreeID, anchor: .pinned(previousActiveTabID))
        // Re-fetch until the daemon has actually persisted tab order / active
        // tab. `worktreeTabOrders[worktreeID] != nil` was the old gate and it
        // latched on the empty response a poll gets while the daemon is still
        // mid-create, permanently stranding the worktree with no stored order
        // and no hydrated selection. The scheduler owns the dedup and the
        // attempt cap that keep this from becoming a poll loop.
        scheduleTabStateHydration(worktreeID: worktreeID)
    }

    /// Reconcile note tabs — remove tabs whose note no longer exists,
    /// add tabs for notes not already represented.
    func reconcileNoteTabs(worktreeID: UUID, notes: [Note]) {
        // Same identity capture as reconcileTabs — see the comment there.
        let previousActiveTabID = explicitActiveTabID(worktreeID: worktreeID)
        var currentTabs = tabs[worktreeID] ?? []
        let noteIDs = Set(notes.map(\.id))

        // Collect note IDs already in tabs
        var noteIDsInTabs = Set<UUID>()
        currentTabs.removeAll { tab in
            if case .note(let id) = tab.content {
                if !noteIDs.contains(id) {
                    layouts.removeValue(forKey: tab.id)
                    return true
                }
                noteIDsInTabs.insert(id)
            }
            return false
        }

        // Add tabs for notes not already represented
        for note in notes where !noteIDsInTabs.contains(note.id) {
            currentTabs.append(TBDShared.Tab(id: note.id, content: .note(noteID: note.id), label: nil))
        }

        tabs[worktreeID] = currentTabs
        applyStoredOrder(worktreeID: worktreeID, anchor: .pinned(previousActiveTabID))
    }

    /// Poll all cached PR statuses from the daemon (background, every ~30s).
    func refreshPRStatuses() async {
        do {
            let fetched = try await daemonClient.listPRStatuses()
            // Only update if changed to avoid unnecessary SwiftUI redraws
            if fetched != prStatuses {
                prStatuses = fetched
            }
        } catch {
            logger.error("Failed to list PR statuses: \(error)")
            handleConnectionError(error)
        }
        // Outside the `do`, deliberately. The two come from different daemon
        // paths — `pr.list` runs the git/`gh` poll, `pr.bindingsAll` is one
        // indexed read — so a GitHub hiccup must not also freeze the dropdown.
        // Same reasoning as `refreshPRStatus(worktreeID:)` below.
        await refreshPRBindings()
    }

    /// Fetch and publish EVERY worktree's PR bindings.
    ///
    /// One call, not a fan-out, and the "one" is what fixes the bug the
    /// per-worktree shape had: the app could only ask about worktrees it already
    /// knew had PRs (a branch-derived status, an existing binding, a tombstone,
    /// or the selection), so a worktree whose only PR was bound by the
    /// `gh pr create` hook — on a branch it never checked out, hence in no
    /// status cache — stayed invisible until the user selected it. That is the
    /// headline case of the multi-PR design, so the daemon reports the whole
    /// table and the app replaces its maps wholesale.
    ///
    /// The two surviving semantics:
    ///
    /// - a FAILED fetch keeps the previous maps. It is now one failure for the
    ///   whole fleet rather than one per worktree, so this early return is the
    ///   only thing standing between an RPC hiccup and every toolbar blanking at
    ///   once.
    /// - a worktree ABSENT from a SUCCESSFUL response loses its entry, so a
    ///   `tbd pr detach` is observed. `PRBindingRefresh.state(from:)` owns that,
    ///   which is how it can be asserted without a daemon.
    func refreshPRBindings() async {
        let result: PRBindingsAllResult
        do {
            result = try await prBindingsFetcher()
        } catch {
            // Leave the previous values in place — a failed fetch is not
            // evidence that any worktree lost its PRs.
            logger.error("Failed to list PR bindings: \(String(describing: error), privacy: .public)")
            return
        }
        let next = PRBindingRefresh.state(from: result)
        if next.bindings != prBindings { prBindings = next.bindings }
        if next.detachedCounts != prDetachedCounts { prDetachedCounts = next.detachedCounts }
    }

    /// Trigger an immediate PR refresh for one worktree (on-select).
    func refreshPRStatus(worktreeID: UUID) async {
        do {
            let status = try await daemonClient.refreshPRStatus(worktreeID: worktreeID)
            if status != prStatuses[worktreeID] {
                prStatuses[worktreeID] = status
            }
        } catch {
            logger.error("Failed to refresh PR status for \(worktreeID): \(error)")
            handleConnectionError(error)
        }
        // Bindings are fetched even when the status refresh failed: the two
        // come from different daemon paths (a `gh` call versus one indexed
        // SELECT), so a GitHub hiccup must not also blank the dropdown. The
        // whole fleet comes back rather than this worktree alone — it is one
        // round trip either way, and a targeted fetch is what left hook-bound
        // worktrees invisible until they were selected.
        await refreshPRBindings()
    }

    /// Refresh unread notifications from the daemon.
    /// Notifications for currently visible worktrees (selected or pinned) are
    /// automatically marked as read so the badge never appears while the user
    /// is looking at the terminal.
    func refreshNotifications() async {
        do {
            let fetched = try await daemonClient.listNotifications()

            // Auto-mark-as-read for worktrees the user is currently looking at
            let visible = visibleWorktreeIDs
            let toMarkRead = Self.worktreeIDsToAutoMarkRead(unreadSummaries: fetched, visible: visible)
            for worktreeID in toMarkRead {
                do {
                    try await daemonClient.markNotificationsRead(worktreeID: worktreeID)
                } catch {
                    logger.warning("Failed to auto-mark-read for \(worktreeID): \(error)")
                }
            }

            // Only include notifications for non-visible worktrees in UI state
            let filtered = fetched.filter { !visible.contains($0.key) }
            if filtered != unreadByWorktree {
                unreadByWorktree = filtered
            }
        } catch {
            logger.error("Failed to list notifications: \(error)")
            handleConnectionError(error)
        }
    }

    /// Pure mirror of `refreshNotifications`' auto-mark-read reconcile: a
    /// `notifications.markRead` RPC is due only for worktrees that BOTH have
    /// unread rows (present in the daemon's unread-only summary) AND are
    /// currently visible. Keying off the fetched summary is load-bearing in
    /// two directions: idle poll ticks (no unread anywhere) fire zero RPCs,
    /// and a notification arriving while its worktree is already visible is
    /// still marked read on the next tick. A guard on `unreadByWorktree`
    /// would break the latter — it excludes visible worktrees by
    /// construction, so an arrive-while-visible notification would never
    /// qualify and would resurface as unread once the worktree left view.
    nonisolated static func worktreeIDsToAutoMarkRead(
        unreadSummaries: [UUID: UnreadSummary],
        visible: Set<UUID>
    ) -> [UUID] {
        unreadSummaries.keys.filter { visible.contains($0) }
    }

    /// UserDefaults key for the WIP terminal-auto-resize feature. Off by
    /// default — the feature broadcasts main-area pixel size to the daemon
    /// and resizes every tracked tmux window on app resize / terminal
    /// create. See `mainAreaTerminalSize()` and `scheduleMainAreaSizeBroadcast()`
    /// for the two enforcement points. Settings UI toggle lives in the
    /// "Experimental" section of the General settings tab.
    static let terminalAutoResizeKey = "enableTerminalAutoResize"

    /// UserDefaults key for showing the sidebar's Scratch section (repo-less
    /// scratch spaces). Default on.
    static let showScratchSectionKey = "showScratchSection"

    /// UserDefaults key for the Claude tab hover card (account email, profile,
    /// 5h/weekly usage, spawn time). Default on; the Settings → Claude toggle
    /// turns it off for users who find the hover card noisy.
    static let showClaudeTabUsageTooltipKey = "showClaudeTabUsageTooltip"

    /// Pure, testable mirror of the sidebar's Scratch-section gate:
    /// shown whenever the setting is on, regardless of whether any scratch
    /// spaces exist yet. This keeps the section (and its hover "+" create
    /// button) reachable for a brand-new user with zero scratch spaces —
    /// otherwise there'd be no UI path to create the first one.
    /// `spaces` is currently unused for the visibility decision but is kept
    /// in the signature for API stability with the existing call site.
    nonisolated static func scratchSectionVisible(setting: Bool, spaces: [Worktree]) -> Bool {
        setting
    }

    /// Pure, testable mirror of the sidebar's Remote-section gate: shown only
    /// when at least one provider is registered. Unlike Scratch, there's no
    /// user-facing "create the first one" affordance to keep reachable — a
    /// provider is registered out-of-band (config), not created from this
    /// section — so an empty roster simply hides the section entirely.
    nonisolated static func remoteSectionVisible(providers: [RemoteProviderStatus]) -> Bool {
        !providers.isEmpty
    }

    /// Pure, testable mirror of `WorktreeRowView`'s scratch-row dimming rule:
    /// a scratch row dims only when its directory is missing AND it was
    /// never promoted. `tbd scratch promote` MOVES the folder to its
    /// destination repo, so a promoted row's directory never exists again —
    /// dimming it as "missing" would contradict the "→ promoted to <repo>"
    /// caption shown alongside it. Non-scratch worktrees never dim here.
    ///
    /// `directoryExists` is an autoclosure so the caller's `stat()` is only
    /// paid for un-promoted scratch rows: every sidebar row re-evaluates its
    /// body on any AppState `@Published` change, and an eager argument would
    /// charge every regular row a synchronous disk hit per render for a flag
    /// this rule ignores.
    nonisolated static func scratchRowIsDimmed(
        _ worktree: Worktree,
        directoryExists: @autoclosure () -> Bool
    ) -> Bool {
        worktree.isScratch && worktree.promotedToRepoID == nil && !directoryExists()
    }

    /// Whether the WIP main-area resize broadcast is enabled. Default false.
    private var terminalAutoResizeEnabled: Bool {
        userDefaults.bool(forKey: Self.terminalAutoResizeKey)
    }

    /// UserDefaults key mirroring the `@AppStorage("autoSuspendClaude")`
    /// toggle in the Settings → Experimental section. Read from non-View
    /// contexts (the pre-sleep suspend hook) so the gate is honored outside
    /// the View layer.
    static let autoSuspendClaudeKey = "autoSuspendClaude"

    /// Whether auto-suspend is enabled. Fails closed: defaults to false when
    /// the user has never touched the toggle, matching the `@AppStorage`
    /// defaults. Tests pass a private `UserDefaults(suiteName:)` so they
    /// never mutate the developer's live app preferences.
    static func autoSuspendClaudeEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: autoSuspendClaudeKey) as? Bool ?? false
    }

    /// UserDefaults key mirroring the `@AppStorage` toggle in
    /// Settings → Fleet Automation that gates the Nightwatch / Daywatch feature.
    /// When off (the default), the sidebar mode control is hidden entirely —
    /// the desk agent acts on the live fleet (nudging stuck sessions,
    /// dispatching work) and its safety rules are still changing, so it
    /// stays opt-in.
    static let nightwatchExperimentalKey = "nightwatchExperimentalEnabled"

    /// Whether the experimental Nightwatch / Daywatch UI is enabled. Fails
    /// closed: defaults to false so the sidebar control only appears once the
    /// user opts in from Settings → Fleet Automation. Tests pass a private
    /// `UserDefaults(suiteName:)` so they never touch live app preferences.
    static func nightwatchExperimentalEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: nightwatchExperimentalKey) as? Bool ?? false
    }

    /// Pure target-selection for the pre-sleep suspend hook. Returns the
    /// worktree IDs to best-effort suspend before the machine sleeps:
    /// `[]` when auto-suspend is disabled, otherwise every worktree ID
    /// (flattened across repos, plus repo-less scratch spaces — the daemon's
    /// suspend handler is worktree-kind agnostic). No I/O — trivially
    /// unit-testable for both gate branches without a live daemon.
    static func worktreeIDsToSuspendForSleep(
        worktrees: [UUID: [Worktree]],
        scratchWorktrees: [Worktree],
        autoSuspendEnabled: Bool
    ) -> [UUID] {
        guard autoSuspendEnabled else { return [] }
        return worktrees.values.flatMap { $0 }.map(\.id) + scratchWorktrees.map(\.id)
    }

    /// Best-effort suspend of idle Claude terminals across all worktrees when
    /// the machine is about to sleep, so if the tmux server dies during a long
    /// sleep, wake has less to recover.
    ///
    /// This is an OPT-IN optimization gated on the existing `autoSuspendClaude`
    /// toggle (default OFF) — NOT the safety net. Short sleeps (lid close)
    /// usually leave the tmux server alive, so unconditionally exiting every
    /// idle Claude session on every sleep would force needless manual resumes.
    /// The unconditional safety is #284 (park-on-reboot), which already
    /// guarantees no OOM by parking terminals as suspended on reboot/server
    /// death. Gating keeps all proactive-suspend behavior under the one toggle
    /// the user already controls.
    ///
    /// When the gate is off this makes ZERO daemon calls. Otherwise it fires a
    /// fire-and-forget `worktreeSuspend` per worktree; the daemon filters to
    /// `isClaudeResumable && suspendedAt == nil`, waits briefly per terminal
    /// for idle, and skips busy ones — so firing for every worktree is safe and
    /// no-ops worktrees with nothing to suspend.
    func suspendIdleClaudeForSleep(defaults: UserDefaults = .standard) {
        let enabled = Self.autoSuspendClaudeEnabled(defaults: defaults)
        let ids = Self.worktreeIDsToSuspendForSleep(
            worktrees: worktrees,
            scratchWorktrees: scratchWorktrees,
            autoSuspendEnabled: enabled
        )
        guard !ids.isEmpty else {
            logger.debug("suspendIdleClaudeForSleep: nothing to do (enabled=\(enabled, privacy: .public))")
            return
        }
        logger.info("suspendIdleClaudeForSleep: best-effort suspending \(ids.count, privacy: .public) worktree(s) before sleep")
        for id in ids {
            Task { [daemonClient] in
                try? await daemonClient.worktreeSuspend(worktreeID: id)
            }
        }
    }

    /// UserDefaults key for the `@AppStorage` toggle in the Settings → Claude
    /// section that gates the live transcript pane. The View layer
    /// (`PanePlaceholder`) reads it directly via `@AppStorage`;
    /// `transcriptFeatureEnabled(defaults:)` exposes the same read for non-View
    /// callers. On by default — the toggle only exists so a user can turn the
    /// pane off.
    static let enableTranscriptKey = "enableTranscript"

    /// The one default for `enableTranscriptKey`. Every read site — this
    /// helper and each View's `@AppStorage` — must spell the default with this
    /// constant, never a bare literal: an `@AppStorage` default that disagrees
    /// with the helper is invisible (both compile, both "work") and silently
    /// makes the pane appear enabled to one caller and disabled to another.
    static let enableTranscriptDefault = true

    /// UserDefaults key for the usage reset-time display preference
    /// (Settings → Claude → "Usage reset times"). Stores the raw value of
    /// `ProfileUsagePresentation.ResetTimeStyle`; defaults to `.timeOfReset`.
    /// Read via `@AppStorage` in the view layer and injected into the
    /// presentation helpers as a parameter — never read from
    /// `UserDefaults.standard` inside them (tests construct with explicit
    /// values).
    static let usageResetTimeStyleKey = "usageResetTimeStyle"

    /// Read of the live-transcript toggle for non-View callers (the View layer
    /// uses `@AppStorage` directly). Defaults to true when the user has never
    /// touched the toggle, matching the `@AppStorage` default.
    static func transcriptFeatureEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enableTranscriptKey) as? Bool ?? enableTranscriptDefault
    }

    /// UserDefaults key for a Claude spawn-env setting, by registry ID.
    nonisolated static func claudeEnvKey(_ settingID: String) -> String {
        "claudeEnvSetting.\(settingID)"
    }

    /// Build the overrides map from UserDefaults: a setting is included only
    /// when the user has changed it from its registry default. Settings left
    /// at default are omitted so the daemon falls back to registry defaults.
    nonisolated static func claudeEnvOverrides(defaults: UserDefaults = .standard) -> [String: ClaudeEnvValue] {
        var overrides: [String: ClaudeEnvValue] = [:]
        for setting in ClaudeEnvRegistry.all {
            let key = claudeEnvKey(setting.id)
            switch setting.kind {
            case .toggle(let def, _):
                if let stored = defaults.object(forKey: key) as? Bool, stored != def {
                    overrides[setting.id] = .bool(stored)
                }
            }
        }
        return overrides
    }

    /// Push the current Claude spawn-env setting overrides to the daemon.
    /// Safe to call repeatedly — the daemon persists the latest value.
    func pushClaudeSpawnPreferences() {
        let overrides = Self.claudeEnvOverrides(defaults: userDefaults)
        Task { [daemonClient] in
            try? await daemonClient.setClaudeSpawnPreferences(
                ClaudeSpawnPreferences(settingOverrides: overrides))
        }
    }

    /// Push the app's current foreground state to the daemon. Called on every
    /// (re)connect: the daemon defaults to background git-polling cadence at
    /// startup, and only the focus notifications would otherwise correct it —
    /// which never fire if the app was already active when the daemon started.
    func pushForegroundState() {
        let isForeground = NSApp?.isActive ?? false
        Task { [daemonClient] in
            do {
                try await daemonClient.setAppForegroundState(isForeground: isForeground)
            } catch {
                logger.warning("pushForegroundState(\(isForeground)) failed: \(error)")
            }
        }
    }

    /// Convert the current `mainAreaSize` (pixels) into tmux cell dimensions
    /// using SwiftTerm's font metrics. Floors at the tmux minimum (80x24) so
    /// degenerate window sizes during launch never produce a too-small pane.
    /// Returns `(nil, nil)` when the auto-resize feature flag is off so the
    /// daemon's `cols ?? TmuxManager.defaultCols` / `rows ?? defaultRows`
    /// fallback fires (220×50). Returning `(0, 0)` would NOT trigger the
    /// fallback — `Optional.some(0)` is non-nil — and tmux would drop back
    /// to its own 80×24 default with the un-reflowable hard-wrapped
    /// scrollback that #73 introduced these defaults to prevent.
    func mainAreaTerminalSize() -> (cols: Int?, rows: Int?) {
        guard terminalAutoResizeEnabled else { return (nil, nil) }
        // Use the user's current font so initial pane dimensions match what
        // the freshly-spawned `TBDTerminalView` will render with. Falls back
        // to the SwiftTerm default if `appearance` hasn't been wired yet
        // (only possible during pre-`onAppear` startup ordering).
        let font = appearance?.font ?? TBDTerminalView.defaultMonospaceFont
        let cell = TBDTerminalView.cellDimensions(for: font)
        guard cell.width > 0, cell.height > 0 else { return (80, 24) }
        let cols = max(80, Int(mainAreaSize.width / cell.width))
        let rows = max(24, Int(mainAreaSize.height / cell.height))
        return (cols, rows)
    }

    /// Debounced RPC: tell the daemon the main area resized so it can resize
    /// every tracked tmux window. Coalesces rapid resize events into a single
    /// RPC ~300ms after the user stops dragging the window edge.
    private func scheduleMainAreaSizeBroadcast() {
        // Belt-and-suspenders: `mainAreaTerminalSize()` already returns
        // (nil, nil) when the flag is off, but this also avoids spinning up
        // the debounce Task and the noop diff against `lastBroadcastCols/Rows`
        // for every mainAreaSize change while disabled.
        guard terminalAutoResizeEnabled else { return }
        mainAreaSizeBroadcastTask?.cancel()
        let (cols, rows) = mainAreaTerminalSize()
        guard let cols, let rows else { return }
        // Skip noop broadcasts: same cell dims as the previous send.
        guard cols != lastBroadcastCols || rows != lastBroadcastRows else { return }
        mainAreaSizeBroadcastTask = Task { [weak self] in
            // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            guard !Task.isCancelled, let self else { return }
            do {
                try await self.daemonClient.setMainAreaSize(cols: cols, rows: rows)
                self.lastBroadcastCols = cols
                self.lastBroadcastRows = rows
            } catch {
                logger.warning("setMainAreaSize broadcast failed: \(error)")
            }
        }
    }

}
