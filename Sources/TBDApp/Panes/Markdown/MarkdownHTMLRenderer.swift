import CComrakFFI
import Foundation

/// Turns markdown into an HTML body fragment using comrak's safe mode.
///
/// Safe mode is the security contract: raw HTML is clobbered to
/// `<!-- raw HTML omitted -->` and unsafe URL schemes are emptied, so no
/// downstream sanitizer is required. See
/// `docs/specs/2026-07-28-markdown-display-options-design.md`.
enum MarkdownHTMLRenderer {

    /// Returns the rendered HTML body, or nil when the input cannot cross the
    /// C boundary — an embedded NUL, or invalid UTF-8.
    static func renderBody(_ markdown: String) -> String? {
        guard !markdown.utf8.contains(0) else { return nil }
        return markdown.withCString { cString -> String? in
            guard let raw = tbd_markdown_to_html(cString) else { return nil }
            defer { tbd_markdown_free(raw) }
            return String(cString: raw)
        }
    }
}
