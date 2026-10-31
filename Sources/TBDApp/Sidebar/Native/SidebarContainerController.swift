import AppKit

/// The native sidebar's root: the outline's scroll view filling the column,
/// then a divider and the pinned dock along the bottom edge — the stack the
/// SwiftUI path's footer group draws, where one divider tops the dock and the
/// footer beneath it.
///
/// The dock's height is `PinnedDockMetrics.height(rowCount:availableHeight:)`:
/// at most five rows and 40% of the height the outline shares with it. It is
/// recomputed on every layout and whenever the dock's row count changes.
@MainActor
final class SidebarContainerController: NSViewController {
    /// The divider between the outline and the dock, as SwiftUI's `Divider`.
    static let dividerThickness: CGFloat = 1

    let outlineController: SidebarOutlineController
    let dockController: DockTableController
    /// The dock's backdrop, pinned to the bottom edge: the bar material the
    /// SwiftUI footer beneath it draws, so the dock and the footer read as one
    /// group.
    let dockSlot = NSVisualEffectView(frame: .zero)
    private(set) var dockHeight: NSLayoutConstraint?

    /// - Parameter sheets: the slot `NativeSidebarView` presents the
    ///   sidebar's sheets from, shared by the outline and the dock.
    init(appState: AppState, defaults: UserDefaults, sheets: NativeSidebarSheetPresenter? = nil) {
        let presenter = sheets ?? NativeSidebarSheetPresenter()
        let outline = SidebarOutlineController(appState: appState, defaults: defaults, sheets: presenter)
        outlineController = outline
        // The dock dims a missing scratch directory from the outline's
        // answers, probed off the main thread; it never reads the disk itself.
        dockController = DockTableController(
            appState: appState, defaults: defaults, sheets: presenter,
            directoryExists: { [weak outline] path in outline?.scratchDirectoryExists[path] ?? true })
        super.init(nibName: nil, bundle: nil)
        let dock = dockController
        outline.onScratchDirectoriesChanged = { [weak dock] in dock?.scheduleRebuild() }
        dock.onRowCountChange = { [weak self] in self?.updateDockHeight() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: .zero)
        addChild(outlineController)
        addChild(dockController)
        let outlineView = outlineController.view
        let dockView = dockController.view
        let divider = NSBox(frame: .zero)
        divider.boxType = .separator
        dockSlot.material = .titlebar
        dockSlot.blendingMode = .withinWindow
        dockSlot.state = .followsWindowActiveState
        for view in [outlineView, divider, dockSlot, dockView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        root.addSubview(outlineView)
        root.addSubview(divider)
        root.addSubview(dockSlot)
        dockSlot.addSubview(dockView)
        let dockHeight = dockSlot.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            outlineView.topAnchor.constraint(equalTo: root.topAnchor),
            outlineView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            outlineView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outlineView.bottomAnchor.constraint(equalTo: divider.topAnchor),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: Self.dividerThickness),
            divider.bottomAnchor.constraint(equalTo: dockSlot.topAnchor),
            dockSlot.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            dockSlot.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            dockSlot.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            dockHeight,
            dockView.topAnchor.constraint(equalTo: dockSlot.topAnchor),
            dockView.leadingAnchor.constraint(equalTo: dockSlot.leadingAnchor),
            dockView.trailingAnchor.constraint(equalTo: dockSlot.trailingAnchor),
            dockView.bottomAnchor.constraint(equalTo: dockSlot.bottomAnchor),
        ])
        self.dockHeight = dockHeight
        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateDockHeight()
    }

    /// The height the outline shares with the dock: the outline's own plus
    /// the dock's, which is the column below the divider's line. Measured that
    /// way, never as the outline's height alone, so the dock's height never
    /// feeds back into its own input — the reason `SidebarView` measures its
    /// `List` and never the dock.
    var dockAvailableHeight: CGFloat {
        max((viewIfLoaded?.bounds.height ?? 0) - Self.dividerThickness, 0)
    }

    /// Sizes the dock for its rows. A layout pass after a change finds the
    /// height already right, so it settles in one extra pass.
    func updateDockHeight() {
        guard let dockHeight else { return }
        let height = PinnedDockMetrics.height(
            rowCount: dockController.rows.count, availableHeight: dockAvailableHeight)
        guard height != dockHeight.constant else { return }
        dockHeight.constant = height
    }
}
