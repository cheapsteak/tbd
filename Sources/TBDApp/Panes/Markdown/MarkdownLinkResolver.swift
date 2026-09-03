import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "markdown")

/// Rewrites document-relative `<a href>` values into absolute `file://` URLs.
///
/// The document is loaded with `baseURL: nil`, i.e. `about:blank`, so a
/// relative href has nothing to resolve against: `[log](./log.md)` arrives at
/// the navigation policy as `about:blank`-relative junk and is dropped, so the
/// click does nothing. Resolving at document-build time is deliberate in
/// preference to emitting a `<base href="file:///…">`, which would change
/// subresource resolution for the WHOLE document rather than just its links.
///
/// Resolution and containment mirror `MarkdownImageInliner` exactly: a
/// relative href resolves against the document's own directory, the result
/// must live under the symlink-resolved worktree root, and symlinks are
/// resolved on both sides. What the two do with the result differs — an image
/// is read and inlined, a link is only rewritten — but the trust boundary is
/// the same one, for the same reason.
struct MarkdownLinkResolver {

    private let documentDirectory: URL
    /// Symlink-resolved path the candidate must live under.
    private let containmentRoot: String
    private let fileManager: FileManager

    /// - Parameters:
    ///   - documentDirectory: what a relative `href` is *resolved against* —
    ///     the markdown file's own directory.
    ///   - worktreeRoot: the trust boundary the resolved candidate must stay
    ///     inside. Deliberately NOT the document directory: `docs/guide.md`
    ///     linking `../README.md` is a mainstream repo layout.
    init(documentDirectory: URL, worktreeRoot: URL, fileManager: FileManager = .default) {
        self.documentDirectory = documentDirectory.standardizedFileURL
        // Resolve symlinks on BOTH sides. Resolving only the candidate breaks
        // every repo that lives under a symlinked path; resolving neither lets
        // a symlink inside the repo point anywhere on disk.
        self.containmentRoot = worktreeRoot.standardizedFileURL.resolvingSymlinksInPath().path
        self.fileManager = fileManager
    }

    func resolve(html: String) -> String {
        // Matches href="..." on anchor tags. comrak emits double-quoted
        // attributes, same as for `<img src>`. The leading `\s` is what keeps
        // `<abbr …>` and any other `a`-initial tag out of the match.
        let pattern = #"<a(\s[^>]*?)href="([^"]*)"([^>]*?)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }

        var result = html
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        // Reversed so each replacement leaves the earlier ranges valid.
        for match in matches.reversed() {
            guard let full = Range(match.range, in: result),
                  let hrefRange = Range(match.range(at: 2), in: result) else { continue }
            let href = String(result[hrefRange])
            guard let rewritten = rewritten(href: href) else { continue }
            let prefix = Range(match.range(at: 1), in: result).map { String(result[$0]) } ?? " "
            let suffix = Range(match.range(at: 3), in: result).map { String(result[$0]) } ?? ""
            // Preserve the tag's other attributes (title, most often) —
            // rebuilding it from scratch would drop every link's tooltip.
            result.replaceSubrange(full, with: #"<a\#(prefix)href="\#(rewritten)"\#(suffix)>"#)
        }
        return result
    }

    /// The replacement href, or nil to leave the tag exactly as it was.
    private func rewritten(href: String) -> String? {
        // Anything that already names a scheme — http, mailto, data, an
        // absolute file: URL — is somebody else's decision.
        if hasScheme(href) { return nil }
        // Protocol-relative `//host/path` carries no scheme but is remote.
        if href.hasPrefix("//") { return nil }
        // Fragment-only hrefs are same-document anchors. Every README table of
        // contents depends on them reaching the webview untouched.
        if href.hasPrefix("#") { return nil }

        // comrak percent-encodes and entity-escapes destinations, so decode
        // before doing anything else. This MUST precede the containment check:
        // otherwise `%2e%2e%2fsecret.md` is a traversal vector that the
        // lexical check never sees.
        var decoded = (href.removingPercentEncoding ?? href)
            .replacingOccurrences(of: "&amp;", with: "&")
        // `./doc.md#section` navigates to the file. The fragment is dropped:
        // the pane re-renders the linked document from the top and has no
        // scroll-to-anchor plumbing across a document switch.
        if let hash = decoded.firstIndex(of: "#") { decoded = String(decoded[..<hash]) }
        // Re-check the decoded form: percent-encoding can hide both of the
        // shapes rejected above.
        guard !decoded.isEmpty, !decoded.hasPrefix("//"), !hasScheme(decoded) else { return nil }

        // Resolved against the DOCUMENT directory (that is what `href` is
        // relative to), contained against the WORKTREE ROOT.
        let candidate = documentDirectory.appendingPathComponent(decoded).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(containmentRoot + "/") else {
            logger.debug("rejected link outside worktree root: \(href, privacy: .public)")
            return nil
        }
        // A link to something that is not there stays unrewritten, so a broken
        // link keeps doing what it does today — nothing — rather than opening a
        // Finder window on a path that does not exist.
        guard fileManager.fileExists(atPath: resolved.path) else { return nil }

        // The UNRESOLVED path is what the href becomes: it is the path the
        // sidebar shows and the pane selects, and containment has already been
        // judged against the symlink-resolved target.
        return Self.escapeAttribute(candidate.absoluteString)
    }

    /// Does this destination name a URL scheme?
    private func hasScheme(_ value: String) -> Bool {
        if let url = URL(string: value), url.scheme != nil { return true }
        return false
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
