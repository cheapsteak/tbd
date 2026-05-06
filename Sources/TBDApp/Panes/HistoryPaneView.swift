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

            // Right panel: transcript or empty state
            if let summary = selectedSummary {
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
        if sessions.isEmpty && !loadState.isLoading {
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
            List(sessions) { summary in
                SessionRowView(summary: summary, isSelected: selectedSessionID == summary.sessionId)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task { await appState.selectSession(summary, worktreeID: worktreeID) }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowBackground(
                        selectedSessionID == summary.sessionId
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear
                    )
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
                ScrollView {
                    TranscriptItemsView(items: messages, terminalID: nil)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

