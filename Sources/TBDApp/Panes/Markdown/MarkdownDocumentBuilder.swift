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
    ///   - worktreeRoot: the containment boundary for those resolved paths,
    ///     and what a root-relative `href` (`/docs/setup.md`) resolves
    ///     against.
    static func build(
        markdown: String, documentDirectory: URL, worktreeRoot: URL, css: String
    ) -> String? {
        // The renderer refuses a NUL byte, and front matter is split off before
        // it looks, so refuse here too: one NUL means one outcome wherever it sits.
        guard !markdown.utf8.contains(0) else { return nil }
        let (frontMatter, source) = MarkdownFrontMatter.split(markdown)
        guard let body = MarkdownHTMLRenderer.renderBody(source) else { return nil }
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
        // Front matter goes in last, so neither regex pass ever sees its text.
        // An empty block has no header at all.
        let header = frontMatter?.html ?? ""
        let content = header.isEmpty ? inlined : header + "\n" + inlined
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
        \(content)
        </body>
        </html>
        """
    }
}
