import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "markdown")

/// Default-off gate for the webview markdown viewer.
///
/// App-only behavior, so `UserDefaults` is the right home per CLAUDE.md —
/// precedent is `enableTranscript`. Graduation: flip the default after a soak,
/// then delete the MarkdownUI path from the viewer.
enum MarkdownViewerPreferences {
    static let useWebViewKey = "markdown.viewer.usewebview"

    static func useWebView(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: useWebViewKey)
    }
}

/// Reads and renders markdown off the main actor.
///
/// Mirrors `CodeViewerHighlightService` (added in commit 4fc71bcc), which moved
/// the *code* path off-main. The markdown path never got the same treatment and
/// still read on the main thread at `CodeViewerPaneView.swift:406`.
actor MarkdownRenderService {
    static let shared = MarkdownRenderService()

    /// Matches the existing viewer guard.
    private static let maxFileSize = 1024 * 1024

    func render(path: String, css: String) async -> String? {
        let url = URL(fileURLWithPath: path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else {
            logger.debug("markdown file unreadable: \(path, privacy: .public)")
            return nil
        }
        guard size <= Self.maxFileSize else {
            logger.debug("markdown file too large: \(size, privacy: .public) bytes")
            return nil
        }
        guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        return MarkdownDocumentBuilder.build(
            markdown: markdown,
            documentDirectory: url.deletingLastPathComponent(),
            css: css
        )
    }
}
