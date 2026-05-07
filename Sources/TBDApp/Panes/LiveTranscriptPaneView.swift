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

    var body: some View {
        let _ = Self.bodyLogged.withLock { logged in
            if !logged.contains(terminalID) {
                logged.insert(terminalID)
                Self.perfLog.debug("body.first terminalID=\(Self.shortID(terminalID.uuidString), privacy: .public)")
            }
        }
        Group {
            if let err = loadError {
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
            await pollLoop()
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
    private var transcriptWithAutoscroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                TranscriptItemsView(items: messages, terminalID: terminalID)
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: AtBottomGeometry.self) { geometry in
                AtBottomGeometry(
                    contentHeight: geometry.contentSize.height,
                    viewportBottom: geometry.contentOffset.y + geometry.containerSize.height
                )
            } action: { _, new in
                atBottom = new.contentHeight - new.viewportBottom < 50
            }
            .overlay(alignment: .bottomTrailing) {
                jumpToBottomButton(proxy: proxy)
            }
            .animation(.easeInOut(duration: 0.2), value: atBottom)
            .onAppear {
                let sidShort = Self.shortID(currentSessionID ?? "")
                Self.perfLog.debug("view.appear sid=\(sidShort, privacy: .public) count=\(messages.count, privacy: .public)")
            }
        }
    }

    @ViewBuilder
    private func jumpToBottomButton(proxy: ScrollViewProxy) -> some View {
        if !atBottom {
            Button {
                guard let lastID = messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
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
        }
        lastSessionID = sid

        do {
            let result = try await appState.daemonClient.terminalTranscript(terminalID: terminalID)
            failureCount = 0
            finalCount = result.messages.count
            // Resolved sessionID may differ from terminal.claudeSessionID if a rollover
            // happened mid-flight; trust the daemon's resolution.
            let resolvedSID = result.sessionID ?? sid
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
            changed = didChange
        } catch {
            failureCount += 1
            Self.log.debug("transcript poll failed: \(error.localizedDescription, privacy: .public)")
        }

        let pollElapsed = ContinuousClock.now - pollStart
        let pollMs = Int(pollElapsed.components.seconds * 1000 + pollElapsed.components.attoseconds / 1_000_000_000_000_000)
        Self.perfLog.debug("pollOnce.end sid=\(sidShort, privacy: .public) elapsed_ms=\(pollMs, privacy: .public) changed=\(changed, privacy: .public) count=\(finalCount, privacy: .public)")
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

/// Inputs to the at-bottom check, ferried through `onScrollGeometryChange`'s
/// Equatable transform. `atBottom` is true when `contentHeight - viewportBottom < 50`.
private struct AtBottomGeometry: Equatable {
    let contentHeight: CGFloat
    let viewportBottom: CGFloat
}
