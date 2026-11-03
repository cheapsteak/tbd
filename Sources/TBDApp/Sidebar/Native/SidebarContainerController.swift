import AppKit
import SwiftUI

/// The native sidebar's root: the outline's scroll view filling the column,
/// then the pinned dock along the bottom edge, the outline's bottom on the
/// dock's top. The dock and the footer beneath it (`SidebarView`) share one
/// `.bar` backdrop, which starts at the dock's top edge.
///
/// The dock's height is `PinnedDockMetrics.height(rowCount:availableHeight:)`:
/// at most five rows and 40% of the list above it. It is recomputed on every
/// layout and whenever the dock's row count changes.
///
/// The outline and the dock share one sheet presenter and one `+` menu.
@MainActor
final class SidebarContainerController: NSViewController {
    let outlineController: SidebarOutlineController
    let dockController: DockTableController
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
            directoryExists: { [weak outline] path in outline?.scratchDirectoryExists[path] ?? true },
            plusMenu: outline.plusMenu)
        super.init(nibName: nil, bundle: nil)
        let dock = dockController
        outline.onScratchDirectoriesChanged = { [weak dock] in dock?.scheduleRebuild() }
        dock.onRowCountChange = { [weak self] in self?.dockRowCountChanged() }
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
        // The SwiftUI footer's own backdrop, behind the dock from its top
        // edge down, so the dock and the footer read as one group.
        let backdrop = NSHostingView(rootView: SidebarBarBackdrop())
        backdrop.sizingOptions = []
        for view in [outlineView, backdrop, dockView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        root.addSubview(outlineView)
        root.addSubview(backdrop)
        root.addSubview(dockView)
        let dockHeight = dockView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            outlineView.topAnchor.constraint(equalTo: root.topAnchor),
            outlineView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            outlineView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outlineView.bottomAnchor.constraint(equalTo: dockView.topAnchor),
            dockView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            dockView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            dockView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            dockHeight,
            backdrop.topAnchor.constraint(equalTo: dockView.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        self.dockHeight = dockHeight
        view = root

        // The shared `+` menu opening or closing keeps its `+` shown in
        // whichever list it belongs to; each list asks about its own rows.
        let outline = outlineController
        let dock = dockController
        outline.plusMenu.onOpenChange = { [weak outline, weak dock] _, _ in
            outline?.applyHoverToAvailableRows()
            dock?.applyHoverToAvailableRows()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateDockHeight()
    }

    /// The list height the clamp's 40% is of: the dock settles where it is
    /// 40% of the list above it. The outline and the dock share the whole
    /// column, the outline's bottom edge on the dock's top, so with
    /// `fraction` = 0.4 that list is (outline + dock) / (1 + fraction), and a
    /// dock sized from it lands there in one pass instead of feeding its own
    /// height back into the outline's.
    var dockAvailableHeight: CGFloat {
        let column = viewIfLoaded?.bounds.height ?? 0
        return column / (1 + PinnedDockMetrics.maxSidebarFraction)
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

    /// The dock's rows changed in number: it takes its new height now, laid
    /// out before the dock scrolls a new selection into it.
    private func dockRowCountChanged() {
        updateDockHeight()
        viewIfLoaded?.layoutSubtreeIfNeeded()
    }
}

/// The `.bar` material the SwiftUI footer draws behind itself.
private struct SidebarBarBackdrop: View {
    var body: some View {
        Rectangle().fill(.bar)
    }
}
