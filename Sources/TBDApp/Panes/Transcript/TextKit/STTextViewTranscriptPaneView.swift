import SwiftUI
import TBDShared
import os

/// TextKit 2 live-transcript pane: mirrors `LiveTranscriptPaneView`'s data path
/// (poll loop, resolveThread, liveThreadPath drill, HangWatchdog, Signposts,
/// PerfHarness) but renders via `STTextViewTranscriptView` instead of the
/// SwiftUI `ScrollView` + `TranscriptItemsView` stack. (#129)
///
/// Rendered in place of `LiveTranscriptPaneView` when
/// `AppState.useTextKitTranscriptKey` is `true`. Shares the same
/// `init(terminalID:worktreeID:)` shape so the `PanePlaceholder` call site swaps
/// cleanly.
struct STTextViewTranscriptPaneView: View {
    let terminalID: UUID
    let worktreeID: UUID
    @EnvironmentObject var appState: AppState
    @Environment(\.openTranscriptOverlay) private var openTranscriptOverlay

    private let pollInterval: TimeInterval = 1.5
    private let errorThreshold = 3

    @State private var loadError: String?
    @State private var hasShownInitialMessages = false
    @State private var lastSessionID: String?
    @State private var retryToken = 0

    /// Tracks whether STTextView's scroll position is within ~50pt of the bottom.
    /// Drives the floating jump-to-bottom button.
    @State private var atBottom: Bool = true

    /// Incremented by the jump-to-bottom button to trigger `scrollToEndOfDocument`.
    @State private var scrollToBottomToken: Int = 0

    /// Synthetic items rendered only when the perf harness is active (env-gated).
    @State private var harnessMessages: [TranscriptItem] = []

    private static let log = Logger(subsystem: "com.tbd.app", category: "live-transcript")
    nonisolated private static let perfLog = Logger(subsystem: "com.tbd.app", category: "perf-transcript")
    private static let diagLog = Logger(subsystem: "com.tbd.app", category: "textkit-pane")

    nonisolated private static let bodyLogged = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])

    nonisolated private static func shortID(_ s: String) -> String {
        return String(s.suffix(4))
    }

    /// Returns the role label and a ≤50-char text prefix for a TranscriptItem.
    private static func diagLabel(_ item: TranscriptItem) -> (role: String, text: String) {
        switch item {
        case .userPrompt(_, let t, _):
            return ("user", String(t.prefix(50)))
        case .assistantText(_, let t, _, _):
            return ("assistant", String(t.prefix(50)))
        case .thinking(_, let t, _):
            return ("thinking", String(t.prefix(50)))
        case .systemReminder(_, _, let t, _):
            return ("system", String(t.prefix(50)))
        case .toolCall(_, let name, _, _, _, _, _, _):
            return ("tool", name)
        case .slashCommand(_, let name, _, _):
            return ("slash", name)
        }
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

    private var path: [String] {
        appState.liveThreadPath[terminalID] ?? []
    }

    /// Process-lifetime cache of the perf-harness config; inert (nil) in production.
    private static let harnessConfigCache: TranscriptPerfHarnessConfig? =
        TranscriptPerfHarness.config(from: ProcessInfo.processInfo.environment)

    private var harnessConfig: TranscriptPerfHarnessConfig? { Self.harnessConfigCache }

    private var displayedMessages: [TranscriptItem] {
        TranscriptPerfHarness.displayedMessages(
            harnessActive: harnessConfig != nil,
            harness: harnessMessages,
            real: resolveThread(root: messages, path: path)
        )
    }

    var body: some View {
        let _ = Self.bodyLogged.withLock { logged in
            if !logged.contains(terminalID) {
                logged.insert(terminalID)
                Self.perfLog.debug("textkit.body.first terminalID=\(Self.shortID(terminalID.uuidString), privacy: .public)")
            }
        }
        Group {
            if harnessConfig != nil {
                textKitTranscript
            } else if let err = loadError {
                errorState(message: err)
            } else if currentSessionID == nil {
                emptyState(text: "This terminal has no Claude session.")
            } else if messages.isEmpty && !hasShownInitialMessages {
                emptyState(text: "Waiting for Claude to start the conversation…")
            } else {
                textKitTranscript
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: TaskKey(terminalID: terminalID, sessionID: currentSessionID, retryToken: retryToken)) {
            Self.perfLog.debug("textkit.task.start terminalID=\(Self.shortID(terminalID.uuidString), privacy: .public)")
            if let cfg = harnessConfig {
                await runPerfHarness(cfg)
            } else {
                await pollLoop()
            }
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

    /// The TextKit 2 transcript renderer with jump-to-bottom overlay.
    ///
    /// `STTextViewTranscriptView` wraps an `NSScrollView`/`STTextView` directly —
    /// it must NOT be nested inside a SwiftUI `ScrollView`, which would give the
    /// NSScrollView an unbounded ideal size and cause layout hangs (#129).
    @ViewBuilder
    private var textKitTranscript: some View {
        let cardContext = TranscriptCardContext(
            terminalID: terminalID,
            openTranscriptOverlay: openTranscriptOverlay,
            navigateToThread: { id in
                appState.liveThreadPath[terminalID, default: []].append(id)
            },
            appState: appState
        )
        STTextViewTranscriptView(
            context: cardContext,
            atBottom: $atBottom,
            scrollToBottomToken: scrollToBottomToken,
            nodesProvider: { transcriptRenderNodes(from: displayedMessages) }
        )
        // Pin the representable's identity to BOTH the terminal AND its current
        // Claude session. Terminal alone is insufficient: a single terminal hosts
        // MULTIPLE Claude sessions over its lifetime (/clear, /compact, resume all
        // roll `claudeSessionID` — see AppState.applyTerminalSessionDelta). With a
        // terminalID-only id, a session rollover does NOT change identity, so the
        // stateful Coordinator (its bound TranscriptDocument + cached previousNodes)
        // PERSISTS across the rollover. If the `@State lastSessionID` rollover guard
        // misses the change (it resets to nil whenever the view is recreated, e.g.
        // tab switch), `liveThreadPath[terminalID]` is never reset and the pane
        // keeps rendering the PREVIOUS session's drilled-in subagent thread —
        // foreign content. Composing the session id into the identity forces a
        // fresh Coordinator + clean rebuild on every session switch within a
        // terminal, so the pane always re-resolves to the new session's primary
        // (Main) timeline. The poll loop is re-keyed in lockstep via `.task(id:)`.
        // Without a session, fall back to terminalID so the empty/placeholder
        // states still have a stable identity. (#129)
        .id(PaneIdentity(terminalID: terminalID, sessionID: currentSessionID))
        // Diag: log the composed pane identity each time textKitTranscript is evaluated. (#129)
        .onAppear {
            let tidShort = String(terminalID.uuidString.suffix(4))
            let sid = currentSessionID ?? "nil"
            Self.diagLog.debug("paneIdentity term=\(tidShort, privacy: .public) sid=\(sid, privacy: .public)")
        }
        .overlay(alignment: .bottomLeading) {
            jumpToBottomButton
                .animation(.easeInOut(duration: 0.2), value: atBottom)
        }
        .onAppear { recordAppearContext() }
        .onChange(of: displayedMessages.count) { _, newCount in
            recordCountContext(newCount)
        }
        .onDisappear { clearContext() }
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

    // MARK: - HangWatchdog context helpers

    private func recordAppearContext() {
        let sidShort = Self.shortID(currentSessionID ?? "")
        Self.perfLog.debug("textkit.view.appear sid=\(sidShort, privacy: .public) count=\(displayedMessages.count, privacy: .public)")
        let tidShort = String(terminalID.uuidString.suffix(4))
        let count = displayedMessages.count

        // Diag: log session resolution on appear so a capture can identify which
        // session this terminal resolved to and how. (#129)
        let sid = currentSessionID
        let rootCount = sid.map { appState.sessionTranscripts[$0]?.count ?? 0 } ?? 0
        let threadPath = path
        let resolved = resolveThread(root: messages, path: threadPath)
        Self.diagLog.debug(
            "resolve sid term=\(tidShort, privacy: .public) sid=\(sid ?? "nil", privacy: .public) lastSessionID=\(self.lastSessionID ?? "nil", privacy: .public) source=terminal.claudeSessionID"
        )
        Self.diagLog.debug(
            "messages term=\(tidShort, privacy: .public) sid=\(sid ?? "nil", privacy: .public) rootCount=\(rootCount, privacy: .public)"
        )
        Self.diagLog.debug(
            "thread term=\(tidShort, privacy: .public) pathCount=\(threadPath.count, privacy: .public) path=\(threadPath.joined(separator: ","), privacy: .public) displayedCount=\(resolved.count, privacy: .public)"
        )
        if let first = resolved.first {
            let (role, text) = Self.diagLabel(first)
            Self.diagLog.debug("displayed.first term=\(tidShort, privacy: .public) role=\(role, privacy: .public) text=\(text, privacy: .public)")
        }
        if let last = resolved.last, resolved.count > 1 {
            let (role, text) = Self.diagLabel(last)
            Self.diagLog.debug("displayed.last term=\(tidShort, privacy: .public) role=\(role, privacy: .public) text=\(text, privacy: .public)")
        }

        HangWatchdog.shared.recordContext { snap in
            snap.focusedTerminalIDShort = tidShort
            snap.transcriptItemCount = count
            snap.paneLabel = "liveTranscript"
        }
    }

    private func recordCountContext(_ newCount: Int) {
        let tidShort = String(terminalID.uuidString.suffix(4))
        HangWatchdog.shared.recordContext { snap in
            snap.focusedTerminalIDShort = tidShort
            snap.transcriptItemCount = newCount
            snap.paneLabel = "liveTranscript"
        }
    }

    private func clearContext() {
        HangWatchdog.shared.recordContext { snap in
            snap.focusedTerminalIDShort = nil
            snap.transcriptItemCount = nil
            snap.paneLabel = nil
        }
    }

    // MARK: - Perf harness (env-gated)

    @MainActor
    private func runPerfHarness(_ cfg: TranscriptPerfHarnessConfig) async {
        harnessMessages = TranscriptPerfHarness.makeSyntheticItems(count: cfg.preseed)
        let tidShort = String(terminalID.uuidString.suffix(4))
        HangWatchdog.shared.recordContext { snap in
            snap.focusedTerminalIDShort = tidShort
            snap.transcriptItemCount = cfg.preseed
            snap.paneLabel = "liveTranscript"
        }
        let batch = cfg.injectBatch
        Self.perfLog.debug("textkit.perf-harness run.start preseed=\(cfg.preseed, privacy: .public) inject=\(cfg.injectCount, privacy: .public) ms=\(cfg.injectIntervalMs, privacy: .public) batch=\(batch, privacy: .public)")

        for i in 0..<cfg.injectCount {
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: UInt64(cfg.injectIntervalMs) * 1_000_000)
            if Task.isCancelled { break }
            let startIndex = cfg.preseed + i * batch
            let next = TranscriptPerfHarness.makeSyntheticItems(count: batch, startIndex: startIndex)
            harnessMessages.append(contentsOf: next)
            Self.perfLog.debug("textkit.perf-harness inject seq=\(i + 1, privacy: .public)/\(cfg.injectCount, privacy: .public) batch=\(batch, privacy: .public) total=\(self.harnessMessages.count, privacy: .public)")
        }

        Self.perfLog.debug("textkit.perf-harness run.end total=\(self.harnessMessages.count, privacy: .public)")
    }

    // MARK: - Polling

    private func pollLoop() async {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            await pollOnce(failureCount: &consecutiveFailures)
            if consecutiveFailures >= errorThreshold {
                loadError = "Lost connection to the daemon."
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    private func pollOnce(failureCount: inout Int) async {
        guard let sid = currentSessionID else { return }
        let sidShort = Self.shortID(sid)
        let tidShort = String(terminalID.uuidString.suffix(4))
        Self.perfLog.debug("textkit.pollOnce.start sid=\(sidShort, privacy: .public)")
        // Diag: log session resolution on each poll so we can track which sid is in use. (#129)
        Self.diagLog.debug(
            "resolve sid term=\(tidShort, privacy: .public) sid=\(sid, privacy: .public) lastSessionID=\(self.lastSessionID ?? "nil", privacy: .public) source=terminal.claudeSessionID"
        )
        let pollStart = ContinuousClock.now
        var changed = false
        var finalCount = 0

        // Detect session rollover.
        if let last = lastSessionID, last != sid {
            hasShownInitialMessages = false
            // Diag: rollover fired — sid changed from last to current. (#129)
            Self.diagLog.debug(
                "rollover term=\(tidShort, privacy: .public) last=\(last, privacy: .public) current=\(sid, privacy: .public) action=reset"
            )
            liveThreadPathReset()
        } else if lastSessionID == nil {
            // Diag: first poll, no prior sid to compare. (#129)
            Self.diagLog.debug(
                "rollover term=\(tidShort, privacy: .public) last=nil current=\(sid, privacy: .public) action=skip-nil"
            )
        } else {
            // Diag: sid unchanged — rollover guard skipped. (#129)
            Self.diagLog.debug(
                "rollover term=\(tidShort, privacy: .public) last=\(lastSessionID ?? "nil", privacy: .public) current=\(sid, privacy: .public) action=skip-same"
            )
        }
        lastSessionID = sid

        do {
            let result = try await appState.daemonClient.terminalTranscript(terminalID: terminalID)
            failureCount = 0
            finalCount = result.messages.count
            let resolvedSID = result.sessionID ?? sid
            let swapInterval = TranscriptSignposts.signposter.beginInterval("transcript.swap")
            let didChange: Bool = await MainActor.run {
                Self.perfLog.debug("textkit.pollOnce.mainActor.start sid=\(sidShort, privacy: .public)")
                let mainActorStart = ContinuousClock.now
                let prev = appState.sessionTranscripts[resolvedSID] ?? []
                let equalStart = ContinuousClock.now
                let equal = messagesEqual(prev, result.messages)
                let equalElapsed = ContinuousClock.now - equalStart
                let equalMs = Int(equalElapsed.components.seconds * 1000 + equalElapsed.components.attoseconds / 1_000_000_000_000_000)
                let swapStart = ContinuousClock.now
                if !equal {
                    appState.sessionTranscripts[resolvedSID] = result.messages
                    appState.touchSessionTranscript(resolvedSID)
                }
                let swapElapsed = ContinuousClock.now - swapStart
                let swapMs = Int(swapElapsed.components.seconds * 1000 + swapElapsed.components.attoseconds / 1_000_000_000_000_000)
                if !result.messages.isEmpty {
                    hasShownInitialMessages = true
                }
                let mainActorElapsed = ContinuousClock.now - mainActorStart
                let mainActorMs = Int(mainActorElapsed.components.seconds * 1000 + mainActorElapsed.components.attoseconds / 1_000_000_000_000_000)
                Self.perfLog.debug("textkit.pollOnce.mainActor.end sid=\(sidShort, privacy: .public) elapsed_ms=\(mainActorMs, privacy: .public) equal_ms=\(equalMs, privacy: .public) swap_ms=\(swapMs, privacy: .public)")
                return !equal
            }
            TranscriptSignposts.signposter.endInterval("transcript.swap", swapInterval)
            changed = didChange
            // Diag: log message source, thread resolution, and displayed head/tail
            // after each successful poll so we can identify which conversation is
            // rendering in this terminal. Only log on change to reduce noise. (#129)
            if didChange {
                let rootCount = appState.sessionTranscripts[resolvedSID]?.count ?? 0
                Self.diagLog.debug(
                    "messages term=\(tidShort, privacy: .public) sid=\(resolvedSID, privacy: .public) rootCount=\(rootCount, privacy: .public)"
                )
                let threadPath = path
                let resolved = resolveThread(root: messages, path: threadPath)
                Self.diagLog.debug(
                    "thread term=\(tidShort, privacy: .public) pathCount=\(threadPath.count, privacy: .public) path=\(threadPath.joined(separator: ","), privacy: .public) displayedCount=\(resolved.count, privacy: .public)"
                )
                if let first = resolved.first {
                    let (role, text) = Self.diagLabel(first)
                    Self.diagLog.debug("displayed.first term=\(tidShort, privacy: .public) role=\(role, privacy: .public) text=\(text, privacy: .public)")
                }
                if let last = resolved.last, resolved.count > 1 {
                    let (role, text) = Self.diagLabel(last)
                    Self.diagLog.debug("displayed.last term=\(tidShort, privacy: .public) role=\(role, privacy: .public) text=\(text, privacy: .public)")
                }
            }
        } catch {
            failureCount += 1
            Self.log.debug("textkit transcript poll failed: \(error.localizedDescription, privacy: .public)")
        }

        let pollElapsed = ContinuousClock.now - pollStart
        let pollMs = Int(pollElapsed.components.seconds * 1000 + pollElapsed.components.attoseconds / 1_000_000_000_000_000)
        Self.perfLog.debug("textkit.pollOnce.end sid=\(sidShort, privacy: .public) elapsed_ms=\(pollMs, privacy: .public) changed=\(changed, privacy: .public) count=\(finalCount, privacy: .public)")
    }

    /// Clears the subagent drill path for this terminal on session rollover.
    private func liveThreadPathReset() {
        appState.liveThreadPath[terminalID] = []
    }

    private func messagesEqual(_ a: [TranscriptItem], _ b: [TranscriptItem]) -> Bool {
        let start = ContinuousClock.now
        let result = a == b
        let elapsed = ContinuousClock.now - start
        if max(a.count, b.count) > 100 {
            let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            Self.perfLog.debug("textkit.messagesEqual elapsed_ms=\(ms, privacy: .public) count_a=\(a.count, privacy: .public) count_b=\(b.count, privacy: .public) result=\(result, privacy: .public)")
        }
        return result
    }
}

private struct TaskKey: Equatable {
    let terminalID: UUID
    let sessionID: String?
    let retryToken: Int
}

/// SwiftUI identity for the TextKit transcript representable. Composes the
/// terminal with its CURRENT Claude session so a session rollover within one
/// terminal (multi-session) tears down and rebuilds the stateful Coordinator,
/// re-resolving from a clean baseline rather than persisting the prior session's
/// drilled-in subagent thread. `sessionID == nil` (no session yet) still yields a
/// stable per-terminal identity for the empty/placeholder states. (#129)
private struct PaneIdentity: Hashable {
    let terminalID: UUID
    let sessionID: String?
}
