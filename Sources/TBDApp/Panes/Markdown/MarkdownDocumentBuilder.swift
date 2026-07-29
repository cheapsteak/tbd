import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "markdown")

/// Assembles the full HTML document handed to the webview.
///
/// The document is self-contained: CSS is inlined and local images are
/// `data:` URIs, so the same string is valid both in the viewer and as a
/// browser export.
enum MarkdownDocumentBuilder {

    /// - Parameters:
    ///   - documentDirectory: what relative image `src` values resolve against.
    ///   - worktreeRoot: the containment boundary for those resolved paths.
    static func build(
        markdown: String, documentDirectory: URL, worktreeRoot: URL, css: String
    ) -> String? {
        guard let body = MarkdownHTMLRenderer.renderBody(markdown) else { return nil }
        var inliner = MarkdownImageInliner(
            documentDirectory: documentDirectory, worktreeRoot: worktreeRoot
        )
        let inlined = inliner.inline(html: body)
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(css)
        </style>
        </head>
        <body>
        \(inlined)
        </body>
        </html>
        """
    }

    /// The bundled stylesheet. Falls back to an empty string if the resource
    /// is missing, which renders unstyled rather than failing the document.
    static let defaultCSS: String = {
        guard let url = Bundle.module.url(forResource: "markdown-default", withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("bundled markdown-default.css missing; rendering unstyled")
            return ""
        }
        return css
    }()
}
