import Foundation
import os

/// One incremental read of a growing JSONL.
///
/// The buffer is truncated at its LAST newline *before* UTF-8 decoding, and the
/// returned offset advances only that far. Two consequences, both deliberate: a
/// chunk boundary can never split a multi-byte character, so the decode cannot
/// fail spuriously; and a half-written trailing line is simply re-read whole on
/// the next tick instead of being parsed as garbage.
///
/// That truncation also makes every window **line-aligned at both ends**:
/// `offset` is either zero or one past a newline this type itself returned, and
/// the decoded region always ends at a newline. So a decode failure here is
/// never a transient split — those bytes sit past the last newline and are not
/// in the region being decoded. It can only be bytes between two newlines that
/// are not valid UTF-8, and re-reading them on the next tick produces exactly
/// the same failure. Reporting that as "no news" forever would wedge the
/// session: the offset never advances, every tick re-reads the same bad window,
/// and the pane silently stops updating.
///
/// So an undecodable window falls back to decoding line by line, keeping every
/// line that decodes and skipping the ones that do not, then advancing past the
/// whole window. Nothing is lost that would have survived anyway — the JSONL
/// parser downstream rejects a line that is not valid UTF-8 too — and no line
/// is decoded lossily, because a repaired line could parse into a *wrong* item
/// rather than failing loudly. The skip is logged, so a session that hit this
/// leaves a trace rather than quietly dropping content.
enum TranscriptFileWindow {

    private static let log = Logger(subsystem: "com.tbd.app", category: "transcript-source")

    struct Read {
        let lines: [String]
        let newOffset: UInt64
    }

    static func read(path: String, from offset: UInt64) -> Read? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.readToEnd(), !data.isEmpty else {
                return Read(lines: [], newOffset: offset)
            }
            guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
                // No complete line in the window yet — withhold everything.
                return Read(lines: [], newOffset: offset)
            }
            let complete = data[data.startIndex...lastNewline]
            let newOffset = offset + UInt64(complete.count)
            guard let text = String(data: complete, encoding: .utf8) else {
                return skippingUndecodableLines(complete, newOffset: newOffset, path: path)
            }
            let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            return Read(lines: lines, newOffset: newOffset)
        } catch {
            return nil
        }
    }

    /// The recovery path for a window that is not valid UTF-8 as a whole.
    ///
    /// Splits on the newline byte and decodes each line on its own. `0x0A`
    /// cannot occur inside a multi-byte UTF-8 sequence — every continuation
    /// byte is `>= 0x80` — so splitting the raw bytes yields exactly the lines
    /// a successful whole-window decode would have, and the ones that are valid
    /// come back byte-accurate.
    ///
    /// Always returns a `Read`: the offset must advance past the offending
    /// bytes, or the next tick re-reads them and the session stays wedged.
    private static func skippingUndecodableLines(
        _ complete: Data.SubSequence, newOffset: UInt64, path: String
    ) -> Read {
        var lines: [String] = []
        var skipped = 0
        for lineBytes in complete.split(separator: UInt8(ascii: "\n")) {
            if let line = String(data: Data(lineBytes), encoding: .utf8) {
                lines.append(line)
            } else {
                skipped += 1
            }
        }
        log.error(
            """
            transcript window is not valid UTF-8: skipped \(skipped, privacy: .public) line(s), \
            kept \(lines.count, privacy: .public), advancing to offset \
            \(newOffset, privacy: .public) path=\(path, privacy: .public)
            """)
        return Read(lines: lines, newOffset: newOffset)
    }
}
