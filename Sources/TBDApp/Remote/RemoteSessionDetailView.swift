import SwiftUI
import TBDShared
import os

private let detailLogger = Logger(subsystem: "com.tbd.app", category: "remoteDetail")

/// Which pane `RemoteSessionDetailView` is showing. Also doubles as the
/// one-shot navigation hint carried by `AppState.remoteSessionRequestedTab`
/// (set by a context-menu action like "View Log" that jumps straight to a
/// tab rather than the default).
enum RemoteSessionDetailTab: String, CaseIterable, Equatable, Hashable {
    case attach = "Attach"
    case log = "Log"
}

/// Detail pane shown when a remote-session sidebar row is selected
/// (`AppState.selectedRemoteSession`) — routed from `ContentView` the same
/// way `ScratchDetailView`/`RepoDetailView` are. No file viewer or diff
/// panel: those are local-worktree-only and simply aren't rendered here
/// (spec non-goal for v1 remote sessions).
///
/// The caller (`ContentView`) is expected to key this view with
/// `.id(selection)` — a fresh `RemoteSessionDetailView` per distinct
/// (provider, sessionID) pair, so switching to a DIFFERENT session always
/// starts with fresh `@State` (never an attach process left running against
/// the wrong session, never a previous session's cached log text).
struct RemoteSessionDetailView: View {
    let selection: RemoteSessionSelection
    @EnvironmentObject var appState: AppState

    @State private var selectedTab: RemoteSessionDetailTab = .attach
    @State private var hasStartedAttach = false
    @State private var showStopConfirm = false
    @State private var logRefreshToken = 0

    private var session: RemoteSessionInfo? {
        appState.remoteSessions.first {
            $0.provider == selection.provider && $0.payload.id == selection.sessionID
        }
    }

    private var providerStatus: RemoteProviderStatus? {
        appState.remoteProviders.first { $0.config.name == selection.provider }
    }

    /// Capabilities gate BOTH the tabs here and the context-menu items in
    /// `RemoteSessionActionMenu` — same source (`describe.capabilities`),
    /// same reasoning: omit what the provider hasn't declared rather than
    /// show a control that can only fail.
    private var capabilities: [String] {
        providerStatus?.describe?.capabilities ?? []
    }

    /// `gone` (absent from the provider's last two `list` snapshots) drops
    /// Attach/Send the same way `RemoteSessionActionMenu.items(gone:)`
    /// collapses the context menu — see `RemoteSessionDetailGates`. A
    /// session not yet found in the mirror at all (`session == nil`) is a
    /// distinct, more transient state and isn't treated as gone here.
    private var isGone: Bool {
        session?.gone ?? false
    }

    private var availableTabs: [RemoteSessionDetailTab] {
        RemoteSessionDetailGates.available(capabilities: capabilities, gone: isGone)
    }

    /// The tab actually rendered — derived from `availableTabs` and
    /// `selectedTab` on every `body` evaluation (see
    /// `RemoteSessionDetailGates.initialTab`), rather than trusting
    /// `selectedTab`'s `@State` default to already be correct. This is what
    /// makes a single-tab provider (e.g. `log`-only) render unconditionally:
    /// `selectedTab`'s placeholder default is `.attach`, which is simply not
    /// in `availableTabs` for that provider, so `effectiveTab` falls back to
    /// `.log` — no dependence on `onAppear`/`onChange` timing.
    private var effectiveTab: RemoteSessionDetailTab? {
        RemoteSessionDetailGates.initialTab(available: availableTabs, requested: selectedTab)
    }

    private var displayName: String {
        appState.remoteSessionDisplayName(
            provider: selection.provider, sessionID: selection.sessionID, providerTitle: session?.payload.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if RemoteSessionDetailGates.showsPicker(available: availableTabs) {
                Picker("", selection: $selectedTab) {
                    ForEach(availableTabs, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                Divider()
            }

            contentArea

            if RemoteSessionDetailGates.showsSendField(capabilities: capabilities, gone: isGone) {
                Divider()
                sendField
            }
        }
        .onAppear { adoptPendingTab() }
        .onChange(of: appState.remoteSessionRequestedTab) { _, _ in adoptPendingTab() }
        .onChange(of: availableTabs) { _, tabs in
            // Keeps `selectedTab` itself valid (not just what's rendered,
            // which `effectiveTab` already guarantees) so the Picker's
            // binding never retains a selection that's dropped out of
            // `availableTabs` — e.g. a provider's capabilities shrinking
            // while this view is mounted.
            if let corrected = RemoteSessionDetailGates.initialTab(available: tabs, requested: selectedTab),
               corrected != selectedTab {
                selectedTab = corrected
            }
        }
    }

    /// Consumes (reads AND clears) the one-shot tab hint — checked in both
    /// `onAppear` and `onChange` so it lands whether this view mounted after
    /// the hint was set (normal case) or the hint arrives while already
    /// mounted (reselecting the same tab-jump action twice in a row).
    private func adoptPendingTab() {
        guard let requested = appState.remoteSessionRequestedTab else { return }
        if availableTabs.contains(requested) {
            selectedTab = requested
        }
        appState.remoteSessionRequestedTab = nil
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(displayName)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                if let session, !session.gone {
                    Button("Stop", role: .destructive) { showStopConfirm = true }
                        .confirmationDialog(
                            "Stop \(displayName)?",
                            isPresented: $showStopConfirm,
                            titleVisibility: .visible
                        ) {
                            Button("Stop", role: .destructive) { stopSession() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This asks the provider to terminate the remote session.")
                        }
                }
            }

            HStack(spacing: 8) {
                Text(providerStatus?.describe?.name ?? selection.provider)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let session {
                    chip(session.payload.state.rawValue.capitalized, tint: .secondary)
                    chip(agentStateLabel(session.payload.agentState), tint: agentStateTint(session.payload.agentState))
                }
            }

            if let session, session.gone {
                Label("No longer reported by the provider", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if session == nil {
                Label("Session not found in the current mirror", systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let reason = session?.payload.agentStateReason, !reason.isEmpty {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let meta = session?.payload.meta, !meta.isEmpty {
                metaRows(meta)
            }
        }
        .padding(16)
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
    }

    /// `meta` is treated as opaque display data — every key (including the
    /// well-known `repo`/`branch`) is rendered plainly, sorted by key, per
    /// the contract's rule that a caller with no special handling for a key
    /// just shows it as an opaque row.
    private func metaRows(_ meta: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(meta.keys.sorted(), id: \.self) { key in
                HStack(alignment: .top, spacing: 6) {
                    Text(key)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 60, alignment: .trailing)
                    Text(meta[key] ?? "")
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.top, 2)
    }

    private func agentStateLabel(_ state: RemoteAgentState) -> String {
        state.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func agentStateTint(_ state: RemoteAgentState) -> Color {
        switch state {
        case .working: return .blue
        case .waitingInput: return .orange
        case .idle, .exited, .unknown: return .secondary
        }
    }

    private func stopSession() {
        Task {
            do {
                try await appState.daemonClient.remoteStop(provider: selection.provider, sessionID: selection.sessionID)
            } catch {
                detailLogger.error(
                    "remoteStop failed for \(selection.provider, privacy: .public)/\(selection.sessionID, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var contentArea: some View {
        if availableTabs.isEmpty {
            VStack {
                Spacer()
                Text("This provider doesn't support attach or a log view for this session.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                // The attach pane, once started, stays MOUNTED (just hidden)
                // while another tab is showing — switching to Log must never
                // tear down and respawn the live attach process. Log's own
                // state is cheap to lose and refetch, so it mounts only
                // on-demand instead.
                if availableTabs.contains(.attach) {
                    attachSection
                        .opacity(effectiveTab == .attach ? 1 : 0)
                        .allowsHitTesting(effectiveTab == .attach)
                }
                if effectiveTab == .log, availableTabs.contains(.log) {
                    RemoteLogTabView(
                        provider: selection.provider, sessionID: selection.sessionID, refreshToken: logRefreshToken)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var attachSection: some View {
        if hasStartedAttach, let config = providerStatus?.config {
            RemoteAttachTerminalView(provider: config, sessionID: selection.sessionID)
        } else {
            attachPrompt
        }
    }

    private var attachPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Not attached")
                .font(.headline)
            Text("Attach opens a live terminal to this remote session.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // Explicit user gesture only — selecting this row (or this tab)
            // never spawns the attach process by itself.
            Button("Attach") { hasStartedAttach = true }
                .buttonStyle(.borderedProminent)
                .disabled(providerStatus?.config == nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Send

    @State private var sendText: String = ""
    @State private var isSending = false

    private var sendField: some View {
        HStack(spacing: 8) {
            TextField("Send text to session…", text: $sendText, onCommit: performSend)
                .textFieldStyle(.roundedBorder)
            Button("Send") { performSend() }
                .disabled(sendText.isEmpty || isSending)
        }
        .padding(10)
    }

    private func performSend() {
        guard !sendText.isEmpty else { return }
        let text = sendText + "\n"
        sendText = ""
        isSending = true
        Task {
            defer { isSending = false }
            do {
                try await appState.daemonClient.remoteSend(
                    provider: selection.provider, sessionID: selection.sessionID, text: text)
                // Give the remote side a moment to act before re-pulling
                // scrollback — `send`'s exit 0 only means the bytes reached
                // the transport, not that the agent has acted on them yet
                // (docs/remote-provider-contract.md § `send`).
                try? await Task.sleep(for: .seconds(1))
                logRefreshToken += 1
            } catch {
                detailLogger.error(
                    "remoteSend failed for \(selection.provider, privacy: .public)/\(selection.sessionID, privacy: .public): \(error, privacy: .public)")
            }
        }
    }
}

/// Read-only scrollback view: fetches `remote.log` on appear and whenever
/// `refreshToken` changes (driven by the parent after a `send`), plus a
/// manual Refresh button. Renders the returned text completely as-is — no
/// parsing, no sanitizing, no ANSI stripping (raw provider bytes, ANSI
/// passthrough intended per the contract) — and never infers session state
/// from it (screen-scraping state out of rendered/log text is prohibited in
/// this codebase).
private struct RemoteLogTabView: View {
    let provider: String
    let sessionID: String
    var refreshToken: Int

    @EnvironmentObject var appState: AppState
    @State private var text = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                Button("Refresh") { Task { await fetch() } }
                    .disabled(isLoading)
            }
            .padding(8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
            }
        }
        .onAppear { Task { await fetch() } }
        .onChange(of: refreshToken) { _, _ in Task { await fetch() } }
    }

    private func fetch() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await appState.daemonClient.remoteLog(provider: provider, sessionID: sessionID, lines: 2000)
            text = result.text
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
