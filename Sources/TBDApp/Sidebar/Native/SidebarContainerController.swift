import AppKit

/// The native sidebar's root: the outline's scroll view filling the column,
/// above a slot for the pinned dock. The slot is empty and zero-height until
/// the native dock fills it.
@MainActor
final class SidebarContainerController: NSViewController {
    let outlineController: SidebarOutlineController
    /// Where the pinned dock goes, pinned to the bottom edge.
    let dockSlot = NSView(frame: .zero)
    private(set) var dockHeight: NSLayoutConstraint?

    /// - Parameter sheets: the slot `NativeSidebarView` presents the
    ///   sidebar's sheets from.
    init(appState: AppState, defaults: UserDefaults, sheets: NativeSidebarSheetPresenter? = nil) {
        outlineController = SidebarOutlineController(appState: appState, defaults: defaults, sheets: sheets)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: .zero)
        addChild(outlineController)
        let outlineView = outlineController.view
        outlineView.translatesAutoresizingMaskIntoConstraints = false
        dockSlot.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(outlineView)
        root.addSubview(dockSlot)
        let dockHeight = dockSlot.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            outlineView.topAnchor.constraint(equalTo: root.topAnchor),
            outlineView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            outlineView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outlineView.bottomAnchor.constraint(equalTo: dockSlot.topAnchor),
            dockSlot.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            dockSlot.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            dockSlot.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            dockHeight,
        ])
        self.dockHeight = dockHeight
        view = root
    }
}
