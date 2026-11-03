import AppKit
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
        QuickLookPresenter.shared.preview(url: URL(fileURLWithPath: path))
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
