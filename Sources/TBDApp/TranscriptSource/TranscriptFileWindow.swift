import Foundation

/// One incremental read of a growing JSONL.
///
/// The buffer is truncated at its LAST newline *before* UTF-8 decoding, and the
/// returned offset advances only that far. Two consequences, both deliberate: a
/// chunk boundary can never split a multi-byte character, so the decode cannot
/// fail spuriously; and a half-written trailing line is simply re-read whole on
/// the next tick instead of being parsed as garbage.
enum TranscriptFileWindow {

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
            guard let text = String(data: complete, encoding: .utf8) else { return nil }
            let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            return Read(lines: lines, newOffset: offset + UInt64(complete.count))
        } catch {
            return nil
        }
    }
}
