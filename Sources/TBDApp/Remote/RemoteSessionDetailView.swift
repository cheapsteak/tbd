import SwiftUI
import TBDShared
import os

private let detailLogger = Logger(subsystem: "com.tbd.app", category: "remoteDetail")

/// Pure copy decisions for the two independent remote-session state axes.
/// Shared by the detail pane's prompts, the provider desk and the
/// sidebar so none can present terminal liveness as evidence of agent
/// activity.
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

    /// The line about the remote session's fate on the detached and
    /// provider-authentication prompts. It reads the provider's own reported
    /// state — `list`/`events` are authoritative about the session, never the
    /// local viewer process exiting — so it claims the session keeps running
    /// only when the provider says it is running or starting, and says
    /// nothing about liveness when the state is unknown or not yet mirrored.
    static func detachedFateLine(terminalState: RemoteProcessState?) -> String {
        switch terminalState {
        case .running, .starting:
            return "The session keeps running remotely."
        case .exited:
            return "The remote session has exited."
        case .unknown, nil:
            return "The remote session is unaffected by detaching."
        }
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

/// Constructs the raw terminal input for the send footer. A terminal's Enter
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
/// Laid out like a local session: the terminal fills the pane, and the
/// session's name and its Reconnect / Stop actions live in the window
/// toolbar (`ContentView`). The only chrome here is a compact warning strip,
/// rendered only while a warning actually applies, and — only while no live
/// attached terminal is showing — a send footer (see
/// `RemoteSessionDetailGates.showsSendFooter`). When the transcript is
/// available and open, the session's conversation sits beside the terminal in
/// a horizontal split (`RemoteTranscriptPaneView`).
///
/// The caller deliberately does NOT key this view with `.id(selection)`:
/// this view hosts `RemoteAttachPager`, which keeps recently-viewed
/// sessions' attach terminals alive across selection changes AND across
/// excursions to a non-remote section (bounded keep-alive — see
/// `RemoteAttachLifecycle`), and `.id()`-ing the parent would tear that
/// pager down (and every live connection it holds) on every single session
/// switch. Instead this view resets its own per-session-only `@State`
/// explicitly via `.onChange(of: selection)`.
struct RemoteSessionDetailView: View {
    let selection: RemoteSessionSelection
    @Environment(AppState.self) var appState
    /// Behavior seam for `performSend`'s post-send delay (CLAUDE.md "New
    /// delays and timers take an injected clock"). Last property with a
    /// default so the synthesized memberwise init needs no call-site
    /// changes.
    var clock: any Clock<Duration> = ContinuousClock()

    /// Non-nil while the provider's remediation command is running in its
    /// own PTY sheet. Cleared on selection change — see `body`.
    @State private var runningRemediation: RemoteRemediationRun?

    private var session: RemoteSessionInfo? {
        appState.remoteSessions.first {
            $0.provider == selection.provider && $0.payload.id == selection.sessionID
        }
    }

    private var providerStatus: RemoteProviderStatus? {
        appState.remoteProviders.first { $0.config.name == selection.provider }
    }

    /// Capabilities gate BOTH what fills this pane and the context-menu items
    /// in `RemoteSessionActionMenu` — same source (`describe.capabilities`),
    /// same reasoning: omit what the provider hasn't declared rather than
    /// show a control that can only fail.
    private var capabilities: [String] {
        providerStatus?.describe?.capabilities ?? []
    }

    /// `gone` (absent from the provider's last two `list` snapshots) drops
    /// attach the same way `RemoteSessionActionMenu.items(gone:)` collapses
    /// the context menu. A session not yet found in the mirror at all
    /// (`session == nil`) is a distinct, more transient state and isn't
    /// treated as gone here.
    private var isGone: Bool {
        session?.gone ?? false
    }

    /// Derived on every `body` evaluation — never cached in `@State` — so no
    /// `onAppear`/`onChange` timing can leave the pane blank.
    private var content: RemoteSessionDetailContent {
        RemoteSessionDetailGates.content(
            capabilities: capabilities, gone: isGone, exited: session?.payload.state == .exited)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasWarnings {
                warningStrip
                Divider()
            }
            contentArea
            if showsSendFooter {
                Divider()
                sendFooter
            }
        }
        // Attached to the view's ROOT, deliberately — never inside
        // `authPrompt`/`contentArea`. That subtree is conditional on
        // `authPresentation != nil`, and running the command is expected to
        // clear `.needsAuth`, which unmounts the subtree, tears down the
        // sheet's PTY (`dismantleNSView` → `terminate()`) and kills an
        // interactive login mid-flow. This parent stays mounted through
        // every auth/detach branch below it.
        .sheet(item: $runningRemediation) { run in
            RemoteRemediationTerminalSheet(run: run)
        }
        // Tells AppState which session's attach slot is actually visible, so
        // a focus claim never lands in a pane this view is keeping
        // transparent (the log fallback, a detached or auth prompt).
        .onChange(of: showsAttachSlot ? selection : nil, initial: true) { _, shown in
            appState.setRemoteAttachSlotShown(shown)
        }
        // Replaces what `.id(selection)` would give for free (see this
        // view's doc comment) for everything EXCEPT the attach terminal,
        // which lives in `RemoteAttachPager`/`AppState`, keyed by selection.
        // A non-nil `runningRemediation` surviving a selection change would
        // re-present itself with no user gesture — and, on a session
        // belonging to a DIFFERENT provider, run the previous provider's
        // command under a label the user never asked for.
        .onChange(of: selection) { _, _ in
            runningRemediation = nil
            sendText = ""
            isSending = false
            selectionEpoch += 1
        }
    }

    /// Whether `selection`'s attach terminal currently has a live PTY
    /// mounted in `RemoteAttachPager` — the only state that distinguishes
    /// "render the pager slot" from "render the detached/reattach prompt"
    /// for the CURRENTLY viewed session (a session that's eligible and
    /// selected but not in this set is, by construction, explicitly
    /// detached — see `RemoteAttachLifecycle`).
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

    // MARK: - Warning strip

    private var providerIssue: String? {
        providerStatus.flatMap { RemoteProviderStatusPresentation.issueSummary($0) }
    }

    /// Only actionable warnings earn space above the terminal: the session
    /// is gone or missing from the mirror, or the provider reports a
    /// problem. Routine state — including agent activity a provider doesn't
    /// report — lives in the sidebar, as it does for local sessions.
    private var hasWarnings: Bool {
        session == nil || isGone || providerIssue != nil
    }

    private var warningStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isGone {
                Label("No longer reported by the provider", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if session == nil {
                Label("Session not found in the current mirror", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }

            if let providerIssue {
                Label(providerIssue, systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                if providerStatus?.hasStaleSnapshot == true {
                    Text(Self.staleSnapshotNote(
                        attachAvailable: appState.attachEligibleRemoteSelections.contains(selection)))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }

    /// The note under a stale-inventory issue. It mentions attach only when
    /// this session can actually be attached to.
    static func staleSnapshotNote(attachAvailable: Bool) -> String {
        attachAvailable
            ? "Attach remains available; changes are paused until inventory refresh recovers."
            : "Changes are paused until inventory refresh recovers."
    }

    // MARK: - Content

    /// A horizontal split: the terminal side on the left, and — when the
    /// provider declares `transcript.read`, the flag is on and the shared
    /// `remoteTranscriptOpen` preference says open — the transcript on the
    /// right. The split is always the container, even with one child, so
    /// opening or closing the transcript only adds or removes the second
    /// child and never restructures the left one: `RemoteAttachPager` stays
    /// mounted either way (see `terminalArea` and `RemoteDetailSplit`).
    private var contentArea: some View {
        RemoteDetailSplit(showsTrailing: appState.remoteSessionShowsTranscriptPane(selection)) {
            terminalArea
        } trailing: {
            RemoteTranscriptLivePane(selection: selection)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var terminalArea: some View {
        ZStack {
            // `RemoteAttachPager` is mounted UNCONDITIONALLY here — never
            // nested inside a check scoped to the CURRENT selection's
            // capabilities — because it hosts every attached remote session,
            // not just this one. Gating its existence on this session's own
            // content would tear down every OTHER (background,
            // recently-viewed) session's live connection the moment the user
            // merely LOOKS AT a session that can't attach — e.g. a gone
            // session — exactly the kind of accidental mass-teardown this
            // pager exists to prevent. Visibility (not existence) is
            // controlled by opacity/hit-testing below; `showsAttachSlot` is
            // already `false` whenever `content != .attach`, so the pager
            // simply stays transparent and non-hit-testable behind whatever
            // renders instead.
            RemoteAttachPager(
                mounts: appState.attachedRemoteMountKeys,
                activeSelection: selection
            )
            .opacity(showsAttachSlot ? 1 : 0)
            .allowsHitTesting(showsAttachSlot)

            switch content {
            case .attach:
                if !isAttached {
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
            case .log:
                RemoteLogView(
                    provider: selection.provider, sessionID: selection.sessionID, refreshToken: logRefreshToken)
                    .id(AppState.remoteSessionKey(provider: selection.provider, sessionID: selection.sessionID))
            case .unsupported:
                Text("This provider doesn't support attach or a log view for this session.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Whether the pager's slot for THIS selection should be visually
    /// foremost right now: this session can attach and is actually mounted
    /// (not explicitly detached). Any other remote session the pager happens
    /// to also be keeping warm in the background stays fully transparent and
    /// non-hit-testable — this session is the only thing the user can see or
    /// interact with.
    private var showsAttachSlot: Bool {
        content == .attach && isAttached
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
    /// needs attention, states the session's fate from the provider's
    /// reported state (`detachedFateLine`), and offers the provider's own
    /// remediation as the primary action.
    private func authPrompt(_ presentation: RemoteProviderAuthPresentation) -> some View {
        VStack {
            Spacer()
            RemoteProviderAuthCTAView(
                presentation: presentation,
                sessionFateLine: RemoteSessionStatePresentation.detachedFateLine(
                    terminalState: session?.payload.state),
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
            // Read from the provider's reported state, never from this local
            // viewer's exit code — see `detachedFateLine`.
            Text(RemoteSessionStatePresentation.detachedFateLine(terminalState: session?.payload.state))
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
    @State private var logRefreshToken = 0
    /// Bumped on every selection change so an in-flight send can tell that
    /// the pane has moved on — see `performSend`.
    @State private var selectionEpoch = 0

    private var showsSendFooter: Bool {
        RemoteSessionDetailGates.showsSendFooter(
            capabilities: capabilities, gone: isGone,
            snapshotFresh: providerStatus?.hasStaleSnapshot != true,
            hasLiveAttachedPane: showsAttachSlot)
    }

    private var sendFooter: some View {
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
        let target = selection
        // This view is reused across selections (see the type's doc
        // comment), so a send that completes after the user moved to another
        // session must not touch that session's state. The Task captures a
        // copy of this struct, whose `selection` never changes; the epoch is
        // `@State`, so the Task reads its live value.
        let epoch = selectionEpoch
        sendText = ""
        isSending = true
        Task {
            defer { if selectionEpoch == epoch { isSending = false } }
            do {
                try await appState.daemonClient.remoteSend(
                    provider: target.provider, sessionID: target.sessionID, text: text)
                // Give the remote side a moment to act before re-pulling
                // scrollback — `send`'s exit 0 only means the bytes reached
                // the transport, not that the agent has acted on them yet
                // (docs/remote-provider-contract.md § `send`).
                try? await clock.sleep(for: .seconds(1))
                if selectionEpoch == epoch { logRefreshToken += 1 }
            } catch {
                detailLogger.error(
                    "remoteSend failed for \(target.provider, privacy: .public)/\(target.sessionID, privacy: .public): \(error, privacy: .public)")
            }
        }
    }
}

/// Read-only scrollback — the fallback that fills the pane only when the
/// session can't be attached to. Fetches `remote.log` on appear and whenever
/// `refreshToken` changes (driven by the parent after a send), plus a manual
/// Refresh button. Renders the returned text completely as-is — no
/// parsing, no sanitizing, no ANSI stripping (raw provider bytes, ANSI
/// passthrough intended per the contract) — and never infers session state
/// from it (screen-scraping state out of rendered/log text is prohibited in
/// this codebase).
private struct RemoteLogView: View {
    let provider: String
    let sessionID: String
    var refreshToken: Int

    @Environment(AppState.self) var appState
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
