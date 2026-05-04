import AppKit
import SwiftUI
import TBDShared

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("filePanel.isVisible") private var showFilePanel = true
    @AppStorage("filePanel.width") private var filePanelWidth: Double = 280
    @AppStorage("autoSuspendClaude") private var autoSuspendClaude: Bool = true
    @State private var conductorHotkeyMonitor = ConductorHotkeyMonitor()
    @State private var contentAreaHeight: CGFloat = 600
    /// Saved first responder to restore when conductor hides.
    @State private var previousFirstResponder: NSResponder?

    private var selectedWorktree: Worktree? {
        guard let id = appState.selectedWorktreeIDs.first else { return nil }
        return appState.worktrees.values.flatMap { $0 }.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
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
                    .overlay(alignment: .top) {
                        if let terminal = appState.currentConductorTerminal {
                            ConductorOverlayView(
                                terminal: terminal,
                                tmuxServer: TBDConstants.conductorsTmuxServer,
                                parentHeight: contentAreaHeight
                            )
                            .opacity(appState.showConductor ? 1 : 0)
                            .allowsHitTesting(appState.showConductor)
                        }
                    }
                }
            }
            .navigationSplitViewStyle(.prominentDetail)
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

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        autoSuspendClaude.toggle()
                    } label: {
                        Image(systemName: autoSuspendClaude ? "pause.circle.fill" : "pause.circle")
                            .foregroundStyle(autoSuspendClaude ? .primary : .secondary)
                    }
                    .accessibilityLabel(autoSuspendClaude ? "Auto-suspend on" : "Auto-suspend off")
                    .help(autoSuspendClaude
                        ? "Auto-suspend is on — idle Claude instances are suspended when switching worktrees"
                        : "Auto-suspend is off — Claude instances stay running when switching worktrees")

                    // Conductor toggle
                    Button {
                        toggleConductor()
                    } label: {
                        Image(systemName: appState.conductorActive
                            ? (appState.showConductor ? "wand.and.stars" : "wand.and.stars.inverse")
                            : "wand.and.stars.inverse")
                            .foregroundStyle(appState.showConductor ? .primary : .secondary)
                    }
                    .help(appState.conductorActive
                        ? (appState.showConductor ? "Hide conductor (\u{2325}')" : "Show conductor (\u{2325}')")
                        : "Start conductor (\u{2325}')")
                    .contextMenu {
                        if appState.conductorActive, let conductor = appState.currentConductor {
                            Button("Stop Conductor") {
                                Task {
                                    try? await appState.daemonClient.conductorStop(name: conductor.name)
                                    appState.showConductor = false
                                    await appState.refreshConductors()
                                }
                            }
                            Button("Remove Conductor", role: .destructive) {
                                Task {
                                    try? await appState.daemonClient.conductorTeardown(name: conductor.name)
                                    appState.showConductor = false
                                    await appState.refreshConductors()
                                }
                            }
                        }
                    }

                    Picker("Filter", selection: $appState.repoFilter) {
                        Text("All Repos").tag(UUID?.none)
                        Divider()
                        ForEach(appState.repos) { repo in
                            Text(repo.displayName).tag(UUID?.some(repo.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .help("Filter sidebar by repository")

                    if let worktreeID = appState.selectedWorktreeIDs.first,
                       appState.selectedWorktreeIDs.count == 1,
                       let prStatus = appState.prStatuses[worktreeID],
                       let prURL = URL(string: prStatus.url) {
                        Button {
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
                        } label: {
                            PRButtonLabel(prStatus: prStatus)
                        }
                        .help("Open PR in browser pane")
                    }

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
        .onChange(of: appState.selectedWorktreeIDs) { oldSelection, newSelection in
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
            conductorHotkeyMonitor.install { [weak appState] in
                guard appState != nil else { return }
                toggleConductor()
            }
        }
    }

    // MARK: - Conductor

    private func toggleConductor() {
        if appState.conductorActive {
            if appState.showConductor {
                // Hiding — restore previous focus
                appState.showConductor = false
                if let prev = previousFirstResponder {
                    NSApp.keyWindow?.makeFirstResponder(prev)
                    previousFirstResponder = nil
                }
            } else {
                // Showing — save current focus
                previousFirstResponder = NSApp.keyWindow?.firstResponder
                appState.showConductor = true
            }
        } else {
            Task { await appState.ensureConductorRunning() }
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
            appState.notifications[worktreeID] = nil
            Task {
                await appState.markNotificationsRead(worktreeID: worktreeID)
            }
        }
    }
}

// MARK: - PRButtonLabel

private struct PRButtonLabel: View {
    let prStatus: PRStatus

    private var iconName: String {
        switch prStatus.state {
        case .open, .changesRequested, .mergeable: return "git-pull-request"
        case .merged:                              return "git-merge"
        case .closed:                              return "git-pull-request-closed"
        }
    }

    private var iconColor: Color {
        switch prStatus.state {
        case .open:             return .secondary
        case .changesRequested: return .red
        case .mergeable:        return .green
        case .merged:           return .purple
        case .closed:           return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            if let nsImage = loadIcon(iconName) {
                Image(nsImage: nsImage)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(iconColor)
            }
            Text("#\(prStatus.number)")
                .font(.caption)
                .fontWeight(.medium)
        }
    }

    private func loadIcon(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
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
