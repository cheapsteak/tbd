import Foundation
import TBDShared

/// Writes a first message that never reached its worktree to a file the
/// operator can find again: `~/tbd/repos/<repoID>/unsent-prompts/
/// <yyyyMMdd-HHmmss>-<worktree-name>.md`.
///
/// Written only when creation or parking fails — never while the operator is
/// typing — so the directory holds exactly the messages that were lost
/// somewhere else. The pasteboard copy that accompanies it is a convenience;
/// this file is the store, because the next copy overwrites the pasteboard.
///
/// `OrphanGC` is the named reconciler for the directory: it removes files
/// older than 30 days under `gcEnabled`.
enum UnsentPromptFile {
    /// Longest worktree-name fragment a filename carries. Names are generated
    /// slugs or operator-typed display names; this keeps a pasted paragraph
    /// from producing a filename the filesystem refuses.
    static let maxNameLength = 80

    /// The `yyyyMMdd-HHmmss` stamp, in the operator's local time unless a
    /// test pins a zone.
    static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// A worktree name reduced to characters every filesystem and shell takes
    /// without quoting: ASCII letters, digits, `.`, `_` and `-`. Anything else
    /// becomes `-`, runs collapse, and leading or trailing `-`/`.` are dropped
    /// so the result can never be a dotfile or `..`. An empty result falls
    /// back to `worktree`.
    static func sanitizedName(_ name: String) -> String {
        var out = ""
        var lastWasDash = false
        for scalar in name.unicodeScalars {
            let isSafe = scalar.isASCII
                && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-")
            if isSafe && scalar != "-" {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        let trimmed = String(out.prefix(maxNameLength))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "worktree" : trimmed
    }

    /// Write `text` into `directory`, creating it if needed, and return the
    /// path written. Never overwrites: a name already taken — two failures in
    /// the same second for the same name — gets `-2`, `-3`, … before `.md`.
    /// The no-overwrite check is the write itself (`.withoutOverwriting`), so
    /// a concurrent writer cannot slip in between a check and the write.
    static func write(
        text: String,
        worktreeName: String,
        directory: URL,
        date: Date,
        timeZone: TimeZone = .current
    ) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = "\(timestamp(date, timeZone: timeZone))-\(sanitizedName(worktreeName))"
        let body = Data((text.hasSuffix("\n") ? text : text + "\n").utf8)
        var attempt = 1
        while true {
            let fileName = attempt == 1 ? "\(stem).md" : "\(stem)-\(attempt).md"
            let url = directory.appendingPathComponent(fileName)
            do {
                try body.write(to: url, options: .withoutOverwriting)
                return url.path
            } catch CocoaError.fileWriteFileExists where attempt < 1000 {
                attempt += 1
            }
        }
    }
}
