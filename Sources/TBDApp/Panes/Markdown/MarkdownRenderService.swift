import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "markdown")

/// Reads and renders markdown off the main actor.
///
/// Mirrors `CodeViewerHighlightService` (added in commit 4fc71bcc), which moved
/// the *code* path off-main. The markdown path never got the same treatment and
/// still read on the main thread at `CodeViewerPaneView.swift:406`.
actor MarkdownRenderService {
    static let shared = MarkdownRenderService()

    /// Matches the existing viewer guard.
    private static let maxFileSize = 1024 * 1024

    /// - Parameter worktreeRoot: trust boundary for local image inlining.
    ///   Empty falls back to the document's own directory — the narrower of
    ///   the two, so an unknown root can only ever reject more.
    func render(path: String, worktreeRoot: String, css: String) async -> String? {
        let url = URL(fileURLWithPath: path)
        // Read size and type from the RESOLVED url. `attributesOfItem` would
        // not: it has lstat semantics and reports a symlink as the length of
        // its target *string* (~6 bytes) while `String(contentsOf:)` follows
        // the link and reads the whole target — measured at 6 bytes reported
        // for 1,600,000 characters read. `README.md -> huge-file` is a thing a
        // repo can check in. Same defect, same shape of fix, as
        // `MarkdownImageInliner`.
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(
                  forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize else {
            logger.debug("markdown file unreadable: \(path, privacy: .public)")
            return nil
        }
        guard size <= Self.maxFileSize else {
            logger.debug("markdown file too large: \(size, privacy: .public) bytes")
            return nil
        }
        // Read from `resolved` so the stat and the read address the same file.
        guard let markdown = try? String(contentsOf: resolved, encoding: .utf8) else { return nil }

        let documentDirectory = url.deletingLastPathComponent()
        return MarkdownDocumentBuilder.build(
            markdown: markdown,
            documentDirectory: documentDirectory,
            worktreeRoot: worktreeRoot.isEmpty
                ? documentDirectory
                : URL(fileURLWithPath: worktreeRoot),
            css: css
        )
    }
}
