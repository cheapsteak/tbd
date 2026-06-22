import SwiftUI
import TBDShared

// MARK: - Overlay helpers

@MainActor
func isOverlayItemFor(terminalID: UUID, coordinator: TranscriptOverlayCoordinator) -> Bool {
    if case .item(let f)? = coordinator.current, f.terminalID == terminalID { return true }
    return false
}

/// True when the overlay should suppress key/mouse events from reaching
/// the given terminal's underlying NSView.
///
/// Two cases trigger suppression:
/// - An item frame for THIS terminal (the overlay sits over this terminal).
/// - Any file frame (file frames always render at the window root over
///   every terminal, so they must suppress every terminal's events).
@MainActor
func shouldSuppressEvents(in coordinator: TranscriptOverlayCoordinator, forTerminalID terminalID: UUID) -> Bool {
    if isOverlayItemFor(terminalID: terminalID, coordinator: coordinator) { return true }
    if case .file? = coordinator.current { return true }
    return false
}

// MARK: - PanePlaceholder

/// Universal leaf wrapper that renders the appropriate pane content
/// based on PaneContent type. Replaces the former TerminalPanelPlaceholder.
struct PanePlaceholder: View {
    let content: PaneContent
    let worktree: Worktree
    let tabID: UUID?
    @Binding var layout: LayoutNode
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var overlayCoordinator: TranscriptOverlayCoordinator
    @State private var isHeaderHovering = false
    @State private var showSourceCode = false
    @State private var hasRenderableContent = false
    @StateObject private var webviewState = WebviewState()
    @State private var didCopyURL = false
    @AppStorage(AppState.enableTranscriptKey) private var transcriptFeatureEnabled = false
    @AppStorage(AppState.useTextKitTranscriptKey) private var useTextKitTranscript = false

    /// Find the Terminal model matching a terminal ID in this pane's worktree.
    private func terminal(for id: UUID) -> Terminal? {
        appState.terminal(id: id, in: worktree.id)
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
            // Defer @State writes to the next runloop tick.
            //
            // SwiftUI propagates preference values during its layout / render
            // pass — and on pane teardown the preference resets to its
            // default, which fires this handler *while* the host view is
            // mid-layout. Mutating @State synchronously here re-invalidates
            // the view inside the same pass, producing
            // "NSHostingView is being laid out reentrantly while rendering
            // its SwiftUI content" and (with our FilePreviewView changes
            // adding @StateObject + .task teardown work in the same phase)
            // a SIGTRAP in GraphHost.updatePreferences.
            //
            // Hopping to the next main-actor turn lets the current layout
            // pass finish, then schedules a normal subsequent render.
            Task { @MainActor in
                if newValue && !hasRenderableContent {
                    showSourceCode = false
                }
                hasRenderableContent = newValue
            }
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
        .applyTranscriptCopyPathContextMenu(path: transcriptPath)
    }

    /// Description of the current drilled-into subagent for the heading, or nil
    /// at the Main level. Resolves against the terminal's live transcript.
    private func liveThreadHeadingLabel(terminalID: UUID, path: [String]) -> String? {
        guard !path.isEmpty,
              let sessionID = terminal(for: terminalID)?.claudeSessionID,
              let items = appState.sessionTranscripts[sessionID] else { return nil }
        return threadLabel(root: items, path: path)
    }

    /// Resolved Claude session JSONL path for liveTranscript panes; nil otherwise.
    private var transcriptPath: String? {
        if case .liveTranscript(_, let terminalID) = content {
            let path = terminal(for: terminalID)?.transcriptPath
            return (path?.isEmpty ?? true) ? nil : path
        }
        return nil
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
            Text(webviewState.currentURL?.absoluteString ?? url.absoluteString)
                .truncationMode(.tail)
                .help(webviewState.currentURL?.absoluteString ?? url.absoluteString)
        case .codeViewer(_, let path):
            Text(URL(fileURLWithPath: path).lastPathComponent)
        case .note(let noteID):
            EditableNoteTitle(noteID: noteID, worktreeID: worktree.id)
        case .liveTranscript(_, let terminalID):
            let term = terminal(for: terminalID)
            let path = appState.liveThreadPath[terminalID] ?? []
            let label = liveThreadHeadingLabel(terminalID: terminalID, path: path)
            HStack(spacing: 4) {
                if path.isEmpty {
                    Image(systemName: "text.bubble")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text(term?.label ?? "Transcript")
                } else {
                    Button {
                        appState.liveThreadPath[terminalID]?.removeLast()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left")
                            Text(label ?? "Subagent").lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var toolbarActions: some View {
        switch content {
        case .terminal(let terminalID):
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

            if terminal(for: terminalID)?.isClaudeResumable == true && transcriptFeatureEnabled {
                Button(action: { openTranscript(terminalID: terminalID) }) {
                    HStack(spacing: 2) {
                        Image(systemName: "text.bubble")
                        Text("Transcript")
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Open a chat-style live transcript pane")
            }

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

            Button(action: copyWebviewURL) {
                Image(systemName: didCopyURL ? "checkmark" : "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Copy URL")

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

        case .liveTranscript:
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
            WebviewPaneView(url: url, state: webviewState)
        case .codeViewer(_, let path):
            CodeViewerPaneView(path: path, worktreePath: worktree.path, showSourceCode: showSourceCode)
        case .note(let noteID):
            NotePaneView(noteID: noteID, worktreeID: worktree.id)
        case .liveTranscript(_, let terminalID):
            if transcriptFeatureEnabled {
                Group {
                    if useTextKitTranscript {
                        STTextViewTranscriptPaneView(terminalID: terminalID, worktreeID: worktree.id)
                    } else {
                        LiveTranscriptPaneView(terminalID: terminalID, worktreeID: worktree.id)
                    }
                }
                .environment(\.openFilePreview, { path in
                    let newContent = PaneContent.codeViewer(id: UUID(), path: path)
                    layout = layout.splitPane(id: content.paneID, direction: .horizontal, newContent: newContent)
                })
                .environment(\.openTranscriptOverlay) { itemID in
                    overlayCoordinator.open(terminalID: terminalID, itemID: itemID)
                }
            } else {
                transcriptDisabledPlaceholder
            }
        }
    }

    @ViewBuilder
    private func terminalContent(terminalID: UUID) -> some View {
        if AppState.shouldSuppressTerminalInLayout(
            terminalID: terminalID,
            dockedTerminalIDs: appState.dockedTerminalIDs
        ) {
            // This terminal is pinned and currently owned by PinnedTerminalDock.
            // Rendering a second TerminalPanelView here (this is the worktree
            // layout / keep-alive pager path) would mount the same terminal
            // twice and collide on the shared `tbd-view-<id>` tmux session. The
            // dock holds the live viewer; show a placeholder instead. This
            // placeholder is only ever offscreen (a kept-alive non-selected
            // worktree) — selecting the worktree moves the terminal into
            // `visibleTerminalIDs`, so it leaves `dockedTerminalIDs` and renders
            // for real in the main area.
            pinnedInDockPlaceholder
        } else if let terminal = terminal(for: terminalID) {
            if appState.suspendingTerminalIDs.contains(terminal.id) {
                // Show screenshot (or black fallback) — no live tmux connection
                Group {
                    if let screenshot = appState.suspendingSnapshots[terminal.id] {
                        Image(nsImage: screenshot)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color.black
                    }
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Suspending...")
                    }
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .padding(8)
                }
            } else {
                TerminalPanelView(
                    terminalID: terminalID,
                    tmuxServer: worktree.tmuxServer,
                    tmuxWindowID: terminal.tmuxWindowID,
                    tmuxBridge: appState.tmuxBridge,
                    tabCloseContext: tabID.map { TabCloseContext(worktreeID: worktree.id, tabID: $0) },
                    worktreePath: worktree.path,
                    remoteURL: appState.repos.first(where: { $0.id == worktree.repoID })?.remoteURL,
                    onFilePathClicked: { path in
                        layout = routeFileClick(into: layout, terminalID: terminalID, path: path)
                    },
                    onTerminalNotification: { title, body in
                        debugLog("OSC 777: \(title) — \(body)")
                    },
                    onDeadWindow: {
                        Task { await appState.recreateTerminalWindow(terminalID: terminalID) }
                    },
                    initialSnapshot: terminal.suspendedSnapshot,
                    isSuspendedSnapshot: terminal.suspendedAt != nil,
                    shouldSuppressEvents: { [overlayCoordinator] in
                        shouldSuppressEvents(in: overlayCoordinator, forTerminalID: terminalID)
                    }
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
                .overlay {
                    if let frame = overlayCoordinator.current,
                       isOverlayItemFor(terminalID: terminalID, coordinator: overlayCoordinator) {
                        TranscriptOverlayView(
                            frame: frame,
                            hasBack: overlayCoordinator.hasBack,
                            onBack: { overlayCoordinator.pop() },
                            onClose: { overlayCoordinator.close() }
                        )
                        .environment(\.openFilePreview, { path in
                            let newContent = PaneContent.codeViewer(id: UUID(), path: path)
                            layout = layout.splitPane(id: content.paneID, direction: .horizontal, newContent: newContent)
                        })
                        .padding(16)
                    }
                }
                .onDisappear {
                    if isOverlayItemFor(terminalID: terminalID, coordinator: overlayCoordinator) {
                        overlayCoordinator.close()
                    }
                    appState.snapshotProviders.removeValue(forKey: terminalID)
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

    /// Placeholder shown in the worktree-layout path for a terminal that is
    /// currently pinned and rendered live in `PinnedTerminalDock`. Avoids a
    /// second `TerminalPanelView` for the same terminal (which would fight over
    /// the shared `tbd-view-<id>` tmux session). Never user-visible in practice
    /// — only the offscreen kept-alive pager hits this branch.
    private var pinnedInDockPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "pin.fill")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Pinned — shown in the dock")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Placeholder shown when a transcript pane exists but the feature flag is off.
    /// Renders a centered message pointing the user to enable the feature in Settings.
    private var transcriptDisabledPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Transcript view is turned off")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Enable it in Settings → Experimental")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - Webview Actions

    private func copyWebviewURL() {
        guard case .webview(_, let initialURL) = content else { return }
        let urlString = (webviewState.currentURL ?? initialURL).absoluteString
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urlString, forType: .string)
        didCopyURL = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopyURL = false
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

    private func openTranscript(terminalID: UUID) {
        layout = layout.splitPane(
            id: content.paneID,
            direction: .horizontal,
            newContent: .liveTranscript(id: UUID(), terminalID: terminalID)
        )
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

// MARK: - Transcript Copy Path Context Menu

private extension View {
    /// Attach the "Copy Conversation Path" context menu only when a transcript
    /// path is available — non-transcript panes get no contextMenu at all so
    /// right-click is a true no-op rather than showing an empty menu.
    @ViewBuilder
    func applyTranscriptCopyPathContextMenu(path: String?) -> some View {
        if let path {
            self.contextMenu {
                Button("Copy Conversation Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
        } else {
            self
        }
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
