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
    let tabs: [TBDShared.Tab]
    let worktreeID: UUID
    @EnvironmentObject private var appState: AppState
    @Binding var activeTabIndex: Int
    var onAddShell: () -> Void = {}
    var onAddClaude: () -> Void = {}
    var onAddClaudeProfile: (UUID) -> Void = { _ in }
    var onChooseAccount: () -> Void = {}
    var onAddCodex: () -> Void = {}
    var onAddNote: () -> Void = {}
    var onCloseTab: (Int) -> Void
    var terminalForTab: (UUID) -> Terminal? = { _ in nil }
    // Park (formerly suspend/resume) is a row-level action now; fork moved to
    // the profile-picker "Fork Session" menu (#361). No tab-level closures.
    var isHistorySelected: Bool = false
    var onHistoryTab: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                TabBarItem(
                    tab: tab,
                    index: index,
                    worktreeID: worktreeID,
                    isSelected: index == activeTabIndex,
                    terminal: terminalForTab(tab.id),
                    onSelect: { activeTabIndex = index },
                    onClose: { onCloseTab(index) }
                )
            }

            AddTabButton(
                profiles: appState.modelProfiles,
                onAddShell: onAddShell,
                onAddClaude: onAddClaude,
                onAddClaudeProfile: onAddClaudeProfile,
                onChooseAccount: onChooseAccount,
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
    let profiles: [ModelProfileWithUsage]
    let onAddShell: () -> Void
    let onAddClaude: () -> Void
    let onAddClaudeProfile: (UUID) -> Void
    let onChooseAccount: () -> Void
    let onAddCodex: () -> Void
    let onAddNote: () -> Void
    @State private var isHovering = false
    @State private var availability = AgentExecutableAvailability.detect()

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
            .task {
                availability = AgentExecutableAvailability.detect()
            }
    }

    private func showMenu() {
        availability = AgentExecutableAvailability.detect()
        let coordinator = MenuCoordinator(
            onShell: onAddShell,
            onClaude: onAddClaude,
            onClaudeProfile: onAddClaudeProfile,
            onChooseAccount: onChooseAccount,
            onCodex: onAddCodex,
            onNote: onAddNote
        )
        let menu = AddTabMenu.build(
            profiles: profiles,
            availability: availability,
            coordinator: coordinator
        )

        // Keep coordinator alive for the duration of the menu.
        objc_setAssociatedObject(menu, "coordinator", coordinator, .OBJC_ASSOCIATION_RETAIN)

        let location = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: location, in: nil)
    }
}

struct AgentExecutableAvailability: Equatable {
    var claude: Bool
    var codex: Bool

    static let allAvailable = AgentExecutableAvailability(claude: true, codex: true)

    static func detect(
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        homeDir: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> AgentExecutableAvailability {
        AgentExecutableAvailability(
            claude: isExecutableOnPath("claude", path: path, homeDir: homeDir, fileManager: fileManager),
            codex: isExecutableOnPath("codex", path: path, homeDir: homeDir, fileManager: fileManager)
        )
    }

    private static func isExecutableOnPath(
        _ executable: String,
        path: String?,
        homeDir: String,
        fileManager: FileManager
    ) -> Bool {
        if executable.contains("/") {
            return fileManager.isExecutableFile(atPath: executable)
        }

        let pathDirs = (path ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        let fallbackDirs = [
            "\(homeDir)/.local/bin",
            "\(homeDir)/.volta/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]

        var seen = Set<String>()
        for dir in pathDirs + fallbackDirs {
            guard seen.insert(dir).inserted else { continue }
            let candidate = (dir as NSString).appendingPathComponent(executable)
            if fileManager.isExecutableFile(atPath: candidate) {
                return true
            }
        }
        return false
    }
}

/// Routes "+" menu clicks from AppKit's target/selector world into SwiftUI
/// closures. Internal (not private) so AddTabMenu and the unit tests can use it.
final class MenuCoordinator: NSObject {
    let onShell: () -> Void
    let onClaude: () -> Void
    let onClaudeProfile: (UUID) -> Void
    let onChooseAccount: () -> Void
    let onCodex: () -> Void
    let onNote: () -> Void

    init(
        onShell: @escaping () -> Void,
        onClaude: @escaping () -> Void,
        onClaudeProfile: @escaping (UUID) -> Void,
        onChooseAccount: @escaping () -> Void = {},
        onCodex: @escaping () -> Void,
        onNote: @escaping () -> Void
    ) {
        self.onShell = onShell
        self.onClaude = onClaude
        self.onClaudeProfile = onClaudeProfile
        self.onChooseAccount = onChooseAccount
        self.onCodex = onCodex
        self.onNote = onNote
    }

    @objc func addShell() { onShell() }
    @objc func addClaude() { onClaude() }
    @objc func chooseAccount() { onChooseAccount() }
    @objc func addCodex() { onCodex() }
    @objc func addNote() { onNote() }

    /// Profile menu items carry their `ModelProfile.id` in `representedObject`.
    /// A nil representedObject (should not happen for profile items) is a no-op.
    @objc func addClaudeProfile(_ sender: NSMenuItem) {
        guard let profileID = sender.representedObject as? UUID else { return }
        onClaudeProfile(profileID)
    }
}

// MARK: - AddTabMenu

/// Pure builder for the "+" new-tab NSMenu. Extracted from AddTabButton so the
/// menu structure (especially the nested Claude profile items) can be
/// unit-tested without popping up UI.
enum AddTabMenu {
    /// Builds the new-tab menu. Profile items are inserted, indented, directly
    /// below the "Claude" item — clicking one starts a Claude session pinned to
    /// that profile. With an empty `profiles` list, no profile items appear and
    /// the menu is identical to the pre-feature menu.
    static func build(
        profiles: [ModelProfileWithUsage],
        availability: AgentExecutableAvailability = .allAvailable,
        coordinator: MenuCoordinator
    ) -> NSMenu {
        let menu = NSMenu()

        let shellItem = NSMenuItem(
            title: "Shell", action: #selector(MenuCoordinator.addShell), keyEquivalent: ""
        )
        shellItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        shellItem.target = coordinator
        menu.addItem(shellItem)

        if availability.claude {
            let claudeIcon = claudeAsteriskImage()
            let claudeItem = NSMenuItem(
                title: "Claude", action: #selector(MenuCoordinator.addClaude), keyEquivalent: ""
            )
            claudeItem.image = claudeIcon
            claudeItem.target = coordinator
            menu.addItem(claudeItem)

            // One item per profile. The primary line is the profile's display
            // name plus a short login-identity suffix (" — email" / " — needs
            // /login" for oauth profiles); when the daemon has a usage snapshot,
            // a smaller, indented secondary line underneath spells out the
            // usage ("5h 0% · resets 23:10 · wk 76% · Fable 100%"). Each gets a
            // transparent placeholder icon the same size as the Claude asterisk
            // so its title lines up in the same title column as "Claude" — the
            // empty icon slot is the visual nesting cue. The profile id rides
            // along in `representedObject` for MenuCoordinator.addClaudeProfile.
            for entry in profiles {
                let line = ProfileUsagePresentation.menuLine(for: entry)
                let item = NSMenuItem(
                    title: line.primary,
                    action: #selector(MenuCoordinator.addClaudeProfile(_:)),
                    keyEquivalent: ""
                )
                if let attributed = twoLineAttributedTitle(line) {
                    item.attributedTitle = attributed
                    // Setting attributedTitle syncs `title` to its flattened
                    // string; restore the identity-only plain title (used by
                    // accessibility and any title-based lookups).
                    item.title = line.primary
                }
                item.image = blankIcon(size: claudeIcon.size)
                item.representedObject = entry.profile.id
                item.target = coordinator
                menu.addItem(item)
            }

            // Full account picker dialog — richer data (bars, reset times,
            // staleness) than the compact suffixes above can carry.
            let chooseItem = NSMenuItem(
                title: "Choose account…",
                action: #selector(MenuCoordinator.chooseAccount),
                keyEquivalent: ""
            )
            chooseItem.image = blankIcon(size: claudeIcon.size)
            chooseItem.target = coordinator
            menu.addItem(chooseItem)
        }

        if availability.codex {
            let codexItem = NSMenuItem(
                title: "Codex", action: #selector(MenuCoordinator.addCodex), keyEquivalent: ""
            )
            codexItem.image = NSImage(
                systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil
            )
            codexItem.target = coordinator
            menu.addItem(codexItem)
        }

        menu.addItem(.separator())

        let noteItem = NSMenuItem(
            title: "Note", action: #selector(MenuCoordinator.addNote), keyEquivalent: ""
        )
        noteItem.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)
        noteItem.target = coordinator
        menu.addItem(noteItem)

        return menu
    }

    /// Renders the ✳ glyph as a template image for the Claude menu item.
    private static func claudeAsteriskImage() -> NSImage {
        let label = NSAttributedString(
            string: "✳", attributes: [.font: NSFont.systemFont(ofSize: 13)]
        )
        let image = NSImage(size: label.size())
        image.lockFocus()
        label.draw(at: .zero)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// A fully-transparent image used as the icon for profile menu items, so
    /// their titles align with the "Claude" item's title (the empty icon slot
    /// is the visual nesting cue). Sized to match `claudeAsteriskImage()`.
    private static func blankIcon(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()   // empty draw pass — produces a transparent representation
        image.unlockFocus()
        return image
    }

    /// An attributed two-line NSMenuItem title — identity at menu size, the
    /// usage line smaller, secondary-colored, and indented underneath. nil when
    /// there is no secondary line, so snapshotless profiles keep the plain
    /// single-line title set at item creation.
    static func twoLineAttributedTitle(
        _ line: ProfileUsagePresentation.MenuLineModel
    ) -> NSAttributedString? {
    guard let secondary = line.secondary, !secondary.isEmpty else { return nil }
    let title = NSMutableAttributedString(
        string: line.primary,
        attributes: [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ]
    )
    let secondaryStyle = NSMutableParagraphStyle()
    secondaryStyle.firstLineHeadIndent = 10
    secondaryStyle.headIndent = 10
    secondaryStyle.paragraphSpacingBefore = 1
    title.append(NSAttributedString(
        string: "\n\(secondary)",
        attributes: [
            .font: NSFont.menuFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: secondaryStyle,
        ]
    ))
        return title
    }
}

// MARK: - Swap-profile menu composition

/// Testable composition for the tab's swap-profile submenus ("Swap profile" /
/// "Fork Session"), following the `AddTabMenu` pattern: pure helpers here, the
/// SwiftUI lowering in `TabBarItem.swapProfileMenuItems(mode:)`.
enum SwapProfileMenu {
    /// Footer caption for the in-place "Swap profile" submenu when the session
    /// is mid-run: the swap resumes in place, so it interrupts the current run.
    static let interruptsRunCaption =
        "Resumes in this tab on the new account — interrupts current run"

    /// The warning caption to append to a swap-profile submenu, or nil when no
    /// warning is needed. Only an `.inPlace` swap of a mid-run session
    /// (`activityState == .working`) warns — `.fork` duplicates into a new tab
    /// and leaves the source session untouched, so it never does.
    static func busyCaption(mode: TerminalSwapMode,
                            activityState: TerminalActivityState?) -> String? {
        guard mode == .inPlace, activityState == .working else { return nil }
        return interruptsRunCaption
    }

    /// Formats a swap-profile menu item label with compact usage stats appended.
    /// Examples: "Gmail", "Gmail — 5h 40% · wk 16%", "Gmail — no data".
    /// The usage suffix is sourced from the same per-profile snapshots the
    /// hover cards and account picker use.
    static func menuLabel(
        for profile: ModelProfile,
        usage: ProfileUsageSnapshot?
    ) -> String {
        let baseName = profile.name
        guard let snapshot = usage, !snapshot.buckets.isEmpty else {
            return baseName
        }
        guard let summary = ProfileUsagePresentation.usageSummary(for: snapshot) else {
            return baseName
        }
        return "\(baseName) — \(summary)"
    }
}

// MARK: - TabParkMenuModel

/// Pure decision behind the tab context menu's per-terminal park affordance:
/// which of Hibernate / Wake (if either) the menu should offer for a tab's
/// terminal. The two states are mutually exclusive by definition —
/// `isManuallyHibernatable` requires the terminal NOT be parked — so at most
/// one item ever shows. Extracted from the view so each branch is
/// unit-testable without SwiftUI (same pattern as `RowActionMenu`).
enum TabParkMenuModel {
    enum ParkAction: Equatable {
        /// Terminal is live and manually hibernatable → offer "Hibernate".
        case hibernate
        /// Terminal is parked (hibernated or legacy-suspended) → offer "Wake".
        case wake
    }

    /// nil = show neither item (no terminal, non-Claude terminal, or a Claude
    /// session that is mid-turn / waiting on a permission prompt).
    static func action(for terminal: Terminal?) -> ParkAction? {
        guard let terminal else { return nil }
        if terminal.isManuallyHibernatable { return .hibernate }
        if terminal.isParked { return .wake }
        return nil
    }
}

// MARK: - TabBarItem

private struct TabBarItem: View {
    let tab: TBDShared.Tab
    let index: Int
    let worktreeID: UUID
    let isSelected: Bool
    let terminal: Terminal?
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false
    @State private var isHoveringClose = false
    @State private var isEditing: Bool = false
    @State private var dropEdge: DropEdge? = nil
    @State private var measuredWidth: CGFloat = 100
    @AppStorage("codeViewer.showSidebar") private var showSidebar = false
    @AppStorage(AppState.showClaudeTabUsageTooltipKey)
    private var showClaudeTabUsageTooltip: Bool = true
    @AppStorage(AppState.usageResetTimeStyleKey)
    private var usageResetTimeStyle: ProfileUsagePresentation.ResetTimeStyle = .timeOfReset
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
        terminal?.isClaudeResumable == true
    }

    private var isCodexTerminal: Bool {
        terminal?.isCodexTerminal == true
    }

    /// Whether this tab's session is PARKED — hibernated (authoritative) or
    /// legacy-suspended. Drives the calm moon icon + dimmed label. Suspend
    /// merged into hibernate; the play/pause suspend button was retired.
    private var isParked: Bool {
        terminal?.hibernatedAt != nil || terminal?.suspendedAt != nil
    }

    /// Hover card describing which account this session runs on: pinned
    /// email + profile name (or the ambient-drift note for NULL-profile legacy
    /// sessions), current 5h/weekly usage, and spawn time. nil (no card)
    /// for non-Claude tabs, or when the "Show usage tooltip on Claude tabs"
    /// setting is off.
    private var accountHoverCard: HoverCardModel? {
        guard let terminal else { return nil }
        return AccountHoverCards.claudeTabCard(
            terminal: terminal,
            profiles: appState.modelProfiles,
            resetStyle: usageResetTimeStyle,
            enabled: showClaudeTabUsageTooltip
        )
    }

    /// Bold this tab's label when its terminal fired a `.responseComplete`
    /// while in the background. Never bold the active/selected tab — activating
    /// it clears the unread state, but guard here too so the active tab can
    /// never render bold even for a frame. Mirrors WorktreeRowView's bold.
    private var hasUnreadCompletion: Bool {
        guard !isSelected else { return false }
        let tids = appState.terminalIDs(in: tab)
        return tids.contains { appState.unreadTerminals.contains($0) }
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
                                    .fontWeight(hasUnreadCompletion ? .bold : .regular)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .foregroundStyle(isParked ? .tertiary : (isSelected ? .primary : .secondary))
                            }
                        )
                        .font(.system(size: 11))
                        .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(tabLabel)
                            .font(.system(size: 11))
                            .fontWeight(hasUnreadCompletion ? .bold : .regular)
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(isParked ? .tertiary : (isSelected ? .primary : .secondary))
                    }

                    if terminal?.pendingResumeAt != nil {
                        Text("⏳")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .padding(.leading, 4)
                            .help("Session limit hit — TBD will type \"continue\" at this time. Right-click to cancel.")
                    }
                }
                .padding(.leading, 8)
                .frame(minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
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
        // Stretch to the tab bar's full height (30px) so the bottom-aligned
        // active indicator seats flush against the divider below the strip.
        // Without maxHeight the 28px item center-aligns in the 30px bar,
        // leaving a ~1px sliver under the indicator. Content stays centered,
        // so the label doesn't shift on select/deselect.
        .frame(minHeight: 28, maxHeight: .infinity)
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
        // Active-tab indicator: a bottom lip drawn as an overlay so it never
        // participates in layout — the tab content must not shift on selection.
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 2)
            }
        }
        .onPreferenceChange(TabWidthPreference.self) { measuredWidth = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovering)
        // nil = no card (non-Claude tabs).
        .hoverCard(accountHoverCard)
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
            // Defer the @Published write off SwiftUI's view-graph update pass.
            // Writing it synchronously here re-invalidates the body that owns
            // this preview, causing a runaway re-render loop. The equality
            // guard also keeps a redundant same-value write (the catch-all
            // .onDrop below also clears to nil) from publishing needlessly.
            .onAppear {
                let id = tab.id
                Task { @MainActor in
                    if appState.draggingTabID != id { appState.draggingTabID = id }
                }
            }
            // Drag preview is dismissed on any drag end — drop, drop-outside-window,
            // Escape, drop on a non-target. Covers cancel paths that neither the
            // per-tab delegate nor the outer catch-all see.
            .onDisappear {
                Task { @MainActor in
                    if appState.draggingTabID != nil { appState.draggingTabID = nil }
                }
            }
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
        SwapProfileMenu.menuLabel(for: entry.profile, usage: entry.usageSnapshot)
    }

    @ViewBuilder
    private func swapProfileMenuItems(mode: TerminalSwapMode) -> some View {
        Button {
            guard let terminalID = terminal?.id else { return }
            Task { await appState.swapTerminalProfile(terminalID: terminalID, newProfileID: nil, mode: mode) }
        } label: {
            let prefix = terminal?.profileID == nil ? "● " : "  "
            Text("\(prefix)Default (logged in)")
        }

        Divider()

        ForEach(appState.modelProfiles, id: \.profile.id) { entry in
            Button {
                guard let terminalID = terminal?.id else { return }
                Task { await appState.swapTerminalProfile(terminalID: terminalID, newProfileID: entry.profile.id, mode: mode) }
            } label: {
                let prefix = terminal?.profileID == entry.profile.id ? "● " : "  "
                Text("\(prefix)\(formatProfileSubmenuLabel(entry))")
            }
        }

        // Busy-session safeguard: an in-place swap of a mid-run session
        // interrupts the current run, so warn before the user picks a target.
        if let caption = SwapProfileMenu.busyCaption(
            mode: mode, activityState: terminal?.activityState
        ) {
            Divider()
            Text(caption).font(.caption)
        }
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

    /// The terminal this tab renders, for deep-link anchoring — nil for
    /// non-terminal panes (webview, code viewer, note), whose links fall back
    /// to the worktree alone.
    private var linkTerminalID: UUID? {
        switch tab.content {
        case .terminal(let terminalID): return terminalID
        case .liveTranscript(_, let terminalID): return terminalID
        default: return nil
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if let path = copyablePath {
            Button(copyPathLabel) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }

        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                DeepLink.makeShareableOpenURL(worktreeID, terminalID: linkTerminalID).absoluteString,
                forType: .string
            )
        }
        Divider()

        if isClaudeTerminal {
            Button(formatProfileHeader(terminal?.profileID)) {}
                .disabled(true)

            Menu("Swap profile") {
                swapProfileMenuItems(mode: .inPlace)
            }

            Divider()

            Menu {
                swapProfileMenuItems(mode: .fork)
            } label: {
                Label("Fork Session", systemImage: "arrow.triangle.branch")
            }

            // Park (formerly the Suspend/Resume play/pause button) lives here
            // as per-terminal Hibernate/Wake items — THIS tab's session only,
            // unlike the worktree row's action which sweeps every session in
            // the worktree. A scheduled auto-resume can still be pending on a
            // live session that hit its limit, so keep the cancel affordance
            // here too (#341).
            switch TabParkMenuModel.action(for: terminal) {
            case .hibernate:
                Button {
                    guard let terminalID = terminal?.id else { return }
                    Task { await appState.hibernateTerminal(terminalID: terminalID, worktreeID: worktreeID) }
                } label: {
                    Label("Hibernate", systemImage: "moon.zzz")
                }
            case .wake:
                Button {
                    guard let terminalID = terminal?.id else { return }
                    Task { await appState.wakeParkedTerminalUserInitiated(terminalID: terminalID, worktreeID: worktreeID) }
                } label: {
                    Label("Wake", systemImage: "sun.max")
                }
            case nil:
                EmptyView()
            }

            if terminal?.pendingResumeAt != nil {
                Button {
                    guard let terminalID = terminal?.id else { return }
                    Task { await appState.cancelScheduledResume(terminalID: terminalID) }
                } label: {
                    Label("Cancel Scheduled Resume", systemImage: "clock.badge.xmark")
                }
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
            if isParked {
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
            return AutoTabLabelResolver.terminalLabel(
                terminal: terminal,
                fallbackIndex: index,
                modelProfiles: appState.modelProfiles,
                worktreeTabs: appState.tabs[worktreeID] ?? [],
                worktreeTerminals: appState.terminals[worktreeID] ?? []
            )
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
