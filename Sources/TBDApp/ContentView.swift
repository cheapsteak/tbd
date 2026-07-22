import AppKit
import SwiftUI
import TBDShared

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var overlayCoordinator: TranscriptOverlayCoordinator
    @AppStorage("filePanel.isVisible") private var showFilePanel = true
    @AppStorage("filePanel.width") private var filePanelWidth: Double = 280
    @AppStorage(AppState.nightwatchExperimentalKey) private var nightwatchExperimental: Bool = false
    @State private var contentAreaHeight: CGFloat = 600
    // Part of the PR split button's .id key: the baked (non-template) icon
    // colors depend on the appearance, and the materialized-once toolbar item
    // only picks up a re-bake when the id changes.
    @Environment(\.colorScheme) private var colorScheme

    private var selectedWorktree: Worktree? {
        guard let id = appState.selectedWorktreeIDs.first else { return nil }
        // findWorktree also resolves scratch spaces (repo-less worktrees).
        return appState.findWorktree(id: id)
    }

    @ViewBuilder
    private var worktreeTitleItem: some View {
        if let worktree = selectedWorktree {
            WorktreeTitleView(
                appState: appState,
                worktree: worktree,
                repoName: worktree.repoID.flatMap { appState.repoName(for: $0) }
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Persistent, non-blocking cross-build warning: the shared daemon
            // was started from a different worktree's build than this app.
            // Advisory only — the app keeps working with whatever RPCs still
            // decode; the user decides when to restart.
            if let warning = appState.daemonBuildMismatchMessage,
               !appState.daemonBuildMismatchDismissed {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(warning).font(.caption)
                    Spacer()
                    Button("Dismiss") {
                        appState.daemonBuildMismatchDismissed = true
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.yellow.opacity(0.2))
            }

            // Nightwatch desk session status banner (Phase A visible worker).
            // Gated on the experimental flag like every other nightwatch surface
            // (fail-closed to hidden when the user never opted in).
            if nightwatchExperimental {
                NightwatchDeskStatusBanner()
            }

            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 400)
            } detail: {
                if !appState.isConnected {
                    disconnectedView
                } else if appState.selectedScratchSection {
                    ScratchDetailView()
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
                        // Uses the canonical tab-keyed set — never iterate
                        // `layouts.values` unkeyed: stale worktree-keyed
                        // entries persisted by the pre-split grid path would
                        // make hidden terminals look visible. Those entries
                        // are not pruned at restore time (keys can't be
                        // classified at init; Phase 2 import drops them).
                        if let frame = overlayCoordinator.current,
                           overlayFrameIsWindowRoot(frame, visibleTerminalIDs: appState.visibleTerminalIDs) {
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

                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .principal) {
                        worktreeTitleItem
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .principal) {
                        worktreeTitleItem
                    }
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
                    let worktree = appState.findWorktree(id: worktreeID)
                    let armed = worktree.map { appState.effectiveAutoArchive(for: $0) } ?? false
                    let hibernateArmed = worktree.map { appState.effectiveAutoHibernate(for: $0) } ?? false
                    let blocked = !appState.children(of: worktreeID).isEmpty
                    ToolbarItem(placement: .primaryAction) {
                        ControlGroup {
                            // Split button: label = primary click (open PR); the
                            // attached chevron opens the menu.
                            Menu {
                                if worktree != nil {
                                    // `armed` is captured at materialization time; the .id
                                    // rebuild below is what refreshes the checkmark (getter
                                    // re-evaluations never reach the materialized NSMenu).
                                    Toggle("Auto-archive worktree on PR merge", isOn: Binding(
                                        get: { armed },
                                        set: { newValue in
                                            Task { await appState.setAutoArchive(worktreeID: worktreeID, enabled: newValue) }
                                        }
                                    ))
                                    .disabled(blocked)
                                    // Plain 2-state toggle bound to the EFFECTIVE
                                    // value; the setter always writes explicit
                                    // true/false (no UI path back to nil — the
                                    // tri-state stays reachable via daemon/DB only,
                                    // matching auto-archive). Deliberately NOT
                                    // `.disabled(blocked)`: `blocked` is the
                                    // archive-specific active-children rule, and the
                                    // daemon's precedence lets an armed-but-blocked
                                    // archive still hibernate.
                                    Toggle("Auto-hibernate sessions on PR merge", isOn: Binding(
                                        get: { hibernateArmed },
                                        set: { newValue in
                                            Task { await appState.setAutoHibernate(worktreeID: worktreeID, enabled: newValue) }
                                        }
                                    ))
                                }
                            } label: {
                                PRButtonLabel(prStatus: prStatus, isAutoArchiveArmed: armed, isAutoHibernateArmed: hibernateArmed)
                            } primaryAction: {
                                // cmd+click opens the PR in the default browser instead of an in-app tab.
                                if NSEvent.modifierFlags.contains(.command) {
                                    NSWorkspace.shared.open(prURL)
                                    return
                                }
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
                                    let tab = TBDShared.Tab(id: UUID(), content: .webview(id: webviewID, url: prURL), label: "PR #\(prStatus.number)")
                                    appState.tabs[worktreeID, default: []].append(tab)
                                    appState.activeTabIndices[worktreeID] = (appState.tabs[worktreeID]?.count ?? 1) - 1
                                }
                            }
                            // Keep "#123" neutral like the original plain Button (the
                            // split button otherwise accent-tints it); the icon keeps
                            // its baked status color via renderingMode(.original).
                            .tint(.primary)
                            // Build the tooltip as an ordered clause list so
                            // "more options" is structurally guaranteed to land
                            // last, whatever combination of arm states applies.
                            // The archive clause keeps its three-way wording:
                            // while child worktrees exist the daemon's
                            // AutoArchiveOnMergeCoordinator skips archiving (it
                            // re-checks active children at merge time), so an
                            // armed-but-blocked worktree must not promise
                            // "auto-archives on merge".
                            .help({
                                var clauses = ["Open PR #\(prStatus.number)"]
                                if armed && blocked {
                                    clauses.append("auto-archive armed (paused while child worktrees exist)")
                                } else if armed {
                                    clauses.append("auto-archives on merge")
                                }
                                if hibernateArmed { clauses.append("auto-hibernates on merge") }
                                clauses.append("more options")
                                return clauses.joined(separator: " · ")
                            }())
                            // AppKit materializes this split button's NSMenu and
                            // label ONCE; later SwiftUI re-evaluations of the
                            // Toggle checkmark and armed badge never reach the
                            // already-built NSMenuToolbarItem. Changing the id
                            // forces the item to be recreated, so the key must
                            // include EVERYTHING the label/menu render: worktree
                            // + whether its row has loaded (gates the menu's
                            // items), armed + hibernateArmed + blocked (menu +
                            // help), the rendered PRStatus fields (number, state,
                            // url — not reason, which presentation ignores), and
                            // colorScheme (baked icon colors).
                            .id(PRButtonLabel.prSplitButtonID(
                                worktreeID: worktreeID,
                                worktreeFound: worktree != nil,
                                armed: armed,
                                hibernateArmed: hibernateArmed,
                                blocked: blocked,
                                prStatus: prStatus,
                                colorScheme: colorScheme
                            ))
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
        .overlay(alignment: .bottomTrailing) { ToastOverlay() }
        .onChange(of: appState.selectedWorktreeIDs) { oldSelection, newSelection in
            overlayCoordinator.close()
            markSelectedWorktreesAsRead(newSelection)
            let newlySelected = newSelection.subtracting(oldSelection)
            for worktreeID in newlySelected {
                Task { await appState.refreshPRStatus(worktreeID: worktreeID) }
            }
            Task {
                for worktreeID in newSelection {
                    await appState.refreshTerminals(worktreeID: worktreeID)
                }
                // Cold-start race fix: after terminals refresh on focus, re-invoke
                // the wake decision. The synchronous focusTerminalAfterSelectionChange
                // below runs before refreshTerminals completes, so the wake decision
                // may race against an empty terminals[worktreeID] list. Re-invoking
                // after the full load ensures parked terminals are visible.
                if newSelection.count == 1, let id = newSelection.first {
                    appState.wakeHibernatedTerminalsOnFocus(worktreeID: id)
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
        .nightwatchModeTint(appState.nightwatchMode, experimentalEnabled: nightwatchExperimental)
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

// Internal (not private) so TBDAppTests can exercise the baked-image geometry
// and the .id key computation.
struct PRButtonLabel: View {
    let prStatus: PRStatus
    let isAutoArchiveArmed: Bool
    let isAutoHibernateArmed: Bool
    // Feeds the baked-icon cache key (and, at the ContentView level, the
    // toolbar item's .id key) so light/dark changes re-bake the non-template
    // icon, which can't auto-adapt the way a tinted template would.
    @Environment(\.colorScheme) private var colorScheme

    /// Baked image geometry: a 12×12 status icon, followed left→right by up to
    /// two 12×12 armed badges — an `archivebox` (auto-archive) then a
    /// `moon.zzz` (auto-hibernate) — each preceded by a 3pt gap and composited
    /// into the same bitmap. The order is stable regardless of which flags are
    /// armed: when only hibernate is armed, `moon.zzz` occupies the first badge
    /// slot immediately after the icon (no empty archivebox gap).
    static let iconSide: CGFloat = 12
    static let badgeGap: CGFloat = 3

    /// A queued PR renders the full-color bus (with its position baked in)
    /// instead of the status icon; BOTH armed badges are suppressed in that
    /// mode (the bus owns the label), so the baked image stays a single square.
    var isMergeQueued: Bool { prStatus.mergeQueuePosition != nil }

    /// Number of armed badges to composite. Zero when queued (the bus glyph
    /// supersedes both badges), otherwise one per armed flag.
    var badgeCount: Int {
        guard !isMergeQueued else { return 0 }
        return (isAutoArchiveArmed ? 1 : 0) + (isAutoHibernateArmed ? 1 : 0)
    }

    var bakedWidth: CGFloat {
        Self.iconSide + CGFloat(badgeCount) * (Self.badgeGap + Self.iconSide)
    }

    /// The `.id` key for the PR split-button toolbar item. AppKit materializes
    /// the split button's NSMenu and label ONCE, so the key must include
    /// EVERYTHING the label/menu render — anything omitted here can change in
    /// SwiftUI state without ever reaching the materialized AppKit item.
    /// `worktreeFound` matters because the menu's items (the auto-archive and
    /// auto-hibernate Toggles) are gated on the worktree row having loaded: a
    /// menu materialized before the row appears would otherwise stay
    /// permanently empty. `hibernateArmed` mirrors `armed`: without it the
    /// hibernate Toggle's checkmark would freeze at its first-render value. The key
    /// contains exactly the `PRStatus` fields the label/menu/primaryAction
    /// consume: `number` (label text/help), `state` (icon via
    /// `PRStatusPresentation`), `url` (captured by `primaryAction`, so a
    /// re-pointed PR must recreate the item too), and `mergeQueuePosition`
    /// (the bus glyph short-circuits on it and bakes the position into the
    /// icon, so a 2→1 queue move with an unchanged `state` must still rebuild).
    /// `reason` is deliberately excluded — the split button's presentation
    /// ignores it, and keying on it would force spurious toolbar-item rebuilds
    /// for zero visual change.
    ///
    /// This key MUST stay a String. The macOS 26 toolbar bridge only honors
    /// `.id` identity changes for String values here — a custom Hashable
    /// struct key was observed NOT to trigger NSMenuToolbarItem recreation
    /// (verified live 2026-07-03: stale help text, missing badge). Do not
    /// "clean this up" back into a struct.
    static func prSplitButtonID(
        worktreeID: UUID,
        worktreeFound: Bool,
        armed: Bool,
        hibernateArmed: Bool,
        blocked: Bool,
        prStatus: PRStatus,
        colorScheme: ColorScheme
    ) -> String {
        "pr-split-\(worktreeID)-\(worktreeFound)-\(armed)-\(hibernateArmed)-\(blocked)"
            + "-\(prStatus.number)-\(prStatus.state.rawValue)-\(prStatus.url)"
            + "-\(prStatus.mergeQueuePosition.map(String.init) ?? "nil")"
            + "-\(colorScheme)"
    }

    /// Aspect-fits `size` into `slot`, centered. Used to draw the archivebox
    /// badge (non-square intrinsic size, ~16×14) into its square badge slot
    /// without stretching it.
    static func aspectFitRect(for size: NSSize, in slot: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return slot }
        let scale = min(slot.width / size.width, slot.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(
            x: slot.midX - fitted.width / 2,
            y: slot.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    var body: some View {
        HStack(spacing: 3) {
            if let presentation = PRStatusPresentation.make(for: prStatus),
               let nsImage = coloredIcon(presentation, colorScheme: colorScheme) {
                Image(nsImage: nsImage)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: bakedWidth, height: Self.iconSide)
            }
            // macOS 26 flattens a toolbar split-button (Menu) label to exactly
            // ONE image + ONE plain text string: a separate trailing Image is
            // dropped, and an inline Text(Image(...)) attachment is stripped
            // entirely. Any badge (like the auto-archive-armed archivebox or
            // the auto-hibernate-armed moon.zzz) must therefore be composited
            // INTO the single baked NSImage.
            Text(verbatim: "#\(prStatus.number)")
                .font(.caption)
                .fontWeight(.medium)
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var clauses = ["PR #\(prStatus.number)"]
        if isAutoArchiveArmed { clauses.append("auto-archive on merge is on") }
        if isAutoHibernateArmed { clauses.append("auto-hibernate on merge is on") }
        return clauses.joined(separator: ", ")
    }

    /// Cache for baked `.asset` icons, keyed by (asset name, colorSemantic,
    /// archiveArmed, hibernateArmed, colorScheme). (The `.emoji` bus glyph is
    /// cached separately by
    /// `PRStatusPresentation.busImage`.) The bake does disk I/O (`Bundle.module.url` +
    /// `NSImage(contentsOf:)`) plus symbol creation on every body evaluation,
    /// and — per the materialize-once behavior documented at the `.id` call
    /// site — those re-evaluations never reach AppKit anyway. MainActor
    /// confinement (SwiftUI body runs on main) makes this safe without locks.
    /// colorSemantic must be part of the key: several PR states share the
    /// same icon name but bake different colors.
    @MainActor
    private static var bakedIconCache: [String: NSImage] = [:]

    /// Bakes the status color into a NON-template image. Toolbar `Menu` /
    /// split-button labels render template images monochrome (AppKit tints
    /// them with the control color and ignores `.foregroundStyle`), so the
    /// icon must carry its own color and be drawn with `.renderingMode(.original)`.
    /// When auto-archive and/or auto-hibernate are armed, an `archivebox`
    /// and/or `moon.zzz` badge (each tinted `secondaryLabelColor`) is
    /// composited left→right after the status icon — the flattened toolbar
    /// label keeps only this one image, so the badges must live inside it.
    @MainActor
    func coloredIcon(_ presentation: PRStatusPresentation, colorScheme: ColorScheme) -> NSImage? {
        // Merge-queue bus: full-color glyph with its position baked in via the
        // SAME shared helper the sidebar uses. It must NOT be tinted, so skip
        // the color-baking fill path entirely (and both armed badges — queue
        // mode supersedes them, matching `bakedWidth`).
        if case .emoji = presentation.glyph {
            return PRStatusPresentation.busImage(position: presentation.badge, side: Self.iconSide)
        }
        guard case .asset(let name) = presentation.glyph else { return nil }
        // Both armed flags MUST be in the key: an armed/unarmed pair otherwise
        // renders from the same cached bitmap and the badge silently never
        // updates.
        let cacheKey = "\(name)-\(presentation.colorSemantic)"
            + "-\(isAutoArchiveArmed)-\(isAutoHibernateArmed)-\(colorScheme)"
        if let cached = Self.bakedIconCache[cacheKey] { return cached }
        let nsColor = presentation.nsColor
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Icons"),
              let base = NSImage(contentsOf: url) else { return nil }
        base.isTemplate = true
        // Ordered list of armed badge symbols, left→right: archivebox then
        // moon.zzz. Only the armed ones are included, so when only hibernate is
        // armed moon.zzz takes the first slot immediately after the status icon.
        var badges: [NSImage] = []
        if isAutoArchiveArmed,
           let archive = NSImage(systemSymbolName: "archivebox", accessibilityDescription: "Auto-archive on merge is on") {
            badges.append(archive)
        }
        if isAutoHibernateArmed,
           let moon = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "Auto-hibernate on merge is on") {
            badges.append(moon)
        }
        let side = Self.iconSide
        let img = NSImage(size: NSSize(width: bakedWidth, height: side), flipped: false) { _ in
            // Colors are resolved inside this draw handler, so dynamic colors
            // (like secondaryLabelColor) pick up the current appearance.
            let iconRect = NSRect(x: 0, y: 0, width: side, height: side)
            base.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
            nsColor.set()
            iconRect.fill(using: .sourceAtop)
            for (index, badge) in badges.enumerated() {
                // Aspect-fit: the badge symbols' intrinsic sizes are non-square
                // (archivebox ~16×14); drawing them straight into the square
                // slot would stretch them.
                let slotX = side + CGFloat(index + 1) * Self.badgeGap + CGFloat(index) * side
                let slot = NSRect(x: slotX, y: 0, width: side, height: side)
                let badgeRect = Self.aspectFitRect(for: badge.size, in: slot)
                badge.draw(in: badgeRect, from: .zero, operation: .sourceOver, fraction: 1)
                NSColor.secondaryLabelColor.set()
                badgeRect.fill(using: .sourceAtop)
            }
            return true
        }
        img.isTemplate = false
        Self.bakedIconCache[cacheKey] = img
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
