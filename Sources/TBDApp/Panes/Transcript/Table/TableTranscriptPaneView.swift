import SwiftUI
import TBDShared
import os

/// NSTableView live-transcript pane: mirrors `STTextViewTranscriptPaneView`'s
/// data path (poll loop, session-rollover guard, thread resolution, jump-to-
/// bottom) but renders via `TableTranscriptView` — a view-based NSTableView
/// hosting the existing SwiftUI `SelectableTranscriptRow` per cell with an
/// explicit height cache, instead of the single-document STTextView.
///
/// Rendered in place of the other panes when
/// `AppState.useTableViewTranscriptKey` is `true` (precedence:
/// tableview > textkit > swiftui). Shares the same
/// `init(terminalID:worktreeID:)` shape so the `PanePlaceholder` call site swaps
/// cleanly. (#129)
struct TableTranscriptPaneView: View {
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

    /// Within ~120pt of the bottom. Drives the floating jump-to-bottom button.
    @State private var atBottom: Bool = true

    /// Incremented by the jump-to-bottom button to ask the table to scroll to
    /// the last row.
    @State private var scrollToBottomToken: Int = 0

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
        .task(id: TaskKey(terminalID: terminalID, sessionID: currentSessionID, retryToken: retryToken)) {
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
    private var tableTranscript: some View {
        let cardContext = TranscriptCardContext(
            terminalID: terminalID,
            openTranscriptOverlay: openTranscriptOverlay,
            appState: appState
        )
        TableTranscriptView(
            context: cardContext,
            atBottom: $atBottom,
            scrollToBottomToken: scrollToBottomToken,
            nodesProvider: { timedRenderNodes(from: displayedMessages) }
        )
        // Compose the terminal with its current Claude session so a session
        // rollover within one terminal tears down and rebuilds the stateful
        // Coordinator, re-resolving from a clean baseline rather than persisting
        // the prior session's drilled-in subagent thread. Mirrors the TextKit
        // pane's identity rationale. (#129)
        .id(PaneIdentity(terminalID: terminalID, sessionID: currentSessionID))
        .overlay(alignment: .bottomLeading) {
            jumpToBottomButton
                .animation(.easeInOut(duration: 0.2), value: atBottom)
        }
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
    private func timedRenderNodes(from messages: [TranscriptItem]) -> [TranscriptRenderNode] {
        let timing = openTiming
        let buildStart = DispatchTime.now().uptimeNanoseconds
        let nodes = transcriptRenderNodes(from: messages)
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

        // Detect session rollover: reset the initial-state guard.
        if let last = lastSessionID, last != sid {
            hasShownInitialMessages = false
        }
        lastSessionID = sid

        do {
            let fetchStart = DispatchTime.now().uptimeNanoseconds
            let result = try await appState.daemonClient.terminalTranscript(terminalID: terminalID)
            // One-shot RPC round-trip marker for the FIRST poll on open.
            if !openTiming.didLogFetch {
                openTiming.didLogFetch = true
                let ms = Double(DispatchTime.now().uptimeNanoseconds &- fetchStart) / 1_000_000
                Self.openLog.debug(
                    "table.open.fetchDone ms=\(ms, format: .fixed(precision: 1), privacy: .public) itemCount=\(result.messages.count, privacy: .public)")
            }
            failureCount = 0
            let resolvedSID = result.sessionID ?? sid
            await MainActor.run {
                let prev = appState.sessionTranscripts[resolvedSID] ?? []
                if prev != result.messages {
                    appState.sessionTranscripts[resolvedSID] = result.messages
                    appState.touchSessionTranscript(resolvedSID)
                }
                if !result.messages.isEmpty {
                    hasShownInitialMessages = true
                }
            }
        } catch {
            failureCount += 1
            Self.log.debug("table transcript poll failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private struct TaskKey: Equatable {
    let terminalID: UUID
    let sessionID: String?
    let retryToken: Int
}

/// SwiftUI identity for the table transcript representable. Composes the terminal
/// with its current Claude session so a session rollover tears down and rebuilds
/// the stateful Coordinator. (#129)
private struct PaneIdentity: Hashable {
    let terminalID: UUID
    let sessionID: String?
}
