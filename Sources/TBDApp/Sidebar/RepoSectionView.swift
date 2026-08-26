import AppKit
import os
import SwiftUI
import TBDShared

struct HoverPressButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isPressed
                          ? Color.primary.opacity(0.15)
                          : isHovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .padding(6)
            .contentShape(Rectangle())
            .padding(-6)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

struct RepoSectionView: View {
    let repo: Repo
    @Environment(AppState.self) var appState

    @State private var isEditing = false
    @State private var isSectionHovered = false
    @State private var isChevronHovered = false
    @State private var hoverDebounceTask: Task<Void, Error>?
    @State private var showRemoveConfirm = false
    // `.sheet(item:)` over the provider itself (not `.sheet(isPresented:)` +
    // a separate `Bool`) — a nil provider structurally can't present an
    // empty sheet, unlike the previous `if let` inside an `isPresented`
    // sheet body.
    @State private var remoteCreateSheetProvider: RemoteProviderStatus?
    // Hover the `+` (or ⌥-click it) to open the model-profile picker; a plain
    // click still creates a worktree with the default profile.
    @StateObject private var newWorktreeMenu = HoverMenuModel()
    /// Where this row's disclosure chevron sits — after the name (the
    /// default) or before it. See `AppState.chevronBeforeProjectNameKey` and
    /// `chevronButton`.
    @AppStorage(AppState.chevronBeforeProjectNameKey)
    private var chevronBeforeProjectName: Bool = AppState.chevronBeforeProjectNameDefault

    private func onSectionHoverChange(_ hovering: Bool) {
        if hovering {
            hoverDebounceTask?.cancel()
            hoverDebounceTask = nil
            if !isSectionHovered {
                isSectionHovered = true
            }
        } else {
            hoverDebounceTask?.cancel()
            hoverDebounceTask = Task { @MainActor in
                // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
                try await Task.sleep(nanoseconds: 80_000_000)
                isSectionHovered = false
                // The chevron is torn down by this same gate, so its
                // `onHover(false)` may never arrive — without this the
                // worktree rows would stay dimmed at 0.7 forever.
                isChevronHovered = false
            }
        }
    }

    var mainWorktree: Worktree? {
        (appState.worktrees[repo.id] ?? [])
            .first { $0.status == .main }
    }

    var topLevelWorktrees: [Worktree] {
        (appState.worktrees[repo.id] ?? [])
            .filter { ($0.status == .active || $0.status == .creating) && $0.parentWorktreeID == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Remote sessions resolved to this repo (`RemoteSessionInfo.resolvedRepoID
    /// == repo.id`) that do NOT already own a worktree row in this section,
    /// rendered after every local worktree. See
    /// `RepoSectionView.matchedRemoteSessions` for the filter/sort rule.
    ///
    /// Memoized on the two arrays it derives from, because this property is
    /// evaluated far more often than either of them changes: terminal output
    /// flushes the SwiftUI graph continuously, and each evaluation would
    /// otherwise re-run the filter and the date-parsing sort.
    ///
    /// The two comparisons are not equally cheap. `AppState` guards its
    /// `worktrees` writes on inequality, so a refresh that changed nothing
    /// hands back the same buffer, which `Array`'s `==` is implemented to
    /// short-circuit on — an optimization, not a guaranteed contract, and
    /// correctness here does not rest on it: without the short-circuit the
    /// comparison is merely elementwise. `remoteSessions` is assigned
    /// unconditionally on every `refreshRemote()`, so it is elementwise —
    /// still far cheaper than the sort it replaces, and `refreshRemote()` is
    /// driven by change events rather than a timer, so it mostly runs when a
    /// recompute was due anyway.
    var matchedRemoteSessions: [RemoteSessionInfo] {
        let sessions = appState.remoteSessions
        let sectionWorktrees = appState.worktrees[repo.id] ?? []
        if let cached = RepoSectionView.matchedRemoteSessionsCache[repo.id],
           cached.sessions == sessions,
           cached.worktrees == sectionWorktrees {
            return cached.result
        }
        let result = RepoSectionView.matchedRemoteSessions(
            sessions,
            repoID: repo.id,
            worktrees: sectionWorktrees
        )
        RepoSectionView.matchedRemoteSessionsCache[repo.id] =
            (sessions: sessions, worktrees: sectionWorktrees, result: result)
        return result
    }

    /// Backing store for the memoization above: one entry per repo section
    /// that has rendered, replaced in place. Entries are never evicted, so the
    /// bound is repos rendered over the life of the process, not repos
    /// currently registered — removing a repo from the list leaves an inert
    /// entry behind, holding the two source arrays as they stood at that
    /// render — including a snapshot of the whole `remoteSessions` list, which
    /// `AppState` may since have replaced — plus the derived result, which is
    /// this cache's own. That is deliberate: repos are low-cardinality and
    /// user-created, and a removed repo whose section renders again wants the
    /// entry anyway.
    ///
    /// A plain `static var` rather than `@State`: it is written from inside a
    /// `body` evaluation, and SwiftUI state written during a view update
    /// faults with "Modifying state during view update" (the same hazard that
    /// keeps `AppState`'s derived caches `@ObservationIgnored`).
    ///
    /// Note the getter above reads both `remoteSessions` and `worktrees`
    /// *before* consulting this cache. It has to: they are the cache key, but
    /// they are also what registers this view's dependency on them, and a body
    /// served from a cache hit that read neither would drop both — see "THE
    /// WARM-CACHE DEPENDENCY TRAP" in `AppState.swift`. `RepoSectionView`
    /// is inferred `@MainActor` from `View`, so this storage is
    /// main-actor-isolated and race-free; the `nonisolated` statics below
    /// deliberately never touch it, which keeps them callable — and pure —
    /// from a plain test context.
    @MainActor private static var matchedRemoteSessionsCache:
        [UUID: (sessions: [RemoteSessionInfo], worktrees: [Worktree], result: [RemoteSessionInfo])] = [:]

    private var activeWorktreeCount: Int {
        (appState.worktrees[repo.id] ?? [])
            .filter { $0.status == .active || $0.status == .creating }
            .count
    }

    private var removeButtonLabel: String {
        activeWorktreeCount > 0 ? "Archive Worktrees & Remove" : "Remove"
    }

    private var removeConfirmMessage: String {
        let base = "This unregisters the repo from TBD. Your git repository and files on disk are not touched."
        if activeWorktreeCount > 0 {
            let plural = activeWorktreeCount == 1 ? "worktree" : "worktrees"
            return "\(activeWorktreeCount) active \(plural) will be archived first.\n\n\(base)"
        }
        return base
    }

    /// Hoisted out of the chevron `Image`'s `.foregroundStyle` so the type
    /// checker sees a plain property reference there instead of an inline
    /// `AnyShapeStyle`-wrapped ternary — one of two such properties (see
    /// `nameForegroundStyle`) contributing to `RepoSectionView.body`'s
    /// type-check time. Deliberately NOT merged into one shared property
    /// with `nameForegroundStyle`: their non-missing branches differ
    /// (`.secondary` here vs. selection-dependent there), and folding them
    /// together would change the chevron's rendered color when a repo is
    /// selected — a real behavior change, not a pure restructuring.
    private var chevronForegroundStyle: AnyShapeStyle {
        repo.status == .missing
            ? AnyShapeStyle(Color.secondary.opacity(0.5))
            : AnyShapeStyle(HierarchicalShapeStyle.secondary)
    }

    /// See `chevronForegroundStyle` — same hoist, for the repo name label.
    private var nameForegroundStyle: AnyShapeStyle {
        repo.status == .missing
            ? AnyShapeStyle(Color.secondary.opacity(0.5))
            : AnyShapeStyle(appState.selectedRepoID == repo.id ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
    }

    var body: some View {
        headerRow
        if repo.expanded {
            expandedContent
        }
    }

    /// The section header row (chevron, name, `+`) and every modifier
    /// attached to it — extracted out of `body` alongside `expandedContent`,
    /// and further split into `headerHStack` + its own sub-pieces below, so
    /// the type checker sees several smaller expressions instead of one
    /// combining all of them (see the `-warn-long-function-bodies` note on
    /// this file). Pure restructuring: identical content, order, and
    /// modifiers.
    @ViewBuilder
    private var headerRow: some View {
        headerHStack
        .frame(height: 22, alignment: .bottom)
        .background(Color.white.opacity(0.0001))
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectRepo(id: repo.id)
        }
        .onHover { hovering in
            onSectionHoverChange(hovering)
        }
        .contextMenu { repoContextMenu }
        .sheet(item: $remoteCreateSheetProvider) { provider in
            remoteCreateSheetContent(for: provider)
        }
        .confirmationDialog(
            "Remove \(repo.displayName) from list?",
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button(removeButtonLabel, role: .destructive) {
                Task { await appState.removeRepo(repoID: repo.id, force: activeWorktreeCount > 0) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeConfirmMessage)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: SidebarHeaderMetrics.headerRowLeadingInset,
                                  bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .tag(repo.id)
    }

    /// The header row's actual content (the chevron and the name in the order
    /// `chevronBeforeProjectName` asks for, an optional "missing" badge, and
    /// the `+`), with none of `headerRow`'s trailing modifiers — see
    /// `headerRow`'s doc comment.
    @ViewBuilder
    private var headerHStack: some View {
        HStack(spacing: SidebarHeaderMetrics.headerSpacing) {
            if chevronBeforeProjectName {
                chevronButton
            }
            nameLabel
            if !chevronBeforeProjectName {
                chevronButton
            }
            if repo.status == .missing {
                missingBadge
            }
            Spacer()
            newWorktreePlusButton
        }
    }

    /// Whether the chevron button is mounted at all right now — the one
    /// behavior the two placements disagree about, in pure form so a test can
    /// call it without a SwiftUI render. After the name (the default) it rides
    /// the row's hover gate along with the `+`; before the name it is always
    /// mounted.
    ///
    /// Main-actor isolated, unlike this file's other pure statics: it forwards
    /// to `HoverMenuModel.shouldShowPlus`, which is isolated itself, and
    /// calling the real gate matters more here than callability from a
    /// nonisolated test.
    static func chevronMounted(beforeName: Bool, hovered: Bool, menuOpen: Bool) -> Bool {
        SidebarHeaderMetrics.chevronMounted(
            beforeTitle: beforeName,
            revealed: HoverMenuModel.shouldShowPlus(hovered: hovered, menuOpen: menuOpen)
        )
    }

    /// This row's disclosure chevron. Everything about how it looks and when
    /// it is mounted lives in `SectionDisclosureChevron`, which the Scratch
    /// section wears too; what a project row adds is the dimming of a
    /// `.missing` repo and the hover edge that dims its worktree rows.
    private var chevronButton: some View {
        SectionDisclosureChevron(
            isExpanded: repo.expanded,
            beforeTitle: chevronBeforeProjectName,
            isMounted: RepoSectionView.chevronMounted(
                beforeName: chevronBeforeProjectName,
                hovered: isSectionHovered,
                menuOpen: newWorktreeMenu.isOpen
            ),
            accessibilityLabel: repo.expanded
                ? "Collapse \(repo.displayName)"
                : "Expand \(repo.displayName)",
            glyphStyle: chevronForegroundStyle,
            onHoverChange: { isChevronHovered = $0 },
            toggle: {
                Task { await appState.setRepoExpanded(id: repo.id, expanded: !repo.expanded) }
            }
        )
    }

    @ViewBuilder
    private var nameLabel: some View {
        RenameableLabel(
            text: repo.displayName,
            isEditing: $isEditing,
            onCommit: { newName in
                Task {
                    await appState.renameRepo(id: repo.id, displayName: newName)
                }
            }
        ) {
            Text(repo.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(nameForegroundStyle)
        }
        // Claw back the chevron's trailing slack when it leads the name, so
        // the pair reads as one label. Nothing to claw back in the default
        // placement, where the chevron trails instead — see `chevronButton`'s
        // own leading padding there. The constant lives in
        // `SidebarHeaderMetrics` because the chevron-less section headers
        // derive their own title inset from it.
        .padding(.leading, chevronBeforeProjectName ? SidebarHeaderMetrics.nameLeadingClawback : 0)
    }

    @ViewBuilder
    private var missingBadge: some View {
        Text("[missing]")
            .font(.caption)
            .foregroundStyle(.red.opacity(0.7))
        Button("Locate…") {
            locateRepo()
        }
        .buttonStyle(.link)
        .font(.caption)
    }

    /// Hover the `+` (or ⌥-click it) to open the model-profile picker; a
    /// plain click still creates a worktree with the default profile — see
    /// `HoverMenuModel`/`handlePlusButton`.
    @ViewBuilder
    private var newWorktreePlusButton: some View {
        Group {
            if HoverMenuModel.shouldShowPlus(hovered: isSectionHovered, menuOpen: newWorktreeMenu.isOpen) {
                // Hover opens the unified profile picker; its "Choose a
                // branch…" row drills into the branch list. ⌥-click opens
                // it immediately. No tooltip — it would render on top of
                // the hover menu.
                SectionHeaderPlusButton(action: handlePlusButton)
                .accessibilityLabel("New worktree")
                .disabled(repo.status == .missing)
                // `.disabled` blocks the click path but NOT `.onHover`
                // tracking-area events, so gate the hover-open explicitly —
                // a missing repo must never open the picker.
                .onHover { if repo.status != .missing { newWorktreeMenu.triggerHover($0) } }
                .background(
                    FloatingMenuAnchor(
                        isPresented: newWorktreeMenu.isOpen,
                        content: WorktreeProfilePickerView(
                            repoID: repo.id,
                            highlightDefaultProfile: newWorktreeMenu.isTriggerHovered,
                            onClose: { newWorktreeMenu.closeNow() },
                            // The picker closes itself first (see its own
                            // `startRemoteSession`), so this only has to create
                            // outright or present the sheet this view owns.
                            onStartRemoteSession: { startRemoteSession(with: $0) }
                        )
                        .environment(appState)
                        .background(.ultraThickMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onHover { newWorktreeMenu.menuHover($0) }
                    )
                )
            } else {
                Color.clear
            }
        }
        .frame(width: 20, height: 20)
    }

    /// Insets for every row under this section's title, so the rows track
    /// the title's own column rather than a hardcoded number of their own.
    private var childRowInsets: EdgeInsets {
        EdgeInsets(
            top: 0,
            leading: SidebarHeaderMetrics.childRowLeadingInset(
                chevronBeforeProjectName: chevronBeforeProjectName),
            bottom: 0,
            trailing: 0)
    }

    /// The expanded repo's rows: main worktree, top-level worktree subtree
    /// (with drag reorder), then matched remote sessions — extracted out of
    /// `body` alongside `headerRow`. Pure restructuring: identical content,
    /// order, and modifiers.
    @ViewBuilder
    private var expandedContent: some View {
        if let main = mainWorktree {
            WorktreeRowView(worktree: main, isMain: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.0001))
                .opacity(isChevronHovered ? 0.7 : 1.0)
                .onHover { onSectionHoverChange($0) }
                .listRowInsets(childRowInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .tag(main.id)
        }
        ForEach(topLevelWorktrees) { wt in
            WorktreeSubtreeView(worktree: wt, depth: 0, sectionRepoID: repo.id)
                .opacity(isChevronHovered ? 0.7 : 1.0)
                .onHover { onSectionHoverChange($0) }
        }
        .onMove { source, destination in
            appState.reorderTopLevelWorktrees(
                repoID: repo.id,
                fromOffsets: source,
                toOffset: destination
            )
        }
        // Matched remote sessions render AFTER local worktrees, never
        // interleaved: local worktrees have a user-controlled sort order
        // (`sortOrder`/drag reorder above) and remote ones have nothing
        // comparable, so appending is predictable while interleaving
        // would look arbitrary relative to a manual reorder the user set
        // up on purpose.
        ForEach(matchedRemoteSessions) { session in
            RemoteSessionRowView(session: session)
                .opacity(isChevronHovered ? 0.7 : 1.0)
                .onHover { onSectionHoverChange($0) }
                .listRowInsets(childRowInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .tag(session.id)
        }
    }

    /// Sessions resolved to `repoID`, dismissed tombstones excluded, sorted
    /// oldest-first by reported creation time. Pure — split out from the
    /// computed `matchedRemoteSessions` property so it's directly testable
    /// without an `AppState`/view hierarchy. `nonisolated` for the same
    /// reason as `RemoteSectionView`'s pure helpers (see its doc comment).
    ///
    /// `worktrees` is the section's own worktree list, and a session that one
    /// of those rows already stands for is dropped here: a remote lane that
    /// has been adopted into a `Worktree` row renders as that row, and would
    /// otherwise appear a second time as a session row under the same repo.
    /// The join is on the `(provider, sessionID)` pair both sides carry —
    /// `Worktree.location` for the row, `provider`/`payload.id` for the
    /// session — never on display name or branch, which adoption seeds once
    /// and the user is then free to change. The parameter is required rather
    /// than defaulted so a new call site cannot silently reintroduce the
    /// duplicate.
    ///
    /// An adopted lane therefore has exactly one surface, never two. It cannot
    /// yet have zero either, because there is currently no way to retire an
    /// adopted row: archiving a remote lane is refused (stopping the provider's
    /// session is unimplemented), so the row simply persists. When remote
    /// archive does land, this filter needs no change to stay correct —
    /// `AppState.visibleWorktrees` drops archived rows from `worktrees`, so the
    /// session would fall back to rendering as a plain session row.
    nonisolated static func matchedRemoteSessions(
        _ all: [RemoteSessionInfo],
        repoID: UUID,
        worktrees: [Worktree]
    ) -> [RemoteSessionInfo] {
        let adopted = Set(worktrees.map(\.location).filter { !$0.isLocal })
        return all
            .filter { $0.resolvedRepoID == repoID && !$0.dismissed }
            .filter { !adopted.contains(.remote(provider: $0.provider, sessionID: $0.payload.id)) }
            .sorted(by: RepoSectionView.isOrderedByCreation)
    }

    /// Ascending creation-time ordering for two remote sessions. A session
    /// with a missing/unparseable `created_at` (allowed by the contract —
    /// `docs/remote-provider-contract.md` doesn't require it) sorts after
    /// every dated session; any remaining tie (including two undated
    /// sessions) breaks on the row's own stable `id` so ordering is fully
    /// deterministic across renders regardless of source-array order.
    nonisolated static func isOrderedByCreation(_ a: RemoteSessionInfo, _ b: RemoteSessionInfo) -> Bool {
        let da = RepoSectionView.parsedCreatedAt(a.payload.createdAt)
        let db = RepoSectionView.parsedCreatedAt(b.payload.createdAt)
        switch (da, db) {
        case let (x?, y?) where x != y: return x < y
        case (nil, .some): return false
        case (.some, nil): return true
        default: return a.id.uuidString < b.id.uuidString
        }
    }

    /// The two ISO 8601 profiles `parsedCreatedAt` accepts, built once and
    /// reused. `ISO8601DateFormatter.init` bottoms out in ICU's `udat_open`,
    /// and `isOrderedByCreation` parses both of its operands on every
    /// comparison, so building them per call dominated the sort.
    ///
    /// Two formatters and not one: `ISO8601DateFormatter` does not accept both
    /// profiles in a single `formatOptions` value. `formatOptions` is set here
    /// and never mutated afterwards.
    ///
    /// Deliberately NOT `Sendable`, which is what makes the confinement below
    /// machine-checked rather than merely intended: `withLock` requires its
    /// return type to be `Sendable`, so a body that handed a formatter back
    /// out — `withLock { $0 }` — fails to compile.
    private struct CreatedAtParsers {
        let fractionalSeconds: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        let wholeSeconds = ISO8601DateFormatter()
    }

    /// Guards the shared parsers. `parsedCreatedAt` is `nonisolated` so a
    /// plain test context can call it without hopping to `RepoSectionView`'s
    /// inferred `@MainActor` isolation, and Swift Testing runs suites in
    /// parallel — so two threads genuinely can reach one formatter at once,
    /// even though every caller in the app is already on the main actor.
    ///
    /// A lock rather than `nonisolated(unsafe)` because the platform does not
    /// promise what that would assume. Both `NSDateFormatter.h` and
    /// `NSISO8601DateFormatter.h` are audited for sendability, and only
    /// `DateFormatter` carries `NS_SWIFT_SENDABLE` ("All mutable state
    /// protected by locks") — so the subclass's silence is a deliberate
    /// withholding, not an oversight. An uncontended `os_unfair_lock` acquire
    /// is nothing next to the ICU parse it wraps, so the guarantee is close to
    /// free here.
    ///
    /// `uncheckedState:` rather than `initialState:` because the state is not
    /// `Sendable` — see `CreatedAtParsers`. That is the point: it is the
    /// unconstrained initializer that lets a non-`Sendable` value be locked,
    /// and keeping the value non-`Sendable` is what makes escaping it a
    /// compile error.
    nonisolated private static let createdAtParsers =
        OSAllocatedUnfairLock(uncheckedState: CreatedAtParsers())

    nonisolated static func parsedCreatedAt(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        // `docs/remote-provider-contract.md` shows a whole-second
        // `created_at` example but never pins a profile, so a conforming
        // provider can legally emit fractional seconds
        // (`2026-07-24T18:02:11.123Z`) — a default-options formatter rejects
        // those outright, sorting every such row as undated. Try
        // `.withFractionalSeconds` first, then fall back to the plain
        // whole-second profile.
        return RepoSectionView.createdAtParsers.withLock { parsers -> Date? in
            if let date = parsers.fractionalSeconds.date(from: raw) { return date }
            return parsers.wholeSeconds.date(from: raw)
        }
    }

    // MARK: - The cloud gate — pure, view-free forms of what the two owned
    // create surfaces render, so a test can call the exact decision each
    // surface makes rather than re-deriving it. See
    // `CloudCreateEntryPresentationTests`'s cross-surface parity suite,
    // which checks this against `CloudCreateEntryPresentation.pickerProviders`
    // (the `+` picker's gate) and `RemoteProviderHeaderRow.canCreate`
    // (`RemoteSectionView.swift`) — the other two owned surfaces — for
    // agreement.

    /// The providers `newRemoteSessionMenuItem`'s context menu lists. A thin,
    /// named forward to `CloudCreateEntryPresentation.createProviders` so the
    /// view has no inline gate logic of its own to drift from what this
    /// function (and its test coverage) pins.
    nonisolated static func remoteSessionMenuProviders(
        providers: [RemoteProviderStatus], claudeCloudEnabled: Bool
    ) -> [RemoteProviderStatus] {
        CloudCreateEntryPresentation.createProviders(providers, claudeCloudEnabled: claudeCloudEnabled)
    }


    // MARK: - Context menu

    /// Extracted out of the row's `.contextMenu` — the nested conditionals
    /// plus `ForEach` in `newRemoteSessionMenuItem` were part of what pushed
    /// `body`'s type-check time well past budget (see the `-warn-long-
    /// function-bodies` note on this file). Pure restructuring: same items,
    /// same order, same conditions.
    @ViewBuilder
    private var repoContextMenu: some View {
        Button(repo.expanded ? "Collapse" : "Expand") {
            Task { await appState.setRepoExpanded(id: repo.id, expanded: !repo.expanded) }
        }
        Button("Rename...") {
            isEditing = true
        }
        Button(repo.hidden ? "Unhide" : "Hide") {
            Task { await appState.setRepoHidden(id: repo.id, hidden: !repo.hidden) }
        }
        newRemoteSessionMenuItem
        Divider()
        Button("Remove from List...", role: .destructive) {
            showRemoveConfirm = true
        }
    }

    /// A repo-scoped entry point into the create sheet, prefilled with this
    /// repo — omitted (not disabled) when no remote provider is offerable at
    /// all, mirroring how `RemoteSessionActionMenu` omits capability-gated
    /// items rather than graying them out. A single provider skips straight
    /// to the sheet; more than one asks which provider first.
    ///
    /// The compiled cloud provider joins this list for free once the daemon
    /// registers it; `CloudCreateEntryPresentation` is what takes it back out
    /// when the flag has been turned off since boot, and the fast-path count
    /// is decided AFTER that filter so a hidden entry cannot leave a
    /// two-entry submenu with a dead row in it.
    @ViewBuilder
    private var newRemoteSessionMenuItem: some View {
        let providers = RepoSectionView.remoteSessionMenuProviders(
            providers: appState.remoteProviders,
            claudeCloudEnabled: appState.daemonCapabilities?.claudeCloudEnabled ?? false)
        if !providers.isEmpty {
            if providers.count == 1, let only = providers.first {
                Button("New Remote Session…") { openRemoteCreateSheet(for: only) }
                    .disabled(only.hasStaleSnapshot)
            } else {
                Menu("New Remote Session…") {
                    ForEach(providers, id: \.config.name) { provider in
                        Button(provider.describe?.name ?? provider.config.name) {
                            openRemoteCreateSheet(for: provider)
                        }
                        .disabled(provider.hasStaleSnapshot)
                    }
                }
            }
        }
    }

    /// Extracted out of the `.sheet(item:)` body for the same reason as
    /// `repoContextMenu` — a multi-argument `RemoteCreateSheet` init with a
    /// nested `RemoteCreateFormLogic.repoPrefill` call inline in the trailing
    /// closure was contributing to `body`'s type-check time.
    @ViewBuilder
    private func remoteCreateSheetContent(for provider: RemoteProviderStatus) -> some View {
        RemoteCreateSheet(
            provider: provider.config,
            describe: provider.describe,
            // Same normalization `RemoteRepoMatching` uses to resolve a
            // session's `meta["repo"]` back to a repo — so a session created
            // from here round-trips into THIS repo's section instead of
            // landing unmatched.
            repoPrefill: RemoteCreateFormLogic.repoPrefill(remoteURL: repo.remoteURL),
            repoDefaults: repo.remoteCreateDefaults,
            // The section the optimistic lane row belongs to while the
            // provider is starting the session.
            repoID: repo.id
        )
    }

    /// The `+` menu's remote-lane row: create outright when every required
    /// answer is already knowable, and fall back to the form when it is not.
    ///
    /// Deliberately NOT wired to the repo context menu's "New Remote
    /// Session…", which keeps opening the form unconditionally — that item is
    /// how you reach the form to type a prompt or pick a branch, and it stays
    /// the way to do so.
    private func startRemoteSession(with provider: RemoteProviderStatus) {
        let launch = RemoteCreateFormLogic.launch(
            describe: provider.describe,
            repoPrefill: RemoteCreateFormLogic.repoPrefill(remoteURL: repo.remoteURL),
            repoDefaults: repo.remoteCreateDefaults,
            globalDefaults: appState.globalRemoteCreateDefaults,
            generatedSlug: NameGenerator.generate())
        switch launch {
        case .createNow(let paramsJSON):
            Task {
                await appState.createRemoteSession(
                    provider: provider.config.name, paramsJSON: paramsJSON, repoID: repo.id)
            }
        case .openForm:
            // The sheet re-resolves from the same inputs, so it opens on the
            // values this decision just computed.
            openRemoteCreateSheet(for: provider)
        }
    }

    private func handlePlusButton() {
        guard repo.status != .missing else { return }
        switch HoverMenuModel.plusOutcome(optionHeld: NSEvent.modifierFlags.contains(.option)) {
        case .openMenu:
            newWorktreeMenu.openImmediately()
        case .createDefault:
            // A plain click short-circuits any hover-opened menu to the fast
            // default-create path.
            newWorktreeMenu.closeNow()
            createWorktree()
        }
    }

    private func createWorktree() {
        appState.createWorktree(repoID: repo.id)
    }

    private func openRemoteCreateSheet(for provider: RemoteProviderStatus) {
        remoteCreateSheetProvider = provider
    }

    private func locateRepo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the new location of \(repo.displayName)"
        panel.prompt = "Relocate"
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await appState.relocateRepo(id: repo.id, newPath: url.path)
            }
        }
    }
}
