import SwiftUI
import TBDShared
import os

/// Read-only chat-style follower of a Claude terminal's current session
/// transcript. Polls the daemon every `pollInterval` while visible, writes
/// results into appState.sessionTranscripts (keyed by sessionID), and
/// re-targets automatically when the underlying terminal's claudeSessionID
/// changes (e.g., /clear, /compact, suspend/resume).
struct LiveTranscriptPaneView: View {
    let terminalID: UUID
    let worktreeID: UUID
    @EnvironmentObject var appState: AppState

    /// Polling interval. Constant for v1; deliberately not user-configurable.
    private let pollInterval: TimeInterval = 1.5
    /// Number of consecutive failed polls before flipping to the error state.
    private let errorThreshold = 3

    @State private var loadError: String?
    @State private var hasShownInitialMessages = false
    @State private var lastSessionID: String?
    @State private var retryToken = 0

    /// True when the visible viewport is within ~50pt of the bottom of
    /// the transcript content. Drives the floating jump-to-bottom button:
    /// shown only when the user has consciously scrolled up.
    @State private var atBottom: Bool = true

    /// Synthetic items rendered only when the perf harness is active (env-gated).
    /// Empty and unused in production.
    @State private var harnessMessages: [TranscriptItem] = []

    private static let log = Logger(subsystem: "com.tbd.app", category: "live-transcript")
    nonisolated private static let perfLog = Logger(subsystem: "com.tbd.app", category: "perf-transcript")

    /// Tracks which terminal IDs have already emitted a `body.first` marker
    /// for this process, so the per-(logger lifetime, terminalID) one-shot
    /// log fires exactly once. Throwaway diagnostic state — removed when the
    /// `perf-transcript` instrumentation is cleaned up.
    nonisolated private static let bodyLogged = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])

    /// Last 4 characters of an identifier for compact log lines.
    nonisolated private static func shortID(_ s: String) -> String {
        return String(s.suffix(4))
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

    /// Process-lifetime cache of the perf-harness config. The process
    /// environment is stable for the process lifetime, so resolve it ONCE
    /// (mirroring the `HangWatchdog.shared` pattern) rather than re-parsing on
    /// every `harnessConfig` access — `body` reads it 4+ times per pass, on the
    /// very main thread the harness measures.
    private static let harnessConfigCache: TranscriptPerfHarnessConfig? =
        TranscriptPerfHarness.config(from: ProcessInfo.processInfo.environment)

    /// Perf-harness config, resolved from the environment. `nil` (inert) in
    /// production; non-nil only when `TBD_TRANSCRIPT_PERF_HARNESS` is set.
    private var harnessConfig: TranscriptPerfHarnessConfig? { Self.harnessConfigCache }

    /// The items the transcript view actually renders. When the harness is
    /// active this is the synthetic `harnessMessages`; otherwise the real
    /// appState-derived `messages`. The poll loop still reads `messages`.
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
                Self.perfLog.debug("body.first terminalID=\(Self.shortID(terminalID.uuidString), privacy: .public)")
            }
        }
        Group {
            if harnessConfig != nil {
                // Perf-harness mode (env-gated): always show the transcript so
                // the synthetic injector drives the real scroll path.
                transcriptWithAutoscroll
            } else if let err = loadError {
                errorState(message: err)
            } else if currentSessionID == nil {
                emptyState(text: "This terminal has no Claude session.")
            } else if messages.isEmpty && !hasShownInitialMessages {
                emptyState(text: "Waiting for Claude to start the conversation…")
            } else {
                transcriptWithAutoscroll
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: TaskKey(terminalID: terminalID, retryToken: retryToken)) {
            Self.perfLog.debug("task.start terminalID=\(Self.shortID(terminalID.uuidString), privacy: .public)")
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

    /// Single live-transcript scroll path. Restored to the original (pre-A/B)
    /// modifier chain after the issue #129 scroll-strategy experiment proved
    /// scroll is not the lever (`.current ≈ .initialOnly`). The only deltas vs
    /// pre-experiment main are measurement-only and default-identical in
    /// production: the `TranscriptPerfHarness.autoscrollGate` (which equals
    /// `atBottom` when the harness is off) and one silent `.debug` fire/skip log
    /// per append.
    @ViewBuilder
    private var transcriptWithAutoscroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                TranscriptItemsView(items: displayedMessages, terminalID: terminalID, atBottom: $atBottom)
                    .environment(\.navigateToThread) { id in
                        appState.liveThreadPath[terminalID, default: []].append(id)
                    }
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .overlay(alignment: .bottomLeading) {
                jumpToBottomButton(proxy: proxy)
                    .animation(.easeInOut(duration: 0.2), value: atBottom)
            }
            .onAppear { recordAppearContext() }
            .onChange(of: displayedMessages.last?.id) { oldID, newID in
                // Edge guard: only react when both ends exist (a real append),
                // never on first paint or teardown.
                guard oldID != nil, newID != nil else { return }
                // `autoscrollGate` == `atBottom` in production; in harness mode
                // it pins to bottom so the scroll fires on every injected batch
                // (issue #129 measurement). One silent fire/skip debug log.
                let gate = TranscriptPerfHarness.autoscrollGate(
                    harnessActive: harnessConfig != nil,
                    atBottom: atBottom
                )
                guard gate, let targetID = lastRenderedNodeID(for: displayedMessages) else {
                    Self.perfLog.debug(
                        "autoscroll fired=false atBottom=\(self.atBottom, privacy: .public) gate=\(gate, privacy: .public) count=\(self.displayedMessages.count, privacy: .public)"
                    )
                    return
                }
                Self.perfLog.debug(
                    "autoscroll fired=true atBottom=\(self.atBottom, privacy: .public) gate=\(gate, privacy: .public) count=\(self.displayedMessages.count, privacy: .public)"
                )
                let scrollInterval = TranscriptSignposts.signposter.beginInterval("transcript.scrollTo")
                proxy.scrollTo(targetID, anchor: .bottom)
                TranscriptSignposts.signposter.endInterval("transcript.scrollTo", scrollInterval)
            }
            .onChange(of: displayedMessages.count) { _, newCount in
                recordCountContext(newCount)
            }
            .onDisappear { clearContext() }
        }
    }

    // MARK: - HangWatchdog context helpers

    /// `.onAppear` context: log + feed the hang watchdog so a stall caught
    /// during transcript layout has the focused terminal + item count attached.
    private func recordAppearContext() {
        let sidShort = Self.shortID(currentSessionID ?? "")
        Self.perfLog.debug("view.appear sid=\(sidShort, privacy: .public) count=\(displayedMessages.count, privacy: .public)")
        let tidShort = String(terminalID.uuidString.suffix(4))
        let count = displayedMessages.count
        HangWatchdog.shared.recordContext { snap in
            snap.focusedTerminalIDShort = tidShort
            snap.transcriptItemCount = count
            snap.paneLabel = "liveTranscript"
        }
    }

    /// `.onChange(displayedMessages.count)` context — unchanged across strategies.
    private func recordCountContext(_ newCount: Int) {
        let tidShort = String(terminalID.uuidString.suffix(4))
        HangWatchdog.shared.recordContext { snap in
            snap.focusedTerminalIDShort = tidShort
            snap.transcriptItemCount = newCount
            snap.paneLabel = "liveTranscript"
        }
    }

    /// `.onDisappear` context: clear the pane-specific fields so a hang in
    /// another pane (terminal, file viewer, etc.) doesn't get logged with a
    /// stale `pane=liveTranscript` tag and old item count.
    private func clearContext() {
        HangWatchdog.shared.recordContext { snap in
            snap.focusedTerminalIDShort = nil
            snap.transcriptItemCount = nil
            snap.paneLabel = nil
        }
    }

    @ViewBuilder
    private func jumpToBottomButton(proxy: ScrollViewProxy) -> some View {
        if !atBottom {
            Button {
                guard let lastID = lastRenderedNodeID(for: displayedMessages) else { return }
                let scrollInterval = TranscriptSignposts.signposter.beginInterval("transcript.scrollTo")
                proxy.scrollTo(lastID, anchor: .bottom)
                TranscriptSignposts.signposter.endInterval("transcript.scrollTo", scrollInterval)
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

    // MARK: - Perf harness (env-gated)

    /// Drive a deterministic synthetic streaming run: seed `cfg.preseed` heavy
    /// items, then append `cfg.injectBatch` heavy items every
    /// `cfg.injectIntervalMs` for `cfg.injectCount` ticks. Each tick does ONE
    /// `harnessMessages.append(contentsOf:)`, so it fires ONE
    /// `displayedMessages.last?.id` change → ONE production
    /// `.onChange → proxy.scrollTo(anchor: .bottom)` over `batch` new heavy rows.
    /// This faithfully reproduces the issue #129 freeze (a poll landing many
    /// heavy items at once) without touching real appState/daemon. Inert in
    /// production — only reached when `harnessConfig != nil`.
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
        Self.perfLog.debug("perf-harness run.start preseed=\(cfg.preseed, privacy: .public) inject=\(cfg.injectCount, privacy: .public) ms=\(cfg.injectIntervalMs, privacy: .public) batch=\(batch, privacy: .public)")

        for i in 0..<cfg.injectCount {
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: UInt64(cfg.injectIntervalMs) * 1_000_000)
            if Task.isCancelled { break }
            let startIndex = cfg.preseed + i * batch
            let next = TranscriptPerfHarness.makeSyntheticItems(count: batch, startIndex: startIndex)
            harnessMessages.append(contentsOf: next)
            Self.perfLog.debug("perf-harness inject seq=\(i + 1, privacy: .public)/\(cfg.injectCount, privacy: .public) batch=\(batch, privacy: .public) total=\(self.harnessMessages.count, privacy: .public)")
        }

        Self.perfLog.debug("perf-harness run.end total=\(self.harnessMessages.count, privacy: .public)")
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
        Self.perfLog.debug("pollOnce.start sid=\(sidShort, privacy: .public)")
        let pollStart = ContinuousClock.now
        var changed = false
        var finalCount = 0

        // Detect session rollover.
        if let last = lastSessionID, last != sid {
            hasShownInitialMessages = false
            liveThreadPathReset()
        }
        lastSessionID = sid

        do {
            let result = try await appState.daemonClient.terminalTranscript(terminalID: terminalID)
            failureCount = 0
            finalCount = result.messages.count
            // Resolved sessionID may differ from terminal.claudeSessionID if a rollover
            // happened mid-flight; trust the daemon's resolution.
            let resolvedSID = result.sessionID ?? sid
            let swapInterval = TranscriptSignposts.signposter.beginInterval("transcript.swap")
            let didChange: Bool = await MainActor.run {
                Self.perfLog.debug("pollOnce.mainActor.start sid=\(sidShort, privacy: .public)")
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
                Self.perfLog.debug("pollOnce.mainActor.end sid=\(sidShort, privacy: .public) elapsed_ms=\(mainActorMs, privacy: .public) equal_ms=\(equalMs, privacy: .public) swap_ms=\(swapMs, privacy: .public)")
                return !equal
            }
            TranscriptSignposts.signposter.endInterval("transcript.swap", swapInterval)
            changed = didChange
        } catch {
            failureCount += 1
            Self.log.debug("transcript poll failed: \(error.localizedDescription, privacy: .public)")
        }

        let pollElapsed = ContinuousClock.now - pollStart
        let pollMs = Int(pollElapsed.components.seconds * 1000 + pollElapsed.components.attoseconds / 1_000_000_000_000_000)
        Self.perfLog.debug("pollOnce.end sid=\(sidShort, privacy: .public) elapsed_ms=\(pollMs, privacy: .public) changed=\(changed, privacy: .public) count=\(finalCount, privacy: .public)")
    }

    /// Clears the subagent drill path for this terminal — called on session
    /// rollover (/clear, /compact, suspend/resume) so a new session opens on Main.
    private func liveThreadPathReset() {
        appState.liveThreadPath[terminalID] = []
    }

    private func messagesEqual(_ a: [TranscriptItem], _ b: [TranscriptItem]) -> Bool {
        let start = ContinuousClock.now
        let result = a == b
        let elapsed = ContinuousClock.now - start
        if max(a.count, b.count) > 100 {
            let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            Self.perfLog.debug("messagesEqual elapsed_ms=\(ms, privacy: .public) count_a=\(a.count, privacy: .public) count_b=\(b.count, privacy: .public) result=\(result, privacy: .public)")
        }
        return result
    }
}

private struct TaskKey: Equatable {
    let terminalID: UUID
    let retryToken: Int
}
