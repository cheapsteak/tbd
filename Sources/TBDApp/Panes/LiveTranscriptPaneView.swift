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
    // NOTE: Autoscroll-freeze-on-user-scroll detection is deliberately deferred.
    // SwiftUI doesn't expose ScrollView scroll position cleanly without
    // `.scrollPosition` (macOS 14+) or GeometryReader hacks. For v1, autoscroll
    // is always on; the "Jump to latest" pill never appears in practice. Wire
    // `.scrollPosition` later to flip this to false on manual scroll-up.
    @State private var autoscrollEnabled = true

    private static let log = Logger(subsystem: "com.tbd.app", category: "live-transcript")

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
        .task(id: TaskKey(terminalID: terminalID, retryToken: retryToken)) { await pollLoop() }
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
        ZStack(alignment: .bottomTrailing) {
            ScrollViewReader { proxy in
                TranscriptItemsView(items: messages, terminalID: terminalID)
                    .onChange(of: messages.last?.id) { _, newID in
                        guard autoscrollEnabled, let id = newID else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                    .onAppear {
                        if let id = messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
            }

            if !autoscrollEnabled {
                Button(action: { autoscrollEnabled = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                        Text("Jump to latest")
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(12)
            }
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

        // Detect session rollover.
        if let last = lastSessionID, last != sid {
            autoscrollEnabled = true
            hasShownInitialMessages = false
        }
        lastSessionID = sid

        do {
            let result = try await appState.daemonClient.terminalTranscript(terminalID: terminalID)
            failureCount = 0
            // Resolved sessionID may differ from terminal.claudeSessionID if a rollover
            // happened mid-flight; trust the daemon's resolution.
            let resolvedSID = result.sessionID ?? sid
            await MainActor.run {
                let prev = appState.sessionTranscripts[resolvedSID] ?? []
                if !messagesEqual(prev, result.messages) {
                    appState.sessionTranscripts[resolvedSID] = result.messages
                }
                if !result.messages.isEmpty {
                    hasShownInitialMessages = true
                }
            }
        } catch {
            failureCount += 1
            Self.log.debug("transcript poll failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func messagesEqual(_ a: [TranscriptItem], _ b: [TranscriptItem]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { $0.id == $1.id }
    }
}

private struct TaskKey: Equatable {
    let terminalID: UUID
    let retryToken: Int
}
