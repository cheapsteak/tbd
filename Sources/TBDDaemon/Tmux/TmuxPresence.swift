import Foundation

/// What a tmux liveness probe actually learned.
///
/// The `Bool` probes (`serverExists`, `windowExists`) collapse two very
/// different answers into `false`: "tmux ran and told us there is no such
/// window" and "we never got an answer at all" — a spawn failure, or the 15 s
/// `TmuxManager.commandTimeout` firing on a server that is merely busy. Callers
/// that destroy state on `false` therefore destroy it on ignorance. Field
/// measurement: a 2026-09-02 daemon restart parked 49 of 56 live lane sessions
/// in one reconcile pass, every row carrying the same `hibernatedAt`, because
/// the machine was still digesting a build and the probes timed out.
///
/// `TmuxPresence` keeps the two apart so a caller can choose. `absent` is a
/// positive statement — tmux itself answered that the server or window does not
/// exist — and is the only value that licenses parking or deleting a row.
public enum TmuxPresence: String, Sendable, Equatable, CustomStringConvertible {
    /// tmux answered and the resource is there.
    case alive
    /// tmux answered and the resource is not there. Positive evidence.
    case absent
    /// No usable answer: a timeout, a spawn failure, or output we cannot
    /// classify. Ignorance, never evidence.
    case unknown

    public var description: String { rawValue }
}

/// Classifies the error a tmux probe threw into a `TmuxPresence`.
///
/// Deliberately a whitelist of tmux's own "it isn't there" messages rather than
/// a blacklist of failures: anything unrecognised has to read as `unknown`, so
/// a future tmux release that renames a message degrades to "leave the row
/// alone" instead of to "destroy it". Only `TmuxError.commandFailed` can ever
/// be `absent` — a `timedOut` never reached tmux, and `unexpectedOutput` means
/// tmux answered something we could not read.
enum TmuxPresenceClassifier {
    /// tmux's phrasing when the server socket has no server behind it. Covers
    /// both a clean "no server running on <socket>" and the connect failure a
    /// missing socket file produces ("error connecting to <socket> (No such
    /// file or directory)").
    /// Kept to tmux's own two phrasings rather than a generic "no such file"
    /// match: a tmux command that failed for an unrelated reason can easily
    /// mention a missing file, and reading that as `absent` would be the exact
    /// mistake this type exists to prevent.
    static let serverAbsentMarkers = [
        "no server running on",
        "error connecting to"
    ]

    /// tmux's phrasing when a server is up but the target window is gone.
    static let windowAbsentMarkers = [
        "can't find window",
        "can't find pane",
        "no such window",
        "window not found"
    ]

    /// The presence a *server* probe should report for a thrown error.
    static func serverPresence(for error: Error) -> TmuxPresence {
        presence(for: error, absentMarkers: serverAbsentMarkers)
    }

    /// The presence a *window* probe should report for a thrown error.
    ///
    /// A server-absent answer counts as window-absent: if there is no server,
    /// there is positively no window on it. The reverse is not true, which is
    /// why the two marker lists stay separate.
    static func windowPresence(for error: Error) -> TmuxPresence {
        presence(for: error, absentMarkers: windowAbsentMarkers + serverAbsentMarkers)
    }

    private static func presence(for error: Error, absentMarkers: [String]) -> TmuxPresence {
        guard case let TmuxError.commandFailed(_, status, output) = error else {
            // `.timedOut` and `.unexpectedOutput` are both "no usable answer".
            return .unknown
        }
        // 127 is this file's own "tmux executable is unavailable" synthetic
        // failure and anything else that never launched a binary. Nothing tmux
        // says about a missing window arrives with it.
        guard status != 127 else { return .unknown }
        let haystack = output.lowercased()
        return absentMarkers.contains(where: haystack.contains) ? .absent : .unknown
    }
}
