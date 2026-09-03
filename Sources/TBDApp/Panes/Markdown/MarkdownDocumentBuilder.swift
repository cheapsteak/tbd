import Foundation

/// Assembles the full HTML document handed to the webview.
///
/// The document is self-contained: CSS is inlined and local images are
/// `data:` URIs, so the same string is valid both in the viewer and as a
/// browser export.
enum MarkdownDocumentBuilder {

    /// - Parameters:
    ///   - documentDirectory: what relative image `src` and link `href` values
    ///     resolve against.
    ///   - worktreeRoot: the containment boundary for those resolved paths.
    static func build(
        markdown: String, documentDirectory: URL, worktreeRoot: URL, css: String
    ) -> String? {
        guard let body = MarkdownHTMLRenderer.renderBody(markdown) else { return nil }
        // Links first, images second: the inliner's output carries multi-megabyte
        // base64 `data:` URIs, and there is no reason to run a second regex pass
        // over them.
        let resolver = MarkdownLinkResolver(
            documentDirectory: documentDirectory, worktreeRoot: worktreeRoot
        )
        let linked = resolver.resolve(html: body)
        var inliner = MarkdownImageInliner(
            documentDirectory: documentDirectory, worktreeRoot: worktreeRoot
        )
        let inlined = inliner.inline(html: linked)
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
}
