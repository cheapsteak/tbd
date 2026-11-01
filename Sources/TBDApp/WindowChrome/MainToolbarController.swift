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
///   window's appearance. It sets nothing on the toolbar beyond
///   `window.toolbar`; every item change goes through `scheduleApply()`.
/// - **Update loop.** `DockTableController`'s: `MainToolbarSnapshot.make(from:)`
///   runs inside `withObservationTracking`, and a change schedules one apply on
///   the next main-loop turn, outside SwiftUI's update pass.
/// - **Apply.** Re-installs the toolbar if something replaced it on the window,
///   diffs the items against `MainToolbarLayout.identifiers(for:)` with inserts
///   and removes only, so the items both layouts share are never rebuilt, then
///   updates the present items' content in place.
///
/// Spec: docs/specs/2026-11-01-appkit-window-chrome-design.md, "The toolbar"
/// and "Width".
@MainActor
final class MainToolbarController: NSObject, NSToolbarDelegate, NSMenuDelegate {
    /// One main window, so one toolbar under this identifier. Toolbars that
    /// share an identifier mirror each other's item changes, which is why
    /// tests pass identifiers of their own.
    nonisolated static let toolbarIdentifier = NSToolbar.Identifier("tbd.mainToolbar")

    let toolbar: NSToolbar
    let appState: AppState
    /// The title cluster's view, placed in the title item as it is.
    let titleView: NSView
    /// Raises the Stop confirmation, which `ContentView` owns.
    var requestRemoteStop: (RemoteSessionSelection) -> Void

    private(set) weak var window: NSWindow?
    private(set) weak var split: MainSplitViewController?

    /// The collapsed state the layout is computed for, as the split last
    /// reported it.
    private(set) var sidebarCollapsed = false

    /// The snapshot the last apply used. A click reads what the toolbar shows
    /// from it, such as the Servers button's main URL.
    private(set) var appliedSnapshot: MainToolbarSnapshot?

    private var applyScheduled = false
    private var appearanceObservation: NSKeyValueObservation?

    // MARK: Item state, kept here so `+Items` can reach it

    /// Whether the repo filter's menu is open, so its items are not rebuilt
    /// under the pointer.
    let filterMenuTracker: FilterMenuTracker
    /// The popup the filter options were last built into, and the options.
    weak var builtFilterPopup: NSPopUpButton?
    var builtFilterOptions: [RepoFilterPresentation.Option] = []
    /// The Servers icon per running state, appearance and accessibility label.
    var serversImages: [String: NSImage] = [:]

    /// - Parameter identifier: tests pass a unique one, so toolbars from
    ///   tests running side by side do not mirror each other's items.
    init(
        appState: AppState,
        titleView: NSView,
        requestRemoteStop: @escaping (RemoteSessionSelection) -> Void,
        identifier: NSToolbar.Identifier = MainToolbarController.toolbarIdentifier
    ) {
        self.appState = appState
        self.titleView = titleView
        self.requestRemoteStop = requestRemoteStop
        toolbar = NSToolbar(identifier: identifier)
        filterMenuTracker = FilterMenuTracker()
        super.init()
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.delegate = self
        filterMenuTracker.onClose = { [weak self] in self?.scheduleApply() }
    }

    // MARK: Install

    /// Puts the toolbar on `window`, follows `split`'s collapse and the
    /// window's appearance, and schedules the first apply. Safe to call again
    /// for the same window.
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
        // The handler is `@Sendable`; AppKit changes appearance on the main
        // thread, and `performOnMain` covers any other.
        appearanceObservation = window.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainToolbarController.performOnMain { self?.scheduleApply() }
        }
        scheduleApply()
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

    // MARK: The update loop

    /// Schedules one apply on the next main-loop turn; further calls before it
    /// runs are covered by it.
    func scheduleApply() {
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.performScheduledApply() }
        }
    }

    private func performScheduledApply() {
        guard applyScheduled else { return }
        applyNow()
    }

    private func applyNow() {
        let state = appState
        let snapshot = withObservationTracking {
            MainToolbarSnapshot.make(from: state)
        } onChange: { [weak self] in
            // On the writing thread; the weak reference is read on the main
            // one, so the controller is never released anywhere else.
            MainToolbarController.performOnMain { self?.scheduleApply() }
        }
        // Anything scheduled while reading is covered by this apply; a change
        // after the tracking re-armed schedules afresh.
        applyScheduled = false
        apply(snapshot)
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
        appliedSnapshot = snapshot
        // Something else, such as a SwiftUI scene update, can set the window's
        // toolbar; ours comes back here.
        if let window, window.toolbar !== toolbar {
            toolbarLogger.info("Main toolbar was replaced on its window; re-installing it")
            attach(to: window)
        }
        applyLayout(MainToolbarLayout.identifiers(for: snapshot.layoutState(sidebarCollapsed: sidebarCollapsed)))
        updateContent(snapshot)
    }

    private func applyLayout(_ target: [NSToolbarItem.Identifier]) {
        let current = toolbar.items.map(\.itemIdentifier)
        let edits = MainToolbarLayout.edits(from: current, to: target)
        guard !edits.isEmpty else { return }
        for edit in edits {
            switch edit {
            case .remove(let index):
                toolbar.removeItem(at: index)
            case .insert(let identifier, let index):
                toolbar.insertItem(withItemIdentifier: identifier, at: index)
            }
        }
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
        makeItem(itemIdentifier)
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
