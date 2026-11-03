import AppKit

/// The two actions on the file viewer's "Cannot preview" screen. Neither one
/// opens the file in its default app: Quick Look previews it in place and
/// Finder reveals it. Closures so a test can build the view with recording
/// stand-ins.
@MainActor
struct BinaryFallbackActions {
    var openQuickLook: @MainActor (String) -> Void
    var reveal: @MainActor (String) -> Void

    static func live(
        workspace: any FileRevealing = NSWorkspace.shared,
        presenter: QuickLookPresenter = .shared
    ) -> BinaryFallbackActions {
        BinaryFallbackActions(
            openQuickLook: { path in presenter.preview(url: URL(fileURLWithPath: path)) },
            reveal: { path in revealInFinder(path: path, workspace: workspace) }
        )
    }
}
