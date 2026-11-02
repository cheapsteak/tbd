import AppKit
import SwiftUI
import TBDShared

/// Sidebar section listing every registered remote-agent provider and its
/// UNMATCHED sessions — ones whose `meta["repo"]` didn't resolve to a
/// locally registered repo (`RemoteSessionInfo.resolvedRepoID == nil`).
/// Matched sessions instead render inside their repo's own `RepoSectionView`
/// section, after its local worktrees (spec 2026-07-24: "daily-driving this
/// is unusable with remote worktrees off in their own section").
///
/// Modeled on `ScratchSectionView`'s flat header+rows composition (no
/// SwiftUI `Section` — this `List` doesn't use one anywhere else). Rendered
/// below the repo `ForEach` in `SidebarView` (not above — position shouldn't
/// make remoteness focal).
///
/// Every registered provider keeps a header here even when all of its sessions
/// are grouped under repositories. The header is now the stable entry point to
/// its Provider Desk. The whole section renders nothing when no providers are
/// registered — see `AppState.remoteSectionVisible(providers:)`.
struct RemoteSectionView: View {
    @Environment(AppState.self) var appState
    /// Read only to place the session rows under their provider's title —
    /// see `SidebarHeaderMetrics.childRowLeadingInset`.
    @AppStorage(AppState.chevronBeforeProjectNameKey)
    private var chevronBeforeProjectName: Bool = AppState.chevronBeforeProjectNameDefault
    /// See `AppState.sidebarWorkflowGroupsKey`.
    @AppStorage(AppState.sidebarWorkflowGroupsKey)
    private var workflowGroups: Bool = AppState.sidebarWorkflowGroupsDefault
    /// See `AppState.sidebarCollapseEndedSessionsKey`.
    @AppStorage(AppState.sidebarCollapseEndedSessionsKey)
    private var collapseEnded: Bool = AppState.sidebarCollapseEndedSessionsDefault

    var body: some View {
        let knownRepoIDs = SidebarSessionPlacement.knownRepoIDs(repos: appState.repos, repoFilter: appState.repoFilter)
        ForEach(
            appState.remoteProviders.filter {
                RemoteSectionView.shouldShowHeader(
                    provider: $0,
                    sessions: appState.remoteSessions,
                    knownRepoIDs: knownRepoIDs
                )
            },
            id: \.config.name
        ) { provider in
            RemoteProviderHeaderRow(provider: provider)
            providerSessionGroups(provider.config.name)
        }
    }

    private var childInsets: EdgeInsets {
        EdgeInsets(top: 0, leading: SidebarHeaderMetrics.childRowLeadingInset(
            chevronBeforeProjectName: chevronBeforeProjectName), bottom: 0, trailing: 0)
    }

    /// Ungrouped (the default), the provider's sessions list inline under
    /// its header; grouped, they file under Remote and Exited disclosures.
    @ViewBuilder
    private func providerSessionGroups(_ provider: String) -> some View {
        let layout = appState.sidebarProviderLayout(
            provider: provider, grouped: workflowGroups, collapseEnded: collapseEnded)
        let remoteID = SidebarGroupID(owner: .provider(provider), kind: .remote)
        let exitedID = SidebarGroupID(owner: .provider(provider), kind: .exited)
        sessionRows(layout.inlineSessions, depth: 0)
        if let ended = layout.ended {
            let endedID = SidebarGroupID(owner: .provider(provider), kind: .ended)
            SidebarGroupHeader(id: endedID, title: "Ended", summary: ended.summary)
                .listRowInsets(childInsets)
            if appState.expandedSidebarGroups.contains(endedID) {
                sessionRows(ended.ended, depth: 1)
            }
        }
        if let groups = layout.remoteGroups {
            SidebarGroupHeader(id: remoteID, title: "Remote", summary: groups.summary)
                .listRowInsets(childInsets)
            if appState.expandedSidebarGroups.contains(remoteID) {
                sessionRows(groups.sessions, depth: 1)
                if groups.hasExited {
                    SidebarGroupHeader(id: exitedID, title: "Exited", summary: groups.exitedSummary)
                        .padding(.leading, 16)
                        .listRowInsets(childInsets)
                    if appState.expandedSidebarGroups.contains(exitedID) {
                        sessionRows(groups.exitedSessions, depth: 2)
                    }
                }
            }
        }
    }

    private func sessionRows(_ sessions: [RemoteSessionInfo], depth: Int) -> some View {
        ForEach(sessions) { session in
            RemoteSessionRowView(session: session)
                .padding(.leading, CGFloat(depth) * 16)
                .listRowInsets(childInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .tag(session.id)
        }
    }

    /// Providers are first-class selectable places, so a registered provider
    /// always keeps a header regardless of health or session grouping.
    nonisolated static func shouldShowHeader(
        provider _: RemoteProviderStatus, sessions _: [RemoteSessionInfo], knownRepoIDs _: Set<UUID>
    ) -> Bool {
        true
    }
}

/// One provider's section header: name + a health-suffix icon when the
/// provider isn't fully healthy, plus a `+` to create a new session on this
/// provider (Task 10 — opens `RemoteCreateSheet` with no repo prefill; the
/// repo-scoped equivalent lives on `RepoSectionView`'s context menu).
/// Styled consistently with `RepoSectionView`'s header (12pt semibold name,
/// 22pt bottom-aligned row) — a provider is the section-level analogue of a
/// repo, so it wears the same weight of chrome rather than
/// `ScratchSectionView`'s `.headline`. The name is a keyboard-accessible
/// button that opens the Provider Desk. Provider health never dims the rows
/// below it: per the contract, an unreachable provider never means its
/// sessions are dead, only that the local mirror may be stale — health is
/// section-level state shown here, the same way a `.missing` repo dims only
/// its own header/chevron in `RepoSectionView`, not an unrelated signal
/// painted onto every row.
struct RemoteProviderHeaderRow: View {
    let provider: RemoteProviderStatus
    @Environment(AppState.self) var appState
    @State private var showingCreateSheet = false
    /// Whether the auth CTA popover (opened from the `.needsAuth` indicator)
    /// is showing.
    @State private var showingAuthPopover = false
    /// Non-nil while the provider's remediation command runs in its own PTY
    /// sheet. Presented from the ROW, not from inside the popover — a
    /// popover can't host a sheet of its own.
    @State private var runningRemediation: RemoteRemediationRun?
    /// Read only to place the title, for the same reason as
    /// `ScratchSectionView`'s copy: this header has no chevron, and a project
    /// row's chevron placement decides which column every section title sits
    /// in. See `SidebarHeaderMetrics.titleLeadingInset`.
    @AppStorage(AppState.chevronBeforeProjectNameKey)
    private var chevronBeforeProjectName: Bool = AppState.chevronBeforeProjectNameDefault

    private var issueSummary: String? {
        RemoteProviderStatusPresentation.issueSummary(provider)
    }

    /// Whether this header's `+` and its `RemoteCreateSheet` may be offered
    /// at all — the fifth create entry routed through
    /// `CloudCreateEntryPresentation`, alongside the two `+` pickers' cloud
    /// rows (`WorktreeProfilePickerView.cloudLaneEntry`) and the two
    /// context-menu items (`RepoSectionView.cloudSessionMenuEntry`,
    /// `WorktreeRowView.cloudSessionMenuEntry`). True for every non-cloud
    /// provider regardless of the flag; false for the compiled cloud provider
    /// once `claude_cloud_enabled` has been turned off, even though the daemon
    /// booted with it on and still keeps the provider registered here — the
    /// state `remote.create` refuses with "claude cloud sessions disabled".
    /// Omitted (not merely disabled) to match the same convention every other
    /// entry follows for this gate; staleness stays a separate,
    /// disabled-not-omitted axis on the button below.
    private var canCreate: Bool {
        CloudCreateEntryPresentation.offersCreate(
            provider: provider,
            claudeCloudEnabled: appState.daemonCapabilities?.claudeCloudEnabled ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: -1) {
            HStack(spacing: SidebarHeaderMetrics.headerSpacing) {
                // The name spans the row's free width instead of a trailing
                // `Spacer()`, so the whole empty stretch is the desk's hit
                // target rather than dead chrome. The title inset is padding
                // INSIDE the label, ahead of that full-width frame, so the
                // indent still belongs to the desk's hit target — padding the
                // button instead would carve the gutter back out of it.
                Button {
                    appState.selectRemoteProvider(provider.config.name)
                } label: {
                    // The registry key. `describe.name` names the provider's
                    // KIND, so two entries running the same binary against
                    // different backends rendered as two identical rows —
                    // see `RemoteProviderIdentityPresentation`.
                    Text(RemoteProviderIdentityPresentation.headline(provider))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(
                            appState.selectedRemoteProvider == provider.config.name
                                ? HierarchicalShapeStyle.primary
                                : HierarchicalShapeStyle.secondary
                        )
                        .lineLimit(1)
                        .padding(.leading, SidebarHeaderMetrics.titleLeadingInset(
                            chevronBeforeProjectName: chevronBeforeProjectName))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(RemoteProviderIdentityPresentation.headline(provider)) provider desk")
                .help(RemoteProviderIdentityPresentation.compactSummary(provider))
                healthSuffix
                if canCreate {
                    Button {
                        showingCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(provider.hasStaleSnapshot)
                    .help(provider.hasStaleSnapshot
                          ? "Inventory is stale; refresh must recover before creating sessions"
                          : "New \(RemoteProviderIdentityPresentation.headline(provider)) session")
                }
            }
            if let issueSummary {
                Text(issueSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Same inset as the name above, so the summary keeps
                    // hanging under it rather than under the chevron column.
                    .padding(.leading, SidebarHeaderMetrics.titleLeadingInset(
                        chevronBeforeProjectName: chevronBeforeProjectName))
                    .help(issueSummary)
            }
        }
        .frame(minHeight: 22, alignment: .bottom)
        .listRowInsets(EdgeInsets(top: 0, leading: SidebarHeaderMetrics.headerRowLeadingInset,
                                  bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(
            appState.selectedRemoteProvider == provider.config.name
                ? Color.accentColor.opacity(0.13)
                : Color.clear
        )
        .sheet(isPresented: $showingCreateSheet) {
            RemoteCreateSheet(provider: provider.config, describe: provider.describe, repoPrefill: nil)
        }
        // No `if let authPresentation` inside: the run carries its own
        // presentation, so health flipping off `.needsAuth` while the
        // command is still running (the expected outcome!) can't collapse
        // the sheet's content to an empty view while it stays presented.
        .sheet(item: $runningRemediation) { run in
            RemoteRemediationTerminalSheet(run: run)
        }
    }

    /// The auth CTA for this provider, or nil when its health isn't
    /// `.needsAuth` — the exact same pure decision the session detail pane
    /// renders, so the two surfaces can't disagree.
    ///
    /// Provider-level chrome, so published health is the ONLY signal here.
    /// The detail pane additionally passes its own session's attach-exit
    /// class (`localAuthExit`); this row has no session in view and nothing
    /// local to add.
    private var authPresentation: RemoteProviderAuthPresentation? {
        RemoteProviderAuthPresentation.make(from: provider)
    }

    @ViewBuilder
    private var healthSuffix: some View {
        switch provider.health {
        case .stale:
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help(issueSummary ?? "Provider unreachable — sessions may be stale")
        case .needsAuth:
            // The indicator is a BUTTON here (unlike the other health cases,
            // which are passive): needing authentication is the one health
            // state with an action attached, and the popover carries the
            // same CTA the session detail pane shows.
            //
            // Reuses the shared adaptive attention tint (`RowStatusIndicator.swift`)
            // rather than raw `.orange` — that pair was chosen for legibility
            // against this exact sidebar background in both appearances.
            Button {
                showingAuthPopover = true
            } label: {
                Image(systemName: "key.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(SuffixRowIndicator.attention.color)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(provider.errorMessage ?? provider.remediationLabel ?? "Authentication needed")
            .popover(isPresented: $showingAuthPopover, arrowEdge: .bottom) {
                if let presentation = authPresentation {
                    RemoteProviderAuthCTAView(
                        presentation: presentation,
                        onRun: {
                            showingAuthPopover = false
                            runningRemediation = RemoteRemediationRun(presentation)
                        }
                    )
                    .padding(14)
                }
            }
        case .error:
            // Reuses the shared suffix error tint rather than raw `.red`.
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(SuffixRowIndicator.error.color)
                .help(issueSummary ?? provider.errorMessage ?? "Provider error")
        case .ok:
            EmptyView()
        }
    }
}

/// One remote-session row. Deliberately built to mirror `WorktreeRowView`'s
/// skeleton (same `HStack` spacing, row height, name font, selection
/// background) and to render through the exact same pure vocabulary
/// functions local rows use (`RowStatusIndicator.leading`/`.suffix`/
/// `.shouldBoldName`, `TypingDotsView`, `RowTooltipPreference`) — a remote
/// session is a session first, a remote one second. There is no green/
/// yellow/red liveness dot and no attention "chip": local rows never
/// advertise raw process liveness, and a colored dot / chip is exactly the
/// foreign dialect that got rejected in review.
///
/// Selection: the row is `.tag(session.id)`'d into the sidebar's shared
/// `List(selection: $appState.selectedWorktreeIDs)` — `session.id` is the
/// deterministic per-(provider, sessionID) UUID from `RemoteSessionIdentity`
/// — the same way `RepoSectionView`'s header row is tagged by `repo.id`.
/// That tag exists purely so the row is List-native keyboard-reachable
/// (arrow-key traversal, focus ring); like a repo header, a remote
/// selection doesn't actually LIVE in `selectedWorktreeIDs` at rest — see
/// `AppState.selectedWorktreeIDs`'s `didSet`, which strips a matched tag
/// back out and routes it through `selectRemoteSession(provider:sessionID:)`
/// instead, so `selectedRemoteSession` stays the single source of truth
/// regardless of whether the row was reached by click (`.onTapGesture`
/// below) or by keyboard.
struct RemoteSessionRowView: View {
    let session: RemoteSessionInfo
    @Environment(AppState.self) var appState
    @State private var isEditing = false
    @State private var isRowHovered = false
    @State private var isNameTruncated = false

    private var selection: RemoteSessionSelection {
        RemoteSessionSelection(provider: session.provider, sessionID: session.payload.id)
    }

    private var isSelected: Bool {
        appState.selectedRemoteSession == selection
    }

    /// TBD-owned override, falling back to the provider's `title`, falling
    /// back to the raw id — mirrors `Worktree.displayName` falling back to
    /// the git-derived `name`. See `AppState.remoteSessionDisplayNames`.
    private var displayName: String {
        appState.remoteSessionDisplayName(
            provider: session.provider, sessionID: session.payload.id, providerTitle: session.payload.title
        )
    }

    private var isPending: Bool {
        session.payload.state == .starting
    }

    private var hasBoldNotification: Bool {
        RowStatusIndicator.shouldBoldName(appState.unreadByRemoteSession[selection]?.type)
    }

    private var isRowSecondary: Bool {
        session.payload.state == .exited
    }

    private var suffixIndicator: SuffixRowIndicator? {
        RemoteSessionRowPresentation.suffixIndicator(
            agentState: session.payload.agentState,
            unreadType: appState.unreadByRemoteSession[selection]?.type
        )
    }

    /// The row's provider health, looked up fresh each render. `.ok` when
    /// the provider is unknown/unregistered — an edge case (the session's
    /// own provider vanished from the roster) that shouldn't paint every
    /// row with a staleness note it can't actually reason about.
    private var providerStatus: RemoteProviderStatus? {
        appState.remoteProviders.first { $0.config.name == session.provider }
    }

    @ViewBuilder
    private func leadingIcon() -> some View {
        switch RowStatusIndicator.leading(isPending: isPending && !isEditing, hasPRStatus: false, isRemote: true) {
        case .pending:
            Image(systemName: "circle.dotted")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 12)
        case .remote:
            // ~10pt, tertiary "whisper" tint — the same opacity the
            // hibernated moon uses — so remoteness reads as a quiet fact
            // tucked in the corner, not a badge. "globe" over a
            // connectivity/antenna glyph on purpose: this row must not
            // imply liveness, and a signal-strength-shaped icon would
            // smuggle that back in under a different shape than the
            // rejected liveness dot.
            Image(systemName: "globe")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Color.secondary.opacity(0.55))
                .frame(width: 12, height: 12)
                .help("Remote session")
        // Neither can occur here — a remote row passes `hasPRStatus: false` and
        // never supplies a PR observation — but the switch must stay exhaustive.
        case .prStatus, .prUnknown, nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private func suffixIcon() -> some View {
        switch suffixIndicator {
        case .working:
            TypingDotsView(color: SuffixRowIndicator.working.color)
                .frame(width: 14, height: 12)
                .padding(.leading, -3)
                .offset(y: 2)
                .help("Agent is working")
        case let indicator?:
            if let symbol = indicator.systemImage {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(indicator.color)
                    .frame(width: 12, height: 12)
                    // `agentStateReason` is tooltip-only, never a visible
                    // element — surfaced here, falling back to a generic
                    // label when the provider didn't supply one.
                    .help(session.payload.agentStateReason ?? "Needs your attention")
            }
        case nil:
            EmptyView()
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            leadingIcon()
            RenameableLabel(
                text: displayName,
                isEditing: $isEditing,
                onCommit: { newName in
                    appState.renameRemoteSession(
                        provider: session.provider, sessionID: session.payload.id, displayName: newName
                    )
                },
                // Lets an empty commit clear the TBD-owned override back to
                // the provider's reported `title` (or the raw id) — without
                // this, once renamed a session could never fall back to the
                // computed default again. `renameRemoteSession` removes the
                // persisted key entirely for an empty/whitespace name.
                allowsEmptyCommit: true
            ) {
                VStack(alignment: .leading, spacing: -2) {
                    Text(displayName)
                        .font(.system(size: 13))
                        .fontWeight(hasBoldNotification ? .bold : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isRowSecondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear { updateNameTruncation(availableWidth: proxy.size.width) }
                                    .onChange(of: proxy.size.width) { _, w in updateNameTruncation(availableWidth: w) }
                                    .onChange(of: displayName) { _, _ in updateNameTruncation(availableWidth: proxy.size.width) }
                            }
                        )
                        .anchorPreference(key: RowTooltipPreferenceKey.self, value: .bounds) { anchor in
                            (isRowHovered && isNameTruncated && !isEditing)
                                ? RowTooltipPreference(text: displayName, anchor: anchor)
                                : nil
                        }
                    if let caption = RemoteSessionRowPresentation.caption(
                        state: session.payload.state, agentState: session.payload.agentState,
                        gone: session.gone, exitCode: session.payload.exitCode,
                        staleness: RemoteSessionRowPresentation.stalenessCaption(
                            health: providerStatus?.health ?? .ok,
                            lastSuccessfulSnapshotAt: providerStatus?.lastSuccessfulSnapshotAt ?? session.lastSeen)
                    ) {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            suffixIcon()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 28)
        // Same dimming convention scratch rows use for a missing directory
        // (`AppState.scratchRowIsDimmed`) — `gone` is the remote analogue of
        // "the thing this row points at is no longer there". Never gated on
        // provider health: an unreachable provider must not dim rows.
        .opacity(session.gone ? 0.5 : 1.0)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isRowHovered = $0 }
        .onTapGesture {
            appState.selectRemoteSession(provider: session.provider, sessionID: session.payload.id)
        }
        .contextMenu {
            let actions = menuActions
            ForEach(Array(actions.items().enumerated()), id: \.offset) { _, item in
                switch item {
                case let .action(action):
                    actionButton(action, actions: actions)
                case .divider:
                    Divider()
                }
            }
        }
    }

    /// The menu's items and side effects, shared with the native sidebar.
    private var menuActions: RemoteSessionActionMenuActions {
        RemoteSessionActionMenuActions(appState: appState, session: session, onRename: { isEditing = true })
    }

    @ViewBuilder
    private func actionButton(
        _ action: RemoteSessionActionMenu.Action, actions: RemoteSessionActionMenuActions
    ) -> some View {
        Button(role: action.role == .destructive ? .destructive : nil) {
            actions.run(action.kind)
        } label: {
            Text(action.title)
        }
        .disabled(!action.isEnabled)
        .help(action.disabledHelp ?? "")
    }

    private func updateNameTruncation(availableWidth: CGFloat) {
        let font = NSFont.systemFont(ofSize: 13, weight: hasBoldNotification ? .bold : .regular)
        let ideal = (displayName as NSString).size(withAttributes: [.font: font]).width
        let truncated = ideal > availableWidth + 0.5
        if truncated != isNameTruncated { isNameTruncated = truncated }
    }
}
