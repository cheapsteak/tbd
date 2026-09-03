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
/// Containment matches `MarkdownImageInliner`: the result must live under the
/// symlink-resolved worktree root, symlinks are resolved on both sides, and
/// the target must be a regular file. What the two do with the result differs
/// — an image is read and inlined, a link is only rewritten — but the trust
/// boundary is the same one, for the same reason.
///
/// Resolution differs in one place: a root-relative `/docs/setup.md` resolves
/// against the worktree root rather than the document's directory, which is
/// what a leading slash means to every forge that renders a repo's markdown.
/// The image pass does not yet do this.
struct MarkdownLinkResolver {

    private let documentDirectory: URL
    /// What a ROOT-relative href (`/docs/setup.md`) resolves against. Kept
    /// unresolved so a rewritten href names the path the user navigated
    /// rather than its realpath — see the return of `rewritten(href:)`.
    private let worktreeRoot: URL
    /// Symlink-resolved path the candidate must live under.
    private let containmentRoot: String
    private let fileManager: FileManager

    /// - Parameters:
    ///   - documentDirectory: what a relative `href` is *resolved against* —
    ///     the markdown file's own directory.
    ///   - worktreeRoot: the trust boundary the resolved candidate must stay
    ///     inside, and what a ROOT-relative `href` resolves against.
    ///     Deliberately NOT the document directory for containment either:
    ///     `docs/guide.md` linking `../README.md` is a mainstream repo layout.
    init(documentDirectory: URL, worktreeRoot: URL, fileManager: FileManager = .default) {
        self.documentDirectory = documentDirectory.standardizedFileURL
        self.worktreeRoot = worktreeRoot.standardizedFileURL
        // Symlinks are resolved on BOTH sides — see
        // `MarkdownWorktreeContainment`, which is also what the pane applies
        // to the URL this resolver hands it.
        self.containmentRoot = MarkdownWorktreeContainment.resolvedRoot(worktreeRoot)
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

        // Undo comrak's `escape_href`, the ONLY escaping a destination gets:
        // it emits `&#x27;` for `'` and `&amp;` for `&`, and percent-encodes
        // every other byte outside its HREF_SAFE set. `&#x27;` is undone
        // BEFORE `&amp;`, or a filename holding the literal text `&#x27;` —
        // which comrak wrote as `&amp;#x27;` — comes back as an apostrophe.
        let unescaped = href
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")

        // `./doc.md#section` navigates to the file, dropping the fragment: the
        // pane re-renders the linked document from the top and has no
        // scroll-to-anchor plumbing across a document switch.
        //
        // The split sits between the two decodes, and neither side is
        // arbitrary. AFTER unescaping, because `&#x27;` carries a literal `#`
        // and splitting first would cut `user&#x27;s guide.md` down to
        // `user&`. BEFORE percent-decoding, because `#` is in HREF_SAFE — a
        // real fragment arrives literal while a `#` in a filename arrives as
        // `%23`, so splitting afterwards would cut `a%23b.md`, a link to the
        // real file `a#b.md`, down to `a`.
        let beforeFragment = unescaped.firstIndex(of: "#")
            .map { String(unescaped[..<$0]) } ?? unescaped

        // Decoding MUST precede the containment check: otherwise
        // `%2e%2e%2fsecret.md` is a traversal vector the lexical check never
        // sees.
        let decoded = beforeFragment.removingPercentEncoding ?? beforeFragment

        // Re-check the decoded form: percent-encoding can hide both of the
        // shapes rejected above.
        guard !decoded.isEmpty, !decoded.hasPrefix("//"), !hasScheme(decoded) else { return nil }

        guard let candidate = resolvedCandidate(for: decoded) else { return nil }
        let resolved = candidate.resolvingSymlinksInPath()
        guard MarkdownWorktreeContainment.containsResolved(
            resolved.path, inResolvedRoot: containmentRoot
        ) else {
            logger.debug("rejected link outside worktree root: \(href, privacy: .public)")
            return nil
        }
        // A link to something that is not there stays unrewritten, so a broken
        // link keeps doing what it does today — nothing — rather than opening a
        // Finder window on a path that does not exist. A regular file, not
        // merely an existing one: a directory named `notes.md` is not a
        // document, and neither is a device node. Same check the image pass
        // makes, for the same reason.
        guard fileManager.fileExists(atPath: resolved.path),
              let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true
        else { return nil }

        // The UNRESOLVED path is what the href becomes: it is the path the
        // sidebar shows and the pane selects, and containment has already been
        // judged against the symlink-resolved target.
        return Self.escapeAttribute(candidate.absoluteString)
    }

    /// Where a decoded destination points, before containment is judged.
    ///
    /// A leading `/` addresses the WORKTREE ROOT — what a root-relative href
    /// means to every forge that renders a repo's markdown — and everything
    /// else the DOCUMENT directory, which is what an href is relative to.
    ///
    /// An absolute filesystem path is therefore reinterpreted as root-relative:
    /// `/etc/passwd` becomes `<root>/etc/passwd`, which does not exist, so the
    /// link is left alone. That is the intended outcome — there is no shape of
    /// href that names a file outside the repo.
    private func resolvedCandidate(for decoded: String) -> URL? {
        guard decoded.hasPrefix("/") else {
            return documentDirectory.appendingPathComponent(decoded).standardizedFileURL
        }
        let relative = String(decoded.drop(while: { $0 == "/" }))
        guard !relative.isEmpty else { return nil }
        return worktreeRoot.appendingPathComponent(relative).standardizedFileURL
    }

    /// Schemes that count even without an authority: they carry no path to
    /// resolve, so a destination naming one is never a repo-relative file.
    private static let opaqueSchemes: Set<String> = [
        "about", "blob", "data", "file", "javascript", "mailto",
        "sms", "tel", "urn", "vbscript",
    ]

    /// The non-alphanumeric half of RFC 3986's scheme grammar.
    private static let schemePunctuation: Set<Character> = ["+", "-", "."]

    /// Does this destination name a URL scheme?
    ///
    /// Deliberately NOT `URL(string:)?.scheme != nil`. That reports `v1` for
    /// `v1:changelog.md`, and `:` is in comrak's HREF_SAFE set, so an ordinary
    /// repo-relative filename containing a colon reaches this function
    /// unencoded and would be abandoned as remote — the exact dead link this
    /// resolver exists to fix. A destination counts as scheme-bearing only
    /// when it opens an authority (`scheme://…`) or names one of the opaque
    /// schemes above.
    ///
    /// Erring permissive is safe: whatever gets through still has to resolve
    /// inside the worktree root and name a regular file that exists. A remote
    /// destination that slips past satisfies neither, so it comes out
    /// unrewritten exactly as if it had been recognised here.
    private func hasScheme(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":") else { return false }
        let scheme = value[value.startIndex..<colon].lowercased()
        // RFC 3986 scheme grammar. A colon inside a path segment
        // (`notes/rev:2.md`) fails it and is correctly read as a path.
        let isSchemeCharacter: (Character) -> Bool = { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber
                || Self.schemePunctuation.contains(character)
        }
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy(isSchemeCharacter)
        else { return false }
        if Self.opaqueSchemes.contains(scheme) { return true }
        return value[value.index(after: colon)...].hasPrefix("//")
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
