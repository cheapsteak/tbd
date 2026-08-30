import SwiftUI
import TBDShared
import os

/// The live-transcript pane: a poll loop (with session-rollover guard, thread
/// resolution and jump-to-bottom) feeding `TableTranscriptView` — a view-based
/// NSTableView hosting one SwiftUI `SelectableTranscriptRow` per cell with an
/// explicit height cache.
///
/// The only transcript renderer; shown by `PanePlaceholder` whenever
/// `AppState.enableTranscriptKey` is on. (#129)
struct TableTranscriptPaneView: View {
    let terminalID: UUID
    let worktreeID: UUID
    @Environment(AppState.self) var appState
    @Environment(\.openTranscriptOverlay) private var openTranscriptOverlay
    @Environment(\.openTranscriptLink) private var openTranscriptLink

    private let pollInterval: TimeInterval = 1.5
    private let errorThreshold = 3

    /// Tail-first open: the FIRST fetch asks the daemon for only the last N
    /// visible items (fast even on 2000+ item / 30MB sessions), renders them,
    /// then immediately backfills the FULL transcript in the same poll. The
    /// tail IS the bottom of the full list, so the tail→full swap re-pins to an
    /// unchanged bottom via the existing `.rebuild` path.
    private let tailLimit = 60

    /// Gates the app-side read path. Default spelled with the AppState
    /// constant so this and every other read site cannot disagree.
    @AppStorage(AppState.appSideTranscriptReadKey)
    private var appSideTranscriptRead: Bool = AppState.appSideTranscriptReadDefault

    @State private var loadError: String?
    @State private var hasShownInitialMessages = false
    /// False until the full transcript has been fetched for the current session.
    /// Drives the two-phase first-load and resets on session rollover.
    @State private var hasLoadedFull = false
    @State private var lastSessionID: String?
    @State private var retryToken = 0

    /// Within ~120pt of the bottom. Drives the floating jump-to-bottom button.
    @State private var atBottom: Bool = true

    /// Incremented by the jump-to-bottom button to ask the table to scroll to
    /// the last row.
    @State private var scrollToBottomToken: Int = 0
    @State private var activityGroupExpansion: [String: Bool] = [:]
    /// Bumped alongside every write to `activityGroupExpansion`, so the table can
    /// tell a user-driven disclosure toggle (anchor the clicked row) from a
    /// streaming update (follow the tail).
    @State private var activityToggleToken: Int = 0

    /// Per-pane memo for `TranscriptPresentation.build`, which is called from
    /// inside `tableTranscript` and so re-ran on every body evaluation — and
    /// this view observes `AppState`, so any unrelated publish paid for it.
    /// A reference-type holder in `@State`, the same shape as `openTiming`
    /// below: the default expression re-runs on every memberwise init, but
    /// `@State` keeps the first instance, and allocating an empty box is free
    /// where recomputing the projection is not. Per-pane rather than the
    /// process-wide `.shared` so the live pane and Session History cannot
    /// evict each other out of a size-1 cache.
    @State private var presentationMemo = TranscriptPresentationMemo()

    /// One resolution memo per pane, so a streaming row's repeated re-composes
    /// cost one `stat()` per distinct token rather than one per update. Same
    /// `@State` reference-holder shape as `presentationMemo` above.
    @State private var linkCache = TranscriptLinkResolverCache()

    /// Absolute worktree root for resolving relative paths in transcript text.
    /// Empty when the worktree row has not loaded — or when it is remote, which
    /// `LocalWorktree` rejects — which makes relative paths simply not resolve.
    /// Absolute ones still do.
    ///
    /// `static` and taking its inputs explicitly so the link resolver can call
    /// it from a closure that captures the `AppState` reference and the id,
    /// rather than a copy of this view: the resolver outlives the struct
    /// evaluation that built it, and the root has to be read live.
    private static func worktreePath(in appState: AppState, worktreeID: UUID) -> String {
        appState.findWorktree(id: worktreeID).flatMap(LocalWorktree.init)?.path ?? ""
    }

    private static let log = Logger(subsystem: "com.tbd.app", category: "live-transcript")

    /// OPEN-PATH BOUNDARY TIMING (#129 freeze hunt). Permanent-but-off: emitted
    /// at `.debug` so it is silent + free by default; re-enable with:
    ///   log stream --level debug --predicate
    ///     'subsystem == "com.tbd.app" AND category == "table-transcript"'
    /// These fire ONCE on first open, not on every 1.5s poll. A reference-type
    /// holder so mutating it from non-mutating contexts (the poll loop, the
    /// node-build closure) needs no `@State` write-back.
    private static let openLog = Logger(subsystem: "com.tbd.app", category: "table-transcript")
    @State private var openTiming = OpenTiming()

    /// One-shot open-timing latches + the pane-appear clock origin.
    private final class OpenTiming {
        let paneAppearNanos = DispatchTime.now().uptimeNanoseconds
        var didLogFetch = false
        var didLogNodes = false
        var didLogFirstRender = false
    }

    private var terminal: Terminal? {
        appState.terminals[worktreeID]?.first { $0.id == terminalID }
    }

    private var currentSessionID: String? {
        terminal?.claudeSessionID
    }

    private var messages: [TranscriptItem] {
        guard let sid = currentSessionID else { return [] }
        return appState.sessionTranscripts[sid] ?? []
    }

    private var displayedMessages: [TranscriptItem] {
        messages
    }

    var body: some View {
        Group {
            if let err = loadError {
                errorState(message: err)
            } else if currentSessionID == nil {
                emptyState(text: "This terminal has no Claude session.")
            } else if messages.isEmpty && !hasShownInitialMessages {
                emptyState(text: "Waiting for Claude to start the conversation…")
            } else {
                tableTranscript
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: TaskKey(
            terminalID: terminalID, sessionID: currentSessionID, retryToken: retryToken,
            appSideTranscriptRead: appSideTranscriptRead
        )) {
            await pollLoop()
        }
        .onAppear { recordWatchdogContext(count: displayedMessages.count) }
        .onChange(of: displayedMessages.count) { _, newCount in
            recordWatchdogContext(count: newCount)
        }
        .onChange(of: currentSessionID) { _, _ in
            activityGroupExpansion.removeAll()
        }
        .onDisappear { clearWatchdogContext() }
    }

    // MARK: - Hang watchdog context

    /// Feed the hang watchdog so a main-thread stall caught during transcript
    /// layout names the terminal, pane, and item count that triggered it —
    /// without this a hang stack reports `Focused terminal: -` / `Pane: -` and
    /// the #129-class freeze this pane exists to avoid is unattributable.
    private func recordWatchdogContext(count: Int) {
        let tidShort = String(terminalID.uuidString.suffix(4))
        HangWatchdog.shared.recordContext { snap in
            snap.focusedTerminalIDShort = tidShort
            snap.transcriptItemCount = count
            snap.paneLabel = "liveTranscript"
        }
    }

    /// Clear the pane-specific fields on disappear so a hang in another pane
    /// (terminal, file viewer, …) isn't logged with a stale `pane=liveTranscript`
    /// tag and a dead item count.
    private func clearWatchdogContext() {
        HangWatchdog.shared.recordContext { snap in
            snap.focusedTerminalIDShort = nil
            snap.transcriptItemCount = nil
            snap.paneLabel = nil
        }
    }

    // MARK: - States

    @ViewBuilder
    private func emptyState(text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(text)
                .foregroundStyle(.secondary)
                .font(.callout)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func errorState(message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Could not load transcript")
                .foregroundStyle(.secondary)
                .font(.callout)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Retry") {
                loadError = nil
                retryToken &+= 1
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var tableTranscript: some View {
        let presentation = TranscriptPresentation.build(
            items: displayedMessages,
            expansionOverrides: activityGroupExpansion,
            memo: presentationMemo
        )
        // Read once per body evaluation, from the same helper the resolver
        // closure calls, so the value handed to the table and the value the
        // resolver reads cannot disagree.
        let linkRoot = Self.worktreePath(in: appState, worktreeID: worktreeID)
        let cardContext = TranscriptCardContext(
            terminalID: terminalID,
            openTranscriptOverlay: openTranscriptOverlay,
            toggleActivityGroup: setActivityGroup,
            appState: appState,
            linkResolver: TranscriptLinkDestination.makeLinkResolver(
                worktreeRoot: { [appState, worktreeID] in
                    Self.worktreePath(in: appState, worktreeID: worktreeID)
                },
                cache: linkCache),
            onLinkClicked: openTranscriptLink
        )
        SessionWorkbenchView(
            sections: presentation.indexSections,
            onOpen: { itemID in openTranscriptOverlay?(itemID) }
        ) {
            TableTranscriptView(
                context: cardContext,
                atBottom: $atBottom,
                scrollToBottomToken: scrollToBottomToken,
                activityToggleToken: activityToggleToken,
                linkRoot: linkRoot,
                nodesProvider: { timedRenderNodes(presentation.nodes) }
            )
            // Compose the terminal with its current Claude session so a session
            // rollover within one terminal tears down and rebuilds the stateful
            // Coordinator, re-resolving from a clean baseline rather than persisting
            // the prior session's drilled-in subagent thread. (#129)
            .id(PaneIdentity(terminalID: terminalID, sessionID: currentSessionID))
            .overlay(alignment: .bottomLeading) {
                jumpToBottomButton
                    .animation(.easeInOut(duration: 0.2), value: atBottom)
            }
        }
    }

    private func setActivityGroup(_ id: String, expanded: Bool) {
        activityGroupExpansion[id] = expanded
        activityToggleToken &+= 1
    }

    // MARK: - Jump-to-Bottom

    @ViewBuilder
    private var jumpToBottomButton: some View {
        if !atBottom {
            Button {
                scrollToBottomToken &+= 1
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .background(.ultraThinMaterial, in: Circle())
                    .shadow(radius: 4)
            }
            .buttonStyle(.plain)
            .padding(16)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
            .help("Scroll to bottom")
        }
    }

    // MARK: - Open-path node build (timed, one-shot)

    /// Builds the render nodes, emitting one-shot `.debug` boundary markers for
    /// the FIRST non-empty build (`table.open.nodesBuilt`) and the first render
    /// reaching the table (`table.open.firstRender`, measured from pane appear).
    private func timedRenderNodes(_ nodes: [TranscriptRenderNode]) -> [TranscriptRenderNode] {
        let timing = openTiming
        let buildStart = DispatchTime.now().uptimeNanoseconds
        if !timing.didLogNodes, !nodes.isEmpty {
            timing.didLogNodes = true
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- buildStart) / 1_000_000
            Self.openLog.debug(
                "table.open.nodesBuilt ms=\(ms, format: .fixed(precision: 1), privacy: .public) nodeCount=\(nodes.count, privacy: .public)")
        }
        if !timing.didLogFirstRender, !nodes.isEmpty {
            timing.didLogFirstRender = true
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- timing.paneAppearNanos) / 1_000_000
            Self.openLog.debug(
                "table.open.firstRender ms=\(ms, format: .fixed(precision: 1), privacy: .public)")
        }
        return nodes
    }

    // MARK: - Polling

    private func pollLoop() async {
        let transport = TranscriptPaneTransport.resolve(
            appSideEnabled: appSideTranscriptRead, path: terminal?.transcriptPath)
        if case .appSide(let path) = transport {
            await appSideLoop(path: path)
            return
        }
        var consecutiveFailures = 0
        while !Task.isCancelled {
            await pollOnce(failureCount: &consecutiveFailures)
            if consecutiveFailures >= errorThreshold {
                loadError = "Lost connection to the daemon."
                return
            }
            // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    /// Registers this pane with the poll scheduler and publishes into
    /// `AppState.sessionTranscripts` whenever the source reports a change. The
    /// three view consumers — this pane, the history pane and the overlay —
    /// read that store already, so nothing downstream changes.
    ///
    /// `path` is the already-resolved, non-empty transcript path chosen by
    /// `TranscriptPaneTransport.resolve` — passed in rather than re-read here so
    /// the "no path" case cannot recur inside this loop and strand the pane.
    private func appSideLoop(path: String) async {
        guard let sid = currentSessionID else { return }
        let scheduler = appState.transcriptPollScheduler
        let source = appState.transcriptSource
        let state = appState

        await scheduler.setOnChange { [weak state] sessionID in
            guard let state else { return }
            let raw = await source.items(sessionID: sessionID)
            let items = await Self.mergePendingQuestions(
                sessionID: sessionID, raw: raw, state: state)
            await MainActor.run {
                state.sessionTranscripts[sessionID] = items
                state.touchSessionTranscript(sessionID)
            }
        }
        await TranscriptPaneRegistration.apply(
            enabled: true, sessionID: sid, path: path,
            tier: .foreground, scheduler: scheduler)

        // Publish once immediately so the pane is not blank until the first tick.
        await source.refresh(sessionID: sid, path: path)
        let raw = await source.items(sessionID: sid)
        let items = await Self.mergePendingQuestions(
            sessionID: sid, raw: raw, state: appState)
        appState.sessionTranscripts[sid] = items
        appState.touchSessionTranscript(sid)
        if !items.isEmpty { hasShownInitialMessages = true }

        // Hold the task open so `.task(id:)` teardown deregisters on disappear.
        // `clock.sleep`, never `Task.sleep`: the latter is a lint error here.
        let clock = ContinuousClock()
        while !Task.isCancelled {
            try? await clock.sleep(for: .seconds(1))
        }
        await scheduler.deregister(sessionID: sid)
    }

    /// Folds the daemon's pending `AskUserQuestion` captures into a freshly
    /// read transcript, and reports back whichever the JSONL has now caught up
    /// with.
    ///
    /// A question the `PreToolUse` hook captured renders before its `tool_use`
    /// line reaches the file, so the merge is what makes the card appear at
    /// all. The report is the other half of that same call: on the RPC path
    /// `terminal.transcript` clears a satisfied capture off its own parse, and
    /// here nobody else parses the file, so without it the card would keep
    /// rendering an answered question until the expiry sweep reaped it.
    ///
    /// Skipping both on an empty capture set keeps the common tick off the
    /// (cheap but non-zero) index build and off the socket entirely.
    /// `nonisolated` on purpose: `View` carries `@MainActor`, and inheriting it
    /// here would drag the merge's index build onto the main actor. Only the
    /// `AppState` read needs main, and it says so.
    private nonisolated static func mergePendingQuestions(
        sessionID: String,
        raw: [TranscriptItem],
        state: AppState
    ) async -> [TranscriptItem] {
        let capture = await MainActor.run {
            state.pendingQuestionCaptureForSession(sessionID).map {
                ($0.terminalID, $0.entries, state.askUserQuestionSatisfaction)
            }
        }
        guard let (terminalID, pending, reporter) = capture else { return raw }
        let merged = AskUserQuestionMerger.merge(jsonlItems: raw, pending: pending)
        await reporter.report(
            terminalID: terminalID,
            pendingToolUseIDs: Set(pending.map(\.toolUseID)),
            satisfiedToolUseIDs: merged.satisfiedToolUseIDs)
        return merged.items
    }

    private func pollOnce(failureCount: inout Int) async {
        guard let sid = currentSessionID else { return }

        // Detect session rollover: reset the initial-state guard and force the
        // next first-load to re-run the tail-first two-phase fetch.
        if let last = lastSessionID, last != sid {
            hasShownInitialMessages = false
            hasLoadedFull = false
        }
        lastSessionID = sid

        do {
            if !hasLoadedFull {
                // FIRST load (tail-first): fetch only the last N items (fast),
                // render them, then immediately backfill the full transcript —
                // both within this one pollOnce call, not on the next 1.5s tick.
                let fetchStart = DispatchTime.now().uptimeNanoseconds
                let tail = try await appState.daemonClient.terminalTranscript(
                    terminalID: terminalID, tailLimit: tailLimit)
                // One-shot RPC round-trip marker — now the SMALL tail fetch.
                if !openTiming.didLogFetch {
                    openTiming.didLogFetch = true
                    let ms = Double(DispatchTime.now().uptimeNanoseconds &- fetchStart) / 1_000_000
                    Self.openLog.debug(
                        "table.open.fetchDone ms=\(ms, format: .fixed(precision: 1), privacy: .public) itemCount=\(tail.messages.count, privacy: .public)")
                }
                let tailSID = tail.sessionID ?? sid
                await MainActor.run {
                    let prev = appState.sessionTranscripts[tailSID] ?? []
                    if prev != tail.messages {
                        appState.sessionTranscripts[tailSID] = tail.messages
                        appState.touchSessionTranscript(tailSID)
                    }
                    if !tail.messages.isEmpty {
                        hasShownInitialMessages = true
                    }
                }

                // Backfill: the full transcript carries the earlier items the
                // tail lacks. The store write flows through the normal update
                // path → `.rebuild`, which re-pins the (unchanged) bottom.
                let full = try await appState.daemonClient.terminalTranscript(terminalID: terminalID)
                let fullSID = full.sessionID ?? sid
                await MainActor.run {
                    let prev = appState.sessionTranscripts[fullSID] ?? []
                    if prev != full.messages {
                        appState.sessionTranscripts[fullSID] = full.messages
                        appState.touchSessionTranscript(fullSID)
                    }
                    if !full.messages.isEmpty {
                        hasShownInitialMessages = true
                    }
                }
                // Only mark fully-loaded once the full fetch succeeds; if it
                // threw above we never reach here, so the next poll retries.
                hasLoadedFull = true
                failureCount = 0
                return
            }

            // Subsequent polls: full transcript fetch, as before.
            let result = try await appState.daemonClient.terminalTranscript(terminalID: terminalID)
            failureCount = 0
            let resolvedSID = result.sessionID ?? sid
            // `prev` is a cheap COW snapshot taken on the main actor; the deep
            // equality compare then runs in a detached task so a long
            // transcript never burns main-thread time proving "nothing
            // changed" on an idle tick (#129 territory).
            let prev = appState.sessionTranscripts[resolvedSID] ?? []
            let newMessages = result.messages
            let didChange = await Task.detached(priority: .userInitiated) {
                TranscriptPollDiff.changed(prev: prev, new: newMessages)
            }.value
            // The detached compare isn't cancellation-linked to the poll task:
            // if the pane was torn down (tab close / session rollover) while it
            // ran, skip the publish so a stale snapshot can't resurrect state.
            // An interleaved same-key writer during the suspension is tolerable
            // — the publish is a whole fresh daemon snapshot (never derived
            // from `prev`), so the next 1.5s tick converges.
            if Task.isCancelled { return }
            if didChange {
                appState.sessionTranscripts[resolvedSID] = newMessages
                appState.touchSessionTranscript(resolvedSID)
            }
            if !newMessages.isEmpty {
                hasShownInitialMessages = true
            }
        } catch {
            failureCount += 1
            Self.log.debug("table transcript poll failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Identity of the poll task. Includes `appSideTranscriptRead` so flipping the
/// setting while a pane is open cancels the running transport and starts the
/// other one, rather than leaving the pane on whichever loop it happened to
/// begin with until something else rebuilds it.
private struct TaskKey: Equatable {
    let terminalID: UUID
    let sessionID: String?
    let retryToken: Int
    let appSideTranscriptRead: Bool
}

/// SwiftUI identity for the table transcript representable. Composes the terminal
/// with its current Claude session so a session rollover tears down and rebuilds
/// the stateful Coordinator. (#129)
private struct PaneIdentity: Hashable {
    let terminalID: UUID
    let sessionID: String?
}
