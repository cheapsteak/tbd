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
///   `uninstall(fallbackWindow:)` stops the watching and takes the toolbar off.
/// - **Update loop.** `DockTableController`'s: `MainToolbarSnapshot.make(from:)`
///   runs inside `withObservationTracking`, and a change schedules one apply on
///   the next main-loop turn, outside SwiftUI's update pass. Only the newest
///   registration acts on a change (see `observedChange(generation:)`).
/// - **Apply.** Re-installs the toolbar if something replaced it on the window,
///   diffs the items against `MainToolbarLayout.identifiers(for:)` with inserts
///   and removes only, so the items both layouts share are never rebuilt, then
///   updates the present items' content in place, setting only what changed.
/// - **Replacement.** A replaced toolbar schedules an apply at once, through
///   KVO on `window.toolbar`, so it does not wait for an unrelated change. A
///   window that keeps replacing it is left alone after
///   `maxReinstallBurst` re-installs in quick succession, so the two never
///   ping-pong.
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

    /// How many re-installs in a row, each within `reinstallBurstWindow` of
    /// the attempt before it, the toolbar gets before the controller stops
    /// putting it back and logs an error. Whatever keeps replacing it and this
    /// controller would otherwise trade the window's toolbar on every turn.
    static let maxReinstallBurst = 3

    /// Seconds between re-install attempts beyond which a new burst starts.
    /// A replacement after a quiet spell is re-installed again.
    static let reinstallBurstWindow: TimeInterval = 1

    let toolbar: NSToolbar
    let appState: AppState
    /// The title cluster's view, placed in the title item as it is.
    let titleView: NSView
    /// Raises the Stop confirmation, which `ContentView` owns.
    var requestRemoteStop: (RemoteSessionSelection) -> Void

    private(set) weak var window: NSWindow?
    private(set) weak var split: MainSplitViewController?

    /// Between `install(on:split:)` and `uninstall(fallbackWindow:)`: the
    /// stretch in which a replaced toolbar is put back.
    private(set) var isInstalled = false

    /// The collapsed state the layout is computed for, as the split last
    /// reported it.
    private(set) var sidebarCollapsed = false

    /// The snapshot the last apply used. A click reads what the toolbar shows
    /// from it, such as the Servers button's main URL.
    private(set) var appliedSnapshot: MainToolbarSnapshot?

    /// Applies run so far, for the debug log and for tests.
    private(set) var applyCount = 0
    /// Observed `AppState` changes that scheduled an apply, for the debug log
    /// and for tests: a stale registration's change is not counted.
    private(set) var observedChangeCount = 0

    /// Whether an apply is queued. `scheduleApply()` sets it and enqueues one
    /// apply; `applyNow()` clears it.
    private(set) var applyScheduled = false

    /// Bumped by each apply, which arms a fresh observation registration.
    private var observationGeneration = 0
    private var appearanceObservation: NSKeyValueObservation?
    private var toolbarObservation: NSKeyValueObservation?

    /// When re-installs are attempted, for the burst count. Injected so a test
    /// can place attempts inside or outside one window.
    private let now: @Sendable () -> Date
    private var reinstallBurst = 0
    private var lastReinstallAttempt: Date?

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
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.appState = appState
        self.titleView = titleView
        self.requestRemoteStop = requestRemoteStop
        self.now = now
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
    /// call again for the same window.
    func install(on window: NSWindow, split: MainSplitViewController) {
        // Before the toolbar is set: setting it asks the delegate for items,
        // and the tracking separator needs the split.
        self.window = window
        self.split = split
        sidebarCollapsed = split.isSidebarCollapsed
        split.onSidebarCollapsedChange = { [weak self] collapsed in
            self?.sidebarCollapsedChanged(collapsed)
        }
        if window.toolbar !== toolbar {
            attach(to: window)
        }
        isInstalled = true
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
    /// first, so the removal is not taken for a replacement. `fallbackWindow`
    /// is checked when the toolbar was never installed. Safe to call again.
    func uninstall(fallbackWindow: NSWindow? = nil) {
        isInstalled = false
        appearanceObservation = nil
        toolbarObservation = nil
        if let window = window ?? fallbackWindow, window.toolbar === toolbar {
            window.toolbar = nil
        }
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

    /// The window's `toolbar` changed. Anything but ours schedules the apply
    /// that puts ours back.
    private func windowToolbarChanged() {
        guard isInstalled, let window, window.toolbar !== toolbar else { return }
        scheduleApply()
    }

    /// Puts the toolbar back on `window`, unless this attempt is past
    /// `maxReinstallBurst` in the current burst. Every attempt, refused or
    /// not, extends the burst, so a window that keeps replacing the toolbar
    /// stays refused until it has been quiet for `reinstallBurstWindow`.
    private func reinstall(on window: NSWindow) {
        let attempt = now()
        if let last = lastReinstallAttempt, attempt.timeIntervalSince(last) <= Self.reinstallBurstWindow {
            reinstallBurst += 1
        } else {
            reinstallBurst = 1
        }
        lastReinstallAttempt = attempt
        guard reinstallBurst <= Self.maxReinstallBurst else {
            // Once per burst, not once per refused attempt.
            if reinstallBurst == Self.maxReinstallBurst + 1 {
                let cap = Self.maxReinstallBurst
                let spacing = Self.reinstallBurstWindow
                let found = window.toolbar?.identifier ?? "none"
                toolbarLogger.error("""
                    Main toolbar was put back \(cap, privacy: .public) times, each within \
                    \(spacing, privacy: .public) s of the last, and replaced again; leaving the window's toolbar \
                    (\(found, privacy: .public)) in place until the replacements stop
                    """)
            }
            return
        }
        toolbarLogger.info("Main toolbar was replaced on its window; re-installing it")
        attach(to: window)
    }

    // MARK: The update loop

    /// Schedules one apply on the next main-loop turn; further calls before it
    /// runs are covered by it.
    func scheduleApply() {
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.applyNow() }
        }
    }

    /// The scheduled apply. `scheduleApply()` enqueues it only while none is
    /// queued, and only this clears the flag, so the flag is always set here.
    /// After `uninstall`, a queued apply does nothing.
    private func applyNow() {
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
        apply(snapshot)
    }

    /// A registration armed by the apply numbered `generation` saw a change.
    /// Every apply arms one, including the applies observation did not
    /// trigger, and a one-shot registration cannot be cancelled, so only the
    /// newest acts: the older ones track the same reads and would only
    /// schedule again.
    private func observedChange(generation: Int) {
        guard generation == observationGeneration else { return }
        observedChangeCount += 1
        scheduleApply()
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
        // toolbar; ours comes back here.
        if isInstalled, let window, window.toolbar !== toolbar {
            reinstall(on: window)
        }
        applyLayout(MainToolbarLayout.identifiers(for: snapshot.layoutState(sidebarCollapsed: sidebarCollapsed)))
        updateContent(snapshot)
    }

    private func applyLayout(_ target: [NSToolbarItem.Identifier]) {
        let current = toolbar.items.map(\.itemIdentifier)
        let edits = MainToolbarLayout.edits(from: current, to: target)
        guard !edits.isEmpty else { return }
        MainToolbarLayout.perform(
            edits,
            remove: { index in toolbar.removeItem(at: index) },
            insert: { identifier, index in toolbar.insertItem(withItemIdentifier: identifier, at: index) })
        let result = toolbar.items.map(\.itemIdentifier)
        if result == target {
            toolbarLogger.debug("Main toolbar applied \(edits.count, privacy: .public) edits")
        } else {
            // An insert the delegate could not serve leaves the item out.
            let shown = result.map(\.rawValue).joined(separator: ",")
            let wanted = target.map(\.rawValue).joined(separator: ",")
            toolbarLogger.error(
                "Main toolbar shows [\(shown, privacy: .public)], wanted [\(wanted, privacy: .public)]")
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
