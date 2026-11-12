import Foundation

/// Condenses git's stderr into the lines that say what went wrong.
///
/// git prints progress meters to stderr even when stderr is a pipe, and it
/// prints its verdict last. A `git worktree add` that ran out of disk space was
/// measured at about 282 KB of stderr: a `Preparing worktree` line, thousands of
/// `Updating files:  NN% (a/b)` meters joined by `\r`, about 2,700
/// `error: failed to open file '…': No space left on device` lines, and last
/// `fatal: Could not reset index file to revision 'HEAD'.` Keeping the first
/// few hundred characters of that keeps only meters, so every message built
/// that way dropped the cause.
///
/// So `summary` drops the meters and keeps lines from the end. The raw text
/// stays on `GitError.stderr`, which the create path classifies failures by.
enum GitStderr {

    /// The lines of `stderr` worth showing, last line last, joined by `\n`
    /// and at most `maxCharacters` long.
    ///
    /// Splits on `\r` as well as `\n`, because a progress meter redraws itself
    /// with `\r`; trims each line, and drops blank lines and progress meters.
    /// When the rest does not fit, it keeps as many whole lines from the end as
    /// fit under a first line saying how many earlier lines were left out. A
    /// line is cut only when the last line alone does not fit, and then its
    /// tail is kept. When every line is a meter, the last meter is kept, since
    /// it says how far git got.
    static func summary(_ stderr: String, maxCharacters: Int) -> String {
        let lines = meaningfulLines(of: stderr)
        let whole = lines.joined(separator: "\n")
        guard whole.count > maxCharacters, let last = lines.last else { return whole }

        // Whole lines from the end, each kept only if the omitted-lines notice
        // still fits above it. The notice shortens as more lines are kept, so
        // the first line that does not fit ends the walk.
        var kept: [String] = []
        var keptLength = 0
        for line in lines.reversed() {
            let length = keptLength + (kept.isEmpty ? 0 : 1) + line.count
            let omitted = lines.count - kept.count - 1
            let total = omitted > 0 ? omittedNotice(omitted).count + 1 + length : length
            guard total <= maxCharacters else { break }
            kept.append(line)
            keptLength = length
        }

        if !kept.isEmpty {
            let omitted = lines.count - kept.count
            return omittedNotice(omitted) + "\n" + kept.reversed().joined(separator: "\n")
        }

        // The last line alone does not fit: keep its tail, where git's
        // sentence ends.
        let notice = lines.count > 1 ? omittedNotice(lines.count - 1) + "\n" : ""
        let room = maxCharacters - notice.count - 1
        guard room > 0 else { return String(last.suffix(max(maxCharacters, 0))) }
        return notice + "…" + String(last.suffix(room))
    }

    /// The first line of a summary that left lines out.
    static func omittedNotice(_ count: Int) -> String {
        "… (\(count) earlier line\(count == 1 ? "" : "s") omitted)"
    }

    /// Every non-blank, trimmed line that is not a progress meter. When that
    /// leaves nothing, the last non-blank line, meter or not.
    static func meaningfulLines(of stderr: String) -> [String] {
        let all = stderr
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let meaningful = all.filter { !isProgressMeter($0) }
        if meaningful.isEmpty, let last = all.last { return [last] }
        return meaningful
    }

    /// Whether `line` is one of git's progress meters:
    /// `Updating files:  45% (1294/2876)`, with or without a trailing
    /// `, done.` or throughput, or the count-only form
    /// `remote: Enumerating objects: 5, done.` Optionally prefixed by
    /// `remote: `, as a server's meters are relayed.
    ///
    /// The count-only form must start with a capital letter, so git's own
    /// `error:`, `fatal:`, `warning:` and `hint:` lines never match it.
    static func isProgressMeter(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return progressMeter.firstMatch(in: line, options: [], range: range) != nil
    }

    private static let progressMeter: NSRegularExpression = {
        let percent = #"^(?:remote: )?[A-Za-z ]+:\s+\d{1,3}% \(\d+/\d+\)"#
        let count = #"^(?:remote: )?[A-Z][A-Za-z ]*: \d+(?:, done\.)?$"#
        return try! NSRegularExpression(pattern: "(?:\(percent))|(?:\(count))")
    }()
}
