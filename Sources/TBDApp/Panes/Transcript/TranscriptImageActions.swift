import AppKit
import QuickLookUI
import os

/// The gestures an attached-image thumbnail offers, shared by the native
/// (`TranscriptImageBlockView`) and the SwiftUI (`TranscriptImageAttachmentView`)
/// renderers so the two cannot drift: click previews, the context menu keeps
/// Finder and the pasteboard reachable.
@MainActor
enum TranscriptImageActions {
    private static let log = Logger(subsystem: "com.tbd.app", category: "transcript-image")

    /// Primary click: the macOS Quick Look panel — what the space bar gives you
    /// in Finder. Also the right gesture for a file that is NOT a decodable
    /// image, which Quick Look previews perfectly well (a text file, a PDF).
    static func preview(path: String) {
        TranscriptQuickLook.shared.preview(url: URL(fileURLWithPath: path))
    }

    /// Where "Reveal in Finder" went when click became preview.
    static func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Copies the ORIGINAL file's pixels, not the downsampled thumbnail the
    /// transcript drew. That is a full decode, so it runs off the main thread —
    /// the same hazard class as #129, just triggered by a menu item instead of a
    /// row. A file that does not decode falls back to copying its file URL, so
    /// the menu item is never a no-op.
    static func copyImage(path: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let image = NSImage(contentsOfFile: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    if let image {
                        pasteboard.writeObjects([image])
                    } else {
                        log.debug("transcript-image copy fell back to URL path=\(path, privacy: .public)")
                        pasteboard.writeObjects([URL(fileURLWithPath: path) as NSURL])
                    }
                }
            }
        }
    }
}

/// Drives the shared `QLPreviewPanel` for transcript attachments.
///
/// ## Why the app delegate owns the panel
///
/// `QLPreviewPanel` is a single app-wide panel that finds its controller by
/// walking the responder chain of the key window — it shows an EMPTY window if
/// nothing in that chain claims it. The chain ends at `NSApp` and then the
/// application delegate, so implementing the three `QLPreviewPanelController`
/// methods on `AppDelegate` (see the extension below) covers every caller
/// without either renderer having to seize first-responder status from the
/// transcript's text views — and it covers both renderers with one wiring.
///
/// Verified in this unbundled-SPM process rather than assumed: a probe binary
/// with no `Info.plist` (`Bundle.main.bundleIdentifier == nil`) opened the panel
/// through exactly this app-delegate chain, and it reported
/// `isVisible == true`, a non-nil `currentController`, and the expected
/// `currentPreviewItem` while rendering the picture. QuickLookUI reads nothing
/// out of the bundle here, so no `bundleIdentifier` guard is warranted; the only
/// fallback is for `sharedPreviewPanel` coming back nil, which opens the file in
/// its default app instead of failing silently.
@MainActor
final class TranscriptQuickLook: NSObject, @MainActor QLPreviewPanelDataSource {
    static let shared = TranscriptQuickLook()

    private static let log = Logger(subsystem: "com.tbd.app", category: "transcript-image")

    /// The file the panel shows while this object is its data source. Set before
    /// the panel is asked to appear, because the responder-chain search calls
    /// `acceptsPreviewPanelControl` synchronously inside that call.
    private(set) var previewURL: URL?

    /// Test seam: how the panel is actually put on screen. A test replaces this
    /// so the click path can be exercised without a real Quick Look panel
    /// appearing over the developer's screen mid-run. Production leaves it alone.
    var showPanel: @MainActor () -> Void = { TranscriptQuickLook.showSharedPanel() }

    /// Preview `url`, or open it in its default app if the panel is unavailable.
    func preview(url: URL) {
        previewURL = url
        showPanel()
    }

    private static func showSharedPanel() {
        guard let panel = QLPreviewPanel.shared() else {
            // No panel to drive: opening in Preview.app is the honest fallback,
            // rather than a click that does nothing.
            if let url = shared.previewURL { NSWorkspace.shared.open(url) }
            log.debug("transcript-image quick look unavailable, opened externally")
            return
        }
        if panel.isVisible {
            // Already up on another attachment — swap the item in place.
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        // The key window did not necessarily change, so ask for the controller
        // search explicitly.
        panel.updateController()
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }

    // MARK: - Controller plumbing (called from the AppDelegate extension)

    func accepts() -> Bool { previewURL != nil }

    func beginControl(of panel: QLPreviewPanel?) { panel?.dataSource = self }

    func endControl(of panel: QLPreviewPanel?) {
        // Deliberately keeps `previewURL`: control ends whenever the key window
        // changes, and dropping the item there would blank a panel the user is
        // still looking at.
        panel?.dataSource = nil
    }
}

/// The responder-chain terminus that lets `QLPreviewPanel` find a controller.
/// `QLPreviewPanelController` is an informal protocol on `NSObject`, so these are
/// overrides of category methods and AppKit only ever calls them on the main
/// thread.
extension AppDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { TranscriptQuickLook.shared.accepts() }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { TranscriptQuickLook.shared.beginControl(of: panel) }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { TranscriptQuickLook.shared.endControl(of: panel) }
    }
}
