import AppKit
import SwiftUI
import TBDShared

struct ContentView: View {
    @Environment(AppState.self) var appState
    @EnvironmentObject var overlayCoordinator: TranscriptOverlayCoordinator
    /// The remote session whose toolbar Stop is awaiting confirmation. Holds
    /// the selection itself, not a Bool, so the dialog stops the session it
    /// was raised for even if the selection has moved on.
    @State private var remoteStopConfirm: RemoteSessionSelection?

    /// The `@AppStorage` store for the window's hosted panes, which do not
    /// inherit this view's. `nil` leaves them on `.standard`, as the app's
    /// window root is.
    let hostedAppStorage: UserDefaults?

    /// Spelled out because the private `@State` and `@Environment` properties
    /// would make the memberwise initializer private.
    ///
    /// - Parameter hostedAppStorage: the test seam that mirrors a test root's
    ///   `.defaultAppStorage` into the window's hosted panes. The app
    ///   sets none on its root and passes none here, so the panes read
    ///   `.standard`, as the root does.
    init(hostedAppStorage: UserDefaults? = nil) {
        self.hostedAppStorage = hostedAppStorage
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

            // Same slot, same contract: advisory, non-blocking, dismissible.
            // A newer TBD exists on `main` than the one running. Dismissal is
            // per commit, so waving it away does not hide the next one.
            if let notice = appState.updateNoticeMessage {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    Text(notice).font(.caption)
                    Spacer()
                    Button("Dismiss") {
                        appState.dismissUpdateNotice()
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.blue.opacity(0.15))
            }

            // Auto-update is on, so no banner — but a build that has waited
            // over a day is worth one quiet line.
            if let idle = appState.updateIdleLine() {
                HStack(spacing: 6) {
                    Text(idle).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") {
                        appState.dismissUpdateNotice()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            // The window's split and its `NSToolbar`, all AppKit. The split
            // reaches up under the toolbar and down to the window's bottom
            // edge; each pane's hosted content keeps its own safe area. The
            // status bar is the content pane's, in `MainDetailArea`.
            MainWindowSplitView(
                requestRemoteStop: { remoteStopConfirm = $0 }, appStorage: hostedAppStorage)
                .ignoresSafeArea(.container, edges: .top)
                // The Servers item's list whenever a single worktree becomes
                // selected (the toolbar menu exposes no reliable will-open
                // hook). Selection is not a gesture on the servers, so repo
                // `status` commands do not run here; actions, "Refresh status"
                // and `devServersChanged` deltas refresh it from `AppState`.
                .task(id: appState.selectedWorktreeIDs.count == 1 ? appState.selectedWorktreeIDs.first : nil) {
                    guard appState.selectedWorktreeIDs.count == 1, let id = appState.selectedWorktreeIDs.first else { return }
                    await appState.refreshDevServers(worktreeID: id, trigger: .selection)
                }
        }
        .frame(minWidth: 800, minHeight: 500)
        .overlay(alignment: .bottomTrailing) { ToastOverlay() }
        .confirmationDialog(
            "Stop \(remoteStopConfirm.map { appState.remoteSessionDisplayName(for: $0) } ?? "session")?",
            isPresented: Binding(
                get: { remoteStopConfirm != nil },
                set: { if !$0 { remoteStopConfirm = nil } }
            ),
            titleVisibility: .visible,
            presenting: remoteStopConfirm
        ) { selection in
            Button("Stop", role: .destructive) {
                // Re-checked at confirm time: the session may have gone, or
                // the inventory turned stale, while the dialog was open.
                guard appState.remoteSessionShowsStop(selection) else { return }
                Task { await appState.stopRemoteSession(selection) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This asks the provider to terminate the remote session.")
        }
        // Withdraws the dialog once Stop stops being offered for the session
        // it was raised for, rather than leaving a confirm that can't act.
        .onChange(of: remoteStopConfirm.map { appState.remoteSessionShowsStop($0) }) { _, stillOffered in
            if stillOffered == false { remoteStopConfirm = nil }
        }
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
            // Read once: every button below closes the alert, which clears
            // the path, so each action must use this captured copy.
            if let path = appState.alertRevealPath {
                Button("Copy Path") {
                    appState.pasteboardWriter(path)
                    appState.alertMessage = nil
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    appState.alertMessage = nil
                }
            }
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
}

// MARK: - DetailSectionHostPager

/// NSViewControllerRepresentable hosting the main window's entire detail
/// area as exactly three `NSTabViewController` tab items: `.remote` (the
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
    /// see `MainDetailArea` for why. Changing it is what drives
    /// `updateNSViewController` to bring a different tab forward.
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
    @Environment(AppState.self) var appState
    @EnvironmentObject var overlayCoordinator: TranscriptOverlayCoordinator
    @State private var showingClone = false

    var body: some View {
        // On this host rather than on the empty state that opens it: the
        // empty state goes away the moment a repo exists or the daemon drops,
        // and a sheet that went with it would cancel a clone still running.
        content
            .sheet(isPresented: $showingClone) {
                CloneRepositorySheet()
            }
    }

    /// Chosen by `MainDetailContent.otherTab`, the function the toolbar's
    /// choice of whether to keep its title also comes from.
    @ViewBuilder
    private var content: some View {
        switch MainDetailContent.otherTab(in: appState) {
        case .disconnected:
            disconnectedView
        case .scratchSection:
            ScratchDetailView()
        case .noRepositories:
            emptyStateView
        case .repo(let repoID):
            RepoDetailView(repoID: repoID)
        case .nothingSelected, .remoteSession, .providerDesk:
            // `otherTab` never answers either remote case; those are the
            // pager's other tabs.
            Text("Select a worktree or click + to create one")
                .foregroundStyle(.secondary)
        case .multipleWorktrees, .worktree:
            WorktreeDetailAreaView()
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

            Button {
                showingClone = true
            } label: {
                Label("Clone Repository…", systemImage: "arrow.down.circle")
            }
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
        AddRepositoryPanel.run(appState: appState)
    }
}

// MARK: - WorktreeDetailAreaView

/// The terminal-grid branch of `OtherSectionContent` (`DetailSectionHostPager`'s
/// `.other` tab) — rendered when a worktree (not a remote session, scratch
/// section, or repo-only selection) is what's showing: `TerminalContainerView`,
/// the overlay coordinator's transcript overlay, and the window-wide
/// click-outside catcher.
private struct WorktreeDetailAreaView: View {
    @Environment(AppState.self) var appState
    @EnvironmentObject var overlayCoordinator: TranscriptOverlayCoordinator

    var body: some View {
        TerminalContainerView()
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
