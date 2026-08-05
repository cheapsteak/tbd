import Foundation

/// An image the user attached to a Claude Code prompt, named by a
/// `[Image: source: /absolute/path.png]` marker in the transcript text.
///
/// The marker is the ONLY carrier of the on-disk path. Claude Code writes the
/// pasted bitmap into the JSONL twice: once as a base64 `image` content block on
/// the prompt line (structured, but megabytes wide and pathless), and once as
/// this marker, in a follow-up `isMeta` user line that names the file it spooled
/// into its image cache. Reveal-in-Finder needs the path, so the marker is what
/// we read. See `docs`-free note in `TranscriptImageMarker` for the format.
struct TranscriptImageAttachment: Equatable, Hashable {
    /// Absolute path exactly as the marker spelled it.
    let path: String

    var fileName: String { (path as NSString).lastPathComponent }

    /// Tilde-abbreviated path, for the hover tooltip. The path is deliberately
    /// never DRAWN — replacing it with a thumbnail is the point of the feature —
    /// but it stays one deliberate hover away.
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

/// Splits transcript text at Claude Code's image-attachment markers.
///
/// ## The real format (measured against 113 markers in `~/.claude/projects`)
///
/// A prompt with pasted images produces TWO consecutive JSONL user lines:
///
/// 1. the prompt itself — content `[text, image, image…]`, where the text holds
///    inline `[Image #N]` placeholders at the spot the user pasted, and each
///    `image` block carries the bitmap as base64;
/// 2. a follow-up line with `isMeta: true` and content `[text, text…]` — ONE
///    text block per image, each holding exactly `[Image: source: <abs path>]`.
///
/// Empirically, in that corpus: every marker payload was an absolute path; every
/// marker but one was the entire text block (the exception was a prompt quoting
/// the marker syntax in prose, which is why this parser accepts mid-sentence
/// markers); no text block ever held two markers, because multiple images become
/// multiple text blocks; and `[Image #N]`'s N matched the marker's `N.png`
/// basename, so the inline placeholders and the thumbnails stay in step.
///
/// `[Image #N]` is deliberately left alone. It sits where the user pasted, inside
/// their own sentence, and with several images it is the only thing tying "this
/// paragraph" to "that thumbnail". The `source:` marker — pure machine bookkeeping
/// the user never typed — is what becomes a thumbnail.
enum TranscriptImageMarker {
    /// One piece of a message: literal text, or an image attachment that replaces
    /// the marker at that position.
    enum Segment: Equatable {
        case text(String)
        case image(TranscriptImageAttachment)
    }

    private static let openToken = "[Image: source: "
    private static let closeToken = "]"

    /// Splits `text` into ordered text / image segments.
    ///
    /// Markers inside fenced code blocks are left as literal text — a fenced
    /// block is quoted source, not an attachment (this file's own doc comment
    /// would otherwise render a thumbnail). Only ABSOLUTE paths become image
    /// segments; anything else stays as text, since a path we cannot resolve is
    /// nothing we could reveal in Finder either.
    ///
    /// Fast path: text with no marker at all returns a single `.text` segment
    /// without any per-line work, so the overwhelmingly common message pays one
    /// substring search.
    static func split(_ text: String) -> [Segment] {
        guard text.contains(openToken) else { return [.text(text)] }

        var segments: [Segment] = []
        var textBuffer = ""
        var inFence = false

        // Newlines that merely separated a marker from its neighbours are
        // separators, not content: each text run is rendered as its own markdown
        // document, so a run that is nothing but whitespace would become an empty
        // prose block with real height. Trim the run's edges and drop it if
        // nothing is left. Interior blank lines (paragraph breaks) survive.
        func flushText() {
            let trimmed = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            textBuffer = ""
            guard !trimmed.isEmpty else { return }
            segments.append(.text(trimmed))
        }

        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let isLast = index == lines.count - 1
            if line.hasPrefix("```") {
                inFence.toggle()
                textBuffer += line
                if !isLast { textBuffer += "\n" }
                continue
            }
            if inFence {
                textBuffer += line
                if !isLast { textBuffer += "\n" }
                continue
            }

            var rest = Substring(line)
            while let open = rest.range(of: openToken) {
                guard let close = rest[open.upperBound...].range(of: closeToken) else { break }
                let payload = String(rest[open.upperBound..<close.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                guard payload.hasPrefix("/"), payload.count > 1 else {
                    // Not an absolute path — keep the marker as literal text and
                    // resume scanning after it.
                    textBuffer += rest[rest.startIndex..<close.upperBound]
                    rest = rest[close.upperBound...]
                    continue
                }
                textBuffer += rest[rest.startIndex..<open.lowerBound]
                flushText()
                segments.append(.image(TranscriptImageAttachment(path: payload)))
                rest = rest[close.upperBound...]
            }
            textBuffer += rest
            if !isLast { textBuffer += "\n" }
        }

        flushText()
        return segments
    }
}
