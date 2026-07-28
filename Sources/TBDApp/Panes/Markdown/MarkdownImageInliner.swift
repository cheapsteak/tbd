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
    private let fileManager: FileManager
    private var spent = 0

    init(documentDirectory: URL, fileManager: FileManager = .default) {
        self.documentDirectory = documentDirectory.standardizedFileURL
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
            guard let replacement = replacement(for: src, originalTag: String(result[full])) else {
                continue
            }
            result.replaceSubrange(full, with: replacement)
        }
        return result
    }

    private mutating func replacement(for src: String, originalTag: String) -> String? {
        // Absolute URLs (remote, or already data:) are left as-is.
        if let url = URL(string: src), url.scheme != nil { return nil }

        let candidate = documentDirectory.appendingPathComponent(src).standardizedFileURL
        guard candidate.path.hasPrefix(documentDirectory.path + "/") else {
            logger.debug("rejected image outside document dir: \(src, privacy: .public)")
            return nil
        }
        guard let attrs = try? fileManager.attributesOfItem(atPath: candidate.path),
              let size = attrs[.size] as? Int else { return nil }

        if size > Self.perImageLimit || spent + size > Self.perDocumentBudget {
            return Self.placeholder(filename: candidate.lastPathComponent)
        }
        guard let data = fileManager.contents(atPath: candidate.path) else { return nil }

        spent += size
        let mime = UTType(filenameExtension: candidate.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        return #"<img src="data:\#(mime);base64,\#(data.base64EncodedString())" />"#
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
