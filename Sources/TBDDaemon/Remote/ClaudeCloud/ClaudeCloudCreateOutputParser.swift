import Foundation
import TBDShared

/// Reads the created session's id and its title out of the three prose lines
/// `claude --cloud "<description>"` prints. There is no structured form —
/// `--print` is refused alongside `--cloud` — so those lines are the only
/// channel either value travels on.
///
/// **This is not screen-scraping.** The repository's rule forbids inferring an
/// agent's STATE from a rendered terminal screen; this reads the result line
/// of a non-interactive command TBD itself invoked, the same category as
/// parsing `git`'s output. Nothing here reads a TUI and nothing here infers
/// state — liveness is whatever `list` reports, which for a ledger row is
/// `unknown`.
enum ClaudeCloudCreateOutputParser {
    static let titlePrefix = "Created cloud session: "
    /// The vendor's id shape. Fixed, and printed on all three lines, which is
    /// what makes disagreement detectable. A computed property rather than a
    /// stored `static let`, so building it sidesteps `Regex`'s missing
    /// `Sendable` conformance instead of reaching for `nonisolated(unsafe)`.
    private static var idPattern: Regex<Substring> { /session_[A-Za-z0-9]+/ }

    // `LocalizedError` on the declaration, not a later extension: without an
    // `errorDescription`, `localizedDescription` returns the NSError bridge
    // string and the ids that made a create ambiguous — the whole reason this
    // failure is worth reporting — never reach the log line.
    enum ParseFailure: LocalizedError, Equatable {
        case noSessionID
        case conflictingSessionIDs([String])

        var errorDescription: String? {
            switch self {
            case .noSessionID:
                return
                    "No session id in the create output: `claude --cloud` printed no `session_…` token, so the lane has no identity to record."
            case .conflictingSessionIDs(let ids):
                return
                    "Conflicting session ids in the create output: \(ids.joined(separator: ", ")). The three printed lines must agree on one id."
            }
        }
    }

    /// Strict, and cross-checked against every match — but ONLY on the two
    /// lines whose id is structural: `View:` and `Resume with:`. The third
    /// printed line, `Created cloud session: <title>`, is the vendor's own
    /// server-derived summary of the user's submitted prompt, not a value
    /// with a fixed shape — and a prompt that itself names a
    /// `session_`-prefixed identifier (a filename, a variable, a session the
    /// user asked to resume) makes that line match the id pattern too. Scanning
    /// the whole blob would then see a second, spurious id and fail a create
    /// that actually succeeded, orphaning a real cloud session with no
    /// discovery to ever recover it. Restricting the scan to the two
    /// structural lines keeps the cross-check — two independent witnesses
    /// that must agree — without ever reading the user's own words as if they
    /// were the vendor's identifier.
    ///
    /// An unreadable id costs the lane its identity — there is no session to
    /// record — so zero matches or more than one distinct id is still a
    /// `create` FAILURE rather than a silent empty string.
    static func sessionID(fromOutput raw: String) -> Result<String, ParseFailure> {
        let text = ANSIEscape.strip(raw)
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            .map { String($0) }
        var seen: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("View:") || trimmed.hasPrefix("Resume with:") else { continue }
            for match in trimmed.matches(of: idPattern) {
                let value = String(match.output)
                if !seen.contains(value) { seen.append(value) }
            }
        }
        switch seen.count {
        case 0: return .failure(.noSessionID)
        case 1: return .success(seen[0])
        default: return .failure(.conflictingSessionIDs(seen))
        }
    }

    /// Lenient, and deliberately so. The title line is prose, not a value with
    /// a shape to check, so this parse can only tell whether THIS prefix
    /// matched — a reworded sentence is indistinguishable from a missing one.
    /// A missing or empty title costs nothing but friendliness, because the
    /// row is still named from its id, so it is never a reason to fail a
    /// create that otherwise succeeded. The prefix not matching, the line
    /// being absent, and the remainder being blank after trimming are ONE
    /// outcome: return nil and take the fallback.
    ///
    /// Everything after the prefix up to the next KNOWN line is joined with
    /// single spaces, because a child that formatted to a narrower width than
    /// the pty reports inserts a real newline mid-title.
    static func title(fromOutput raw: String) -> String? {
        let text = ANSIEscape.strip(raw)
        // `split(separator: "\n")` treats `\n` as one specific Character and
        // does not split `"\r\n"` at all — CRLF is a single grapheme cluster
        // in Swift, distinct from `"\n"`. A pty's canonical line discipline
        // emits CRLF by default, and `create` runs on a pty, so that is the
        // realistic case here, not an edge case. `.isNewline` recognizes
        // `\r\n`, lone `\r`, and lone `\n` alike as one separator each.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(where: { $0.hasPrefix(titlePrefix) }) else {
            return nil
        }
        var parts = [String(lines[start].dropFirst(titlePrefix.count))]
        for line in lines[(start + 1)...] {
            // The two other measured lines end the title; so does a blank one.
            if line.isEmpty || line.hasPrefix("View:") || line.hasPrefix("Resume with:") { break }
            parts.append(line)
        }
        let joined = parts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// ANSI-stripped, trimmed, and bounded quoting of raw CLI output for
    /// embedding in a message — shared by `failureMessage` below and by a
    /// non-zero `create` exit that still managed to print a readable id
    /// (`ClaudeCloudCreate.swift`). Bounded because the CLI's output is not a
    /// size TBD controls.
    static func boundedQuote(_ raw: String) -> String {
        let stripped = ANSIEscape.strip(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudeCloudTextBounding.truncated(stripped, limit: 400)
    }

    /// The message a `create` failure carries, quoting what was received so
    /// the `contractBug` on screen names its evidence.
    static func failureMessage(_ failure: ParseFailure, received raw: String) -> String {
        let quoted = boundedQuote(raw)
        switch failure {
        case .noSessionID:
            return "claude --cloud printed no session id; received: \(quoted)"
        case .conflictingSessionIDs(let ids):
            return "claude --cloud printed conflicting session ids "
                + "(\(ids.joined(separator: ", "))); received: \(quoted)"
        }
    }
}
