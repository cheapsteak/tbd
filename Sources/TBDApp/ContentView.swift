import AppKit
import SwiftUI
import TBDShared

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var overlayCoordinator: TranscriptOverlayCoordinator
    @AppStorage("filePanel.isVisible") private var showFilePanel = true
    @AppStorage("filePanel.width") private var filePanelWidth: Double = 280
    @AppStorage(AppState.autoSuspendClaudeKey) private var autoSuspendClaude: Bool = false
    @State private var contentAreaHeight: CGFloat = 600

    private var selectedWorktree: Worktree? {
        guard let id = appState.selectedWorktreeIDs.first else { return nil }
        return appState.worktrees.values.flatMap { $0 }.first { $0.id == id }
    }

    /// Returns the set of terminal IDs currently rendered anywhere in the
    /// detail layout. Used so the window-root fallback overlay only fires
    /// when the bound terminal is NOT visible (closed terminal, History
    /// pane, single-pane mode, etc.).
    private var visibleTerminalIDs: Set<UUID> {
        var ids: Set<UUID> = []
        for layout in appState.layouts.values {
            ids.formUnion(layout.allTerminalIDs())
        }
        return ids
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 400)
            } detail: {
                if !appState.isConnected {
                    disconnectedView
                } else if appState.repos.isEmpty {
                    emptyStateView
                } else if let repoID = appState.selectedRepoID {
                    RepoDetailView(repoID: repoID)
                } else if appState.selectedWorktreeIDs.isEmpty {
                    Text("Select a worktree or click + to create one")
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 0) {
                        TerminalContainerView()
                        if showFilePanel, let worktree = selectedWorktree, !worktree.path.isEmpty {
                            FilePanelDivider(panelWidth: Binding(
                                get: { CGFloat(filePanelWidth) },
                                set: { filePanelWidth = Double($0) }
                            ))
                            FileViewerPanel(worktree: worktree)
                                .frame(width: CGFloat(filePanelWidth))
                                .id(worktree.id)
                        }
                    }
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ContentHeightKey.self, value: geometry.size.height)
                    })
                    .onPreferenceChange(ContentHeightKey.self) { contentAreaHeight = $0 }
                    .overlay {
                        if let frame = overlayCoordinator.current,
                           overlayFrameIsWindowRoot(frame, visibleTerminalIDs: visibleTerminalIDs) {
                            TranscriptOverlayView(
                                frame: frame,
                                hasBack: overlayCoordinator.hasBack,
                                onBack: { overlayCoordinator.pop() },
                                onClose: { overlayCoordinator.close() }
                            )
                            .frame(maxWidth: 900, maxHeight: 700)
                            .padding(20)
                        }
                    }
                    .background {
                        // Window-wide click-outside catcher. Renders transparently behind
                        // the entire detail area; only consumes taps when an overlay is
                        // currently open, so it doesn't interfere with normal interaction.
                        if overlayCoordinator.isOpen {
                            Color.black.opacity(0.001)
                                .onTapGesture { overlayCoordinator.close() }
                                .allowsHitTesting(true)
                        }
                    }
                }
            }
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        appState.navigateBack()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!appState.canGoBack)
                    .help("Back")
                    .keyboardShortcut("[", modifiers: .command)

                    Button {
                        appState.navigateForward()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!appState.canGoForward)
                    .help("Forward")
                    .keyboardShortcut("]", modifiers: .command)
                }

                // macOS 26 fuses ADJACENT bare toolbar items onto one Liquid Glass
                // capsule, and `ToolbarItemGroup` fuses on purpose. The reliable
                // capsule BOUNDARY is `ControlGroup` (→ NSToolbarItemGroup): the PR
                // split button is its sole child, which separates it from both
                // neighbors (confirmed earlier) with no internal gap, while keeping
                // the split-button chevron + status-colored icon. Plain `Button`s
                // for the filter / sidebar separate via placement-matched spacers.
                ToolbarItem(placement: .primaryAction) {
                    Picker("Filter", selection: $appState.repoFilter) {
                        Text("All Repos").tag(UUID?.none)
                        Divider()
                        ForEach(appState.repos) { repo in
                            Text(repo.displayName).tag(UUID?.some(repo.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .help("Filter sidebar by repository")
                }

                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }

                if let worktreeID = appState.selectedWorktreeIDs.first,
                   appState.selectedWorktreeIDs.count == 1,
                   let prStatus = appState.prStatuses[worktreeID],
                   let prURL = URL(string: prStatus.url) {
                    ToolbarItem(placement: .primaryAction) {
                        ControlGroup {
                            // Split button: label = primary click (open PR); the
                            // attached chevron opens the menu.
                            Menu {
                                if appState.findWorktree(id: worktreeID) != nil {
                                    let blocked = !appState.children(of: worktreeID).isEmpty
                                    Toggle("Auto-archive worktree on PR merge", isOn: Binding(
                                        get: {
                                            appState.findWorktree(id: worktreeID)
                                                .map { appState.effectiveAutoArchive(for: $0) } ?? false
                                        },
                                        set: { newValue in
                                            Task { await appState.setAutoArchive(worktreeID: worktreeID, enabled: newValue) }
                                        }
                                    ))
                                    .disabled(blocked)
                                }
                            } label: {
                                let armed = appState.findWorktree(id: worktreeID)
                                    .map { appState.effectiveAutoArchive(for: $0) } ?? false
                                PRButtonLabel(prStatus: prStatus, isAutoArchiveArmed: armed)
                            } primaryAction: {
                                let existingTabs = appState.tabs[worktreeID] ?? []
                                if let existingIndex = existingTabs.firstIndex(where: {
                                    if case .webview(_, let url) = $0.content { return url == prURL }
                                    return false
                                }) {
                                    // Focus existing PR tab
                                    appState.activeTabIndices[worktreeID] = existingIndex
                                } else {
                                    // Create and focus new PR tab
                                    let webviewID = UUID()
                                    let tab = Tab(id: UUID(), content: .webview(id: webviewID, url: prURL), label: "PR #\(prStatus.number)")
                                    appState.tabs[worktreeID, default: []].append(tab)
                                    appState.activeTabIndices[worktreeID] = (appState.tabs[worktreeID]?.count ?? 1) - 1
                                }
                            }
                            // Keep "#123" neutral like the original plain Button (the
                            // split button otherwise accent-tints it); the icon keeps
                            // its baked status color via renderingMode(.original).
                            .tint(.primary)
                            .help("Open PR #\(prStatus.number) · more options")
                        }
                    }

                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .primaryAction)
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        // Defer the toggle one run-loop tick and skip the explicit
                        // withAnimation wrapper. Stacking an easeInOut animation
                        // on top of an in-flight NavigationSplitView selection
                        // change blew the per-window constraint-update budget
                        // (NSGenericException from _uncollapseArrangedView:animated:).
                        // SwiftUI still animates the layout change implicitly.
                        DispatchQueue.main.async { showFilePanel.toggle() }
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .help("Toggle file panel (⌘⇧E)")
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                }
            }

            StatusBarView()
        }
        .frame(minWidth: 800, minHeight: 500)
        .onChange(of: appState.selectedWorktreeIDs) { oldSelection, newSelection in
            overlayCoordinator.close()
            markSelectedWorktreesAsRead(newSelection)
            let newlySelected = newSelection.subtracting(oldSelection)
            for worktreeID in newlySelected {
                Task { await appState.refreshPRStatus(worktreeID: worktreeID) }
            }
            Task {
                try? await appState.daemonClient.worktreeSelectionChanged(
                    selectedWorktreeIDs: appState.selectedWorktreeIDs,
                    suspendEnabled: autoSuspendClaude
                )
                for worktreeID in newSelection {
                    await appState.refreshTerminals(worktreeID: worktreeID)
                }
            }

            // Keep-alive: track most-recently-visited worktree for view-tree preservation.
            if newSelection.count == 1, let id = newSelection.first {
                appState.touchVisitedWorktree(id)
                appState.focusTerminalAfterSelectionChange(worktreeID: id)
            }
        }
        .alert(
            appState.alertIsError ? "Error" : "Success",
            isPresented: Binding(
                get: { appState.alertMessage != nil },
                set: { if !$0 { appState.alertMessage = nil } }
            )
        ) {
            Button("OK") { appState.alertMessage = nil }
        } message: {
            Text(appState.alertMessage ?? "")
        }
        .onAppear {
            // Keep-alive: seed recentlyVisitedWorktreeIDs with the initially-restored
            // selection so the ZStack renders the right SingleWorktreeView on first frame.
            if appState.selectedWorktreeIDs.count == 1, let id = appState.selectedWorktreeIDs.first {
                appState.touchVisitedWorktree(id)
                appState.focusTerminalAfterSelectionChange(worktreeID: id)
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No Repositories")
                .font(.title2)
                .fontWeight(.medium)

            Text("Add a Git repository to get started.\nTBD will manage worktrees and terminals for each repo.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)

            Button(action: addRepo) {
                Label("Add Repository", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Disconnected State

    private var disconnectedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 48))
                .foregroundStyle(.red.opacity(0.6))

            Text("Daemon Not Connected")
                .font(.title2)
                .fontWeight(.medium)

            Text("The TBD daemon is not running.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)

            Button("Start Daemon") {
                Task {
                    await appState.startDaemonAndConnect()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func addRepo() {
        let panel = NSOpenPanel()
        panel.title = "Select a Git Repository"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await appState.addRepo(path: url.path)
            }
        }
    }

    private func markSelectedWorktreesAsRead(_ selection: Set<UUID>) {
        for worktreeID in selection {
            appState.unreadByWorktree[worktreeID] = nil
            Task {
                await appState.markNotificationsRead(worktreeID: worktreeID)
            }
        }
        appState.macNotificationManager.dismissDelivered(worktreeIDs: selection)
    }

}

// MARK: - Overlay helpers

/// Returns true when the overlay's current frame should render in the
/// window-root fallback (i.e. NOT in a terminal-pane `.overlay`).
/// Item frames are window-root when their terminal is not currently
/// visible (closed, in History pane, single-pane mode, etc.).
/// File frames and nil-terminal frames always use the window-root.
private func overlayFrameIsWindowRoot(
    _ frame: OverlayFrame,
    visibleTerminalIDs: Set<UUID>
) -> Bool {
    if case .item(let f) = frame {
        return f.terminalID.map { !visibleTerminalIDs.contains($0) } ?? true
    }
    return true
}

// MARK: - PRButtonLabel

private struct PRButtonLabel: View {
    let prStatus: PRStatus
    let isAutoArchiveArmed: Bool
    // Re-bake the colored icon when the appearance flips (the baked image is
    // non-template, so it can't auto-adapt the way a tinted template would).
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 3) {
            if let presentation = PRStatusPresentation.make(for: prStatus),
               let nsImage = coloredIcon(presentation.iconName, nsColor: presentation.nsColor) {
                Image(nsImage: nsImage)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
            }
            Text(verbatim: "#\(prStatus.number)")
                .font(.caption)
                .fontWeight(.medium)
            if isAutoArchiveArmed {
                // At-a-glance indicator that auto-archive-on-merge is armed for
                // this worktree. A toolbar Menu label renders SF Symbols
                // monochrome (AppKit tints them) — that's fine and desirable
                // here, so a plain template Image needs no baked color.
                Image(systemName: "archivebox")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 11, height: 11)
                    .help("Auto-archive on PR merge is on")
                    .accessibilityLabel("Auto-archive on PR merge is on")
            }
        }
    }

    /// Bakes the status color into a NON-template image. Toolbar `Menu` /
    /// split-button labels render template images monochrome (AppKit tints
    /// them with the control color and ignores `.foregroundStyle`), so the
    /// icon must carry its own color and be drawn with `.renderingMode(.original)`.
    private func coloredIcon(_ name: String, nsColor: NSColor) -> NSImage? {
        _ = colorScheme  // establish a dependency so we re-bake on light/dark change
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Icons"),
              let base = NSImage(contentsOf: url) else { return nil }
        base.isTemplate = true
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            nsColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        img.isTemplate = false
        return img
    }
}

// MARK: - ContentHeightKey

private struct ContentHeightKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 600
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - FilePanelDivider

/// A draggable 1pt divider that resizes the file panel.
/// Uses an 8pt hit target (invisible) centered over the visible line.
private struct FilePanelDivider: View {
    @Binding var panelWidth: CGFloat
    let minWidth: CGFloat = 180
    let maxWidth: CGFloat = 700
    @State private var dragStartWidth: CGFloat = 0

    var body: some View {
        Color.clear
            .frame(width: 8)
            .overlay(Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1))
            .cursor(.resizeLeftRight)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartWidth == 0 { dragStartWidth = panelWidth }
                        // Dragging left → wider panel, dragging right → narrower
                        let proposed = dragStartWidth - value.translation.width
                        panelWidth = max(minWidth, min(maxWidth, proposed))
                    }
                    .onEnded { _ in dragStartWidth = 0 }
            )
    }
}
