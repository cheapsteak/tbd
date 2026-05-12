import AppKit
import SwiftUI
import TBDShared
import UniformTypeIdentifiers

/// Transferable payload identifying a tab during drag/drop. App-only — never crosses the wire.
struct TabDragPayload: Codable, Transferable {
    let tabID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .tbdTabDrag)
    }
}

extension UTType {
    static let tbdTabDrag = UTType(exportedAs: "com.tbd.app.tab-drag")
}

private struct TabWidthPreference: PreferenceKey {
    static let defaultValue: CGFloat = 100
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// DropDelegate so we can read `info.location` during hover via `dropUpdated`,
/// which is the only API path that gives us cursor position before drop time.
/// Drives the leading/trailing insertion indicator on the targeted tab.
private struct TabDropDelegate: DropDelegate {
    let targetTabID: UUID
    let worktreeID: UUID
    let measuredWidth: CGFloat
    @Binding var dropEdge: DropEdge?
    let appState: AppState

    private func edge(for location: CGPoint) -> DropEdge {
        location.x < measuredWidth / 2 ? .leading : .trailing
    }

    func dropEntered(info: DropInfo) {
        dropEdge = edge(for: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropEdge = edge(for: info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        dropEdge = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let dropEdgeValue = edge(for: info.location)
        let providers = info.itemProviders(for: [UTType.tbdTabDrag])
        guard let provider = providers.first else {
            dropEdge = nil
            appState.draggingTabID = nil
            return false
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.tbdTabDrag.identifier) { data, _ in
            Task { @MainActor in
                defer {
                    dropEdge = nil
                    appState.draggingTabID = nil
                }
                guard let data,
                      let payload = try? JSONDecoder().decode(TabDragPayload.self, from: data),
                      payload.tabID != targetTabID else { return }
                appState.reorderTab(
                    draggedID: payload.tabID,
                    in: worktreeID,
                    relativeTo: targetTabID,
                    edge: dropEdgeValue
                )
            }
        }
        return true
    }
}

// MARK: - TabBar

/// Generic tab bar that renders Tab items with type-appropriate icons and labels.
/// Replaces the former TerminalTabBar.
struct TabBar: View {
    let tabs: [Tab]
    let worktreeID: UUID
    @EnvironmentObject private var appState: AppState
    @Binding var activeTabIndex: Int
    var onAddShell: () -> Void = {}
    var onAddClaude: () -> Void = {}
    var onAddCodex: () -> Void = {}
    var onAddNote: () -> Void = {}
    var onCloseTab: (Int) -> Void
    var terminalForTab: (UUID) -> Terminal? = { _ in nil }
    var onSuspendTab: (UUID) -> Void = { _ in }
    var onResumeTab: (UUID) -> Void = { _ in }
    var onForkTab: (UUID) -> Void = { _ in }
    var isHistorySelected: Bool = false
    var onHistoryTab: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0 {
                    // Subtle vertical divider between tabs (iTerm2-style)
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1, height: 18)
                }

                TabBarItem(
                    tab: tab,
                    index: index,
                    worktreeID: worktreeID,
                    isSelected: index == activeTabIndex,
                    terminal: terminalForTab(tab.id),
                    onSelect: { activeTabIndex = index },
                    onClose: { onCloseTab(index) },
                    onSuspend: { onSuspendTab(tab.id) },
                    onResume: { onResumeTab(tab.id) },
                    onFork: { onForkTab(tab.id) }
                )
            }

            // Divider before + button
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1, height: 18)

            AddTabButton(
                onAddShell: onAddShell,
                onAddClaude: onAddClaude,
                onAddCodex: onAddCodex,
                onAddNote: onAddNote
            )
            Spacer()

            HistoryTabButton(
                isSelected: isHistorySelected,
                action: onHistoryTab
            )
        }
        .padding(.horizontal, 0)
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor))
        // Catch-all so dropping a tab on the +/history button or empty
        // strip space still clears `draggingTabID`. Returns false (no
        // reorder), but ends the visual "dragging" state. Per-tab drop
        // delegates above handle real reorders.
        .onDrop(of: [UTType.tbdTabDrag], isTargeted: nil) { _ in
            appState.draggingTabID = nil
            return false
        }
    }
}

// MARK: - AddTabButton

/// Plain Button that shows an NSMenu on click. SwiftUI's Menu + borderlessButton
/// swallows hover events, making custom hover styling impossible. Using NSMenu
/// directly sidesteps this entirely.
private struct AddTabButton: View {
    let onAddShell: () -> Void
    let onAddClaude: () -> Void
    let onAddCodex: () -> Void
    let onAddNote: () -> Void
    @State private var isHovering = false

    var body: some View {
        Image(systemName: "plus")
            .font(.caption)
            .foregroundStyle(isHovering ? .primary : .secondary)
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .padding(6)
            .contentShape(Rectangle())
            .onHover { hovering in isHovering = hovering }
            .onTapGesture { showMenu() }
            .help("New Tab")
    }

    private func showMenu() {
        let menu = NSMenu()

        let shellItem = NSMenuItem(title: "Shell", action: nil, keyEquivalent: "")
        shellItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        menu.addItem(shellItem)

        let claudeItem = NSMenuItem(title: "Claude", action: nil, keyEquivalent: "")
        let claudeLabel = NSAttributedString(string: "✳", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let claudeLabelSize = claudeLabel.size()
        let claudeImage = NSImage(size: claudeLabelSize)
        claudeImage.lockFocus()
        claudeLabel.draw(at: .zero)
        claudeImage.unlockFocus()
        claudeImage.isTemplate = true
        claudeItem.image = claudeImage
        menu.addItem(claudeItem)

        let codexItem = NSMenuItem(title: "Codex", action: nil, keyEquivalent: "")
        codexItem.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
        menu.addItem(codexItem)

        menu.addItem(.separator())

        let noteItem = NSMenuItem(title: "Note", action: nil, keyEquivalent: "")
        noteItem.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)
        menu.addItem(noteItem)

        // Use a coordinator to handle menu item actions via closures
        let coordinator = MenuCoordinator(
            onShell: onAddShell, onClaude: onAddClaude, onCodex: onAddCodex, onNote: onAddNote
        )
        shellItem.target = coordinator
        shellItem.action = #selector(MenuCoordinator.addShell)
        claudeItem.target = coordinator
        claudeItem.action = #selector(MenuCoordinator.addClaude)
        codexItem.target = coordinator
        codexItem.action = #selector(MenuCoordinator.addCodex)
        noteItem.target = coordinator
        noteItem.action = #selector(MenuCoordinator.addNote)

        // Keep coordinator alive for the duration of the menu
        objc_setAssociatedObject(menu, "coordinator", coordinator, .OBJC_ASSOCIATION_RETAIN)

        let location = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: location, in: nil)
    }

}

private class MenuCoordinator: NSObject {
    let onShell: () -> Void
    let onClaude: () -> Void
    let onCodex: () -> Void
    let onNote: () -> Void

    init(onShell: @escaping () -> Void, onClaude: @escaping () -> Void, onCodex: @escaping () -> Void, onNote: @escaping () -> Void) {
        self.onShell = onShell
        self.onClaude = onClaude
        self.onCodex = onCodex
        self.onNote = onNote
    }

    @objc func addShell() { onShell() }
    @objc func addClaude() { onClaude() }
    @objc func addCodex() { onCodex() }
    @objc func addNote() { onNote() }
}

// MARK: - TabBarItem

private struct TabBarItem: View {
    let tab: Tab
    let index: Int
    let worktreeID: UUID
    let isSelected: Bool
    let terminal: Terminal?
    let onSelect: () -> Void
    let onClose: () -> Void
    let onSuspend: () -> Void
    let onResume: () -> Void
    let onFork: () -> Void

    @State private var isHovering = false
    @State private var isHoveringClose = false
    @State private var isEditing: Bool = false
    @State private var dropEdge: DropEdge? = nil
    @State private var measuredWidth: CGFloat = 100
    @AppStorage("codeViewer.showSidebar") private var showSidebar = false
    @EnvironmentObject private var appState: AppState

    private var showClose: Bool {
        isSelected || isHovering
    }

    private var isCodeViewer: Bool {
        if case .codeViewer = tab.content { return true }
        return false
    }

    private var isRenameable: Bool {
        if case .codeViewer = tab.content { return false }
        return true
    }

    private var isClaudeTerminal: Bool {
        terminal?.claudeSessionID != nil
    }

    private var isCodexTerminal: Bool {
        terminal?.label == "Codex"
    }

    private var isSuspended: Bool {
        terminal?.suspendedAt != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            // Clickable tab content area
            Button(action: onSelect) {
                HStack(spacing: 0) {
                    // Sidebar toggle for code viewer tabs
                    if isCodeViewer {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 10))
                            .foregroundStyle(showSidebar ? .primary : .tertiary)
                            .frame(width: 16, height: 16)
                            .padding(.trailing, 2)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    showSidebar.toggle()
                                }
                            }
                    }

                    // Type icon
                    tabIconView
                        .frame(width: 14)
                        .padding(.trailing, 3)

                    if isEditing {
                        RenameableLabel(
                            text: tabLabel,
                            isEditing: $isEditing,
                            onCommit: { newText in
                                appState.renameTab(
                                    tabID: tab.id,
                                    worktreeID: worktreeID,
                                    newLabel: newText
                                )
                            },
                            editorFont: .systemFont(ofSize: 11),
                            selectAllOnEnterEditing: true,
                            allowsEmptyCommit: true,
                            displayContent: {
                                Text(tabLabel)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .foregroundStyle(isSuspended ? .tertiary : (isSelected ? .primary : .secondary))
                            }
                        )
                        .font(.system(size: 11))
                        .frame(width: max(60, measuredWidth - 50))
                    } else {
                        Text(tabLabel)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(isSuspended ? .tertiary : (isSelected ? .primary : .secondary))
                    }
                }
            }
            .buttonStyle(.plain)

            // Close button — right side
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isHoveringClose ? .primary : .secondary)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(isHoveringClose ? 0.08 : 0))
                    )
                    .onHover { hovering in
                        isHoveringClose = hovering
                    }
            }
            .buttonStyle(.plain)
            .padding(.leading, 2)
            .padding(.trailing, 2)
            .opacity(showClose ? 1 : 0)
            .animation(.easeInOut(duration: 0.12), value: showClose)
        }
        .padding(.leading, 8)
        .frame(minHeight: 28)
        .background(
            isSelected
                ? Color(nsColor: .controlBackgroundColor)
                : (isHovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: TabWidthPreference.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(TabWidthPreference.self) { measuredWidth = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovering)
        .contextMenu { contextMenuContent }
        .onHover { hovering in
            isHovering = hovering
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard isRenameable else { return }
                if !isSelected { onSelect() }
                isEditing = true
            }
        )
        .opacity(appState.draggingTabID == tab.id ? 0.4 : 1)
        .overlay(alignment: dropEdge == .leading ? .leading : .trailing) {
            if dropEdge != nil {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .padding(.vertical, 2)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.1), value: dropEdge)
        .draggable(TabDragPayload(tabID: tab.id)) {
            // Drag preview: a translucent copy of the tab content.
            HStack(spacing: 0) {
                tabIconView.frame(width: 14).padding(.trailing, 3)
                Text(tabLabel).font(.system(size: 11)).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(4)
            .opacity(0.85)
            .onAppear { appState.draggingTabID = tab.id }
            // Drag preview is dismissed on any drag end — drop, drop-outside-window,
            // Escape, drop on a non-target. Covers cancel paths that neither the
            // per-tab delegate nor the outer catch-all see.
            .onDisappear { appState.draggingTabID = nil }
        }
        // Use onDrop+DropDelegate (instead of .dropDestination) so we get
        // info.location during hover via dropUpdated, which is required to
        // render the leading/trailing insertion indicator before drop time.
        .onDrop(
            of: [UTType.tbdTabDrag],
            delegate: TabDropDelegate(
                targetTabID: tab.id,
                worktreeID: worktreeID,
                measuredWidth: measuredWidth,
                dropEdge: $dropEdge,
                appState: appState
            )
        )
    }

    private func formatProfileHeader(_ profileID: UUID?) -> String {
        guard let profileID else { return "Profile: Default (logged in)" }
        guard let entry = appState.modelProfiles.first(where: { $0.profile.id == profileID }) else {
            return "Profile: (missing)"
        }
        return "Profile: \(entry.profile.name)"
    }

    private func formatProfileSubmenuLabel(_ entry: ModelProfileWithUsage) -> String {
        entry.profile.name
    }

    /// Absolute path on disk for tab content that has a backing file
    /// (codeViewer points at the file directly; liveTranscript points at
    /// the resolved Claude session JSONL via the underlying terminal).
    private var copyablePath: String? {
        switch tab.content {
        case .codeViewer(_, let path):
            return path.isEmpty ? nil : path
        case .liveTranscript(_, let terminalID):
            let allTerminals = appState.terminals.values.flatMap { $0 }
            return allTerminals.first { $0.id == terminalID }?.transcriptPath
        default:
            return nil
        }
    }

    private var copyPathLabel: String {
        if case .liveTranscript = tab.content { return "Copy Conversation Path" }
        return "Copy Path"
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if let path = copyablePath {
            Button(copyPathLabel) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
            Divider()
        }

        if isClaudeTerminal {
            Button(formatProfileHeader(terminal?.profileID)) {}
                .disabled(true)

            Menu("Swap profile") {
                Button {
                    guard let terminalID = terminal?.id else { return }
                    Task { await appState.swapTerminalProfile(terminalID: terminalID, newProfileID: nil) }
                } label: {
                    let prefix = terminal?.profileID == nil ? "● " : "  "
                    Text("\(prefix)Default (logged in)")
                }

                Divider()

                ForEach(appState.modelProfiles, id: \.profile.id) { entry in
                    Button {
                        guard let terminalID = terminal?.id else { return }
                        Task { await appState.swapTerminalProfile(terminalID: terminalID, newProfileID: entry.profile.id) }
                    } label: {
                        let prefix = terminal?.profileID == entry.profile.id ? "● " : "  "
                        Text("\(prefix)\(formatProfileSubmenuLabel(entry))")
                    }
                }
            }

            Divider()

            Button(action: onFork) {
                Label("Fork Session", systemImage: "arrow.triangle.branch")
            }

            Button(action: isSuspended ? onResume : onSuspend) {
                Label(
                    isSuspended ? "Resume Claude" : "Suspend Claude",
                    systemImage: isSuspended ? "play.circle" : "pause.circle"
                )
            }

            Divider()
        }

        if isRenameable {
            Button("Rename Tab") {
                if !isSelected { onSelect() }
                isEditing = true
            }
            Divider()
        }

        Button(action: onClose) {
            Label("Close Tab", systemImage: "xmark")
        }
    }

    @ViewBuilder
    private var tabIconView: some View {
        let style = isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
        switch tab.content {
        case .terminal:
            if isSuspended {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 10))
                    .foregroundStyle(style)
            } else if isClaudeTerminal {
                Text("✳")
                    .font(.system(size: 10))
                    .foregroundStyle(style)
            } else if isCodexTerminal {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(style)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(style)
            }
        case .webview:
            Image(systemName: "globe")
                .font(.system(size: 10))
                .foregroundStyle(style)
        case .codeViewer:
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(style)
        case .note:
            Image(systemName: "note.text")
                .font(.system(size: 10))
                .foregroundStyle(style)
        case .liveTranscript:
            Image(systemName: "text.bubble")
                .font(.system(size: 10))
                .foregroundStyle(style)
        }
    }

    private var tabLabel: String {
        if let label = tab.label, !label.isEmpty {
            return label
        }
        switch tab.content {
        case .terminal:
            if isClaudeTerminal, let terminal, let profileID = terminal.profileID,
               let entry = appState.modelProfiles.first(where: { $0.profile.id == profileID }) {
                let name = entry.profile.name
                let worktreeID = terminal.worktreeID
                let allTabs = appState.tabs[worktreeID] ?? []
                let allTerminals = appState.terminals[worktreeID] ?? []
                let sameTokenTerminalIDs = Set(
                    allTerminals
                        .filter { $0.profileID == profileID }
                        .map { $0.id }
                )
                let sameTokenTabs = allTabs.filter { tab in
                    if case .terminal(let tID) = tab.content {
                        return sameTokenTerminalIDs.contains(tID)
                    }
                    return false
                }
                let myTerminalID = terminal.id
                let position = (sameTokenTabs.firstIndex { tab in
                    if case .terminal(let tID) = tab.content { return tID == myTerminalID }
                    return false
                } ?? 0) + 1
                return "\(name) \(position)"
            }
            return isClaudeTerminal ? "Claude" : "Terminal \(index + 1)"
        case .webview(_, let url):
            return url.host ?? "Web"
        case .codeViewer(_, let path):
            return URL(fileURLWithPath: path).lastPathComponent
        case .note(let noteID):
            let allNotes = appState.notes.values.flatMap { $0 }
            if let title = allNotes.first(where: { $0.id == noteID })?.title, !title.isEmpty {
                return title
            }
            return "Note \(index + 1)"
        case .liveTranscript:
            return "Transcript"
        }
    }
}

// MARK: - HistoryTabButton

private struct HistoryTabButton: View {
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10))
                .foregroundStyle(
                    isSelected
                        ? AnyShapeStyle(.primary)
                        : AnyShapeStyle(isHovering ? .secondary : .tertiary)
                )
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.primary.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Session History")
    }
}

