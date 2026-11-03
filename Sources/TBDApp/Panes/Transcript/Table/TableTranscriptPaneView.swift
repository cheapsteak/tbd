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

    /// Tail-first open: the FIRST fetch asks the daemon for only the last
    /// `TranscriptTailFirstOpen.tailLimit` visible items (fast even on 2000+
    /// item / 30MB sessions), renders them, then immediately backfills the FULL
    /// transcript in the same poll. The tail IS the bottom of the full list, so
    /// the tail→full swap re-pins to an unchanged bottom via the existing
    /// `.rebuild` path. Session History opens the same way and shares the limit.
    private let tailLimit = TranscriptTailFirstOpen.tailLimit

    @State private var loadError: String?
    @State private var hasShownInitialMessages = false
    /// False until the full transcript has been fetched for the current session.
    /// Drives the two-phase first-load and resets on session rollover.
    @State private var hasLoadedFull = false
    @State private var lastSessionID: String?
    @State private var retryToken = 0

    /// The table, by its identity, that has mounted and settled its open, and
    /// so gets every render node. Any other table mounts on only the last
    /// `TranscriptTailFirstOpen.tailLimit`, whatever the store already holds:
    /// the pane remounts over a populated store when it returns to a worktree
    /// that left the keep-alive set, or when the pane is moved or reopened,
    /// and a table mounted holding every row of a long session stalls the
    /// main thread for 18–21 s (`TranscriptTailFirstOpen`).
    ///
    /// Keyed by the table's `.id` (terminal and session), so a table built for
    /// a new terminal or session does not match it in the pass that builds
    /// it. Cleared whenever the shown table's identity changes or `body` stops
    /// showing the table (an error, no session, or the waiting state;
    /// `shownTableKey`), so a table rebuilt later under an identity that
    /// widened before mounts windowed again too.
    @State private var widenedPane: PaneIdentity?

    /// Within ~120pt of the bottom. Drives the floating jump-to-bottom button.
    @State private var atBottom: Bool = true

    /// Incremented by the jump-to-bottom button to ask the table to scroll to
    /// the last row.
    @State private var scrollToBottomToken: Int = 0
    @State private var promptScroll: TranscriptScrollRequest?
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

    /// The transcript table this pane registered as its focus target, so
    /// `onDisappear` can withdraw exactly the one it installed. A reference box
    /// for the same reason `ComposerViewHandle` is one: it is written from
    /// inside `makeNSView`, where a `@State` write is undefined behaviour, and
    /// nothing renders from it.
    @State private var registeredTable = RegisteredTranscriptTable()

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

    /// The identity of the current run of `pollLoop`. Every input the loop
    /// reads once lives here, so a change to any of them restarts it; see
    /// `TaskKey`.
    private var taskKey: TaskKey {
        TaskKey.resolve(
            terminalID: terminalID,
            sessionID: currentSessionID,
            retryToken: retryToken,
            transcriptPath: terminal?.transcriptPath,
            streamingEnabled: appState.transcriptStreamingEnabled,
            terminalExited: terminal.map(Self.hasExited) ?? true)
    }

    private var messages: [TranscriptItem] {
        guard let sid = currentSessionID else { return [] }
        return appState.sessionTranscripts[sid] ?? []
    }

    private var displayedMessages: [TranscriptItem] {
        mergedTranscript.items
    }

    /// The transcript with this terminal's prompt cards merged in — open
    /// dialogs from the daemon's mirror plus cards `PromptCardRetention` still
    /// holds. View-time only: `appState.sessionTranscripts` stays the unmerged
    /// list the publish path wrote, so an appended card never enters it.
    private var mergedTranscript: PendingPromptMerge.Merged {
        PendingPromptMerge.local(items: messages, appState: appState, terminalID: terminalID)
    }

    private var livePrompts: [PendingPromptPresentation] {
        PendingPromptMerge.livePrompts(appState: appState, terminalID: terminalID)
    }

    /// What `body` shows, in its order of precedence.
    enum Branch: Equatable {
        case error(String)
        case noSession
        case waiting
        case table

        static func resolve(
            loadError: String?, sessionID: String?, messagesEmpty: Bool, hasShownInitialMessages: Bool
        ) -> Branch {
            if let loadError { return .error(loadError) }
            if sessionID == nil { return .noSession }
            if messagesEmpty && !hasShownInitialMessages { return .waiting }
            return .table
        }
    }

    private var branch: Branch {
        Branch.resolve(
            loadError: loadError,
            sessionID: currentSessionID,
            messagesEmpty: messages.isEmpty,
            hasShownInitialMessages: hasShownInitialMessages)
    }

    /// The identity the table is built under: its `.id`, its mount key, and
    /// what its settled open records.
    private var paneIdentity: PaneIdentity {
        PaneIdentity(terminalID: terminalID, sessionID: currentSessionID)
    }

    /// What the widen is cleared on: the identity of the table `body` shows,
    /// or nil while it shows none. Any change of it clears the widen, whether
    /// the table is rebuilt under another identity or leaves the body; a
    /// re-render of the same table, such as the one its own widen causes,
    /// changes nothing.
    static func shownTableKey(_ branch: Branch, identity: PaneIdentity) -> PaneIdentity? {
        branch == .table ? identity : nil
    }

    var body: some View {
        Group {
            switch branch {
            case .error(let message):
                errorState(message: message)
            case .noSession:
                emptyState(text: "This terminal has no Claude session.")
            case .waiting:
                emptyState(text: "Waiting for Claude to start the conversation…")
            case .table:
                tableTranscript
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: taskKey) {
            await pollLoop()
        }
        .onAppear { recordWatchdogContext(count: displayedMessages.count) }
        .onChange(of: displayedMessages.count) { _, newCount in
            recordWatchdogContext(count: newCount)
        }
        .onChange(of: currentSessionID) { _, _ in
            activityGroupExpansion.removeAll()
        }
        // A table identity that widened can be built again: Retry after an
        // error; a session that goes and returns; a pane whose identity moved
        // on before the new table reported its open (torn down inside its two
        // turns, or detached by `WorktreePager` with the report held) and then
        // came back; or, before this pane has shown anything
        // (`hasShownInitialMessages`), a store that empties under it, as a
        // first app-side read that finds no file publishes, and then refills.
        // So the widen is cleared in the update where the shown table's
        // identity changes or the table leaves, on this outer group, which
        // exists whichever branch shows. The table built in that update was
        // built against the old widen, a different key, so it is windowed
        // already, and its own report comes at least two turns later. Not in
        // an `onDisappear`: a removal transition can run that after a
        // same-identity table has mounted and widened again, leaving it stuck
        // on its last `tailLimit` rows.
        .onChange(of: Self.shownTableKey(branch, identity: paneIdentity)) { _, _ in
            widenedPane = nil
        }
        // Prompt-card bookkeeping, outside any body evaluation: a dialog that
        // closes is held until its tool result lands (the merge's `settled`)
        // or the retention timeout passes.
        .onChange(of: livePrompts, initial: true) { _, live in
            appState.promptCardRetention.observe(live: live, for: .local(terminalID: terminalID))
        }
        .onChange(of: mergedTranscript.settled, initial: true) { _, settled in
            appState.promptCardRetention.settle(settled)
            appState.promptAnswers.forget(settled)
        }
        .onDisappear {
            clearWatchdogContext()
            appState.promptCardRetention.forgetLive(for: .local(terminalID: terminalID))
            if let table = registeredTable.view {
                appState.unregisterTranscriptView(table, for: terminalID)
            }
        }
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
        let merged = mergedTranscript
        let presentation = TranscriptPresentation.build(
            items: merged.items,
            expansionOverrides: activityGroupExpansion,
            pendingPrompts: merged.prompts,
            memo: presentationMemo
        )
        // Read once per body evaluation, from the same helper the resolver
        // closure calls, so the value handed to the table and the value the
        // resolver reads cannot disagree.
        let linkRoot = Self.worktreePath(in: appState, worktreeID: worktreeID)
        // One value for the table's `.id`, its mount key and the widen its
        // settled open records, so they cannot disagree.
        let identity = paneIdentity
        // Read here, in the body, so the widen re-runs it and the wider list
        // reaches the table. A read inside `nodesProvider` would happen in
        // `updateNSView` and leave the body depending on nothing.
        let widened = widenedPane
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
            VStack(spacing: 0) {
                TableTranscriptView(
                    context: cardContext,
                    atBottom: $atBottom,
                    scrollToBottomToken: scrollToBottomToken,
                    scrollToItem: promptScroll,
                    activityToggleToken: activityToggleToken,
                    linkRoot: linkRoot,
                    // The window applies to what the open-timing markers saw,
                    // so `table.open.nodesBuilt` still counts every node built;
                    // the table's own `rows=` markers count what it was handed.
                    // Only the table is windowed: the index above reads the
                    // whole presentation. A row streamed in before the widen
                    // slides the window by one, which the coordinator takes as
                    // a `.rebuild` and, at the bottom, follows like any append.
                    nodesProvider: {
                        TranscriptTailFirstOpen.mountedNodes(
                            timedRenderNodes(presentation.nodes),
                            mountKey: identity,
                            widenedKey: widened)
                    },
                    onTableReady: { [appState, terminalID, registeredTable] table in
                        registeredTable.view = table
                        appState.registerTranscriptView(table, for: terminalID)
                    },
                    promptRail: .rail(earlier: nil),
                    // The rest arrives as an update to the table now in the
                    // window, as the backfill after a tail-first fetch does.
                    onOpenSettled: { [identity] in widenedPane = identity }
                )
                // Compose the terminal with its current Claude session so a session
                // rollover within one terminal tears down and rebuilds the stateful
                // Coordinator, re-resolving from a clean baseline rather than persisting
                // the prior session's drilled-in subagent thread. (#129) The prompt
                // rail lives inside the table's view, so the rebuild takes it too.
                .id(identity)
                .overlay(alignment: .bottomLeading) {
                    jumpToBottomButton
                        .animation(.easeInOut(duration: 0.2), value: atBottom)
                }

                // OUTSIDE the `.id` above, deliberately: a `/clear` rebuilds the
                // table, and it must not take a half-written message with it.
                if let decision = Self.composerMount(
                    terminal: terminal,
                    worktree: appState.findWorktree(id: worktreeID)) {
                    Divider()
                    MessageComposerView(
                        terminal: decision.terminal,
                        worktree: decision.worktree,
                        state: decision.state,
                        promptHint: promptHint(for: merged))
                        // A terminal switch reuses this pane, and the composer's
                        // registration is keyed on the terminal it was made for.
                        // A fresh view per terminal is what keeps the two agreeing.
                        .id(decision.terminal.id)
                        // The completion list is an overlay on the composer and
                        // draws UPWARD, out over the transcript above it. The
                        // table is its sibling in this stack and an AppKit view
                        // besides, so it is stated here which of the two paints
                        // on top rather than left to stacking order.
                        //
                        // This lifts the WHOLE composer subtree, so an open menu
                        // also paints over the transcript's own bottom-leading
                        // `jumpToBottomButton` overlay when the transcript is
                        // scrolled up. That is intended: the menu is a transient
                        // popup and, while it is open, it owns the pane. Escape
                        // or a token change closes it and the button is back.
                        //
                        // Defensive, not test-verified: the offscreen harness
                        // already orders this SwiftUI overlay above the AppKit
                        // sibling with or without this modifier, so no test
                        // discriminates it. It guards the live app, where the
                        // transcript's NSTableView may composite over a sibling
                        // overlay instead of respecting SwiftUI's z-order — the
                        // live pass is what actually verifies it.
                        .zIndex(1)
                }
            }
        }
    }

    // MARK: - The mount decision

    /// What the composer mount resolves to, or nil for no composer at all.
    ///
    /// A value rather than a `ComposerState`, because the view's initializer
    /// needs the `LocalWorktree` too, and a row that cannot produce one has no
    /// files on this machine to send a message about — a remote row, or a local
    /// `.creating` placeholder whose path is still empty. Either way: no local
    /// worktree, no composer.
    struct ComposerMount {
        let terminal: Terminal
        let worktree: LocalWorktree
        let state: ComposerState
    }

    /// Whether this pane mounts a composer, and with what.
    ///
    /// Static and taking its inputs explicitly so the gate is assertable without
    /// a view hierarchy.
    ///
    /// `!= .hidden` rather than `isEnabled`: a parked session's composer is
    /// mounted and disabled-looking but very much present, because sending to it
    /// is what resumes it.
    static func composerMount(
        terminal: Terminal?, worktree: Worktree?
    ) -> ComposerMount? {
        guard let worktree else { return nil }
        let state = ComposerState.resolve(
            terminal: terminal, isRemoteWorktree: !worktree.location.isLocal)
        guard state != .hidden, let terminal, let local = LocalWorktree(worktree) else {
            return nil
        }
        return ComposerMount(terminal: terminal, worktree: local, state: state)
    }

    /// The composer's "prompt above" hint action, or nil when no open card can
    /// be answered from this pane.
    private func promptHint(for merged: PendingPromptMerge.Merged) -> (() -> Void)? {
        guard let itemID = merged.answerableCardItemID else { return nil }
        return { promptScroll = .next(after: promptScroll, itemID: itemID) }
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
            // The overlay spans the prompt rail's leading gutter too; keep the
            // button clear of the rail.
            .padding(.leading, PromptRailLayout.width)
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

    private func pollLoop(clock: any Clock<Duration> = ContinuousClock()) async {
        let transport = TranscriptPaneTransport.resolve(path: terminal?.transcriptPath)
        if case .appSide(let path) = transport {
            await appSideLoop(path: path, clock: clock)
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
    /// What each publish writes is composed by `publish` below: JSONL items,
    /// then the daemon's pending `AskUserQuestion` captures, then the session
    /// mod's provisional blocks last.
    ///
    /// `path` is the already-resolved, non-empty transcript path chosen by
    /// `TranscriptPaneTransport.resolve` — passed in rather than re-read here so
    /// the "no path" case cannot recur inside this loop and strand the pane.
    ///
    /// The pane also *declares* its cadence tier (`currentPollTier`) and
    /// re-declares it whenever its visibility changes; the scheduler never
    /// derives one.
    ///
    /// `clock` drives this loop's own tier re-declaration wait; the repo's
    /// clock seam, last parameter, defaulted.
    private func appSideLoop(path: String, clock: any Clock<Duration> = ContinuousClock()) async {
        // Every input this run reads *once* is read here, before the first
        // `await`: `taskKey` is a computed property over `AppState`, so
        // re-reading it after an actor hop could answer differently from the
        // value `.task(id:)` keyed this run on, and the loop would then be
        // running against a resolution nothing restarts it for.
        let key = taskKey
        guard let sid = currentSessionID else { return }
        let scheduler = appState.transcriptPollScheduler
        let source = appState.transcriptSource
        let state = appState

        // Installed once for the whole app, not re-seated per mount: the
        // closure carries nothing of this pane's (see
        // `TranscriptPollScheduler.onChange`).
        await scheduler.setOnChangeIfUnset { [weak state] sessionID in
            guard let state else { return }
            await Self.publish(sessionID: sessionID, state: state, source: source)
        }
        // The session mod's stream file for this session, when the daemon
        // reports streaming on. Taken from the `TaskKey` captured above, so the
        // value this loop registers is the same value its `.task(id:)` was
        // keyed on: the flag can be flipped in Settings at any moment, and a
        // flip restarts this loop rather than being noticed mid-run.
        let streamPath = key.streamPath

        // One token per run of this task, so the hold belongs to *this* pane.
        // The deregistration at the bottom happens whenever this task notices
        // its own cancellation, which can be well after a replacement pane for
        // the same session has registered; the token is what keeps that late
        // call from tearing the replacement's polling down.
        let token = TranscriptPaneToken()
        var tier = currentPollTier()
        await TranscriptPaneRegistration.apply(
            sessionID: sid, path: path, streamPath: streamPath,
            tier: tier, token: token, scheduler: scheduler)

        // Publish once immediately so the pane is not blank until the first tick.
        await source.refresh(sessionID: sid, path: path)
        let items = await Self.publish(sessionID: sid, state: state, source: source)
        if !items.isEmpty { hasShownInitialMessages = true }

        // Hold the task open so `.task(id:)` teardown deregisters on disappear,
        // and re-declare the tier whenever this pane's visibility changes. A
        // pane the viewer-slot LRU keeps mounted after the selection moves
        // elsewhere must drop to the background cadence without being torn
        // down; re-registering under the same token updates this pane's own
        // hold rather than taking a second one, so re-declaring is exactly that
        // gesture (the same one `setAppActive` makes for the whole registry).
        //
        // Polled here rather than watched with an `.onChange` in `body` for two
        // reasons: an observation dependency taken inside this task would not
        // fire anyway, and keeping the watch inside this function leaves the
        // daemon-poll path — which never reaches `appSideLoop` — with the body
        // it always had. A second of stale cadence after a selection change
        // costs at most a handful of extra `stat`s.
        //
        // `clock.sleep`, never `Task.sleep`: the latter is a lint error here.
        while !Task.isCancelled {
            try? await clock.sleep(for: .seconds(1))
            if Task.isCancelled { break }
            let latest = currentPollTier()
            guard latest != tier else { continue }
            tier = latest
            await scheduler.register(
                sessionID: sid, path: path, streamPath: streamPath,
                tier: tier, token: token)
        }
        await scheduler.deregister(sessionID: sid, token: token)
    }

    /// One publish: read what the source has for `sessionID`, merge the
    /// daemon's pending `AskUserQuestion` captures, append the session mod's
    /// provisional blocks, and write the result into `AppState`.
    ///
    /// Returns what it published, for the one caller that needs it — the
    /// initial publish, which latches `hasShownInitialMessages`.
    ///
    /// `nonisolated static` for the same reason `mergePendingQuestions` is:
    /// it runs from the scheduler's `@Sendable` on-change closure, and `View`'s
    /// `@MainActor` would otherwise drag the merge's index build onto main.
    /// Only the `AppState` reads and the store write need main, and they say so.
    ///
    /// **Why the streaming flag and the terminal's state are read here rather
    /// than captured from the pane's `TaskKey`.** The scheduler holds exactly
    /// one on-change closure for the whole app, whichever pane registered
    /// first, and it is passed the session that changed — the closures have to
    /// stay interchangeable between panes (see
    /// `TranscriptPollScheduler.onChange`). A closure carrying one pane's
    /// resolved values would decide for sessions belonging to other panes, so
    /// both are read fresh on the main actor for the session being published.
    @discardableResult
    nonisolated static func publish(
        sessionID: String,
        state: AppState,
        source: TranscriptSource
    ) async -> [TranscriptItem] {
        // One hop onto the source for the items, the stream snapshot and which
        // of its blocks the JSONL has confirmed. Read separately, a `refresh`
        // landing between two of the awaits could hand this publish a
        // transcript from before a block's row and a confirmation from after
        // it — and it would then show neither.
        let snapshot = await source.snapshot(sessionID: sessionID)
        let merged = await mergePendingQuestions(
            sessionID: sessionID, raw: snapshot.items, state: state)

        let (streamingEnabled, terminalExited) = await MainActor.run {
            (state.transcriptStreamingEnabled,
             Self.terminalHasExited(claudeSessionID: sessionID, terminals: state.terminals))
        }
        let items = ProvisionalRowComposer.compose(
            items: merged,
            stream: snapshot.stream,
            confirmedUUIDs: snapshot.confirmedUUIDs,
            sessionEnded: terminalExited || snapshot.heartbeatStale,
            streamingEnabled: streamingEnabled)

        await MainActor.run {
            state.sessionTranscripts[sessionID] = items
            state.touchSessionTranscript(sessionID)
        }
        return items
    }

    /// Whether a terminal's process is gone: parked, by any reason (a park
    /// stamps `hibernatedAt`, an exit included), or suspended.
    nonisolated static func hasExited(_ terminal: Terminal) -> Bool {
        terminal.hibernatedAt != nil || terminal.suspendedAt != nil
    }

    /// Whether the terminal running Claude session `claudeSessionID` has
    /// exited, or no terminal runs it any more. Either way its provisional
    /// blocks can never be confirmed by a live process.
    nonisolated static func terminalHasExited(
        claudeSessionID: String, terminals: [UUID: [Terminal]]
    ) -> Bool {
        for list in terminals.values {
            if let terminal = list.first(where: { $0.claudeSessionID == claudeSessionID }) {
                return hasExited(terminal)
            }
        }
        return true
    }

    /// This pane's cadence tier right now: foreground while its worktree is on
    /// screen, background while the keep-alive LRU is merely holding its view
    /// tree alive. See `TranscriptPaneVisibility` for why the selection set is
    /// the on-screen test.
    private func currentPollTier() -> TranscriptPollTier {
        TranscriptPaneVisibility.tier(
            worktreeID: worktreeID,
            selectedWorktreeIDs: appState.selectedWorktreeIDs)
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

    /// The tail-first open's first write, merged by `openingTailMerge`, and
    /// made only when it changes what the slot holds.
    static func publishOpeningTail(
        _ tail: [TranscriptItem], sessionID: String, into state: AppState
    ) {
        guard let merged = openingTailMerge(
            slot: state.sessionTranscripts[sessionID] ?? [], tail: tail) else { return }
        state.sessionTranscripts[sessionID] = merged
        state.touchSessionTranscript(sessionID)
    }

    /// What the slot should hold once the opening tail lands, or nil to leave
    /// it as it is.
    ///
    /// - **An empty slot** takes the tail.
    /// - **A slot that holds the tail's first item** keeps its history up to
    ///   that item and takes the tail from there. A pane that remounts over a
    ///   store it filled before leaving the keep-alive set holds an older
    ///   snapshot; this refreshes its bottom at once instead of after the full
    ///   fetch, and never cuts the history a widened table is showing. Item
    ///   IDs make the match: `parseTail` builds the tail with the full parse's
    ///   own code, so an item has the same ID in both.
    /// - **A tail whose first item comes from a line with no `uuid`** leaves
    ///   any non-empty slot alone. That item's ID is positional
    ///   (`TranscriptParser.isPositionalFallbackID`), numbered from the start
    ///   of each read, so it can match a different line in a slot an earlier
    ///   tail filled.
    /// - **Any other slot** is left alone for the full fetch that follows to
    ///   refresh: the tail reaches nothing it holds.
    ///
    /// Nil too when the result would equal the slot. Comparing the spliced
    /// suffix is enough, since the history before it is kept as it is.
    nonisolated static func openingTailMerge(
        slot: [TranscriptItem], tail: [TranscriptItem]
    ) -> [TranscriptItem]? {
        guard let first = tail.first else { return nil }
        if slot.isEmpty { return tail }
        if TranscriptParser.isPositionalFallbackID(first.id) { return nil }
        guard let start = slot.lastIndex(where: { $0.id == first.id }) else { return nil }
        if slot[start...].elementsEqual(tail) { return nil }
        return Array(slot[..<start]) + tail
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
                    Self.publishOpeningTail(tail.messages, sessionID: tailSID, into: appState)
                    // Latched whether or not the tail was written: a skipped
                    // write means the store already holds rows to show.
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

/// Identity of the poll task: the terminal, its current Claude session, the
/// retry token, and whether the terminal has a transcript path yet. A change to
/// any of them cancels the running loop and starts a fresh one, rather than
/// leaving the pane on whichever loop it happened to begin with until something
/// else rebuilds it.
///
/// Path availability belongs in the identity because `pollLoop` picks its
/// transport once, at task start: a pane that mounted before its session
/// reported a transcript path would otherwise stay on the daemon poll until the
/// session changed. With it here, the task restarts on the in-process reader the
/// moment the path lands. Only *whether* a path exists is part of the key, never
/// the path string, so a session's path value can churn without restarting the
/// loop.
/// The identity of one run of the pane's poll loop. `.task(id:)` restarts the
/// loop whenever this changes, so every input the loop reads *once* has to be
/// part of it — otherwise the loop keeps running against a stale reading of it
/// and only an unrelated remount repairs the pane.
///
/// `streamPath` is here for exactly that reason: `appSideLoop` resolves the
/// session mod's stream file once, at the top, and flipping the Settings toggle
/// changes what that resolution yields. Without it in the key, turning "Stream
/// assistant text into the transcript" on would do nothing for a pane already
/// on screen. Restarting is cheap and safe here:
/// `TranscriptPollScheduler.register` is idempotent per token, and it already
/// mints a fresh generation when a path changes.
///
/// `terminalExited` is here because a terminal exiting retires every
/// provisional block, and it changes no file the scheduler watches: the restart
/// publishes once at once, and that publish drops the rows.
///
/// Internal, not private, so the resolution can be asserted directly rather
/// than only through a SwiftUI view tree — the same shape, and for the same
/// reason, as `TranscriptPaneTransport.resolve`.
struct TaskKey: Equatable {
    let terminalID: UUID
    let sessionID: String?
    let retryToken: Int
    let hasTranscriptPath: Bool
    /// The stream file this run of the loop will register, or nil when the
    /// daemon reports streaming off or the session has no usable id.
    let streamPath: String?
    let terminalExited: Bool

    /// - Parameter sessionsDir: where session-mod directories live; the
    ///   production `TBDConstants.sessionsDir()` unless a test passes its own.
    static func resolve(
        terminalID: UUID,
        sessionID: String?,
        retryToken: Int,
        transcriptPath: String?,
        streamingEnabled: Bool,
        terminalExited: Bool,
        sessionsDir: URL = TBDConstants.sessionsDir()
    ) -> TaskKey {
        TaskKey(
            terminalID: terminalID,
            sessionID: sessionID,
            retryToken: retryToken,
            hasTranscriptPath: !(transcriptPath ?? "").isEmpty,
            streamPath: streamingEnabled
                ? streamPath(sessionID: sessionID, sessionsDir: sessionsDir) : nil,
            terminalExited: terminalExited)
    }

    /// `<sessionsDir>/<sessionID>/transcript-stream.json`, or nil for a
    /// missing session id or one that is not safe to use as a path. A `/clear`
    /// gives the session a new id, and with it a new path.
    static func streamPath(sessionID: String?, sessionsDir: URL) -> String? {
        guard let sessionID,
              let dir = SessionModSessionFiles.directory(
                sessionsDir: sessionsDir, claudeSessionID: sessionID) else { return nil }
        return dir.appendingPathComponent(SessionModSessionFiles.transcriptStreamFileName).path
    }
}

/// SwiftUI identity for the table transcript representable. Composes the terminal
/// with its current Claude session so a session rollover tears down and rebuilds
/// the stateful Coordinator. (#129) Also the key of the pane's mount window
/// (`TableTranscriptPaneView.shownTableKey`).
struct PaneIdentity: Hashable {
    let terminalID: UUID
    let sessionID: String?
}

/// A weak handle on the transcript table one pane registered.
///
/// Weak because the registry's own reference is weak and this box must not be
/// the thing that keeps a torn-down table alive; it exists only so
/// `onDisappear` can name the view it should withdraw rather than clearing the
/// key and evicting a replacement that has already registered under it.
@MainActor
final class RegisteredTranscriptTable {
    weak var view: NSTableView?
}
