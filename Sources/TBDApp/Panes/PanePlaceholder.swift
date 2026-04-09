import SwiftUI
import TBDShared

// MARK: - PanePlaceholder

/// Universal leaf wrapper that renders the appropriate pane content
/// based on PaneContent type. Replaces the former TerminalPanelPlaceholder.
struct PanePlaceholder: View {
    let content: PaneContent
    let worktree: Worktree
    @Binding var layout: LayoutNode
    @EnvironmentObject var appState: AppState
    @State private var isHeaderHovering = false
    @State private var showSourceCode = false
    @State private var hasRenderableContent = false

    /// Find the Terminal model matching a terminal ID across all worktree terminals.
    private func terminal(for id: UUID) -> Terminal? {
        for (_, terms) in appState.terminals {
            if let t = terms.first(where: { $0.id == id }) {
                return t
            }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar header
            toolbar

            Divider()

            // Pane content
            paneBody
        }
        .onPreferenceChange(HasRenderableContentKey.self) { newValue in
            if newValue && !hasRenderableContent {
                showSourceCode = false
            }
            hasRenderableContent = newValue
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 8) {
            paneLabel
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            toolbarActions

            Button(action: closePane) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help("Close pane")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .onHover { hovering in
            isHeaderHovering = hovering
        }
    }

    @ViewBuilder
    private var paneLabel: some View {
        switch content {
        case .terminal(let terminalID):
            let term = terminal(for: terminalID)
            let isPinned = term?.pinnedAt != nil
            HStack(spacing: 4) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                        .onTapGesture {
                            Task { await appState.setTerminalPin(id: terminalID, pinned: false) }
                        }
                } else if isHeaderHovering {
                    Image(systemName: "pin")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                        .onTapGesture {
                            Task { await appState.setTerminalPin(id: terminalID, pinned: true) }
                        }
                }
            }
        case .webview(_, let url):
            Text(url.host ?? url.absoluteString)
        case .codeViewer(_, let path):
            Text(URL(fileURLWithPath: path).lastPathComponent)
        case .note(let noteID):
            EditableNoteTitle(noteID: noteID, worktreeID: worktree.id)
        }
    }

    @ViewBuilder
    private var toolbarActions: some View {
        switch content {
        case .terminal:
            Button(action: splitRight) {
                HStack(spacing: 2) {
                    Image(systemName: "rectangle.split.1x2")
                        .rotationEffect(.degrees(90))
                    Text("Split Right")
                }
                .font(.caption)
            }
            .buttonStyle(.borderless)

            Button(action: splitDown) {
                HStack(spacing: 2) {
                    Image(systemName: "rectangle.split.1x2")
                    Text("Split Down")
                }
                .font(.caption)
            }
            .buttonStyle(.borderless)

        case .webview:
            // Placeholder for back/forward — will be wired in Task 6
            Button(action: {}) {
                Image(systemName: "chevron.left")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(true)

            Button(action: {}) {
                Image(systemName: "chevron.right")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(true)

        case .codeViewer:
            if hasRenderableContent {
                Button(action: { showSourceCode.toggle() }) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.caption)
                        .foregroundStyle(showSourceCode ? .primary : .secondary)
                }
                .buttonStyle(.borderless)
                .help(showSourceCode ? "Show rendered view" : "Show source code")
            }

        case .note:
            EmptyView()
        }
    }

    // MARK: - Pane Body

    @ViewBuilder
    private var paneBody: some View {
        switch content {
        case .terminal(let terminalID):
            terminalContent(terminalID: terminalID)
        case .webview(_, let url):
            WebviewPaneView(url: url)
        case .codeViewer(_, let path):
            CodeViewerPaneView(path: path, worktreePath: worktree.path, showSourceCode: showSourceCode)
        case .note(let noteID):
            NotePaneView(noteID: noteID, worktreeID: worktree.id)
        }
    }

    @ViewBuilder
    private func terminalContent(terminalID: UUID) -> some View {
        if let terminal = terminal(for: terminalID) {
            TerminalPanelView(
                terminalID: terminalID,
                tmuxServer: worktree.tmuxServer,
                tmuxWindowID: terminal.tmuxWindowID,
                tmuxBridge: appState.tmuxBridge,
                worktreePath: worktree.path,
                remoteURL: appState.repos.first(where: { $0.id == worktree.repoID })?.remoteURL,
                onFilePathClicked: { path in
                    let newContent = PaneContent.codeViewer(id: UUID(), path: path)
                    layout = layout.splitPane(id: terminalID, direction: .horizontal, newContent: newContent)
                },
                onTerminalNotification: { title, body in
                    debugLog("OSC 777: \(title) — \(body)")
                },
                onDeadWindow: {
                    Task { await appState.recreateTerminalWindow(terminalID: terminalID) }
                },
                initialSnapshot: terminal.suspendedSnapshot,
                isSuspendedSnapshot: terminal.suspendedAt != nil
            )
            .id("\(terminal.id)-\(terminal.tmuxWindowID)-\(terminal.suspendedAt != nil)")
            .overlay(alignment: .topTrailing) {
                if terminal.suspendedAt != nil {
                    Button {
                        Task {
                            try? await appState.daemonClient.terminalResume(terminalID: terminal.id)
                            await appState.refreshTerminals(worktreeID: worktree.id)
                        }
                    } label: {
                        Text("Click to resume session")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
            }
        } else {
            // Fallback when terminal data hasn't loaded yet
            ZStack {
                Color(nsColor: .black)

                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(worktree.displayName)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(worktree.branch)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Close

    private func closePane() {
        // Delete the underlying resource for note panes
        if case .note(let noteID) = content {
            Task { await appState.deleteNote(noteID: noteID, worktreeID: worktree.id) }
        }

        if let newLayout = layout.removePane(id: content.paneID) {
            layout = newLayout
        } else {
            // Last pane in this tab — remove the entire tab
            let worktreeID = worktree.id
            if let tabIndex = appState.tabs[worktreeID]?.firstIndex(where: { $0.id == content.paneID || $0.content.paneID == content.paneID }) {
                appState.tabs[worktreeID]?.remove(at: tabIndex)
                appState.layouts.removeValue(forKey: content.paneID)
            }
        }
    }

    // MARK: - Split Actions

    private func splitRight() {
        Task {
            await createTerminalSplit(direction: .horizontal)
        }
    }

    private func splitDown() {
        Task {
            await createTerminalSplit(direction: .vertical)
        }
    }

    /// Creates a real terminal via the daemon, then inserts it as a split pane.
    /// Uses createTerminalForSplit so no extra tab is created — the terminal
    /// lives inside this tab's layout tree.
    private func createTerminalSplit(direction: SplitDirection) async {
        guard let newTerminal = await appState.createTerminalForSplit(worktreeID: worktree.id) else { return }
        layout = layout.splitPane(
            id: content.paneID,
            direction: direction,
            newContent: .terminal(terminalID: newTerminal.id)
        )
    }
}

// MARK: - EditableNoteTitle

/// An inline-editable title for note panes. Displays as text, becomes
/// a text field on click. Commits on Enter or focus loss.
struct EditableNoteTitle: View {
    let noteID: UUID
    let worktreeID: UUID
    @EnvironmentObject var appState: AppState
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var isFocused: Bool

    private var note: Note? {
        appState.notes[worktreeID]?.first { $0.id == noteID }
    }

    var body: some View {
        if isEditing {
            TextField("Title", text: $editText, onCommit: {
                commitEdit()
            })
            .textFieldStyle(.plain)
            .font(.caption)
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onChange(of: isFocused) { _, focused in
                if !focused { commitEdit() }
            }
        } else {
            Text(note?.title ?? "Note")
                .onTapGesture {
                    editText = note?.title ?? ""
                    isEditing = true
                }
        }
    }

    private func commitEdit() {
        isEditing = false
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != note?.title else { return }
        Task {
            await appState.updateNote(noteID: noteID, worktreeID: worktreeID, title: trimmed)
        }
    }
}

