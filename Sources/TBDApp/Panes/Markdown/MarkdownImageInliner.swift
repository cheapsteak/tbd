import Foundation
import os
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "com.tbd.app", category: "markdown")

/// Rewrites repo-local `<img src>` values into `data:` URIs.
///
/// The viewer has no URL scheme handler — see the spec's "Local file
/// resolution" section — so local images must be inlined. Caps are invented
/// rather than copied: GitHub strips `data:` URIs entirely.
struct MarkdownImageInliner {

    /// Largest single image inlined. 2 MiB of image is ~2.7 MiB of base64.
    static let perImageLimit = 2 * 1024 * 1024
    /// Total inlined bytes per document, the binding constraint on
    /// image-heavy READMEs.
    static let perDocumentBudget = 16 * 1024 * 1024

    private let documentDirectory: URL
    /// Symlink-resolved path the candidate must live under.
    private let containmentRoot: String
    private let fileManager: FileManager
    private var spent = 0

    /// - Parameters:
    ///   - documentDirectory: what a relative `src` is *resolved against* —
    ///     the markdown file's own directory.
    ///   - worktreeRoot: the trust boundary the resolved candidate must stay
    ///     inside. Deliberately NOT the document directory: `docs/guide.md`
    ///     referencing `../images/x.png` is a mainstream repo layout, and the
    ///     spec's "Local file resolution" section requires containment under
    ///     the repo root.
    init(documentDirectory: URL, worktreeRoot: URL, fileManager: FileManager = .default) {
        self.documentDirectory = documentDirectory.standardizedFileURL
        // Resolve symlinks on BOTH sides. Resolving only the candidate breaks
        // every repo that lives under a symlinked path; resolving neither lets
        // a symlink inside the repo point anywhere on disk.
        self.containmentRoot = worktreeRoot.standardizedFileURL.resolvingSymlinksInPath().path
        self.fileManager = fileManager
    }

    mutating func inline(html: String) -> String {
        // Matches src="..." on img tags. comrak emits double-quoted
        // attributes, so a single quoting form is sufficient.
        let pattern = #"<img([^>]*?)src="([^"]*)"([^>]*?)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }

        var result = html
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        for match in matches.reversed() {
            guard let full = Range(match.range, in: result),
                  let srcRange = Range(match.range(at: 2), in: result) else { continue }
            let src = String(result[srcRange])
            let prefix = Range(match.range(at: 1), in: result).map { String(result[$0]) } ?? " "
            let suffix = Range(match.range(at: 3), in: result).map { String(result[$0]) } ?? ""
            guard let replacement = replacement(for: src, prefix: prefix, suffix: suffix) else {
                continue
            }
            result.replaceSubrange(full, with: replacement)
        }
        return result
    }

    private mutating func replacement(
        for src: String, prefix: String, suffix: String
    ) -> String? {
        // Absolute URLs (remote, or already data:) are left as-is.
        if let url = URL(string: src), url.scheme != nil { return nil }

        // comrak percent-encodes and entity-escapes destinations, so decode
        // before doing anything else. This MUST precede the containment check:
        // otherwise `%2e%2e%2fsecret.png` is a traversal vector that the
        // lexical check never sees.
        let decoded = (src.removingPercentEncoding ?? src)
            .replacingOccurrences(of: "&amp;", with: "&")

        // Resolved against the DOCUMENT directory (that is what `src` is
        // relative to), contained against the WORKTREE ROOT. Both sides are
        // symlink-resolved — see the initializer.
        let resolved = documentDirectory.appendingPathComponent(decoded)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(containmentRoot + "/") else {
            logger.debug("rejected image outside worktree root: \(src, privacy: .public)")
            return nil
        }

        // resourceValues on the RESOLVED url reports the target's size and
        // type. `attributesOfItem` would not: it has lstat semantics and
        // reports a symlink as ~10 bytes while `contents(atPath:)` follows it
        // and reads the whole target — which silently defeats both caps.
        guard let values = try? resolved.resourceValues(
                  forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize else { return nil }

        // Only real image types are inlined. Independently stops a README or
        // a key from becoming a text/* data URI in the DOM.
        guard let type = UTType(filenameExtension: resolved.pathExtension),
              type.conforms(to: .image),
              let mime = type.preferredMIMEType else { return nil }

        if size > Self.perImageLimit || spent + size > Self.perDocumentBudget {
            return Self.placeholder(filename: resolved.lastPathComponent)
        }
        // Read from `resolved` so the stat and the read address the same file.
        // A TOCTOU window remains; proportionate for a local viewer.
        guard let data = fileManager.contents(atPath: resolved.path) else { return nil }

        spent += size
        // Preserve the tag's other attributes (alt, title) — rebuilding the
        // tag from scratch would silently drop every image's alt text.
        return #"<img\#(prefix)src="data:\#(mime);base64,\#(data.base64EncodedString())"\#(suffix)>"#
    }

    private static func placeholder(filename: String) -> String {
        let escaped = filename
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return #"<span class="tbd-oversized-image" title="\#(escaped)">\#(escaped)</span>"#
    }
}
