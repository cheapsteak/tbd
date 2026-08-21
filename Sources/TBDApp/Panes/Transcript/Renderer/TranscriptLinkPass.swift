import AppKit

/// Marks resolvable file paths and web URLs in rendered transcript prose as
/// `.link` ranges.
///
/// Ranges are marked at render time rather than resolved at click time so
/// `NSTextView` supplies the interaction: a plain click follows the link, a
/// drag still selects text. Reconstructing that by hand would mean fighting
/// AppKit's modal drag-select tracking loop.
///
/// `@MainActor` because the resolver it is handed is main-actor-isolated (see
/// `TranscriptPathResolver`) and because it reads `NSColor`. The two pure URL
/// helpers are explicitly `nonisolated`: the click delegate calls
/// `resolvedPath(from:)` and has no reason to inherit an isolation it does not
/// need.
@MainActor
enum TranscriptLinkPass {
    /// Custom scheme carrying an already-resolved absolute path. The click
    /// delegate reads it back with `resolvedPath(from:)`; resolution never
    /// happens on the click path.
    nonisolated static let fileScheme = "tbd-file"

    static func apply(
        to string: NSMutableAttributedString,
        resolve: @MainActor (String) -> String?
    ) {
        guard string.length > 0 else { return }
        let plain = string.string

        for candidate in TranscriptLinkScanner.scan(plain) {
            guard candidate.range.location + candidate.range.length <= string.length else { continue }
            // Never overwrite a markdown link the renderer already produced.
            guard !hasExistingLink(string, in: candidate.range) else { continue }

            let url: URL?
            if candidate.isURL {
                url = URL(string: candidate.token)
            } else if let resolved = resolve(candidate.token) {
                url = fileURL(forResolvedPath: resolved)
            } else {
                url = nil
            }
            guard let url else { continue }

            string.addAttribute(.link, value: url, range: candidate.range)
            style(string, range: candidate.range)
        }
    }

    /// Builds the `tbd-file:` URL for an already-resolved absolute path.
    ///
    /// The absolute requirement is the URL's, not a style preference: a
    /// relative path produces an opaque `tbd-file:docs/a.md` whose `.path` is
    /// empty, so the click would resolve to nothing. Resolution always returns
    /// an absolute path, and stating the invariant here keeps it from being
    /// implied by a test fixture.
    nonisolated static func fileURL(forResolvedPath path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "\(fileScheme):\(encoded)")
    }

    /// The absolute path carried by a `tbd-file:` URL, or nil for any other URL.
    nonisolated static func resolvedPath(from url: URL) -> String? {
        guard url.scheme == fileScheme else { return nil }
        return url.path
    }

    // MARK: - Private

    private static func hasExistingLink(_ string: NSAttributedString, in range: NSRange) -> Bool {
        var found = false
        string.enumerateAttribute(.link, in: range, options: []) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    /// Code sub-runs underline; prose sub-runs tint.
    ///
    /// A tint inside a code run would be overwritten moments later:
    /// `CodeHighlightService` re-applies `.foregroundColor` over the block
    /// asynchronously once the row is on screen. Underline is untouched by that
    /// pass, so it is the only styling that survives there.
    ///
    /// Styled per sub-run rather than per candidate. A token can straddle the
    /// boundary — `` the file `docs/a`.md `` is one token whose first half is
    /// code — and reading `.tbdCodeContext` once at `range.location` would
    /// misclassify the whole thing, tinting a code run (where the tint is then
    /// erased) or underlining prose.
    private static func style(_ string: NSMutableAttributedString, range: NSRange) {
        // Collected first, applied second: mutating attributes inside
        // `enumerateAttribute` over the same storage is not worth the risk.
        var codeRuns: [NSRange] = []
        var proseRuns: [NSRange] = []
        string.enumerateAttribute(.tbdCodeContext, in: range, options: []) { value, sub, _ in
            if value != nil { codeRuns.append(sub) } else { proseRuns.append(sub) }
        }
        for sub in codeRuns {
            string.addAttribute(
                .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: sub)
        }
        for sub in proseRuns {
            string.addAttribute(.foregroundColor, value: NSColor.linkColor, range: sub)
        }
    }
}
