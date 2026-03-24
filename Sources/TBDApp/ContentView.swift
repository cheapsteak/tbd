import AppKit
import SwiftUI
import TBDShared

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("filePanel.isVisible") private var showFilePanel = true
    @AppStorage("filePanel.width") private var filePanelWidth: Double = 280

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
                        }
                    }
                }
            }
            .navigationSplitViewStyle(.prominentDetail)
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: addRepo) {
                        Label("Add Repository", systemImage: "plus.rectangle.on.folder")
                    }
                    .help("Add a Git repository")

                    Picker("Filter", selection: $appState.repoFilter) {
                        Text("All Repos").tag(UUID?.none)
                        Divider()
                        ForEach(appState.repos) { repo in
                            Text(repo.displayName).tag(UUID?.some(repo.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .help("Filter sidebar by repository")

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showFilePanel.toggle() }
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .help("Toggle file panel (⌘⇧E)")
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                }
            }

            StatusBarView()
        }
        .onChange(of: appState.selectedWorktreeIDs) { _, newSelection in
            markSelectedWorktreesAsRead(newSelection)
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
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
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
