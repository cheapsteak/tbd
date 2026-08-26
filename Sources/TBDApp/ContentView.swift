import AppKit
import SwiftUI
import TBDShared

private enum FilePanelStorageKey {
    static let isVisible = "filePanel.isVisible"
    static let width = "filePanel.width"
}

struct ContentView: View {
    @Environment(AppState.self) var appState
    @EnvironmentObject var overlayCoordinator: TranscriptOverlayCoordinator
    @AppStorage(FilePanelStorageKey.isVisible) private var showFilePanel = true
    @AppStorage(FilePanelStorageKey.width) private var filePanelWidth: Double = 280
    @AppStorage(AppState.nightwatchExperimentalKey) private var nightwatchExperimental: Bool = false
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
        @Bindable var appState = appState
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

            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 400)
            } detail: {
                // The tab choice is resolved HERE, in a real `body`, and handed
                // down as a value. Reading these three properties inside
                // `updateNSViewController` instead would register no
                // dependency — Observation tracks what a `body` evaluation
                // reads — so a selection change that touched nothing else this
                // body reads would leave the detail area on the previous tab.
                DetailSectionHostPager(
                    targetTab: DetailSectionHostPager.targetTab(
                        isConnected: appState.isConnected,
                        selectedRemoteSession: appState.selectedRemoteSession,
                        selectedRemoteProvider: appState.selectedRemoteProvider
                    )
                )
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

                // The PR control is gated on `effectivePRBindings`: every
                // binding the worktree has, or — with none — the legacy single
                // `prStatuses` entry lifted into one synthetic binding, so a
                // worktree whose PRs cannot be bound (`gh` offline or
                // unauthenticated, or the first poll after upgrade still in
                // flight) keeps the control it had before multi-PR. The sidebar
                // row indicator reads the same accessor, so the two surfaces
                // cannot disagree. With neither, no control appears at all.
                if let worktreeID = appState.selectedWorktreeIDs.first,
                   appState.selectedWorktreeIDs.count == 1 {
                    let bindings = appState.effectivePRBindings(worktreeID: worktreeID)
                    if !bindings.isEmpty {
                        let worktree = appState.findWorktree(id: worktreeID)
                        let armed = worktree.map { appState.effectiveAutoArchive(for: $0) } ?? false
                        let hibernateArmed = worktree.map { appState.effectiveAutoHibernate(for: $0) } ?? false
                        let blocked = !appState.children(of: worktreeID).isEmpty
                        // AppKit materializes this split button's NSMenu and
                        // label ONCE; later SwiftUI re-evaluations of the
                        // Toggle checkmark and armed badge never reach the
                        // already-built NSMenuToolbarItem. Changing the id
                        // forces the item to be recreated, so the key must
                        // include EVERYTHING the label/menu render: worktree
                        // + whether its row has loaded (gates the menu's
                        // items), armed + hibernateArmed + blocked (menu +
                        // help), the rendered fields of EVERY binding (number,
                        // state, url, queue position, detached, and the reason
                        // + head branch every menu row's title carries), and
                        // colorScheme (baked icon colors).
                        // Composed once and used in BOTH the help string and the
                        // `.id` key: they must agree, or the item stops
                        // rebuilding when the words it renders change. The
                        // status it ages is the icon binding's — the same
                        // selection rule the sidebar dot uses — so the two
                        // surfaces never disagree about which PR they describe.
                        //
                        // `now: Date()` in the body is deliberate. Both facts it
                        // ages come from `AppState`, and `prObservations` is
                        // republished on every poll (its `observedAt` advances
                        // each attempt), so this body re-evaluates on the same
                        // ~30 s cadence as the facts — a coarse ticker driven by
                        // the data instead of one running beside it, and much
                        // finer than the five-minute buckets `checkedLabel`
                        // renders. **If that republication is ever made
                        // value-only, these clauses freeze and need a real
                        // ticker.**
                        let prFreshnessClauses = PRFreshness.clauses(
                            status: PRBindingPresentation.iconBinding(bindings)?.status,
                            observation: appState.prObservations[worktreeID],
                            now: Date())
                        let splitButtonID = PRButtonLabel.prSplitButtonID(
                            worktreeID: worktreeID,
                            worktreeFound: worktree != nil,
                            armed: armed,
                            hibernateArmed: hibernateArmed,
                            blocked: blocked,
                            bindings: bindings,
                            freshnessClauses: prFreshnessClauses,
                            colorScheme: colorScheme
                        )
                        let helpText = Self.prSplitButtonHelp(
                            bindings: bindings, armed: armed,
                            hibernateArmed: hibernateArmed, blocked: blocked,
                            freshnessClauses: prFreshnessClauses)

                        // Exactly one PR whose URL parses keeps the split button
                        // it has always been: the label is the primary click
                        // (open the PR), the chevron opens the menu. Otherwise
                        // there is no single PR a primary click could mean — a
                        // several-PR worktree, or a lone binding whose stored
                        // URL will not parse — so `primaryAction:` is dropped
                        // and the whole button opens the list. The two shapes
                        // are different `Menu` initializers, so the branch is at
                        // toolbar-item level: a conditional INSIDE the
                        // ControlGroup would risk the NSMenuToolbarItem lowering
                        // the capsule depends on.
                        let primaryURL = Self.prPrimaryActionURL(bindings)
                        if let primaryURL {
                            ToolbarItem(placement: .primaryAction) {
                                ControlGroup {
                                    Menu {
                                        prSplitButtonMenu(
                                            worktreeID: worktreeID, bindings: bindings,
                                            showsBindingRows: false,
                                            worktreeFound: worktree != nil, armed: armed,
                                            hibernateArmed: hibernateArmed, blocked: blocked)
                                    } label: {
                                        PRButtonLabel(bindings: bindings, isAutoArchiveArmed: armed, isAutoHibernateArmed: hibernateArmed)
                                    } primaryAction: {
                                        appState.openPR(url: primaryURL, number: bindings[0].number, worktreeID: worktreeID)
                                    }
                                    // Keep "#123" neutral like the original plain Button (the
                                    // split button otherwise accent-tints it); the icon keeps
                                    // its baked status color via renderingMode(.original).
                                    .tint(.primary)
                                    .help(helpText)
                                    .id(splitButtonID)
                                }
                            }
                        } else {
                            ToolbarItem(placement: .primaryAction) {
                                ControlGroup {
                                    Menu {
                                        prSplitButtonMenu(
                                            worktreeID: worktreeID, bindings: bindings,
                                            showsBindingRows: true,
                                            worktreeFound: worktree != nil, armed: armed,
                                            hibernateArmed: hibernateArmed, blocked: blocked)
                                    } label: {
                                        PRButtonLabel(bindings: bindings, isAutoArchiveArmed: armed, isAutoHibernateArmed: hibernateArmed)
                                    }
                                    .tint(.primary)
                                    .help(helpText)
                                    .id(splitButtonID)
                                }
                            }
                        }

                        if #available(macOS 26.0, *) {
                            ToolbarSpacer(.fixed, placement: .primaryAction)
                        }
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
        // Presented from here rather than from any one creation path: all
        // three (Cmd+N, the sidebar `+` profile popover, the existing-branch
        // picker) funnel through `AppState.createWorktree`, which is what sets
        // the target. Dismissal nils the binding and parks nothing.
        // ONE sheet modifier for both prompt surfaces — composing a first
        // message, and reading back one the agent never received (opened from
        // the sidebar row's glyph, so it outlives the daemon's notification).
        // Two `.sheet(item:)`s on the same view would leave which one presents
        // up to SwiftUI.
        .sheet(
            item: Binding(
                get: {
                    PromptSheet.presented(
                        compose: appState.queuedPromptTarget,
                        readback: appState.parkedPromptReadback)
                },
                set: { if $0 == nil { appState.dismissPresentedPromptSheet() } }
            )
        ) { sheet in
            switch sheet {
            case .compose(let target):
                QueuedPromptModal(target: target).environment(appState)
            case .readback(let readback):
                ParkedPromptReadbackView(readback: readback).environment(appState)
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
        .alert(
            "tmux Not Found",
            isPresented: Binding(
                get: { appState.isTmuxLocationPromptPresented },
                set: { presented in
                    if !presented {
                        appState.dismissTmuxLocationPrompt()
                    }
                }
            )
        ) {
            Button("Locate tmux…") {
                appState.dismissTmuxLocationPrompt()
                locateTmuxExecutable()
            }
            Button("Not Now", role: .cancel) {
                appState.dismissTmuxLocationPrompt()
            }
        } message: {
            Text("TBD could not find tmux in PATH and no saved fallback is available. Locate the tmux executable to use TBD terminals.")
        }
        .onAppear {
            appState.checkTmuxAvailabilityAtStartup()
            // Keep-alive: seed recentlyVisitedWorktreeIDs with the initially-restored
            // selection so the ZStack renders the right SingleWorktreeView on first frame.
            if appState.selectedWorktreeIDs.count == 1, let id = appState.selectedWorktreeIDs.first {
                appState.touchVisitedWorktree(id)
                appState.focusTerminalAfterSelectionChange(worktreeID: id)
            }
        }
    }

    private func locateTmuxExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Locate tmux"
        panel.message = "Choose the tmux executable."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try appState.saveTmuxExecutableFallback(url.path)
        } catch {
            appState.alertIsError = true
            appState.alertMessage = error.localizedDescription
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

    // MARK: - PR split button

    /// The URL a primary click on the split button should open, or `nil` when
    /// the button has no single meaning and must open its menu instead.
    ///
    /// Exactly one binding whose stored URL parses is the only case that has
    /// one. A lone binding with an unparseable URL used to fall into the
    /// several-PR shape while the menu still gated its rows on `count > 1`, so
    /// the label read `#412` and neither the click nor the menu offered that PR
    /// anywhere — a dead control. It now routes through the menu shape, which
    /// renders the PR as a (disabled) row, so the button never promises an
    /// action it cannot perform.
    ///
    /// Static and pure so the branch can be exercised without a toolbar.
    static func prPrimaryActionURL(_ bindings: [PRBinding]) -> URL? {
        guard bindings.count == 1 else { return nil }
        return URL(string: bindings[0].url)
    }

    /// The split button's dropdown. When `showsBindingRows` it opens with one
    /// row per binding (bind order, so a row never moves under the cursor as CI
    /// states change), a `Divider()`, then the auto-archive and auto-hibernate
    /// toggles unchanged. The rows are omitted only when the label's own primary
    /// click already opens the single bound PR, where a lone row would be pure
    /// duplication — the caller decides via `prPrimaryActionURL`.
    @ViewBuilder
    private func prSplitButtonMenu(
        worktreeID: UUID,
        bindings: [PRBinding],
        showsBindingRows: Bool,
        worktreeFound: Bool,
        armed: Bool,
        hibernateArmed: Bool,
        blocked: Bool
    ) -> some View {
        if showsBindingRows && !bindings.isEmpty {
            ForEach(PRBindingPresentation.menuRows(bindings)) { row in
                Button(row.title) {
                    guard let url = row.url else { return }
                    appState.openPR(url: url, number: row.number, worktreeID: worktreeID)
                }
                .disabled(row.url == nil)
            }
            Divider()
        }
        if worktreeFound {
            // `armed` is captured at materialization time; the .id
            // rebuild at the call site is what refreshes the checkmark
            // (getter re-evaluations never reach the materialized NSMenu).
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
    }

    /// The split button's tooltip, as an ordered clause list so "more options"
    /// is structurally guaranteed to land last, whatever combination of arm
    /// states applies. The archive clause keeps its three-way wording: while
    /// child worktrees exist the daemon's `AutoArchiveOnMergeCoordinator` skips
    /// archiving (it re-checks active children at merge time), so an
    /// armed-but-blocked worktree must not promise "auto-archives on merge".
    ///
    /// Static and pure so the wording can be exercised without a toolbar.
    static func prSplitButtonHelp(
        bindings: [PRBinding],
        armed: Bool,
        hibernateArmed: Bool,
        blocked: Bool,
        freshnessClauses: [String] = []
    ) -> String {
        var clauses: [String] = []
        switch bindings.count {
        case 0: break
        case 1:
            // "Open" is a promise about the primary click, so it is made only
            // when there IS one — a lone binding whose URL will not parse gets
            // named, not offered.
            clauses.append(prPrimaryActionURL(bindings) == nil
                           ? bindings[0].refLabel
                           : "Open \(bindings[0].refLabel)")
        // Neutral wording, deliberately: a worktree can hold bindings on both
        // forges, so no single vocabulary would be true of the whole set.
        default: clauses.append("\(bindings.count) pull requests")
        }
        if armed && blocked {
            clauses.append("auto-archive armed (paused while child worktrees exist)")
        } else if armed {
            clauses.append("auto-archives on merge")
        }
        if hibernateArmed { clauses.append("auto-hibernates on merge") }
        // The cache states its own age here, and says when its last re-read
        // failed. This string is materialized once by AppKit, so the freshness
        // clauses are also part of the `.id` key — otherwise the age would
        // freeze at whatever it was when the item was first built.
        clauses += freshnessClauses
        clauses.append("more options")
        return clauses.joined(separator: " · ")
    }
}

// MARK: - DetailSectionHostPager

/// NSViewControllerRepresentable hosting `ContentView`'s entire `detail:`
/// content as exactly three `NSTabViewController` tab items: `.remote` (the
/// sticky `RemoteSessionDetailView` host — mounted once a remote session
/// has ever been selected and NEVER removed afterward), `.providerDesk`
/// (the read-only `RemoteProviderDeskView`), and `.other`
/// (whichever worktree/repo/scratch/empty/disconnected content currently
/// applies — cheap to recreate on every switch, exactly as before; local
/// worktree reattach is already instant via the daemon's own tmux sessions,
/// so that half never needed keep-alive).
///
/// The Provider Desk is a SEPARATE tab rather than a second thing the
/// `.remote` tab can render, and that is load-bearing: swapping the
/// `.remote` slot's root view between `RemoteSessionDetailView` and the
/// desk would structurally remove the detail view, dismantling the
/// `RemoteAttachPager` it hosts and tearing down EVERY live attach
/// connection — precisely the teardown the next paragraph explains this
/// whole pager exists to prevent. Selecting a provider is a read-only
/// glance at the fleet; it must not cost a full SSM/ssh reconnect on the
/// way back.
///
/// This exists because navigating OUT of remote-session mode (selecting a
/// worktree/repo/scratch section) used to unmount `RemoteSessionDetailView`
/// entirely, tearing down every live `RemoteAttachPager` connection it
/// hosted — turning "switch back to the remote session" into a slow, full
/// SSM/ssh reconnect instead of an instant resume. Hoisting the `.remote`
/// slot here, one level above where sections get fully swapped, is what
/// lets it survive that excursion.
///
/// Why `NSTabViewController` rather than a plain SwiftUI `ZStack` +
/// `.opacity`/`.allowsHitTesting`: this codebase already hit exactly this
/// class of bug once — see `WorktreePager`'s doc comment and
/// `docs/superpowers/specs/research-2026-05-06-zstack-event-leak.md`.
/// `.opacity(0)` leaves the underlying AppKit view fully attached to the
/// window (`window != nil`, `isHidden == false`), so `TBDTerminalView`'s
/// shared click-passthrough `NSEvent` monitor — which decides whether to
/// fire based on `window != nil` plus a raw geometric bounds check, not
/// SwiftUI's hit-testing/opacity — would keep matching a merely-invisible
/// remote terminal that happens to share the exact same screen rect as
/// whatever IS visible on top of it, forwarding clicks meant for the
/// worktree page into the hidden remote session's pty. `NSTabViewController`
/// tab-switching genuinely detaches the non-selected tab's content view
/// (`window == nil`), which is the actual invariant `TBDTerminalView`'s
/// monitor teardown already depends on for local worktree terminals (see
/// the `tv.window != nil` guards in `TerminalPanelView`).
///
/// Each tab's content is a small internally-reactive wrapper — it reads
/// `@Environment`/`@AppStorage` state itself rather than being handed a
/// fresh value on every `updateNSViewController` — so its
/// `NSHostingController` is created exactly once and its `rootView` is
/// never reassigned: the same "stable identity, reactive interior" shape
/// `WorktreePager`/`RemoteAttachPager` already use for their own tab items.
struct DetailSectionHostPager: NSViewControllerRepresentable {
    /// Which of the three tab items should be in front.
    enum DetailTab: String, Equatable {
        case remote
        case providerDesk
        case other
    }

    /// Resolved by the caller's `body` rather than read from `appState` here —
    /// see the call site in `ContentView.body` for why. Changing it is what
    /// drives `updateNSViewController` to bring a different tab forward.
    let targetTab: DetailTab

    @Environment(AppState.self) var appState
    @EnvironmentObject var appearance: AppearanceSettings
    @EnvironmentObject var overlayCoordinator: TranscriptOverlayCoordinator

    private static let remoteTabID = DetailTab.remote.rawValue
    private static let providerDeskTabID = DetailTab.providerDesk.rawValue
    private static let otherTabID = DetailTab.other.rawValue

    func makeNSViewController(context: Context) -> NSTabViewController {
        let vc = NSTabViewController()
        vc.tabStyle = .unspecified
        vc.transitionOptions = []
        return vc
    }

    func updateNSViewController(_ vc: NSTabViewController, context: Context) {
        let currentIDs = Set(vc.tabViewItems.compactMap { $0.identifier as? String })

        if !currentIDs.contains(Self.remoteTabID) {
            let host = NSHostingController(
                rootView: RemoteSessionHostSlot()
                    .environment(appState)
                    .environmentObject(appearance)
            )
            let item = NSTabViewItem(viewController: host)
            item.identifier = Self.remoteTabID
            vc.addTabViewItem(item)
        }

        if !currentIDs.contains(Self.providerDeskTabID) {
            let host = NSHostingController(
                rootView: ProviderDeskHostSlot()
                    .environment(appState)
                    .environmentObject(appearance)
            )
            let item = NSTabViewItem(viewController: host)
            item.identifier = Self.providerDeskTabID
            vc.addTabViewItem(item)
        }

        if !currentIDs.contains(Self.otherTabID) {
            let host = NSHostingController(
                rootView: OtherSectionContent()
                    .environment(appState)
                    .environmentObject(overlayCoordinator)
            )
            let item = NSTabViewItem(viewController: host)
            item.identifier = Self.otherTabID
            vc.addTabViewItem(item)
        }

        let targetID = targetTab.rawValue
        if let idx = vc.tabViewItems.firstIndex(where: { $0.identifier as? String == targetID }),
           vc.selectedTabViewItemIndex != idx {
            vc.selectedTabViewItemIndex = idx
        }
    }

    /// Which tab should be in front. Disconnected always wins, matching the
    /// former if/else's top-priority `!appState.isConnected` check —
    /// `OtherSectionContent` renders the disconnected message itself, so
    /// this just makes sure that's the tab actually in front while
    /// disconnected, regardless of whatever remote session was selected
    /// before the daemon dropped. A session selection outranks a provider
    /// selection; the two are already mutually exclusive in `AppState`, so
    /// the order only decides an unreachable tie deterministically. Pure and
    /// `nonisolated` so it's directly unit-testable without an
    /// `NSTabViewController`.
    nonisolated static func targetTab(
        isConnected: Bool,
        selectedRemoteSession: RemoteSessionSelection?,
        selectedRemoteProvider: String?
    ) -> DetailTab {
        guard isConnected else { return .other }
        if selectedRemoteSession != nil { return .remote }
        if selectedRemoteProvider != nil { return .providerDesk }
        return .other
    }
}

/// The `.remote` tab's content. Internally reactive — reads
/// `AppState.remoteSessionHostSelection` itself on every body evaluation —
/// so `DetailSectionHostPager` never needs to reassign this tab's
/// `NSHostingController.rootView`; only the `selection` value `body`
/// resolves to changes across renders, which is exactly the "same view
/// identity, new property value" update `RemoteSessionDetailView` is
/// already built to handle (see its own doc comment on why it's not
/// `.id()`-keyed).
private struct RemoteSessionHostSlot: View {
    @Environment(AppState.self) var appState

    var body: some View {
        if let selection = appState.remoteSessionHostSelection {
            RemoteSessionDetailView(selection: selection)
        } else {
            EmptyView()
        }
    }
}

/// The `.providerDesk` tab's content. Internally reactive for the same
/// reason `RemoteSessionHostSlot` is — `DetailSectionHostPager` creates this
/// `NSHostingController` once and never reassigns its `rootView`.
///
/// Renders nothing when the selected provider is no longer in the roster.
/// `AppState.refreshRemote()` clears `selectedRemoteProvider` when a
/// provider disappears from a successful inventory, so this is a transient
/// window rather than a resting state — and the desk has no honest content
/// to show for a provider TBD no longer knows about.
private struct ProviderDeskHostSlot: View {
    @Environment(AppState.self) var appState

    var body: some View {
        if let name = appState.selectedRemoteProvider,
           let provider = appState.remoteProviders.first(where: { $0.config.name == name }) {
            RemoteProviderDeskView(provider: provider)
        } else {
            EmptyView()
        }
    }
}

/// The `.other` tab's content: the non-remote top-level sections
/// (disconnected/scratch/repo/empty/worktree). Pure relocation of
/// `ContentView`'s former `detailContent` computed property, minus the
/// remote-session branch (now `RemoteSessionHostSlot`'s job) — same
/// conditions, same order, same views.
private struct OtherSectionContent: View {
    @AppStorage(FilePanelStorageKey.isVisible) private var showFilePanel = true
    @AppStorage(FilePanelStorageKey.width) private var filePanelWidth: Double = 280

    @Environment(AppState.self) var appState
    @EnvironmentObject var overlayCoordinator: TranscriptOverlayCoordinator

    var body: some View {
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
            WorktreeDetailAreaView(showFilePanel: $showFilePanel, filePanelWidth: $filePanelWidth)
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
}

// MARK: - WorktreeDetailAreaView

/// The terminal-grid branch of `OtherSectionContent` (`DetailSectionHostPager`'s
/// `.other` tab) — rendered when a worktree (not a remote session, scratch
/// section, or repo-only selection) is what's showing: `TerminalContainerView`
/// + the optional file panel, the overlay coordinator's transcript overlay,
/// and the window-wide click-outside catcher.
///
/// `showFilePanel`/`filePanelWidth` stay `@Binding`: the stable
/// `OtherSectionContent` host owns the corresponding `@AppStorage` values and
/// passes live bindings into this branch. `ContentView` independently observes
/// the same centralized visibility key for its toolbar action.
/// `contentAreaHeight` moves in as this view's own `@State` instead: nothing
/// outside this branch ever read it in `ContentView`.
private struct WorktreeDetailAreaView: View {
    @Environment(AppState.self) var appState
    @EnvironmentObject var overlayCoordinator: TranscriptOverlayCoordinator
    @Binding var showFilePanel: Bool
    @Binding var filePanelWidth: Double
    @State private var contentAreaHeight: CGFloat = 600

    /// The file panel reads a directory, so it binds to the local-only
    /// selection. `LocalWorktree` subsumes the empty-path check this used to
    /// spell out — the optimistic `.creating` placeholder has no directory yet
    /// and does not convert.
    private var selectedLocalWorktree: LocalWorktree? {
        appState.selectedLocalWorktree
    }

    var body: some View {
        HStack(spacing: 0) {
            TerminalContainerView()
            if showFilePanel, let worktree = selectedLocalWorktree {
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
    /// Every live PR bound to the worktree, in bind order. One binding renders
    /// exactly as the pre-multi-PR label did (`#412`); several collapse to a
    /// count (`3 PRs`), because the flattened toolbar label has room for only
    /// one string and one image.
    let bindings: [PRBinding]
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

    /// The status the single icon stands for: the binding needing the most
    /// attention. nil when nothing is bound, or when the worst binding has
    /// never been polled — either way there is no icon to bake.
    var prStatus: PRStatus? { PRBindingPresentation.iconBinding(bindings)?.status }

    /// A queued PR renders the full-color bus (with its position baked in)
    /// instead of the status icon; BOTH armed badges are suppressed in that
    /// mode (the bus owns the label), so the baked image stays a single square.
    var isMergeQueued: Bool { prStatus?.mergeQueuePosition != nil }

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
    /// hibernate Toggle's checkmark would freeze at its first-render value.
    ///
    /// EVERY binding contributes, not just the worst one that drives the icon:
    /// with several PRs bound, the menu lists one row per binding, so a change
    /// to any of them changes what is rendered. Per binding the key carries
    /// exactly the fields the label/menu/primaryAction consume: `number` (label
    /// text, help, menu row), `state` (icon via `PRStatusPresentation`, menu row
    /// reason), `url` (captured by the row's action and by `primaryAction`, so a
    /// re-pointed PR must recreate the item too), `mergeQueuePosition` (the bus
    /// glyph short-circuits on it and bakes the position into the icon, so a
    /// 2→1 queue move with an unchanged `state` must still rebuild),
    /// `detached` (a tombstoned binding drops out of the label count), and
    /// `PRStatus.reason` + `headBranch` — `PRBindingPresentation.menuRows`
    /// renders BOTH into every row title, so "1 check failing" → "3 checks
    /// failing" under an unchanged `.checksFailed`, or a re-pushed head branch,
    /// would otherwise leave the materialized menu showing the stale text.
    ///
    /// `freshnessClauses` is in the key for the same reason: the help string
    /// renders the cache's age and any unresolved last check, so an item built
    /// before those words changed would keep promising a freshness it no longer
    /// has. Note it is the *rendered clauses*, not the raw `observedAt` — the
    /// clauses are bucketed (see `PRFreshness`), so a re-confirmation that does
    /// not change the displayed words rebuilds nothing.
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
        bindings: [PRBinding],
        freshnessClauses: [String] = [],
        colorScheme: ColorScheme
    ) -> String {
        let rendered = bindings.map { binding in
            let status = binding.status
            return "\(binding.number)-\(status?.state.rawValue ?? "nil")-\(escapedIDField(binding.url))"
                + "-\(status?.mergeQueuePosition.map(String.init) ?? "nil")"
                + "-\(binding.detached)"
                + "-\(escapedIDField(status?.reason))"
                + "-\(escapedIDField(binding.headBranch))"
        }.joined(separator: "|")
        return "pr-split-\(worktreeID)-\(worktreeFound)-\(armed)-\(hibernateArmed)-\(blocked)"
            + "-[\(rendered)]"
            + "-[\(freshnessClauses.map(escapedIDField).joined(separator: "|"))]"
            + "-\(colorScheme)"
    }

    /// Escapes one free-text component of `prSplitButtonID` so no value can
    /// forge the key's own separators.
    ///
    /// The key joins fields with `-` and bindings with `|`, and both characters
    /// are legal in the values it interpolates: git permits `|` in a branch
    /// name, and a PR status `reason` is whatever GitHub wrote. Unescaped, two
    /// different binding sets could render the same key — and because AppKit
    /// materializes the split button's menu ONCE per key, the collision is not
    /// cosmetic: the menu would stay frozen on the previous set for as long as
    /// the two agree.
    ///
    /// Escaping `\` first makes the mapping injective, so distinct inputs stay
    /// distinct. `nil` maps to `\0`, which escaping can never produce (its only
    /// outputs are `\\`, `\-` and `\|`), so a literal `"nil"` reason no longer
    /// reads as an absent one either.
    static func escapedIDField(_ value: String?) -> String {
        guard let value else { return #"\0"# }
        return value
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: "-", with: #"\-"#)
            .replacingOccurrences(of: "|", with: #"\|"#)
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
            if let prStatus,
               let presentation = PRStatusPresentation.make(for: prStatus),
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
            // INTO the single baked NSImage. The same flattening is why a
            // several-PR count lives in this text ("3 PRs") rather than in a
            // second image or badge glyph.
            Text(verbatim: PRBindingPresentation.buttonLabel(bindings) ?? "")
                .font(.caption)
                .fontWeight(.medium)
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var clauses: [String] = []
        switch bindings.count {
        // The zero and several arms keep neutral wording — a worktree can span
        // forges, so only the single-binding arm can speak one forge's dialect.
        case 0: clauses.append("No pull requests")
        case 1: clauses.append(bindings[0].refLabel)
        default: clauses.append("\(bindings.count) pull requests")
        }
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
