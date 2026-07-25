import AppKit
import SwiftUI
import TBDShared
import os

private let remoteRowLogger = Logger(subsystem: "com.tbd.app", category: "remote")

/// Sidebar section listing every registered remote-agent provider and its
/// live sessions. Modeled on `ScratchSectionView`'s flat header+rows
/// composition (no SwiftUI `Section` — this `List` doesn't use one anywhere
/// else). Rendered below the repo `ForEach` in `SidebarView` (not above —
/// position shouldn't make remoteness focal). Renders nothing when there are
/// no registered providers: the daemon already returns an empty
/// `remoteProviders` array whenever the `remote_backends_enabled` flag is
/// off or no provider is registered (see `AppState.refreshRemote()`),
/// mirrored by the pure `AppState.remoteSectionVisible(providers:)` gate
/// `SidebarView` checks before mounting this view.
struct RemoteSectionView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ForEach(appState.remoteProviders, id: \.config.name) { provider in
            RemoteProviderHeaderRow(provider: provider)
            ForEach(RemoteSectionView.sessions(in: appState.remoteSessions, forProvider: provider.config.name),
                    id: \.payload.id) { session in
                RemoteSessionRowView(session: session)
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
    }

    /// Sessions belonging to one provider, dismissed tombstones excluded.
    /// Pure — split out from `body` so it's directly testable without
    /// constructing a view hierarchy. `nonisolated` because `View.body`
    /// being `@MainActor` otherwise infers whole-type MainActor isolation
    /// onto every member (including this one) — calling that inferred
    /// isolation from a plain (non-`@MainActor`) test context traps at
    /// runtime instead of failing to compile.
    nonisolated static func sessions(in all: [RemoteSessionInfo], forProvider provider: String) -> [RemoteSessionInfo] {
        all.filter { $0.provider == provider && !$0.dismissed }
    }
}

/// One provider's section header: name + a health-suffix icon when the
/// provider isn't fully healthy. Styled consistently with
/// `RepoSectionView`'s header (12pt semibold name, 22pt bottom-aligned row)
/// — a provider is the section-level analogue of a repo, so it wears the
/// same weight of chrome rather than `ScratchSectionView`'s `.headline`. No
/// tap/selection — there's no provider-level detail view (Task 10 only
/// routes session selections). Provider health never dims the rows below
/// it: per the contract, an unreachable provider never means its sessions
/// are dead, only that the local mirror may be stale — health is
/// section-level state shown here, the same way a `.missing` repo dims only
/// its own header/chevron in `RepoSectionView`, not an unrelated signal
/// painted onto every row.
struct RemoteProviderHeaderRow: View {
    let provider: RemoteProviderStatus

    var body: some View {
        HStack(spacing: 4) {
            Text(provider.describe?.name ?? provider.config.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            healthSuffix
            Spacer()
        }
        .frame(height: 22, alignment: .bottom)
        .listRowInsets(EdgeInsets(top: 0, leading: -2, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var healthSuffix: some View {
        switch provider.health {
        case .stale:
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("Provider unreachable — sessions may be stale")
        case .needsAuth:
            // Reuses the shared adaptive attention tint (`RowStatusIndicator.swift`)
            // rather than raw `.orange` — that pair was chosen for legibility
            // against this exact sidebar background in both appearances.
            Image(systemName: "key.slash")
                .font(.system(size: 11))
                .foregroundStyle(SuffixRowIndicator.attention.color)
                .help(provider.errorMessage ?? provider.remediationLabel ?? "Authentication needed")
        case .error:
            // Reuses the shared suffix error tint rather than raw `.red`.
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(SuffixRowIndicator.error.color)
                .help(provider.errorMessage ?? "Provider error")
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
/// Selection uses `.onTapGesture` + `.contextMenu` — the same ordering
/// `ScratchSectionView`/`RepoSectionView` headers use in this codebase,
/// since remote sessions have no UUID to key a `List` `.tag()`/`selection:`
/// binding on.
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
                        state: session.payload.state, gone: session.gone, exitCode: session.payload.exitCode
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
            Button("Rename…") { isEditing = true }
            if session.gone {
                Button("Dismiss") {
                    Task {
                        do {
                            try await appState.daemonClient.remoteDismiss(
                                provider: session.provider, sessionID: session.payload.id)
                        } catch {
                            remoteRowLogger.error(
                                "remoteDismiss failed for \(session.provider, privacy: .public)/\(session.payload.id, privacy: .public): \(error, privacy: .public)")
                        }
                    }
                }
            } else {
                Button("Stop", role: .destructive) {
                    Task {
                        do {
                            try await appState.daemonClient.remoteStop(
                                provider: session.provider, sessionID: session.payload.id)
                        } catch {
                            remoteRowLogger.error(
                                "remoteStop failed for \(session.provider, privacy: .public)/\(session.payload.id, privacy: .public): \(error, privacy: .public)")
                        }
                    }
                }
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
    nonisolated static func caption(state: RemoteProcessState, gone: Bool, exitCode: Int?) -> String? {
        if gone { return "no longer reported" }
        switch state {
        case .starting:
            return "Starting…"
        case .exited:
            if let exitCode { return "exited (code \(exitCode))" }
            return "exited"
        case .running, .unknown:
            return nil
        }
    }
}
