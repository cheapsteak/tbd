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

/// Pure copy decisions for the two independent remote-session state axes.
/// Shared by the detail header and sidebar so neither can present terminal
/// liveness as evidence of agent activity.
enum RemoteSessionStatePresentation {
    static func terminalLabel(_ state: RemoteProcessState) -> String {
        switch state {
        case .starting: return "Terminal: Starting"
        case .running: return "Terminal: Running"
        case .exited: return "Terminal: Exited"
        case .unknown: return "Terminal: State unavailable"
        }
    }

    static func agentLabel(_ state: RemoteAgentState) -> String {
        switch state {
        case .working: return "Agent: Working"
        case .waitingInput: return "Agent: Waiting for input"
        case .idle: return "Agent: Idle"
        case .exited: return "Agent: Exited"
        case .unknown: return "Agent: State unavailable"
        }
    }

    static func activityUnavailableWarning(
        terminalState: RemoteProcessState, agentState: RemoteAgentState, gone: Bool
    ) -> String? {
        guard !gone, terminalState == .running, agentState == .unknown else { return nil }
        return "Agent activity is unavailable; terminal liveness alone does not confirm agent health."
    }

    static func sidebarCaption(
        terminalState: RemoteProcessState,
        agentState: RemoteAgentState,
        gone: Bool,
        exitCode: Int?,
        staleness: String? = nil
    ) -> String? {
        let base: String? = {
            if gone { return "no longer reported" }
            switch terminalState {
            case .starting:
                return "Starting…"
            case .exited:
                if let exitCode { return "exited (code \(exitCode))" }
                return "exited"
            case .running:
                return agentState == .unknown ? "agent state unavailable" : nil
            case .unknown:
                return "terminal state unavailable"
            }
        }()
        switch (base, staleness) {
        case (nil, nil): return nil
        case (let base?, nil): return base
        case (nil, let staleness?): return staleness
        case (let base?, let staleness?): return "\(base) · \(staleness)"
        }
    }
}

/// Constructs the raw terminal input for the send field. A terminal's Enter
/// key is carriage return, not line feed; the provider receives these bytes
/// verbatim.
enum RemoteSessionSendPayload {
    static func submitting(_ text: String) -> String {
        text + "\r"
    }
}

/// Detail pane shown when a remote-session sidebar row is selected
/// (`AppState.selectedRemoteSession`), hosted (via `RemoteSessionHostSlot`)
/// inside `DetailSectionHostPager`'s `.remote` tab — mounted continuously
/// for the lifetime of the app session once any remote session has ever
/// been selected, hidden (not torn down) whenever a different top-level
/// section is showing, so it survives navigating away and back. No file
/// viewer or diff panel: those are local-worktree-only and simply aren't
/// rendered here (spec non-goal for v1 remote sessions).
///
/// UNLIKE its earlier revision, the caller deliberately does NOT key this
/// view with `.id(selection)`: this view now hosts `RemoteAttachPager`,
/// which keeps recently-viewed sessions' attach terminals alive across
/// selection changes AND across excursions to a non-remote section
/// (bounded keep-alive — see `RemoteAttachLifecycle`), and `.id()`-ing the
/// parent would tear that pager down (and every live connection it holds)
/// on every single session switch, defeating the whole point. Instead this
/// view resets its own per-session-only `@State` explicitly via
/// `.onChange(of: selection)`.
struct RemoteSessionDetailView: View {
    let selection: RemoteSessionSelection
    @EnvironmentObject var appState: AppState
    /// Behavior seam for `performSend`'s post-send delay (CLAUDE.md "New
    /// delays and timers take an injected clock"). Last property with a
    /// default so the synthesized memberwise init needs no call-site
    /// changes.
    var clock: any Clock<Duration> = ContinuousClock()

    @State private var selectedTab: RemoteSessionDetailTab = .attach
    @State private var showStopConfirm = false
    @State private var logRefreshToken = 0
    /// Non-nil while the provider's remediation command is running in its
    /// own PTY sheet. Cleared by `resetForNewSelection()` like every other
    /// per-session `@State` here — see that method.
    @State private var runningRemediation: RemoteRemediationRun?

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
        // Attached to the view's ROOT, deliberately — never inside
        // `authPrompt`/`contentArea`. That subtree is conditional on
        // `authPresentation != nil`, and running the command is expected to
        // clear `.needsAuth`, which unmounts the subtree, tears down the
        // sheet's PTY (`dismantleNSView` → `terminate()`) and kills an
        // interactive login mid-flow. This parent stays mounted through
        // every auth/detach/tab branch below it.
        .sheet(item: $runningRemediation) { run in
            RemoteRemediationTerminalSheet(run: run)
        }
        .onAppear { adoptPendingTab() }
        .onChange(of: selection) { _, _ in resetForNewSelection() }
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

    /// Resets per-session-ONLY local `@State` when `selection` changes.
    /// Replaces what `.id(selection)` used to give for free (see this
    /// view's doc comment for why it's no longer `.id()`-keyed) for
    /// everything EXCEPT the attach terminal itself, which must NOT reset —
    /// that state now lives in `RemoteAttachPager`/`AppState`, keyed by
    /// selection, independent of this view's own lifecycle.
    private func resetForNewSelection() {
        showStopConfirm = false
        sendText = ""
        isSending = false
        selectedTab = .attach
        // Must be reset like the rest: a non-nil `runningRemediation`
        // surviving a selection change re-presents itself with no user
        // gesture — and, on a session belonging to a DIFFERENT provider,
        // would run the previous provider's command under a label the user
        // never asked for.
        runningRemediation = nil
        adoptPendingTab()
    }

    /// Consumes (reads AND clears) the one-shot tab hint — checked in
    /// `onAppear` (first-ever mount), `onChange(of: selection)` (landing on
    /// a DIFFERENT session), and `onChange(of: appState.remoteSessionRequestedTab)`
    /// (a hint arriving while already on the same session, e.g. a second
    /// "View Log" context-menu click) — three timings that between them
    /// cover every way the hint can arrive relative to this view's mount.
    private func adoptPendingTab() {
        guard let requested = appState.remoteSessionRequestedTab else { return }
        if availableTabs.contains(requested) {
            selectedTab = requested
        }
        appState.remoteSessionRequestedTab = nil
    }

    /// Whether `selection`'s attach terminal currently has a live PTY
    /// mounted in `RemoteAttachPager` — the only state that distinguishes
    /// "render the pager slot" from "render the detached/reattach prompt"
    /// for the Attach tab of the CURRENTLY viewed session (a session that's
    /// eligible and selected but not in this set is, by construction,
    /// explicitly detached — see `RemoteAttachLifecycle`).
    private var isAttached: Bool {
        appState.attachedRemoteSelections.contains(selection)
    }

    /// Covers both detach mechanisms — a clean, explicit detach
    /// (`explicitlyDetachedRemoteSessions`) and an unexpected exit still
    /// waiting on provider-health recovery (`pendingReconnectRemoteSessions`)
    /// — so this view renders the same "why aren't we attached" prompt
    /// regardless of which one currently applies. The two are mutually
    /// exclusive per selection (`markRemoteSessionDetached` only ever writes
    /// one of them for a given exit), so lookup order doesn't matter.
    private var detachInfo: RemoteAttachDetachInfo? {
        appState.explicitlyDetachedRemoteSessions[selection]
            ?? appState.pendingReconnectRemoteSessions[selection].map { RemoteAttachDetachInfo(exitCode: $0.exitCode) }
    }

    private var isUnexpectedDetach: Bool {
        RemoteAttachTerminalView.isUnexpectedExit(exitCode: detachInfo?.exitCode)
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
                    chip(RemoteSessionStatePresentation.terminalLabel(session.payload.state), tint: .secondary)
                    chip(
                        RemoteSessionStatePresentation.agentLabel(session.payload.agentState),
                        tint: agentStateTint(session.payload.agentState)
                    )
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

            if let session,
               let warning = RemoteSessionStatePresentation.activityUnavailableWarning(
                   terminalState: session.payload.state,
                   agentState: session.payload.agentState,
                   gone: session.gone
               ) {
                Label(warning, systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
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
        ZStack {
            // `RemoteAttachPager` is mounted UNCONDITIONALLY here — never
            // nested inside an `if availableTabs.contains(.attach)`, an `if
            // availableTabs.isEmpty` (or its `else`), or any other check
            // scoped to the CURRENT selection's tab set — because it hosts
            // every attached remote session, not just this one. Gating its
            // existence on this session's own tab availability would tear
            // down every OTHER (background, recently-viewed) session's live
            // connection the moment the user merely LOOKS AT a session with
            // no available tabs at all — e.g. an attach-only provider whose
            // session went `gone`, which drops both Attach (gone) and Log
            // (never had it), collapsing `availableTabs` to empty — exactly
            // the kind of accidental mass-teardown this pager exists to
            // prevent. Visibility (not existence) is controlled by
            // opacity/hit-testing below, the same idiom the old
            // intra-session Attach/Log toggle used; `showsAttachSlot` is
            // already `false` whenever `availableTabs` is empty (it requires
            // `availableTabs.contains(.attach)`), so the pager simply stays
            // transparent and non-hit-testable behind the empty-state
            // message below without any special-casing here.
            RemoteAttachPager(
                selections: appState.attachedRemoteSelections,
                activeSelection: selection
            )
            .opacity(showsAttachSlot ? 1 : 0)
            .allowsHitTesting(showsAttachSlot)

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
                if effectiveTab == .attach, availableTabs.contains(.attach), !isAttached {
                    // The auth CTA REPLACES the detached prompt rather than
                    // stacking with it: while the provider can't
                    // authenticate, "Reattach" is an action that cannot
                    // succeed, so offering it at all is the misleading part.
                    if let authPresentation {
                        authPrompt(authPresentation)
                    } else {
                        detachedPrompt
                    }
                }
                if effectiveTab == .log, availableTabs.contains(.log) {
                    RemoteLogTabView(
                        provider: selection.provider, sessionID: selection.sessionID, refreshToken: logRefreshToken)
                        .id(AppState.remoteSessionKey(provider: selection.provider, sessionID: selection.sessionID))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Whether the pager's slot for THIS selection should be visually
    /// foremost right now: the Attach tab is what's showing, this session
    /// still declares/permits attach, and it's actually mounted (not
    /// explicitly detached). Any other remote session the pager happens to
    /// also be keeping warm in the background stays fully transparent and
    /// non-hit-testable regardless of which of ITS tabs is internally
    /// selected — this session's chrome is the only thing the user can see
    /// or interact with.
    private var showsAttachSlot: Bool {
        effectiveTab == .attach && availableTabs.contains(.attach) && isAttached
    }

    /// The provider-authentication CTA for this session's provider.
    ///
    /// Unlike the sidebar's provider-level surface, this one feeds the model
    /// a SECOND, local signal alongside published health: whether this
    /// session's own last attach exited in the auth class. Reporting that
    /// exit to the daemon is fire-and-forget, so health may lag it by a
    /// poll — or never catch up at all if the report failed — and in that
    /// window the misleading "Detached / Reattach" prompt is exactly what
    /// renders instead. Both signals feed the same pure decision
    /// (`RemoteProviderAuthPresentation.make`), so the two surfaces still
    /// can't disagree about what a status MEANS, only about how much they
    /// know.
    private var authPresentation: RemoteProviderAuthPresentation? {
        RemoteProviderAuthPresentation.make(
            from: providerStatus,
            fallbackProviderName: selection.provider,
            localAuthExit: appState.remoteSessionHasLocalAuthExit(selection)
        )
    }

    /// Shown in place of `detachedPrompt` while the provider can't
    /// authenticate. Explains that the PROVIDER (not this session) is what
    /// needs attention, keeps the contract's "the session keeps running
    /// remotely" framing, and offers the provider's own remediation as the
    /// primary action.
    private func authPrompt(_ presentation: RemoteProviderAuthPresentation) -> some View {
        VStack {
            Spacer()
            RemoteProviderAuthCTAView(
                presentation: presentation,
                showsSessionReassurance: true,
                onRun: { runningRemediation = RemoteRemediationRun(presentation) }
            )
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// Shown in place of the pager slot once `selection` has detached
    /// (`AppState.explicitlyDetachedRemoteSessions`) — auto-attach means
    /// there is no longer a "not yet attached, click to start" state for an
    /// eligible session (selecting it already started that), only "live" vs
    /// "detached, here's why, click to try again."
    private var detachedPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: isUnexpectedDetach
                  ? "exclamationmark.triangle"
                  : "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text(isUnexpectedDetach ? "Attach ended unexpectedly" : "Detached")
                .font(.headline)
            // Contract-correct framing kept regardless of exit code: only
            // `list`/`events` are authoritative about the remote session's
            // fate, never this local viewer process exiting.
            Text("The session keeps running remotely.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let exitCode = detachInfo?.exitCode {
                Text("exit code \(exitCode)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Reattach") { appState.reattachRemoteSession(selection) }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
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
        let text = RemoteSessionSendPayload.submitting(sendText)
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
                try? await clock.sleep(for: .seconds(1))
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
