import AppKit
import SwiftUI
import TBDShared

/// The action exposed in the transcript header. Determines the button
/// label and which AppState method the button invokes.
enum TranscriptAction {
    /// Active worktree: open a new terminal in the same worktree resuming
    /// the selected Claude session.
    case resume
    /// Archived worktree: revive the worktree and resume the selected
    /// session in its primary terminal.
    case reviveWithSession
}

// MARK: - HistoryPaneView

struct HistoryPaneView: View {
    let worktreeID: UUID
    var transcriptAction: TranscriptAction = .resume
    @EnvironmentObject var appState: AppState

    private var loadState: HistoryLoadState {
        appState.historyLoadStates[worktreeID] ?? .idle
    }

    private var selectedSessionID: String? {
        appState.selectedSessionIDs[worktreeID]
    }

    private var selectedSummary: SessionSummary? {
        guard let sid = selectedSessionID else { return nil }
        return loadState.currentSessions.first { $0.sessionId == sid }
    }

    private var closedTerminals: [TerminalHistoryEntry] {
        appState.closedTerminalHistories[worktreeID] ?? []
    }

    private var selectedClosedTerminal: TerminalHistoryEntry? {
        guard let id = appState.selectedClosedTerminalIDs[worktreeID] else { return nil }
        return closedTerminals.first { $0.id == id }
    }

    @State private var listWidth: CGFloat = 290
    @State private var dragStartWidth: CGFloat? = nil

    var body: some View {
        HStack(spacing: 0) {
            // Left panel: session list
            VStack(spacing: 0) {
                HistoryHeaderRow(loadState: loadState, worktreeID: worktreeID)
                Divider()
                sessionList
            }
            .frame(width: listWidth)

            // Draggable divider
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .contentShape(Rectangle().inset(by: -3))
                .cursor(.resizeLeftRight)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if dragStartWidth == nil { dragStartWidth = listWidth }
                            let newWidth = (dragStartWidth ?? listWidth) + value.translation.width
                            listWidth = max(180, min(500, newWidth))
                        }
                        .onEnded { _ in dragStartWidth = nil }
                )

            // Right panel: closed-terminal capture, transcript, or empty state
            if let entry = selectedClosedTerminal {
                ClosedTerminalDetailView(entry: entry, worktreeID: worktreeID)
            } else if let summary = selectedSummary {
                SessionTranscriptView(
                    sessionId: summary.sessionId,
                    worktreeID: worktreeID,
                    summary: summary,
                    action: transcriptAction
                )
            } else {
                emptyDetailState
            }
        }
    }

    @ViewBuilder
    private var sessionList: some View {
        let sessions = loadState.currentSessions
        if sessions.isEmpty && closedTerminals.isEmpty && !loadState.isLoading {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No sessions found")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(sessions) { summary in
                    SessionRowView(summary: summary, isSelected: selectedSessionID == summary.sessionId)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Task { await appState.selectSession(summary, worktreeID: worktreeID) }
                        }
                        .contextMenu {
                            Button("Copy Conversation Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(summary.filePath, forType: .string)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .listRowBackground(
                            selectedSessionID == summary.sessionId
                                ? Color.accentColor.opacity(0.15)
                                : Color.clear
                        )
                }
                if !closedTerminals.isEmpty {
                    Section("Closed Terminals") {
                        ForEach(closedTerminals) { entry in
                            ClosedTerminalRowView(entry: entry)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    Task { await appState.selectClosedTerminal(entry, worktreeID: worktreeID) }
                                }
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                                .listRowBackground(
                                    selectedClosedTerminal?.id == entry.id
                                        ? Color.accentColor.opacity(0.15)
                                        : Color.clear
                                )
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptyDetailState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Select a session")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - HistoryHeaderRow

/// Fixed-height header showing load state without shifting the list below.
private struct HistoryHeaderRow: View {
    let loadState: HistoryLoadState
    let worktreeID: UUID
    @EnvironmentObject var appState: AppState
    @State private var statusMessage: String? = nil
    @State private var statusClearTask: Task<Void, Never>? = nil

    var body: some View {
        ZStack {
            Color.clear.frame(height: 28)
            content
        }
        .onChange(of: loadState) { oldState, newState in
            handleTransition(from: oldState, to: newState)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .idle:
            EmptyView()

        case .loading:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6)
                Text("Loading sessions…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .loadingStale:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6)
                Text("Checking for new sessions…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .loaded:
            if let msg = statusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }

        case .failed(let msg):
            Button {
                Task { await appState.fetchSessions(worktreeID: worktreeID) }
            } label: {
                Text("Failed to load — click to retry")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(msg)
        }
    }

    private func handleTransition(from oldState: HistoryLoadState, to newState: HistoryLoadState) {
        guard case .loaded(let fresh) = newState else { return }
        // Only show "N new sessions" when refreshing existing data, not on first load.
        let wasRefresh: Bool
        switch oldState {
        case .loadingStale: wasRefresh = true
        default: wasRefresh = false
        }
        if wasRefresh {
            let existingIDs = Set(oldState.currentSessions.map(\.sessionId))
            let newCount = fresh.filter { !existingIDs.contains($0.sessionId) }.count
            statusMessage = newCount > 0
                ? "↑ \(newCount) new session\(newCount == 1 ? "" : "s")"
                : "Up to date"
        } else {
            statusMessage = "Up to date"
        }
        statusClearTask?.cancel()
        statusClearTask = Task {
            // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation { statusMessage = nil }
        }
    }
}

// MARK: - SessionRowView

private struct SessionRowView: View {
    let summary: SessionSummary
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Headline: first user message
            if let first = summary.firstUserMessage {
                Text(first)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Subtitle: last user message (only if different)
            if let last = summary.lastUserMessage, last != summary.firstUserMessage {
                Text(last)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Metadata line (including hash inline)
            metadataLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var metadataLine: some View {
        HStack(spacing: 4) {
            Text("\(summary.lineCount.formatted()) events")
            separator
            Text(summary.fileSize.formattedFileSize)
            separator
            Text(summary.lastMessageAt.smartFormatted)
            if let branch = summary.gitBranch {
                separator
                Text(branch)
                    .lineLimit(1)
            }
            separator
            Text(String(summary.sessionId.prefix(8)))
                .font(.system(.caption2, design: .monospaced))
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private var separator: some View {
        Text("·").foregroundStyle(.quaternary).font(.caption2)
    }
}

// MARK: - SessionTranscriptView

struct SessionTranscriptView: View {
    let sessionId: String
    let worktreeID: UUID
    let summary: SessionSummary
    let action: TranscriptAction
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var overlayCoordinator: TranscriptOverlayCoordinator

    /// True when the visible viewport is within ~50pt of the bottom of
    /// the transcript content. Drives the floating jump-to-bottom button:
    /// shown only when the user has consciously scrolled up.
    @State private var atBottom: Bool = true

    /// Incremented by the jump-to-bottom button to ask the table to scroll to
    /// the last row (NSTableView renderer path).
    @State private var scrollToBottomToken: Int = 0

    private var messages: [TranscriptItem] {
        appState.sessionTranscripts[sessionId] ?? []
    }

    private var isLoading: Bool {
        appState.sessionTranscriptLoading.contains(sessionId)
    }

    private var actionLabel: String {
        switch action {
        case .resume: return "Resume"
        case .reviveWithSession: return "Revive with this session"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Transcript header with Resume button
            HStack {
                if let first = summary.firstUserMessage {
                    Text(first)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(String(sessionId.prefix(8)))
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(actionLabel) {
                    Task {
                        switch action {
                        case .resume:
                            await appState.resumeSession(worktreeID: worktreeID, sessionId: sessionId)
                        case .reviveWithSession:
                            await appState.reviveWithSession(worktreeID: worktreeID, sessionId: sessionId)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contextMenu {
                Button("Copy Conversation Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary.filePath, forType: .string)
                }
            }

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No messages found")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TableTranscriptView(
                    context: TranscriptCardContext(
                        terminalID: nil,
                        openTranscriptOverlay: { itemID in
                            overlayCoordinator.open(
                                terminalID: nil,
                                itemID: itemID,
                                historySessionID: sessionId
                            )
                        },
                        appState: appState
                    ),
                    atBottom: $atBottom,
                    scrollToBottomToken: scrollToBottomToken,
                    nodesProvider: { transcriptRenderNodes(from: messages) }
                )
                // Rebuild the stateful Coordinator when the selected session changes.
                .id(sessionId)
                .overlay(alignment: .bottomTrailing) {
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
                .animation(.easeInOut(duration: 0.2), value: atBottom)
                .onAppear {
                    let count = messages.count
                    HangWatchdog.shared.recordContext { snap in
                        snap.focusedTerminalIDShort = nil
                        snap.transcriptItemCount = count
                        snap.paneLabel = "history"
                    }
                }
                .onChange(of: messages.count) { _, newCount in
                    HangWatchdog.shared.recordContext { snap in
                        snap.transcriptItemCount = newCount
                        snap.paneLabel = "history"
                    }
                }
                .onDisappear {
                    HangWatchdog.shared.recordContext { snap in
                        snap.focusedTerminalIDShort = nil
                        snap.transcriptItemCount = nil
                        snap.paneLabel = nil
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Closed Terminals

/// List row for one captured closed terminal (label/kind + close time).
private struct ClosedTerminalRowView: View {
    let entry: TerminalHistoryEntry

    private var title: String {
        if let label = entry.label, !label.isEmpty { return label }
        switch entry.kind {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .shell, .none: return "Terminal"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Text("closed \(entry.closedAt.smartFormatted)")
                Text("·").foregroundStyle(.quaternary)
                Text("\(entry.lineCount.formatted()) lines")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

/// Right-hand pane for a selected closed terminal: the captured scrollback,
/// read-only, in a single monospaced NSTextView (no highlighting, no per-line
/// rows — the capture can be ~10k lines and must stay cheap to display).
private struct ClosedTerminalDetailView: View {
    let entry: TerminalHistoryEntry
    let worktreeID: UUID
    @EnvironmentObject var appState: AppState

    private var content: String? {
        appState.closedTerminalContents[entry.id]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(entry.label ?? "Terminal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("closed \(entry.closedAt.smartFormatted)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("· Read-only")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Revive") {
                    Task { await appState.reviveClosedTerminal(entry, worktreeID: worktreeID) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if let content {
                if content.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text("No captured output")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ReadOnlyMonospacedTextView(text: content)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Minimal scrollable read-only monospaced text view. One NSTextView for the
/// whole capture — deliberately NOT a SwiftUI per-line list and NOT
/// syntax-highlighted (both are proven main-thread hangs on large text in
/// this app, see #129).
private struct ReadOnlyMonospacedTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            textView.textColor = .textColor
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 8, height: 8)
        }
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else { return }
        textView.string = text
    }
}

// MARK: - Formatting Helpers

private extension Int64 {
    var formattedFileSize: String {
        let bytes = Double(self)
        if bytes < 1_024 { return "\(self) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", bytes / 1_024) }
        return String(format: "%.1f MB", bytes / 1_048_576)
    }
}

