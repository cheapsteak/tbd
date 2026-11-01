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

// MARK: - TabRowMetrics

/// The tab row's dimensions. The workspace tab bar and the side region's strip
/// share one row across the window, so both take their height from here.
enum TabRowMetrics {
    static let height: CGFloat = 30
}

// MARK: - TabBarTrailingItems

/// What the workspace tab bar draws at its trailing end, in order
/// (`TabBarTrailingItem.items`), with what each button does.
/// `PanelSurfaceWorkspaceView` decides them from the tab, its side region and
/// the worktree's notes: the primary's viewer control and Session History,
/// then, while the side region is hidden and the bar reaches the window's
/// right edge, the transcript and Notes buttons (`TabRowEdgeControls`) and
/// the expand button. A bar drawn anywhere else (Session History open, a tab
/// whose layout still splits off a terminal, no tabs) takes `none`.
struct TabBarTrailingItems {
    /// The items, left to right.
    let items: [TabBarTrailingItem]
    /// What the primary's viewer control does.
    let onViewerControl: @MainActor () -> Void
    /// The transcript and Notes buttons the `.edge` items draw, with their
    /// actions; nil for a bar that has none (`none`).
    let edge: TabRowEdgeControls?
    /// What the expand button does.
    let onExpand: @MainActor () -> Void

    /// The daemon path's items: `viewerControl`, the primary's own control
    /// (`WorkspaceTabBarChrome.viewerControl`), or nil when its kind has
    /// none; Session History; and, while the side region is hidden
    /// (`showsSide` false), `edge`'s buttons and the expand button when
    /// `showsExpandButton` (`PanelSurfaceWorkspaceView.showsExpandButton`).
    init(
        viewerControl: PaneChromeControl?,
        onViewerControl: @escaping @MainActor () -> Void,
        edge: TabRowEdgeControls,
        showsSide: Bool,
        showsExpandButton: Bool,
        onExpand: @escaping @MainActor () -> Void
    ) {
        self.init(
            items: TabBarTrailingItem.items(
                viewerControl: viewerControl,
                edgeItems: edge.items,
                showsSide: showsSide,
                showsExpandButton: showsExpandButton),
            onViewerControl: onViewerControl,
            edge: edge,
            onExpand: onExpand)
    }

    /// Stores what it is given: the daemon path's init above, and `none`,
    /// whose items no input decides.
    private init(
        items: [TabBarTrailingItem],
        onViewerControl: @escaping @MainActor () -> Void,
        edge: TabRowEdgeControls?,
        onExpand: @escaping @MainActor () -> Void
    ) {
        self.items = items
        self.onViewerControl = onViewerControl
        self.edge = edge
        self.onExpand = onExpand
    }

    /// Session History alone: no viewer control, no transcript or Notes
    /// button and no expand button.
    ///
    /// Computed rather than stored: Swift 6 accepts a stored static only of a
    /// `Sendable` type, which a struct of closures is not, and building an
    /// empty value costs nothing.
    static var none: TabBarTrailingItems {
        TabBarTrailingItems(items: [.sessionHistory], onViewerControl: {}, edge: nil, onExpand: {})
    }
}

// MARK: - TabBar

/// Generic tab bar that renders Tab items with type-appropriate icons and labels.
/// Replaces the former TerminalTabBar.
///
/// Reads, left to right: the tabs, the + button, then a trailing group in the
/// order `trailing` gives — the primary's viewer control, Session History,
/// and, while the side region is hidden, the transcript button, the Notes
/// button and the expand button — all but Session History only as `trailing`
/// asks. The trailing group keeps its full width at the row's trailing edge
/// however many tabs there are. While the tabs fit
/// in the width it leaves, the + button sits right after the last one; once
/// they overflow — a narrow primary column on the daemon path, beside a wide
/// side region — they scroll horizontally, and the + button stays in view
/// just after them (`TabsThenAddLayout`). The selected tab is scrolled into
/// view when the bar appears, when the selection changes and when the tab
/// list does, so a tab appended and selected, or one selected by a shortcut
/// or from the sidebar, is never left outside the visible tabs.
struct TabBar: View {
    let tabs: [TBDShared.Tab]
    let worktreeID: UUID
    @Environment(AppState.self) private var appState
    @Binding var activeTabIndex: Int
    var onAddShell: () -> Void = {}
    var onAddClaude: () -> Void = {}
    var onAddClaudeProfile: (UUID) -> Void = { _ in }
    var onChooseAccount: () -> Void = {}
    var onAddCodex: () -> Void = {}
    var onCloseTab: (Int) -> Void
    var terminalForTab: (UUID) -> Terminal? = { _ in nil }
    // Park (formerly suspend/resume) is a row-level action now; fork moved to
    // the profile-picker "Fork Session" menu (#361). No tab-level closures.
    var isHistorySelected: Bool = false
    var onHistoryTab: () -> Void = {}
    /// The trailing group's items, Session History among them, in order.
    var trailing: TabBarTrailingItems = .none

    var body: some View {
        ScrollViewReader { proxy in
            row
                .onAppear { scrollSelectedTabIntoView(proxy) }
                .onChange(of: selectedTabID) { _, _ in scrollSelectedTabIntoView(proxy) }
                .onChange(of: tabs.map(\.id)) { _, _ in scrollSelectedTabIntoView(proxy) }
        }
    }

    private var selectedTabID: UUID? {
        Self.tabIDToKeepInView(tabs: tabs, activeTabIndex: activeTabIndex, isHistorySelected: isHistorySelected)
    }

    /// The tab the bar keeps in view: the selected one, or none while Session
    /// History is open or the active index names no tab.
    static func tabIDToKeepInView(
        tabs: [TBDShared.Tab], activeTabIndex: Int, isHistorySelected: Bool
    ) -> UUID? {
        guard !isHistorySelected, tabs.indices.contains(activeTabIndex) else { return nil }
        return tabs[activeTabIndex].id
    }

    /// Scrolls the tabs the least distance that shows the selected one
    /// whole; a tab already in view does not move.
    private func scrollSelectedTabIntoView(_ proxy: ScrollViewProxy) {
        guard let selectedTabID else { return }
        proxy.scrollTo(selectedTabID)
    }

    /// The tabs, the + button and the trailing group, in one row.
    private var row: some View {
        HStack(spacing: 0) {
            TabsThenAddLayout {
                ScrollView(.horizontal, showsIndicators: false) {
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
                    }
                }
                // Tabs that fit stay put under a trackpad swipe.
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

                AddTabButton(
                    profiles: appState.modelProfiles,
                    onAddShell: onAddShell,
                    onAddClaude: onAddClaude,
                    onAddClaudeProfile: onAddClaudeProfile,
                    onChooseAccount: onChooseAccount,
                    onAddCodex: onAddCodex
                )
            }
            // Exactly the width the trailing group leaves, the tabs and the +
            // button at its leading edge: `minWidth: 0` stops the frame from
            // reporting the tabs' full width, which would push the trailing
            // group past the row's end. Clipped only for a column too narrow
            // for the + button itself.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()

            trailingGroup
                // Its full width, at the row's height, sized before the tabs.
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
        .padding(.horizontal, 0)
        .frame(height: TabRowMetrics.height)
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

    /// `trailing`'s items, left to right, in the order it gives them.
    private var trailingGroup: some View {
        HStack(spacing: 0) {
            ForEach(trailing.items) { item in
                trailingItem(item)
            }
        }
    }

    @ViewBuilder
    private func trailingItem(_ item: TabBarTrailingItem) -> some View {
        switch item {
        case .viewerControl(let control):
            PaneChromeControlButton(control: control) {
                trailing.onViewerControl()
            }
        case .sessionHistory:
            HistoryTabButton(
                isSelected: isHistorySelected,
                action: onHistoryTab
            )
        case .edge(let edgeItem):
            // `.edge` items come only with the edge controls that act for them.
            if let edge = trailing.edge {
                TabRowEdgeButton(item: edgeItem, edge: edge)
            }
        case .expand:
            // Shows the hidden side region. It shows only while the region is
            // hidden, and the strip's collapse button only while it is
            // visible, so `⌘\` is bound on at most one of the two at a time.
            SidePanelToggleButton(collapsed: true) {
                trailing.onExpand()
            }
        }
    }
}

// MARK: - TabsThenAddLayout

/// Lays out the workspace tab bar's tabs, a horizontal scroll view, and the
/// + button after them. The tabs take their ideal width — a horizontal scroll
/// view's is its content's — while the + button still fits after them, so it
/// sits right after the last tab. Past that they take the width the button
/// leaves and scroll, and the button stays in view at the scroll area's end.
///
/// A layout rather than a `ViewThatFits` choosing between a plain row and a
/// scrolling one. That would hold two sets of tab items, each with its own
/// rename field, hover and drop state, and both picking up a pending rename,
/// and would swap one set for the other whenever the column crossed the width
/// the tabs need. Here a resize only moves the scroll area's edge: no tab
/// item is rebuilt.
///
/// Each subview's ideal size is measured once, when SwiftUI makes or updates
/// the layout's cache, and both `sizeThatFits` and `placeSubviews` read it
/// from there: an ideal size does not depend on the proposal.
struct TabsThenAddLayout: Layout {
    /// The subviews' ideal sizes, in order.
    struct Cache {
        var idealSizes: [CGSize]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(idealSizes: Self.idealSizes(of: subviews))
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.idealSizes = Self.idealSizes(of: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let ideals = cache.idealSizes
        let widths = Self.widths(idealWidths: ideals.map(\.width), available: proposal.width)
        let height = proposal.height ?? ideals.map(\.height).max() ?? 0
        return CGSize(width: widths.reduce(0, +), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let widths = Self.widths(
            idealWidths: cache.idealSizes.map(\.width),
            available: bounds.width)
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width
        }
    }

    /// The width each subview gets, in order: every one after the first its
    /// ideal width, and the first its ideal width capped to what the others
    /// leave of `available`, never below zero. With no width offered, each
    /// takes its ideal width.
    static func widths(idealWidths: [CGFloat], available: CGFloat?) -> [CGFloat] {
        guard let first = idealWidths.first, let available else { return idealWidths }
        let rest: [CGFloat] = Array(idealWidths.dropFirst())
        let firstWidth: CGFloat = max(0, min(first, available - rest.reduce(0, +)))
        return [firstWidth] + rest
    }

    private static func idealSizes(of subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
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
    @State private var isHovering = false
    /// Optimistic placeholder, deliberately NOT `.detect()`.
    ///
    /// A `@State` default-value expression runs on EVERY call to the memberwise
    /// initializer — `@State` only preserves the stored value after first
    /// mount, it does not stop the expression from re-evaluating. `AddTabButton`
    /// is built inside `TabBar.body`. The bar is built by
    /// `SingleWorktreeView.tabBar(_:)` and drawn by `SingleWorktreeView.body`,
    /// or on the daemon path by `PanelSurfaceWorkspaceView.body`, and
    /// `WorktreePager` keeps one worktree view mounted per kept-alive worktree,
    /// all reading `AppState`. A `detect()` default would therefore re-run on a
    /// change to any property they read (the 2 s poll, terminal churn) for
    /// every mounted worktree, each doing `2 × (PATH dirs + 8)` synchronous
    /// `stat`s on the main thread. The two real refresh paths below cover the
    /// value: `.task` on appear, and a synchronous re-detect in `showMenu()`.
    @State private var availability = AgentExecutableAvailability.allAvailable

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
        // Re-detect synchronously, and build the menu from the value just
        // measured rather than reading `availability` back — the menu can never
        // be built from the optimistic placeholder.
        let detected = AgentExecutableAvailability.detect()
        availability = detected
        let coordinator = MenuCoordinator(
            onShell: onAddShell,
            onClaude: onAddClaude,
            onClaudeProfile: onAddClaudeProfile,
            onChooseAccount: onChooseAccount,
            onCodex: onAddCodex
        )
        let menu = AddTabMenu.build(
            profiles: profiles,
            availability: detected,
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

    init(
        onShell: @escaping () -> Void,
        onClaude: @escaping () -> Void,
        onClaudeProfile: @escaping (UUID) -> Void,
        onChooseAccount: @escaping () -> Void = {},
        onCodex: @escaping () -> Void
    ) {
        self.onShell = onShell
        self.onClaude = onClaude
        self.onClaudeProfile = onClaudeProfile
        self.onChooseAccount = onChooseAccount
        self.onCodex = onCodex
    }

    @objc func addShell() { onShell() }
    @objc func addClaude() { onClaude() }
    @objc func chooseAccount() { onChooseAccount() }
    @objc func addCodex() { onCodex() }

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
            // usage ("5h 0% · resets 23:10 · wk 76%"). Each gets a
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
    /// Appends live session count when present (design 2026-09-05 §8.2).
    /// The usage suffix is sourced from the same per-profile snapshots the
    /// hover cards and account picker use.
    static func menuLabel(
        for profile: ModelProfile,
        usage: ProfileUsageSnapshot?,
        liveSessions: Int? = nil
    ) -> String {
        let baseName = profile.name
        var parts: [String] = [baseName]

        if let snapshot = usage, !snapshot.buckets.isEmpty,
           let summary = ProfileUsagePresentation.usageSummary(for: snapshot) {
            parts.append(summary)
        }

        if let liveSessions, liveSessions > 0 {
            parts.append("\(liveSessions) live")
        }

        guard parts.count > 1 else { return baseName }
        return parts.joined(separator: " — ")
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
    /// session that is mid-turn / waiting on a permission prompt). Transport
    /// does not enter into it: a holder tab whose panel owns the pty is
    /// parked by signal like any other, so it is offered Hibernate too.
    static func action(for terminal: Terminal?) -> ParkAction? {
        guard let terminal else { return nil }
        if terminal.isManuallyHibernatable() { return .hibernate }
        if terminal.isParked { return .wake }
        return nil
    }
}

// MARK: - TabBarItem

/// Pure policy for the tab context menu's "Copy Session ID": the Claude
/// session UUID to copy, or nil to hide the item (no terminal, a shell or
/// Codex tab, or a Claude tab whose session ID is not known yet).
enum CopyClaudeSessionIDMenu {
    static let title = "Copy Session ID"

    static func sessionID(for terminal: Terminal?) -> String? {
        guard let terminal, terminal.isClaudeResumable,
              let id = terminal.claudeSessionID, !id.isEmpty else { return nil }
        return id
    }
}

enum ContinueInCodexMenu {
    static func isVisible(for terminal: Terminal?) -> Bool {
        terminal?.isClaudeResumable == true
            && terminal?.transcriptPath?.isEmpty == false
    }
}

/// Pure policy for the Codex-to-Claude replacement menu. The app uses cached
/// metadata only to shape the affordance; the daemon repeats every check
/// before it interrupts the source process.
enum ContinueInClaudeMenu {
    static func isVisible(for terminal: Terminal?) -> Bool {
        terminal?.isCodexTerminal == true
            && terminal?.transport == .tmux
            && terminal?.transcriptPath?.isEmpty == false
    }

    /// Every visible item is enabled. A tmux Codex row carries no agent
    /// status, so the cached row cannot say whether a turn is open; the
    /// daemon reads the rollout before it replaces anything and refuses a
    /// busy turn with `terminalBusy`.
    static func isEnabled(for terminal: Terminal?) -> Bool {
        isVisible(for: terminal)
    }
}

// MARK: - Tab controls

/// The terminal pin's item in a workspace tab's right-click menu (panel tabs
/// spec, "The renderer"): "Unpin" for a pinned terminal, "Pin" for any other,
/// and no item for a tab with no terminal behind it.
enum TabPinMenu {
    static func title(for terminal: TBDShared.Terminal?) -> String? {
        guard let terminal else { return nil }
        return terminal.pinnedAt != nil ? "Unpin" : "Pin"
    }
}

/// What renaming a note writes (panel tabs spec, "The renderer"): a note's
/// tab in the side region's strip (`AppState.commitSideNoteRename`) and its
/// pane's title field rename the note itself. A workspace tab's rename field
/// sets the tab's label (`AppState.renameTab`).
enum TabRename {
    /// The title a note's rename writes: the trimmed text, or nil when it is
    /// blank or already the note's title.
    static func noteTitle(text: String, currentNoteTitle: String?) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != currentNoteTitle else { return nil }
        return trimmed
    }
}

/// The width a workspace tab's rename field keeps while it is open. Inside
/// the tabs' horizontal scroll view the field is offered no width and takes
/// its ideal one, which on its own is barely wider than the floor; it takes
/// the label's width from when editing began instead, so the tab keeps its
/// width as the field opens.
enum TabRenameFieldWidth {
    /// The narrowest a field is drawn, for a short or empty label.
    static let floor: CGFloat = 60

    /// The field's minimum (and ideal) width for a label `labelWidth` wide.
    static func minimum(labelWidth: CGFloat) -> CGFloat {
        max(floor, labelWidth)
    }
}

/// What a tab bar item does with the pending rename
/// (`AppState.pendingTabRenameID`) when it looks: the item showing that tab
/// opens its rename field and clears the request; any other item leaves it.
struct TabRenamePickUp: Equatable {
    let startsEditing: Bool
    /// The pending rename once the item has looked.
    let pendingIDAfter: UUID?

    static func decide(tabID: UUID, pendingID: UUID?) -> TabRenamePickUp {
        guard pendingID == tabID else {
            return TabRenamePickUp(startsEditing: false, pendingIDAfter: pendingID)
        }
        return TabRenamePickUp(startsEditing: true, pendingIDAfter: nil)
    }
}

/// A workspace tab's hover text: a web page's full address, which its label
/// (the host) leaves out. No other tab has one; a Claude tab has its account
/// hover card instead.
enum WorkspaceTabTooltip {
    static func text(for content: PaneContent) -> String? {
        guard case .webview(_, let url) = content else { return nil }
        return url.absoluteString
    }
}

// MARK: - TabTerminalTarget

/// Pure resolution of the terminal a tab is backed by: the anchor its deep
/// link points at. A pane with no terminal behind it (webview, code viewer,
/// note) resolves to nil, and its deep link falls back to the worktree alone.
///
/// Extracted from the view so each branch is unit-testable without rendering
/// SwiftUI (same pattern as `TabParkMenuModel` and `ContinueInCodexMenu`).
enum TabTerminalTarget {
    static func terminalID(for content: PaneContent) -> UUID? {
        switch content {
        case .terminal(let terminalID): return terminalID
        case .liveTranscript(_, let terminalID): return terminalID
        case .webview, .codeViewer, .note: return nil
        }
    }
}

// MARK: - WorkspaceTabFileMenu

/// The file a workspace tab's right-click menu offers Copy Path, Reveal in
/// Finder and Open With for: the one a pane header's title menu acts on
/// (`headerMenuTarget`), for the tab's content, with the copy item's wording.
/// A file tab offers its file, and a transcript tab its terminal's session
/// `.jsonl` once that terminal's row carries a non-empty one; every other tab
/// offers none, and with no target the menu has none of the three items. On
/// the daemon path no header names the primary, so the tab's menu is where
/// these items are.
///
/// Extracted from the view so each kind is unit-testable without rendering
/// SwiftUI (same pattern as `TabTerminalTarget`).
enum WorkspaceTabFileMenu {
    /// - Parameter transcriptPath: the session `.jsonl` of a terminal, by its
    ///   ID; asked only for the terminal a transcript tab follows.
    static func target(
        for content: PaneContent, transcriptPath: (UUID) -> String?
    ) -> HeaderMenuTarget? {
        var path: String?
        if case .liveTranscript(_, let terminalID) = content {
            path = transcriptPath(terminalID)
        }
        return headerMenuTarget(for: content, transcriptPath: path)
    }
}

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
    /// The label's width as last drawn. The label gives way to the rename
    /// field while editing, so this holds its width from when editing began,
    /// the rename field's minimum.
    @State private var labelWidth: CGFloat = 0
    /// The applications Open With offers for `fileMenuTarget`'s file, looked
    /// up off the main actor when the item appears or that file changes, and
    /// again each time the pointer enters the item, so the right-click that
    /// almost always follows a hover finds the list fresh; never while the
    /// menu is built (`RevealAndOpenWithMenuItems`). One lookup at a time,
    /// and none outlives the item's file or the item (`OpenWithAppsLookup`).
    @StateObject private var fileMenuApps = OpenWithAppsLookup()
    @AppStorage("codeViewer.showSidebar") private var showSidebar = false
    @AppStorage(AppState.showClaudeTabUsageTooltipKey)
    private var showClaudeTabUsageTooltip: Bool = true
    @AppStorage(AppState.usageResetTimeStyleKey)
    private var usageResetTimeStyle: ProfileUsagePresentation.ResetTimeStyle = .timeOfReset
    @Environment(AppState.self) private var appState

    private var showClose: Bool {
        isSelected || isHovering
    }

    /// The rename field's minimum width: the label's width when editing
    /// began, and at least 60 pt.
    private var renameFieldMinWidth: CGFloat {
        TabRenameFieldWidth.minimum(labelWidth: labelWidth)
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
                        // The scroll view offers no width, so the field takes
                        // its ideal one (`TabRenameFieldWidth`).
                        .frame(
                            minWidth: renameFieldMinWidth, idealWidth: renameFieldMinWidth,
                            maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(tabLabel)
                            .font(.system(size: 11))
                            .fontWeight(hasUnreadCompletion ? .bold : .regular)
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(isParked ? .tertiary : (isSelected ? .primary : .secondary))
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.width
                            } action: { width in
                                labelWidth = width
                            }
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
            .modifier(OptionalHelp(text: WorkspaceTabTooltip.text(for: tab.content)))

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
        .onAppear { fileMenuApps.show(path: fileMenuTarget?.path) }
        .onChange(of: fileMenuTarget?.path) { _, path in
            fileMenuApps.show(path: path)
        }
        .onDisappear { fileMenuApps.stop() }
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                fileMenuApps.pointerEntered()
            }
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard isRenameable else { return }
                beginRename()
            }
        )
        .onAppear { pickUpPendingRename() }
        .onChange(of: appState.pendingTabRenameID) { _, _ in
            pickUpPendingRename()
        }
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
            // Defer the tracked write off SwiftUI's view-graph update pass.
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

    @ViewBuilder
    private func continueInClaudeMenuItems() -> some View {
        let enabled = ContinueInClaudeMenu.isEnabled(for: terminal)

        Button("Default (logged in)") {
            guard let terminalID = terminal?.id else { return }
            Task {
                await appState.continueInClaude(
                    sourceTerminalID: terminalID,
                    profileID: nil)
            }
        }
        .disabled(!enabled)

        if !appState.modelProfiles.isEmpty {
            Divider()

            ForEach(appState.modelProfiles, id: \.profile.id) { entry in
                Button(formatProfileSubmenuLabel(entry)) {
                    guard let terminalID = terminal?.id else { return }
                    Task {
                        await appState.continueInClaude(
                            sourceTerminalID: terminalID,
                            profileID: entry.profile.id)
                    }
                }
                .disabled(!enabled)
            }
        }
    }

    /// The file this tab's Copy Path, Reveal in Finder and Open With act on,
    /// and the copy item's wording (`WorkspaceTabFileMenu`); nil for a tab
    /// with no file, which offers none of them. A transcript tab's file is
    /// the session `.jsonl` on its terminal's row in this worktree.
    private var fileMenuTarget: HeaderMenuTarget? {
        WorkspaceTabFileMenu.target(for: tab.content) { terminalID in
            appState.terminal(id: terminalID, in: worktreeID)?.transcriptPath
        }
    }

    /// The terminal this tab renders, for deep-link anchoring — nil for
    /// non-terminal panes (webview, code viewer, note), whose links fall back
    /// to the worktree alone.
    private var linkTerminalID: UUID? {
        TabTerminalTarget.terminalID(for: tab.content)
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if let fileTarget = fileMenuTarget {
            Button(fileTarget.copyLabel) { copyToPasteboard(fileTarget.path) }
            RevealAndOpenWithMenuItems(path: fileTarget.path, apps: fileMenuApps.apps)
        }

        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                DeepLink.makeShareableOpenURL(worktreeID, terminalID: linkTerminalID).absoluteString,
                forType: .string
            )
        }

        if let sessionID = CopyClaudeSessionIDMenu.sessionID(for: terminal) {
            Button(CopyClaudeSessionIDMenu.title) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sessionID, forType: .string)
            }
        }

        Divider()

        if let terminal, let pinTitle = TabPinMenu.title(for: terminal) {
            let pinned = terminal.pinnedAt != nil
            Button {
                Task { await appState.setTerminalPin(id: terminal.id, pinned: !pinned) }
            } label: {
                Label(pinTitle, systemImage: pinned ? "pin.slash" : "pin")
            }

            Divider()
        }

        // Shells move too, so this sits outside the Claude-only block.
        if TransportMigrationMenu.isOffered(
            for: terminal,
            holderSupported: appState.daemonCapabilities?.ptyHolderSupported ?? false) {
            Button {
                guard let terminalID = terminal?.id else { return }
                Task { await appState.migrateTerminalToHolder(terminalID: terminalID) }
            } label: {
                Label(TransportMigrationMenu.title, systemImage: "arrow.right.square")
            }

            Divider()
        }

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

            if ContinueInCodexMenu.isVisible(for: terminal) {
                Button {
                    guard let terminalID = terminal?.id else { return }
                    Task {
                        await appState.continueInCodex(
                            sourceTerminalID: terminalID)
                    }
                } label: {
                    Label("Continue in Codex", systemImage: "arrow.right.circle")
                }
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

        if ContinueInClaudeMenu.isVisible(for: terminal) {
            Menu {
                continueInClaudeMenuItems()
            } label: {
                Label("Continue in Claude", systemImage: "arrow.right.circle")
            }

            Divider()
        }

        if isRenameable {
            Button("Rename Tab") {
                beginRename()
            }
            Divider()
        }

        Button(action: onClose) {
            Label("Close Tab", systemImage: "xmark")
        }
    }

    /// Selects the tab and asks for its rename field through `AppState`
    /// (`requestTabRename`), not this item's own state: selecting can move the
    /// bar to another view, which rebuilds this item, and the item showing the
    /// tab then — this one or its replacement — opens the field.
    private func beginRename() {
        if !isSelected { onSelect() }
        appState.requestTabRename(tabID: tab.id)
    }

    /// Opens the rename field when the pending rename is this tab's.
    private func pickUpPendingRename() {
        guard appState.takePendingTabRename(tabID: tab.id) else { return }
        isEditing = true
    }

    /// Viewer content shows the icon it shares with the side region's strip
    /// (`PanelKind.tabSystemImage`); a terminal's icon follows its session.
    @ViewBuilder
    private var tabIconView: some View {
        let style = isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
        if let viewer = LegacyTabConverter.panelContent(from: tab.content) {
            Image(systemName: viewer.kind.tabSystemImage)
                .font(.system(size: 10))
                .foregroundStyle(style)
        } else if isParked {
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
    }

    /// A user's label wins. Otherwise viewer content shows the title it
    /// shares with the side region's strip (`PanelContent.tabTitle`), with an
    /// untitled note numbered by this tab's position, and a terminal shows
    /// `AutoTabLabelResolver`'s.
    private var tabLabel: String {
        if let label = tab.label, !label.isEmpty {
            return label
        }
        if let viewer = LegacyTabConverter.panelContent(from: tab.content) {
            return viewer.tabTitle(
                noteTitle: { noteID in
                    appState.notes.values.flatMap { $0 }.first(where: { $0.id == noteID })?.title
                },
                untitledNote: "Note \(index + 1)")
        }
        return AutoTabLabelResolver.terminalLabel(
            terminal: terminal,
            fallbackIndex: index,
            modelProfiles: appState.modelProfiles,
            worktreeTabs: appState.tabs[worktreeID] ?? [],
            worktreeTerminals: appState.terminals[worktreeID] ?? []
        )
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

// MARK: - OptionalHelp

/// `.help(text)` when there is text, and nothing otherwise, so a view with no
/// tooltip gets no empty one.
private struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}
