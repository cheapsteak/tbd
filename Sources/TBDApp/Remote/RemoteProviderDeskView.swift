import SwiftUI
import TBDShared

/// Read-only provider-level control surface from issue #565 milestone 2.
/// Every value comes from the provider/session mirror already held by
/// `AppState`; this view never infers capacity or invokes a remote command.
struct RemoteProviderDeskView: View {
    let provider: RemoteProviderStatus

    @EnvironmentObject private var appState: AppState
    @State private var isRefreshing = false
    @State private var runningRemediation: RemoteRemediationRun?

    /// The registry key, never `describe.name` — see
    /// `RemoteProviderIdentityPresentation` for why the desk must not lead
    /// with the provider's KIND.
    private var displayName: String { RemoteProviderIdentityPresentation.headline(provider) }

    private var identityRows: [RemoteProviderIdentityPresentation.Row] {
        RemoteProviderIdentityPresentation.rows(provider)
    }

    private var inventoryState: RemoteProviderInventoryState {
        RemoteProviderInventoryState.make(provider: provider, sessionCount: summary.total)
    }

    private var crossProviderNote: String? {
        RemoteProviderInventoryState.crossProviderNote(
            currentProvider: provider.config.name, sessions: appState.remoteSessions)
    }

    private var summary: RemoteProviderDeskSummary {
        RemoteProviderDeskSummary(provider: provider.config.name, sessions: appState.remoteSessions)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                masthead
                identityBlock
                healthNotice
                attentionNotices
                stateStrips
                sessionLedger
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(displayName)
        .sheet(item: $runningRemediation) { run in
            RemoteRemediationTerminalSheet(run: run)
        }
    }

    private var masthead: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(healthTint.opacity(0.12))
                Image(systemName: healthSymbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(healthTint)
            }
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(displayName)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    // Only when it says something the registry key doesn't:
                    // two entries running the same binary report the same
                    // kind, so showing it unconditionally is what made them
                    // look like the same provider.
                    if let kind = RemoteProviderIdentityPresentation.kindSubtitle(provider) {
                        Text(kind)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 7) {
                    Text(healthTitle)
                    Text("·")
                    Text(freshnessLabel)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Button {
                refresh()
            } label: {
                Label(isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshing)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh provider and mirrored session state")
            .accessibilityLabel(isRefreshing ? "Refreshing provider" : "Refresh provider")
        }
    }

    /// Which backend this registry entry is pointed at, as far as TBD can
    /// honestly say: the provider's own `describe.identity` pairs when it
    /// sends them, and the locally-derivable command line and versions
    /// regardless.
    private var identityBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(identityRows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 108, alignment: .leading)
                    Text(row.value)
                        .font(.callout.monospaced())
                        .foregroundStyle(row.isDistinguishing ? .primary : .secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .accessibilityElement(children: .combine)
            }
            if provider.describe?.identity?.hasDisplayablePairs != true {
                Text("This provider reports no backend identity, so TBD can only show the "
                     + "command it runs. Two entries pointing at different backends are "
                     + "distinguishable here only by that command.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The attention axis, in words: which sessions are blocked and on what,
    /// and how many live terminals are reporting nothing about their agent.
    @ViewBuilder
    private var attentionNotices: some View {
        if !summary.needsAttention.isEmpty || summary.unattributedRunningNotice != nil {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(summary.needsAttention) { session in
                    Button {
                        appState.selectRemoteSession(
                            provider: session.provider, sessionID: session.payload.id)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "hand.raised.fill")
                                .foregroundStyle(SuffixRowIndicator.attention.color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.payload.title ?? session.payload.id)
                                    .fontWeight(.semibold)
                                Text(RemoteAgentAttention.explanation(for: session) ?? "Waiting for input.")
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let notice = summary.unattributedRunningNotice {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                        Text(notice)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                SuffixRowIndicator.attention.color.opacity(summary.needsAttention.isEmpty ? 0 : 0.08),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09))
            }
        }
    }

    @ViewBuilder
    private var healthNotice: some View {
        switch provider.health {
        case .ok:
            EmptyView()
        case .needsAuth:
            if let presentation = RemoteProviderAuthPresentation.make(from: provider) {
                RemoteProviderAuthCTAView(
                    presentation: presentation,
                    showsSessionReassurance: false,
                    onRun: { runningRemediation = RemoteRemediationRun(presentation) }
                )
                .padding(16)
                .background(healthTint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case .stale, .error:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: healthSymbol)
                    .foregroundStyle(healthTint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(healthTitle).fontWeight(.semibold)
                    Text(healthDetail)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(healthTint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var stateStrips: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Work at a glance")
                .font(.headline)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    terminalStrip
                    agentStrip
                }
                VStack(spacing: 12) {
                    terminalStrip
                    agentStrip
                }
            }
        }
    }

    private var terminalStrip: some View {
        ProviderStateStrip(
            title: "Terminal",
            subtitle: "Process state",
            metrics: [
                .init(label: "Starting", value: summary.terminal.starting, tint: .secondary),
                // Not green. Green is the colour a reader takes for progress,
                // and a running terminal is not progress — the agent strip
                // beside this one is the only place that can say so.
                .init(label: "Running", value: summary.terminal.running, tint: .primary),
                .init(label: "Exited", value: summary.terminal.exited, tint: .secondary),
                .init(label: "Gone", value: summary.terminal.gone, tint: .orange),
                .init(label: "Unknown", value: summary.terminal.unknown, tint: .secondary),
            ]
        )
    }

    private var agentStrip: some View {
        ProviderStateStrip(
            title: "Agent",
            subtitle: "Attention state",
            metrics: [
                .init(label: "Working", value: summary.agent.working, tint: .green),
                .init(label: "Waiting", value: summary.agent.waitingInput, tint: SuffixRowIndicator.attention.color),
                .init(label: "Idle", value: summary.agent.idle, tint: .secondary),
                .init(label: "Exited", value: summary.agent.exited, tint: .secondary),
                .init(label: "Unknown", value: summary.agent.unknown, tint: .secondary),
            ]
        )
    }

    private var sessionLedger: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sessions").font(.headline)
                Text("\(summary.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Select a row for attach, log, and session actions")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if inventoryState.warrantsNotice {
                inventoryNotice
            }

            if summary.sessions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.stack.badge.minus")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(inventoryState.title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(emptyStateGuidance)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 38)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                LazyVStack(spacing: 1) {
                    ForEach(summary.sessions) { session in
                        ProviderSessionLedgerRow(session: session) {
                            appState.selectRemoteSession(
                                provider: session.provider,
                                sessionID: session.payload.id
                            )
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09))
                }
            }
        }
    }

    /// The four not-simply-current readings of this provider's inventory,
    /// each stated as itself. A stale list, a list TBD has never populated,
    /// a list whose freshness is unreadable, and a successfully EMPTY list
    /// are four different facts, and only the last is evidence about the
    /// backend.
    private var inventoryNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: inventoryState.isCurrent ? "tray" : "clock.badge.questionmark")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(inventoryState.title).fontWeight(.semibold)
                Text(inventoryState.detail())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The direct answer to "did I just look at the wrong
                // provider" — the confusion this whole surface exists to end.
                if let crossProviderNote {
                    Text(crossProviderNote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// What to do next when the list is empty, which depends on whether the
    /// emptiness is a fact about the provider or about TBD's knowledge of it.
    private var emptyStateGuidance: String {
        // Don't send the user to a control this provider's own state has
        // disabled: `RemoteProviderHeaderRow` gates `+` on `hasStaleSnapshot`
        // until a full inventory recovers.
        if provider.hasStaleSnapshot {
            return "Creating sessions is unavailable until a refresh succeeds."
        }
        if case .emptySuccess = inventoryState {
            return "Use the + button beside \(displayName) in the sidebar to create one."
        }
        return "Refresh to ask \(displayName) for its inventory."
    }

    private var freshnessLabel: String {
        RemoteProviderDeskSummary.freshnessLabel(
            lastSuccessfulSnapshotAt: provider.lastSuccessfulSnapshotAt,
            latestMirrorUpdate: summary.latestMirrorUpdate
        )
    }

    private var healthTitle: String {
        switch provider.health {
        case .ok: "Provider responding"
        case .stale: "Provider unreachable"
        case .needsAuth: "Authentication needed"
        case .error: "Provider error"
        }
    }

    private var healthDetail: String {
        switch provider.health {
        case .stale: provider.errorMessage ?? "Mirrored sessions may be stale. Their last reported states remain unchanged."
        case .error: provider.errorMessage ?? "The provider reported an error."
        case .ok, .needsAuth: ""
        }
    }

    private var healthSymbol: String {
        switch provider.health {
        case .ok: "checkmark.circle.fill"
        case .stale: "clock.badge.exclamationmark"
        case .needsAuth: "key.slash"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var healthTint: Color {
        switch provider.health {
        case .ok: .green
        case .stale: .secondary
        case .needsAuth: SuffixRowIndicator.attention.color
        case .error: SuffixRowIndicator.error.color
        }
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await appState.refreshRemote()
            isRefreshing = false
        }
    }
}

private struct ProviderStateMetric: Identifiable {
    let label: String
    let value: Int
    let tint: Color
    var id: String { label }
}

private struct ProviderStateStrip: View {
    let title: String
    let subtitle: String
    let metrics: [ProviderStateMetric]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 0) {
                ForEach(metrics) { metric in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(metric.value)")
                            .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(metric.value == 0 ? Color.secondary : metric.tint)
                        Text(metric.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(metric.label): \(metric.value)")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ProviderSessionLedgerRow: View {
    let session: RemoteSessionInfo
    let onSelect: () -> Void

    private var title: String { session.payload.title ?? session.payload.id }
    private var repo: String { session.payload.meta?["repo"] ?? "No repository" }
    private var branch: String { session.payload.meta?["branch"] ?? "No branch" }
    /// Shared with the repo section's session ordering. A default-options
    /// `ISO8601DateFormatter` rejects the fractional-seconds form a
    /// conforming provider may legally emit, which silently dropped the
    /// "Created …" line for those rows — see `parsedCreatedAt`'s own comment.
    private var createdDate: Date? {
        RepoSectionView.parsedCreatedAt(session.payload.createdAt)
    }

    var body: some View {
        Button(action: onSelect) {
            ViewThatFits(in: .horizontal) {
                wideRow
                narrowRow
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilitySummary)
        .help("Open \(title)")
    }

    private var wideRow: some View {
        HStack(spacing: 16) {
            titleBlock
                .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
            Text(repo)
                .frame(width: 150, alignment: .leading)
                .lineLimit(1)
            Text(branch)
                .frame(width: 150, alignment: .leading)
                .lineLimit(1)
            stateBlock
                .frame(width: 190, alignment: .leading)
            Text(RemoteProviderDeskSummary.agePhrase(since: session.lastSeen))
                .frame(width: 88, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(rowBackground)
    }

    private var narrowRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleBlock
            HStack(spacing: 6) {
                Label(repo, systemImage: "shippingbox")
                Text("·")
                Label(branch, systemImage: "arrow.triangle.branch")
            }
            .lineLimit(1)
            .foregroundStyle(.secondary)
            stateBlock
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(rowBackground)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .fontWeight(session.payload.agentState == .waitingInput ? .semibold : .regular)
                .lineLimit(1)
            Text(session.payload.id)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            if let createdDate {
                Text("Created \(RemoteProviderDeskSummary.agePhrase(since: createdDate))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var stateBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(stateTint)
                    .frame(width: 7, height: 7)
                Text(terminalLabel)
                Text("·")
                Text(RemoteSessionStatePresentation.agentLabel(session.payload.agentState))
            }
            .lineLimit(1)
            // `RemoteAgentAttention` supersedes the bare reason string: it
            // prefers the structured question block when there is one, and
            // it also speaks for the running-but-unattributed row, which has
            // no reason string at all and used to say only "Updated 3m ago".
            if let explanation = RemoteAgentAttention.explanation(for: session) {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("Updated \(RemoteProviderDeskSummary.agePhrase(since: session.lastSeen))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// `RemoteSessionStatePresentation.terminalLabel` already returns a
    /// self-describing "Terminal: …" phrase, so the mirror-only `gone`
    /// condition carries the same prefix rather than reading as a bare
    /// "Gone" beside a fully-qualified agent label.
    private var terminalLabel: String {
        session.gone ? "Terminal: Gone" : RemoteSessionStatePresentation.terminalLabel(session.payload.state)
    }

    private var stateTint: Color {
        if session.gone { return .orange }
        switch session.payload.agentState {
        case .working: return .blue
        case .waitingInput: return .orange
        case .idle: return .secondary
        case .exited: return .secondary
        case .unknown:
            // A running terminal with no agent state was green here, which
            // read as "this session is working" — the exact claim the
            // contract says this combination cannot support.
            return .secondary
        }
    }

    private var rowBackground: Color {
        session.payload.agentState == .waitingInput
            ? Color.orange.opacity(0.055)
            : Color.primary.opacity(0.025)
    }

    /// Both presentation strings are already prefixed ("Terminal: Running",
    /// "Agent: Working"), so adding "terminal"/"agent" here made VoiceOver
    /// read "terminal Terminal: Running, agent Agent: Working".
    private var accessibilitySummary: String {
        let agent = RemoteSessionStatePresentation.agentLabel(session.payload.agentState)
        return "\(title), \(repo), \(branch), \(terminalLabel), \(agent), "
            + "updated \(RemoteProviderDeskSummary.agePhrase(since: session.lastSeen))"
    }
}
