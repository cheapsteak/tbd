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

// MARK: - ParkedPaneWakeModel

/// Pure gate behind the parked pane's full-surface click-to-wake overlay:
/// only a PARKED terminal (hibernated or legacy-suspended) gets the
/// transparent click-catching layer — a live pane must never have one (it
/// would eat clicks meant for the terminal). Extracted from the view so both
/// branches are unit-testable without SwiftUI (same pattern as
/// `TabParkMenuModel`).
enum ParkedPaneWakeModel {
    static func showsWakeOverlay(for terminal: Terminal?) -> Bool {
        terminal?.isParked == true
    }
}

// MARK: - PanePlaceholder

/// Universal leaf wrapper that renders the appropriate pane content
/// based on PaneContent type. Replaces the former TerminalPanelPlaceholder.
struct PanePlaceholder: View {
    let content: PaneContent
    /// Panes root a terminal's working directory and the code viewer's file
    /// resolution at this worktree's checkout, so the pane tree carries the
    /// proven-local wrapper rather than a bare `Worktree`.
    let worktree: LocalWorktree
    let tabID: UUID?
    @Binding var layout: LayoutNode
    @Environment(AppState.self) var appState
    @EnvironmentObject var overlayCoordinator: TranscriptOverlayCoordinator
    @State private var isHeaderHovering = false
    @State private var showSourceCode = false
    @State private var hasRenderableContent = false
    @State private var showHistoryPalette = false
    @StateObject private var webviewState = WebviewState()
    @State private var didCopyURL = false
    @AppStorage(AppState.enableTranscriptKey)
    private var transcriptFeatureEnabled = AppState.enableTranscriptDefault

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
            // Leading so the chevrons sit in a stable spot on every viewer
            // pane, unaffected by which trailing buttons a pane type has.
            // Both buttons always render (16x16 fixed frames, disabled when
            // unavailable), so the title never jumps.
            if content.isViewerClass {
                historyNavigation
            }

            paneLabel
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // Scoped to the title only (not the whole header row) so
                // right-click on the history chevrons / close button isn't
                // swallowed by the file menu.
                .headerFileContextMenu(for: content, transcriptPath: transcriptPath)

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
            HStack(spacing: 4) {
                Image(systemName: "text.bubble")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                Text(term?.label ?? "Transcript")
            }
        }
    }

    @ViewBuilder
    private var toolbarActions: some View {
        switch content {
        case .terminal(let terminalID):
            if terminal(for: terminalID)?.isClaudeResumable == true && transcriptFeatureEnabled {
                let transcriptOpen = isTranscriptOpen(terminalID: terminalID)
                Button(action: { toggleTranscriptPane(terminalID: terminalID) }) {
                    HStack(spacing: 2) {
                        Image(systemName: transcriptOpen ? "text.bubble.fill" : "text.bubble")
                        Text("Transcript")
                    }
                    .font(.caption)
                    .foregroundStyle(transcriptOpen ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.borderless)
                .help(transcriptOpen
                    ? "Hide the chat-style live transcript pane"
                    : "Show the chat-style live transcript pane")
            }

        case .webview:
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

        case .note, .liveTranscript:
            EmptyView()
        }
    }

    // MARK: - Slot History Navigation

    /// Search icon + back/forward chevrons for viewer-class slot panes. The
    /// search icon opens the MRU history palette (searchable replacement for
    /// the old right-click dropdown — see `historySearchButton`); the
    /// chevrons still left-click step one entry at a time.
    @ViewBuilder
    private var historyNavigation: some View {
        // A pane that hasn't navigated yet has no recorded history — but it
        // always has its current content, so fall back to a single-entry
        // history seeded with it rather than an empty one. Otherwise the
        // search button would wrongly read as "nothing to show" for the
        // common case of a freshly opened viewer slot.
        let history = appState.paneHistories[content.paneID] ?? PaneHistory.seeded(with: content)

        historySearchButton(history: history)

        historyButton(
            icon: "chevron.left",
            help: "Back",
            action: { navigateHistory { $0.goBack() } }
        )
        .disabled(!history.canGoBack)

        historyButton(
            icon: "chevron.right",
            help: "Forward",
            action: { navigateHistory { $0.goForward() } }
        )
        .disabled(!history.canGoForward)
    }

    /// Search icon opening the searchable MRU-history palette (replaces the
    /// former right-click dropdown on the chevrons, which was
    /// undiscoverable). Always enabled for a live viewer slot — it always
    /// has at least its current entry to show, checkmarked, even before any
    /// navigation has happened. Disabled only at zero entries, which in
    /// practice never happens here.
    private func historySearchButton(history: PaneHistory) -> some View {
        Button(action: { showHistoryPalette = true }) {
            // A couple points larger and a lighter weight than the 8pt/bold
            // chevrons/close glyph: at 8pt bold, "line.3.horizontal"'s three
            // bars crowd into a smudge. Regular weight + a touch more size
            // gives the bars air while still reading as the lightest glyph
            // in the row (not heavier than its neighbors).
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .regular))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Search pane history")
        .disabled(!PaneHistoryPaletteButtonModel.isEnabled(entryCount: history.entries.count))
        .popover(isPresented: $showHistoryPalette, arrowEdge: .bottom) {
            PaneHistoryPaletteView(history: history) { index in
                navigateHistory { $0.go(to: index) }
            }
        }
    }

    /// Plain Button — no `.contextMenu` (that dropdown is now the palette
    /// above); never `.onTapGesture`, which blocks `.contextMenu` on macOS
    /// (moot here since there's none left, but keeping the plain-Button
    /// shape avoids reintroducing the trap).
    private func historyButton(
        icon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            // Glyph sized a notch below the close button's 9pt; the 16x16
            // frame + contentShape keeps the full hit target.
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    /// Applies a history navigation to this slot: mutate the slot's history,
    /// then swap the layout content in place keeping the pane UUID. Goes
    /// through `replacingContent` directly — never through the routing
    /// functions — so navigating does not push new history entries.
    private func navigateHistory(_ step: (inout PaneHistory) -> PaneContent?) {
        guard var history = appState.paneHistories[content.paneID],
              let target = step(&history),
              let updated = layout.replacingContent(at: content.paneID, with: target)
        else { return }
        appState.paneHistories[content.paneID] = history
        layout = updated
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
                TableTranscriptPaneView(terminalID: terminalID, worktreeID: worktree.id)
                .environment(\.openFilePreview, { path in
                    let newContent = PaneContent.codeViewer(id: UUID(), path: path)
                    layout = layout.splitPane(id: content.paneID, direction: .horizontal, newContent: newContent)
                })
                .environment(\.openTranscriptOverlay) { itemID in
                    overlayCoordinator.open(terminalID: terminalID, itemID: itemID)
                }
                .environment(\.openTranscriptLink) { target in
                    switch TranscriptLinkDestination.live(
                        target, layout: layout, terminalID: terminalID
                    ) {
                    case .route(let result):
                        if let replaced = result.replaced {
                            appState.recordPaneReplacement(replaced)
                        }
                        layout = result.layout
                    case .openInBrowser(let url):
                        NSWorkspace.shared.open(url)
                    }
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
                        let result = routeFileClick(into: layout, terminalID: terminalID, path: path)
                        if let replaced = result.replaced {
                            appState.recordPaneReplacement(replaced)
                        }
                        layout = result.layout
                    },
                    onTerminalNotification: { title, body in
                        debugLog("OSC 777: \(title) — \(body)")
                    },
                    onMissingWindow: {
                        await appState.requestAutomaticTerminalRecreation(terminalID: terminalID)
                    },
                    initialSnapshot: terminal.suspendedSnapshot,
                    // Show the frozen snapshot backdrop while PARKED — hibernated
                    // (authoritative) or legacy-suspended. The unified park path
                    // captures a snapshot into `suspendedSnapshot`, so hibernated
                    // rows have one too.
                    isSuspendedSnapshot: terminal.isParked,
                    // Reason-phrased hibernate notice, composed INTO the
                    // frozen snapshot's last rows at feed time (in the
                    // terminal's own grid/font — see ParkedSnapshotComposer).
                    // nil for a live terminal so the wake/reconnect path
                    // feeds the snapshot untouched.
                    parkedNoticeMessage: terminal.isParked
                        ? HibernatedBannerModel.message(for: terminal.hibernateReason)
                        : nil,
                    shouldSuppressEvents: { [overlayCoordinator] in
                        shouldSuppressEvents(in: overlayCoordinator, forTerminalID: terminalID)
                    }
                )
                .id("\(terminal.id)-\(terminal.tmuxWindowID)-\(terminal.isParked)")
                .overlay {
                    // Full-surface click-to-wake for a PARKED pane: the whole
                    // frozen snapshot is the resume affordance (the old
                    // corner "Click to resume session" chip was easy to miss;
                    // the in-grid notice block composed into the snapshot's
                    // last rows carries the text). Gated
                    // by ParkedPaneWakeModel so a LIVE terminal never gets a
                    // click-catching layer over it. A transparent plain Button
                    // (not .onTapGesture, which blocks .contextMenu on macOS)
                    // — applied BEFORE the TranscriptOverlayView overlay below
                    // so that overlay stays on top in hit-testing. Plain
                    // left-clicks reach it: TerminalPanelView's click monitor
                    // only consumes Cmd+clicks that resolve a file path.
                    if ParkedPaneWakeModel.showsWakeOverlay(for: terminal) {
                        Button {
                            Task { await appState.wakeParkedTerminalUserInitiated(terminalID: terminal.id, worktreeID: worktree.id) }
                        } label: {
                            Color.clear
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                        .help("Click to resume session")
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
            Text("Enable it in Settings → General → Claude")
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

        appState.paneHistories.removeValue(forKey: content.paneID)

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
            // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopyURL = false
        }
    }

    private func toggleTranscriptPane(terminalID: UUID) {
        let result = toggleTranscript(into: layout, terminalID: terminalID, fromPaneID: content.paneID)
        if let replaced = result.replaced {
            appState.recordPaneReplacement(replaced)
        }
        if let removed = result.removedPaneID {
            // Reused slot: restore its pre-transcript content in place instead
            // of applying the removal layout.
            if let previous = appState.popHistoryForRemovedPane(removed),
               let restored = layout.replacingContent(at: removed, with: previous) {
                layout = restored
                return
            }
        }
        layout = result.layout
    }

    private func isTranscriptOpen(terminalID: UUID) -> Bool {
        layout.firstPaneID(where: { isLiveTranscriptPane($0, for: terminalID) }) != nil
    }
}

// MARK: - Header File Context Menu

private extension View {
    /// Attach the pane-header file context menu (Copy Path / Reveal in Finder /
    /// Open With) only when the pane has an associated file — other panes get no
    /// contextMenu at all so right-click is a true no-op rather than an empty
    /// menu. `transcriptPath` supplies the `.jsonl` path for live-transcript
    /// panes (resolving it needs the terminal model, so the caller passes it in).
    @ViewBuilder
    func headerFileContextMenu(for content: PaneContent, transcriptPath: String?) -> some View {
        if let target = headerMenuTarget(for: content, transcriptPath: transcriptPath) {
            self.contextMenu {
                Button(target.copyLabel) { copyToPasteboard(target.path) }
                Button("Reveal in Finder") { revealInFinder(path: target.path) }

                let apps = openWithApps(forPath: target.path)
                if !apps.isEmpty {
                    Menu("Open With") {
                        ForEach(apps) { app in
                            Button {
                                openFile(path: target.path, withApp: app.url)
                            } label: {
                                Label {
                                    Text(app.displayName)
                                } icon: {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                        .renderingMode(.original)
                                }
                            }
                        }
                    }
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
    @Environment(AppState.self) var appState
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
