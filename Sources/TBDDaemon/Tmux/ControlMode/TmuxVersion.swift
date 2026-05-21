import Foundation

/// A parsed tmux version, comparable so callers can gate features on a minimum.
///
/// Only numeric `major.minor` is significant; a trailing letter suffix
/// (`a`, `b`, …) is preserved for logging but ignored in comparisons.
struct TmuxVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let suffix: String

    init(major: Int, minor: Int, suffix: String = "") {
        self.major = major
        self.minor = minor
        self.suffix = suffix
    }

    /// Parse the output of `tmux -V`, e.g. "tmux 3.6a\n". Returns nil when no
    /// `<int>.<int>` token is present.
    static func parse(_ output: String) -> TmuxVersion? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in trimmed.split(whereSeparator: { $0 == " " || $0 == "-" }) {
            guard let dot = token.firstIndex(of: ".") else { continue }
            let majorPart = token[token.startIndex..<dot]
            let afterDot = token[token.index(after: dot)...]
            guard !majorPart.isEmpty, let major = Int(majorPart) else { continue }
            let minorDigits = afterDot.prefix(while: { $0.isNumber })
            guard !minorDigits.isEmpty, let minor = Int(minorDigits) else { continue }
            let suffix = String(afterDot.dropFirst(minorDigits.count))
            return TmuxVersion(major: major, minor: minor, suffix: suffix)
        }
        return nil
    }

    static func < (lhs: TmuxVersion, rhs: TmuxVersion) -> Bool {
        lhs.major != rhs.major ? lhs.major < rhs.major : lhs.minor < rhs.minor
    }

    static func == (lhs: TmuxVersion, rhs: TmuxVersion) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor
    }

    var description: String { "\(major).\(minor)\(suffix)" }

    /// Minimum version for the control-mode feature set (`%pause`/`%continue`,
    /// `%extended-output`, `pause-after`, `window-size manual`). Spec constraint.
    static let controlModeMinimum = TmuxVersion(major: 3, minor: 2)
}

extension TmuxVersion {
    /// Run `tmux -V` once and parse the result. Returns nil on any failure
    /// (tmux not installed, non-zero exit, unparseable output).
    static func detect(tmuxBinary: String = TmuxManager.tmuxPath()) async -> TmuxVersion? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: tmuxBinary)
            process.arguments = ["-V"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: TmuxVersion.parse(String(decoding: data, as: UTF8.self)))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
