import AppKit
import SwiftUI
import TBDShared
import os

private let remoteRowLogger = Logger(subsystem: "com.tbd.app", category: "remote")

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
    @EnvironmentObject var appState: AppState

    var body: some View {
        let knownRepoIDs = RemoteSectionView.knownRepoIDs(repos: appState.repos, repoFilter: appState.repoFilter)
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
            ForEach(RemoteSectionView.sessions(in: appState.remoteSessions, forProvider: provider.config.name, knownRepoIDs: knownRepoIDs)) { session in
                RemoteSessionRowView(session: session)
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .tag(session.id)
            }
        }
    }

    /// Providers are first-class selectable places, so a registered provider
    /// always keeps a header regardless of health or session grouping.
    nonisolated static func shouldShowHeader(
        provider _: RemoteProviderStatus, sessions _: [RemoteSessionInfo], knownRepoIDs _: Set<UUID>
    ) -> Bool {
        true
    }

    /// Repo ids treated as "has its own rendered section" when deciding
    /// whether a MATCHED remote session (non-nil `resolvedRepoID`) has
    /// somewhere else to render. `SidebarView` doesn't actually render
    /// `appState.repos` — it renders `filteredRepos`, which narrows along
    /// two INDEPENDENT axes: the "show hidden repos" toggle, and an active
    /// `repoFilter`. A session whose `resolvedRepoID` names a repo excluded
    /// by either axis has no `RepoSectionView` mounted for it — and, before
    /// this function existed, was ALSO excluded from this section (because
    /// its repo id was still counted "known"), so it rendered nowhere at
    /// all.
    ///
    /// The two axes get a deliberately different answer here, reasoned
    /// about separately (see `RemoteSectionViewTests` for both halves
    /// pinned down):
    ///
    /// - A repo FILTER never narrows this set: only the filtered repo (if
    ///   any) counts as "known", so every OTHER repo's matched sessions
    ///   become "unmatched" for the duration of the filter and fall through
    ///   to render in this section instead. A repo filter is transient view
    ///   state — the sidebar's search-style "scope to one repo", not a
    ///   durable "I don't want to see this" decision — so silently
    ///   swallowing every other repo's remote sessions while it's active
    ///   would be far harder to defend than showing them somewhere.
    /// - Hidden repos are NOT excluded here (this function doesn't consult
    ///   the "show hidden repos" toggle at all) — a hidden repo's id always
    ///   counts as "known", so its matched sessions stay excluded from this
    ///   section and render nowhere, by analogy with hidden WORKTREES,
    ///   which already vanish from the sidebar entirely once their repo is
    ///   hidden. Hiding a repo is a durable choice; its remote sessions
    ///   disappearing along with it is the deliberate consequence, not a
    ///   bug to route around.
    nonisolated static func knownRepoIDs(repos: [Repo], repoFilter: UUID?) -> Set<UUID> {
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
    /// excluded from `RepoSectionView` because that repo's section no longer
    /// exists. Re-checking membership every render (rather than trusting the
    /// stored value) also means this self-heals for free the moment the repo
    /// reappears in `knownRepoIDs` — no new pinning event required. Resolved
    /// (matched-to-a-known-repo) sessions render inside their repo's section
    /// instead (`RepoSectionView.matchedRemoteSessions`). Pure — split out
    /// from `body` so it's directly testable without constructing a view
    /// hierarchy. `nonisolated` because `View.body` being `@MainActor`
    /// otherwise infers whole-type MainActor isolation onto every member
    /// (including this one) — calling that inferred isolation from a plain
    /// (non-`@MainActor`) test context traps at runtime instead of failing
    /// to compile.
    nonisolated static func sessions(
        in all: [RemoteSessionInfo], forProvider provider: String, knownRepoIDs: Set<UUID>
    ) -> [RemoteSessionInfo] {
        all.filter {
            $0.provider == provider && !$0.dismissed
                && ($0.resolvedRepoID == nil || !knownRepoIDs.contains($0.resolvedRepoID!))
        }
    }
}

/// Compact, testable status copy shared by the provider header and detail
/// pane. `RemoteProviderManager` already bounds `errorMessage` before it
/// crosses RPC; this composes that message with the last complete inventory
/// age so the UI states what is stale, not merely that something failed.
enum RemoteProviderStatusPresentation {
    nonisolated static func issueSummary(
        _ status: RemoteProviderStatus, now: Date = Date()
    ) -> String? {
        guard status.health != .ok else { return nil }
        let message = status.errorMessage ?? fallback(for: status.health)
        guard let lastSuccess = status.lastSuccessfulSnapshotAt else {
            return "\(message) · no successful snapshot yet"
        }
        let age = ProfileUsagePresentation.ageText(since: lastSuccess, now: now)
        let agePhrase = age == "just now" ? "last good just now" : "last good \(age) ago"
        return "\(message) · \(agePhrase)"
    }

    private nonisolated static func fallback(for health: ProviderHealth) -> String {
        switch health {
        case .ok: return "Provider healthy"
        case .stale: return "Inventory unavailable"
        case .needsAuth: return "Authentication needed"
        case .error: return "Provider error"
        }
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
    @EnvironmentObject var appState: AppState
    @State private var showingCreateSheet = false
    /// Whether the auth CTA popover (opened from the `.needsAuth` indicator)
    /// is showing.
    @State private var showingAuthPopover = false
    /// Non-nil while the provider's remediation command runs in its own PTY
    /// sheet. Presented from the ROW, not from inside the popover — a
    /// popover can't host a sheet of its own.
    @State private var runningRemediation: RemoteRemediationRun?

    private var issueSummary: String? {
        RemoteProviderStatusPresentation.issueSummary(provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: -1) {
            HStack(spacing: 4) {
                // The name spans the row's free width instead of a trailing
                // `Spacer()`, so the whole empty stretch is the desk's hit
                // target rather than dead chrome.
                Button {
                    appState.selectRemoteProvider(provider.config.name)
                } label: {
                    Text(provider.describe?.name ?? provider.config.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(
                            appState.selectedRemoteProvider == provider.config.name
                                ? HierarchicalShapeStyle.primary
                                : HierarchicalShapeStyle.secondary
                        )
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(provider.describe?.name ?? provider.config.name) provider desk")
                healthSuffix
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
                      : "New \(provider.describe?.name ?? provider.config.name) session")
            }
            if let issueSummary {
                Text(issueSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(issueSummary)
            }
        }
        .frame(minHeight: 22, alignment: .bottom)
        .listRowInsets(EdgeInsets(top: 0, leading: -2, bottom: 0, trailing: 0))
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
    @EnvironmentObject var appState: AppState
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
        RemoteSessionRowView.suffixIndicator(
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

    /// Pure `agentState` + unread-entry → suffix-slot mapping. Split out
    /// (static, no `appState`/`session` dependency beyond its parameters) so
    /// the steady-state `waitingInput` case and the severity merge are
    /// directly testable.
    ///
    /// Feeds the SAME `notification` argument `WorktreeRowView` feeds
    /// `RowStatusIndicator.suffix` — the higher-severity of the row's edge-
    /// triggered unread entry (e.g. `.error` from a nonzero exit) and the
    /// steady-state `agentState` mapped into the same `NotificationType`
    /// vocabulary (`waitingInput` → `.attentionNeeded`). This is a merge of
    /// two inputs into `suffix`'s existing precedence ladder, not a second
    /// ladder: `RowStatusIndicator.suffix` alone still decides what renders.
    /// Without the unread half of this merge, a session that exits nonzero
    /// would render with NO suffix at all (agentState is `.exited`, which
    /// maps to no steady signal) even though `unreadByRemoteSession` holds
    /// `.error` for it — the loudest case rendering as the quietest row.
    ///
    /// The steady half is STEADY, not edge-triggered — deliberately diverges
    /// from local edge semantics. See `AppState.handleRemoteSessionAttentionDelta`'s
    /// doc comment (`AppState+Remote.swift`) for the full rationale: the
    /// contract reports `agent_state` continuously in every poll, exactly
    /// like `.working` (already rendered steady below), and a remote
    /// session has no pane the user can glance at to rediscover it — so
    /// this reads `agentState` fresh every render rather than relying solely
    /// on the edge-triggered `unreadByRemoteSession` map (which clears the
    /// moment the session is selected, even if it's still waiting).
    nonisolated static func suffixIndicator(
        agentState: RemoteAgentState, unreadType: NotificationType?
    ) -> SuffixRowIndicator? {
        let steadyType: NotificationType? = agentState == .waitingInput ? .attentionNeeded : nil
        return RowStatusIndicator.suffix(
            notification: RemoteSessionRowView.higherSeverity(unreadType, steadyType),
            isWorking: agentState == .working,
            isSuspended: false,
            isHibernated: false
        )
    }

    /// The higher-severity of two optional `NotificationType`s (nil sorts
    /// lowest). Uses the existing `NotificationType.severity` ordering — no
    /// new precedence scale invented here.
    nonisolated static func higherSeverity(_ a: NotificationType?, _ b: NotificationType?) -> NotificationType? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let x?, nil): return x
        case (nil, let y?): return y
        case (let x?, let y?): return x.severity >= y.severity ? x : y
        }
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
        case .prStatus, nil:
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
                    if let caption = RemoteSessionRowView.caption(
                        state: session.payload.state, agentState: session.payload.agentState,
                        gone: session.gone, exitCode: session.payload.exitCode,
                        staleness: RemoteSessionRowView.stalenessCaption(
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
            let provider = appState.remoteProviders.first { $0.config.name == session.provider }
            let capabilities = provider?.describe?.capabilities ?? []
            let items = RemoteSessionActionMenu.items(
                capabilities: capabilities, gone: session.gone,
                snapshotFresh: provider?.hasStaleSnapshot != true,
                // Read from the mirror rather than this row's captured
                // `session`, so a dock copy and a section copy of the same
                // session always offer the same verb.
                isPinned: appState.remoteSessionIsPinned(
                    provider: session.provider, sessionID: session.payload.id)
            )
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                switch item {
                case let .action(action):
                    actionButton(action)
                case .divider:
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: RemoteSessionActionMenu.Action) -> some View {
        Button(role: action.role == .destructive ? .destructive : nil) {
            runAction(action.kind)
        } label: {
            Text(action.title)
        }
    }

    /// Dispatches a `RemoteSessionActionMenu.Kind` to its side effect. Kept
    /// inline (unlike `RowActionMenuActions`) since a remote row has far
    /// fewer actions and none of the context-building complexity that
    /// justified splitting the worktree version out.
    private func runAction(_ kind: RemoteSessionActionMenu.Kind) {
        switch kind {
        case .rename:
            isEditing = true
        case .attach:
            appState.selectRemoteSession(provider: session.provider, sessionID: session.payload.id, tab: .attach)
        case .viewLog:
            appState.selectRemoteSession(provider: session.provider, sessionID: session.payload.id, tab: .log)
        case .sendText:
            // No dedicated tab for Send — the send field renders below
            // whichever tab is active, so this just selects the session.
            appState.selectRemoteSession(provider: session.provider, sessionID: session.payload.id)
        case .copySessionID:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.payload.id, forType: .string)
        case .stop:
            Task {
                do {
                    try await appState.daemonClient.remoteStop(
                        provider: session.provider, sessionID: session.payload.id)
                } catch {
                    remoteRowLogger.error(
                        "remoteStop failed for \(session.provider, privacy: .public)/\(session.payload.id, privacy: .public): \(error, privacy: .public)")
                }
            }
        case .dismiss:
            Task {
                do {
                    try await appState.daemonClient.remoteDismiss(
                        provider: session.provider, sessionID: session.payload.id)
                } catch {
                    remoteRowLogger.error(
                        "remoteDismiss failed for \(session.provider, privacy: .public)/\(session.payload.id, privacy: .public): \(error, privacy: .public)")
                }
            }
        case .pin, .unpin:
            let pinned = kind == .pin
            Task {
                await appState.setRemoteSessionPinned(
                    provider: session.provider, sessionID: session.payload.id, pinned: pinned)
            }
        }
    }

    private func updateNameTruncation(availableWidth: CGFloat) {
        let font = NSFont.systemFont(ofSize: 13, weight: hasBoldNotification ? .bold : .regular)
        let ideal = (displayName as NSString).size(withAttributes: [.font: font]).width
        let truncated = ideal > availableWidth + 0.5
        if truncated != isNameTruncated { isNameTruncated = truncated }
    }

    /// Caption shown under the name. Pure — split out for direct testing.
    /// `gone` wins over process `state`: it's a distinct, more severe axis
    /// (absent from the provider's list entirely — see
    /// `docs/remote-provider-contract.md` § Identity & drift — not merely
    /// exited), so the two captions never stack. Exit code is omitted when
    /// the provider didn't report one.
    ///
    /// `staleness`, when non-nil (see `stalenessCaption`), is appended after
    /// a " · " separator — the same combining idiom
    /// `ProfileUsagePresentation.retryingNote` uses for "usage unavailable —
    /// retrying · last data 2h ago". When there's no other caption to
    /// combine with (a plain `running` session under an unhealthy provider),
    /// `staleness` renders alone rather than being dropped — this is
    /// precisely the case the maintainer flagged: a row that otherwise looks
    /// completely normal during an outage.
    nonisolated static func caption(
        state: RemoteProcessState,
        agentState: RemoteAgentState,
        gone: Bool,
        exitCode: Int?,
        staleness: String? = nil
    ) -> String? {
        RemoteSessionStatePresentation.sidebarCaption(
            terminalState: state,
            agentState: agentState,
            gone: gone,
            exitCode: exitCode,
            staleness: staleness
        )
    }

    /// "as of 2h ago" style note shown when this session's provider isn't
    /// `.ok` — the row-level (as opposed to provider-header-level) staleness
    /// signal. Needed because a remote session grouped into its repo's own
    /// sidebar section sits under a REPO header, nowhere near the provider's
    /// health glyph (`RemoteProviderHeaderRow.healthSuffix`) — that glyph
    /// alone is invisible for a matched session, so without this, a two-hour
    /// outage would leave a grouped row looking completely fresh (its
    /// `agentState` chip/caption reflecting whatever was last polled, with
    /// no cue that it's old). Deliberately reuses
    /// `ProfileUsagePresentation.ageText` — the one relative-age formatter
    /// this codebase already has ("just now"/"3m"/"2h"/"1d") — rather than
    /// inventing a second one. Returns nil when healthy so a fully-working
    /// provider's rows never carry the extra text.
    nonisolated static func stalenessCaption(
        health: ProviderHealth, lastSuccessfulSnapshotAt: Date, now: Date = Date()
    ) -> String? {
        guard health != .ok else { return nil }
        let age = ProfileUsagePresentation.ageText(since: lastSuccessfulSnapshotAt, now: now)
        // `ageText`'s "just now" already reads as a complete phrase (see its
        // own callers in `ProfileUsagePresentation`) — appending "ago" to it
        // would read as "as of just now ago". Every other bucket ("3m",
        // "2h", "1d") needs the suffix.
        return age == "just now" ? "as of just now" : "as of \(age) ago"
    }
}
