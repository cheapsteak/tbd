import AppKit
import Observation
import os
import SwiftUI

private let toolbarLogger = Logger(subsystem: "com.tbd.app", category: "window-chrome")

/// The main window's `NSToolbar` when it is built with the AppKit chrome
/// (`MainWindowChrome.appKit`): the toolbar's delegate, and the one place
/// that changes its items.
///
/// - **Install.** `install(on:split:)` puts the toolbar on the window once the
///   split appears in it, wires the split's collapse report, and watches the
///   window's appearance and its `toolbar`. It sets nothing on the toolbar
///   beyond `window.toolbar`; every item change goes through `scheduleApply()`.
///   `uninstall(fallbackWindow:)` stops the watching, takes the toolbar off
///   and lets go of the window and the split.
/// - **Update loop.** `DockTableController`'s: `MainToolbarSnapshot.make(from:)`
///   runs inside `withObservationTracking`, and a change schedules one apply on
///   the next main-loop turn, outside SwiftUI's update pass. Only the newest
///   registration acts on a change (see `observedChange(generation:)`). The
///   snapshot reads more than it shows, such as every worktree's dev-server
///   list, so an apply only an observed change asked for does nothing when
///   the snapshot, the collapse and the appearance are what the last apply
///   showed and our toolbar is on the window. Every other apply runs in full.
/// - **Apply.** Re-installs the toolbar if something replaced it on the window,
///   diffs the items against `MainToolbarLayout.identifiers(for:)` through
///   `ToolbarLayoutSync`, with inserts and removes only, so the items both
///   layouts share are never rebuilt and an edit that does not take stops the
///   rest, then updates the present items' content in place, setting only
///   what changed.
/// - **Replacement.** A change of the window's `toolbar` away from ours
///   schedules an apply at once, through KVO on `window.toolbar`, so it does
///   not wait for an unrelated change. More than `maxReplacementsInWindow`
///   replacements within `replacementWindow` start a `reinstallCooldown`, in
///   which applies and installs leave the window's toolbar alone, so the two
///   never ping-pong. When it ends, the controller schedules the apply that
///   puts the toolbar back.
///
/// Spec: docs/specs/2026-11-01-appkit-window-chrome-design.md, "The toolbar"
/// and "Width".
@MainActor
final class MainToolbarController: NSObject, NSToolbarDelegate, NSMenuDelegate {
    /// Each toolbar's identifier is this plus a UUID. Toolbars that share an
    /// identifier mirror each other's item changes; with autosave and
    /// customization off, that mirroring is the identifier's only effect, and
    /// it is unwanted — a reopened window's toolbar would follow the old one,
    /// and tests running side by side would follow each other's.
    nonisolated static let identifierPrefix = "tbd.mainToolbar."

    /// How many times something may replace the toolbar on its window within
    /// `replacementWindow` before the controller stops putting it back for
    /// `reinstallCooldown`. Whatever keeps replacing it and this controller
    /// would otherwise trade the window's toolbar on every turn.
    static let maxReplacementsInWindow = 3

    /// The span, in seconds, over which replacements are counted. A
    /// replacement older than this no longer counts.
    static let replacementWindow: TimeInterval = 1

    /// How long a toolbar that replaced ours too often stays on the window.
    static let reinstallCooldown: Duration = .seconds(5)

    let toolbar: NSToolbar
    let appState: AppState
    /// The title cluster's view, placed in the title item as it is.
    let titleView: NSView
    /// Raises the Stop confirmation, which `ContentView` owns.
    var requestRemoteStop: (RemoteSessionSelection) -> Void

    private(set) weak var window: NSWindow?
    private(set) weak var split: MainSplitViewController?

    /// Between `install(on:split:)` and `uninstall(fallbackWindow:)`: the
    /// stretch in which applies are scheduled and a replaced toolbar is put
    /// back.
    private(set) var isInstalled = false

    /// The collapsed state the layout is computed for, as the split last
    /// reported it.
    private(set) var sidebarCollapsed = false

    /// The snapshot the last apply used. A click reads what the toolbar shows
    /// from it, such as the Servers button's main URL.
    private(set) var appliedSnapshot: MainToolbarSnapshot?

    /// Applies run so far, for the debug log and for tests. An apply that
    /// found nothing to do is not counted.
    private(set) var applyCount = 0
    /// Observed `AppState` changes that scheduled an apply, for the debug log
    /// and for tests: a stale registration's change is not counted.
    private(set) var observedChangeCount = 0

    /// Whether an apply is queued. `enqueueApply()` sets it and enqueues one
    /// apply; `applyNow()` clears it.
    private(set) var applyScheduled = false
    /// Whether the queued apply runs in full. `scheduleApply()` sets it; an
    /// apply only an observed change asked for leaves it clear.
    private var queuedApplyRunsInFull = false
    /// What the last apply whose layout landed showed. An apply an observed
    /// change asked for, finding all of it as it was, has nothing to do.
    private var appliedInputs: AppliedInputs?

    /// What an apply shows: the snapshot, the collapse its layout is for and
    /// the appearance its icons are baked for.
    private struct AppliedInputs: Equatable {
        var snapshot: MainToolbarSnapshot
        var sidebarCollapsed: Bool
        var colorScheme: ColorScheme
    }

    /// Bumped by each apply, which arms a fresh observation registration.
    private var observationGeneration = 0
    /// Keeps the items in step with the layout, leaving out an item the
    /// delegate could not serve until the layout changes or an install.
    private var layoutSync = ToolbarLayoutSync()
    private var appearanceObservation: NSKeyValueObservation?
    private var toolbarObservation: NSKeyValueObservation?

    /// When each replacement happened, for the count over
    /// `replacementWindow`. A date seam rather than the clock's instants: the
    /// times are compared, never waited on, and `any Clock<Duration>` cannot
    /// subtract its own instants. Injected so a test can place replacements
    /// inside or outside one window.
    private let now: @Sendable () -> Date
    /// Waits out `reinstallCooldown`. Injected so a test drives the cooldown
    /// in virtual time.
    private let clock: any Clock<Duration>
    /// The replacements inside the current `replacementWindow`.
    private var recentReplacements: [Date] = []
    /// Whether the window showed our toolbar at the last change the watch
    /// saw, so only a change away from ours counts as a replacement.
    private var windowShowsOurToolbar = false
    /// The running cooldown. While it is set, applies and installs leave the
    /// window's toolbar alone and the watch ignores the window's changes.
    private var cooldown: Task<Void, Never>?

    /// Whether a toolbar that replaced ours too often is being left on the
    /// window. For tests.
    var isInReinstallCooldown: Bool { cooldown != nil }

    // MARK: Item state, kept here so `+Items` can reach it

    /// Whether the repo filter's menu is open, so its items are not rebuilt
    /// under the pointer.
    let filterMenuTracker: FilterMenuTracker
    /// The popup the filter options were last built into, and the options.
    weak var builtFilterPopup: NSPopUpButton?
    var builtFilterOptions: [RepoFilterPresentation.Option] = []
    /// The Servers icon per running state, appearance and accessibility label.
    var serversImages: [String: NSImage] = [:]
    /// Per item, the key its image was last derived from, so an unchanged
    /// image is not set again.
    var shownImageKeys: [NSToolbarItem.Identifier: ToolbarImageKey] = [:]

    init(
        appState: AppState,
        titleView: NSView,
        requestRemoteStop: @escaping (RemoteSessionSelection) -> Void,
        now: @escaping @Sendable () -> Date = { Date() },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.appState = appState
        self.titleView = titleView
        self.requestRemoteStop = requestRemoteStop
        self.now = now
        self.clock = clock
        toolbar = NSToolbar(identifier: MainToolbarController.identifierPrefix + UUID().uuidString)
        filterMenuTracker = FilterMenuTracker()
        super.init()
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.delegate = self
        filterMenuTracker.onClose = { [weak self] in self?.scheduleApply() }
    }

    // MARK: Install

    /// Puts the toolbar on `window`, follows `split`'s collapse, the window's
    /// appearance and its `toolbar`, and schedules the first apply. Safe to
    /// call again for the same window, as each `viewDidAppear` does. During a
    /// cooldown it records the window and the split but leaves the window's
    /// toolbar alone: a window ordered back in or unminimized must not restart
    /// the trade the cooldown stops, and the cooldown's end puts ours back.
    func install(on window: NSWindow, split: MainSplitViewController) {
        // Before the toolbar is set: setting it asks the delegate for items,
        // and the tracking separator needs the split.
        self.window = window
        self.split = split
        sidebarCollapsed = split.isSidebarCollapsed
        split.onSidebarCollapsedChange = { [weak self] collapsed in
            self?.sidebarCollapsedChanged(collapsed)
        }
        // An item a layout could not get may be servable now, as the
        // tracking separator is once the split is known.
        layoutSync.reset()
        if cooldown == nil, window.toolbar !== toolbar {
            attach(to: window)
        }
        isInstalled = true
        windowShowsOurToolbar = window.toolbar === toolbar
        // Both handlers are `@Sendable`; AppKit sets both values on the main
        // thread, and `performOnMain` covers any other. Neither reads its
        // change object. The toolbar's is registered after `attach`, so the
        // install's own set is not reported to it.
        appearanceObservation = window.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainToolbarController.performOnMain { self?.scheduleApply() }
        }
        toolbarObservation = window.observe(\.toolbar) { [weak self] _, _ in
            MainToolbarController.performOnMain { self?.windowToolbarChanged() }
        }
        scheduleApply()
    }

    /// Stops following the window and takes the toolbar off it, if it still
    /// shows it; a toolbar something else put there stays. The watching stops
    /// first, so the removal is not taken for a replacement, and a running
    /// cooldown is cancelled. Then it lets go of the window and the split,
    /// whose collapse report it unhooks, so nothing it followed schedules
    /// work and a later install, on this window or another, starts clean.
    /// `fallbackWindow` is checked when the toolbar was never installed. Safe
    /// to call again.
    func uninstall(fallbackWindow: NSWindow? = nil) {
        isInstalled = false
        appearanceObservation?.invalidate()
        appearanceObservation = nil
        toolbarObservation?.invalidate()
        toolbarObservation = nil
        cooldown?.cancel()
        cooldown = nil
        recentReplacements.removeAll()
        if let window = window ?? fallbackWindow, window.toolbar === toolbar {
            window.toolbar = nil
        }
        split?.onSidebarCollapsedChange = nil
        window = nil
        split = nil
        windowShowsOurToolbar = false
        // A registration still armed is stale from here on.
        observationGeneration &+= 1
        appliedInputs = nil
        layoutSync.reset()
    }

    private func attach(to window: NSWindow) {
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
    }

    func sidebarCollapsedChanged(_ collapsed: Bool) {
        sidebarCollapsed = collapsed
        scheduleApply()
    }

    /// The window's `toolbar` changed. A change away from ours is a
    /// replacement, and counts toward the cooldown; a change from one other
    /// toolbar to another does not. Anything but ours schedules the apply that
    /// puts ours back, unless a cooldown is running or this replacement
    /// started one. Applies never count: only the window's changes do.
    private func windowToolbarChanged() {
        guard isInstalled, let window else { return }
        let showsOurs = window.toolbar === toolbar
        let replaced = windowShowsOurToolbar && !showsOurs
        windowShowsOurToolbar = showsOurs
        guard !showsOurs, cooldown == nil else { return }
        if replaced {
            recordReplacement(leaving: window.toolbar)
            guard cooldown == nil else { return }
        }
        scheduleApply()
    }

    /// Counts a replacement, dropping those older than `replacementWindow`.
    /// One more than `maxReplacementsInWindow` starts the cooldown and clears
    /// the count, so the first replacement after the cooldown starts afresh.
    private func recordReplacement(leaving found: NSToolbar?) {
        let at = now()
        recentReplacements.removeAll { at.timeIntervalSince($0) > Self.replacementWindow }
        recentReplacements.append(at)
        guard recentReplacements.count > Self.maxReplacementsInWindow else { return }
        recentReplacements.removeAll()
        startCooldown(leaving: found)
    }

    /// Leaves `found` on the window for `reinstallCooldown`, logging once,
    /// then schedules the apply that puts our toolbar back. `uninstall`
    /// cancels it.
    private func startCooldown(leaving found: NSToolbar?) {
        let cap = Self.maxReplacementsInWindow
        let span = Self.replacementWindow
        let pause = Self.reinstallCooldown
        let foundID = found?.identifier ?? "none"
        toolbarLogger.error("""
            Main toolbar was replaced more than \(cap, privacy: .public) times within \
            \(span, privacy: .public) s; leaving the window's toolbar (\(foundID, privacy: .public)) \
            in place for \(pause.components.seconds, privacy: .public) s
            """)
        let clock = self.clock
        cooldown = Task { [weak self] in
            // A cancelled sleep throws; the check covers a cancel that lands
            // after the sleep returned.
            try? await clock.sleep(for: pause)
            guard !Task.isCancelled else { return }
            self?.cooldownEnded()
        }
    }

    /// The cooldown ran out: the scheduled apply puts the toolbar back if the
    /// window still shows another.
    private func cooldownEnded() {
        cooldown = nil
        guard isInstalled else { return }
        toolbarLogger.info("Main toolbar re-install cooldown ended")
        scheduleApply()
    }

    // MARK: The update loop

    /// Schedules one apply on the next main-loop turn, which runs in full
    /// whatever it finds; further calls before it runs are covered by it.
    /// Install, a replaced toolbar, the cooldown's end, an appearance or
    /// collapse change and the filter menu's close all come through here,
    /// since each asks for something the snapshot does not hold. Does
    /// nothing while the toolbar is not installed, such as after `uninstall`.
    func scheduleApply() {
        guard isInstalled else { return }
        queuedApplyRunsInFull = true
        enqueueApply()
    }

    /// Queues the apply, unless one is queued already.
    private func enqueueApply() {
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.applyNow() }
        }
    }

    /// The scheduled apply. `enqueueApply()` enqueues it only while none is
    /// queued, and only this clears the flag, so the flag is always set here.
    /// After `uninstall`, a queued apply does nothing. Every apply that gets
    /// past that re-arms the tracking, including one that then finds nothing
    /// to do.
    private func applyNow() {
        let runsInFull = queuedApplyRunsInFull
        queuedApplyRunsInFull = false
        guard isInstalled else {
            applyScheduled = false
            return
        }
        observationGeneration &+= 1
        let generation = observationGeneration
        let state = appState
        let snapshot = withObservationTracking {
            MainToolbarSnapshot.make(from: state)
        } onChange: { [weak self] in
            // On the writing thread; the weak reference is read on the main
            // one, so the controller is never released anywhere else.
            MainToolbarController.performOnMain { self?.observedChange(generation: generation) }
        }
        // Anything scheduled while reading is covered by this apply; a change
        // after the tracking re-armed schedules afresh.
        applyScheduled = false
        if !runsInFull, window?.toolbar === toolbar, appliedInputs == inputs(for: snapshot) {
            toolbarLogger.debug("Main toolbar apply skipped: nothing it shows changed")
            return
        }
        apply(snapshot)
    }

    /// A registration armed by the apply numbered `generation` saw a change.
    /// Every apply arms one, including the applies observation did not
    /// trigger, and a one-shot registration cannot be cancelled, so only the
    /// newest acts: the older ones track the same reads and would only
    /// schedule again. `uninstall` makes every armed one stale, so none acts
    /// after it. The apply it queues may find nothing to do.
    private func observedChange(generation: Int) {
        guard generation == observationGeneration else { return }
        observedChangeCount += 1
        enqueueApply()
    }

    private func inputs(for snapshot: MainToolbarSnapshot) -> AppliedInputs {
        AppliedInputs(snapshot: snapshot, sidebarCollapsed: sidebarCollapsed, colorScheme: currentColorScheme)
    }

    /// Runs `body` on the main actor: at once when already on the main thread,
    /// otherwise on the next main-loop turn.
    nonisolated private static func performOnMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }

    // MARK: Apply

    /// Makes the toolbar show `snapshot`. Internal so tests can drive it.
    func apply(_ snapshot: MainToolbarSnapshot) {
        applyCount += 1
        toolbarLogger.debug("Main toolbar apply \(self.applyCount, privacy: .public)")
        appliedSnapshot = snapshot
        // Something else, such as a SwiftUI scene update, can set the window's
        // toolbar; ours comes back here, except during a cooldown.
        if isInstalled, cooldown == nil, let window, window.toolbar !== toolbar {
            toolbarLogger.info("Main toolbar was replaced on its window; re-installing it")
            attach(to: window)
        }
        let landed = applyLayout(
            MainToolbarLayout.identifiers(for: snapshot.layoutState(sidebarCollapsed: sidebarCollapsed)))
        updateContent(snapshot)
        // A layout that stopped short is never taken as shown, so the next
        // apply re-diffs whatever asked for it.
        appliedInputs = landed ? inputs(for: snapshot) : nil
    }

    /// Brings the items to `target` through `layoutSync`, and returns whether
    /// they landed there, less any item the delegate could not serve. A pass
    /// that stops short logs, and when the next pass would get further,
    /// schedules the apply that re-diffs against the items as they then stand.
    private func applyLayout(_ target: [NSToolbarItem.Identifier]) -> Bool {
        let toolbar = self.toolbar
        // On a copy, so no access to the stored value is held while AppKit
        // calls into the delegate for the inserts.
        var sync = layoutSync
        let outcome = sync.pass(
            to: target,
            from: toolbar.items.map(\.itemIdentifier),
            count: { toolbar.items.count },
            remove: { index in toolbar.removeItem(at: index) },
            insert: { identifier, index in toolbar.insertItem(withItemIdentifier: identifier, at: index) })
        layoutSync = sync
        switch outcome {
        case .landed(let edits):
            if edits > 0 {
                toolbarLogger.debug("Main toolbar applied \(edits, privacy: .public) edits")
            }
            return true
        case .stopped(let stop, let retry):
            let shown = toolbar.items.map(\.itemIdentifier.rawValue).joined(separator: ",")
            let wanted = target.map(\.rawValue).joined(separator: ",")
            let next = retry ? "applying again without that item" : "waiting for the next apply"
            toolbarLogger.error("""
                Main toolbar layout stopped at \(String(describing: stop), privacy: .public): \
                shows [\(shown, privacy: .public)], wanted [\(wanted, privacy: .public)]; \
                \(next, privacy: .public)
                """)
            if retry {
                scheduleApply()
            }
            return false
        }
    }

    /// The toolbar's current item for `identifier`.
    func item(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        toolbar.items.first { $0.itemIdentifier == identifier }
    }

    // MARK: Appearance

    /// The color scheme a baked icon is drawn for under `appearance`.
    static func colorScheme(for appearance: NSAppearance) -> ColorScheme {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    /// The window's color scheme, or the app's before the toolbar has one.
    var currentColorScheme: ColorScheme {
        Self.colorScheme(for: window?.effectiveAppearance ?? NSApplication.shared.effectiveAppearance)
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        MainToolbarItemID.allowed
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let snapshot = MainToolbarSnapshot.make(from: appState)
        return MainToolbarLayout.identifiers(for: snapshot.layoutState(sidebarCollapsed: sidebarCollapsed))
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        makeItem(itemIdentifier, willBeInserted: flag)
    }

    // MARK: NSMenuDelegate (the Servers menu)

    /// Rebuilds the Servers menu from the current list each time it opens, so
    /// a list that changed since the last open never shows stale rows.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildServersMenu(menu)
    }
}

/// Follows whether the repo filter's menu is open.
@MainActor
final class FilterMenuTracker: NSObject, NSMenuDelegate {
    private(set) var isOpen = false
    var onClose: (() -> Void)?

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        onClose?()
    }
}
