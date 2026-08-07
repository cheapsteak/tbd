import Foundation

/// Sends a sequence of named tmux keys one at a time, with a fixed pause
/// between them.
///
/// **Why paced at all.** `LimitResumeActuator.sendContinueSequence` established
/// the reason and the number: an agent TUI redraws between keystrokes, and keys
/// delivered back-to-back through the pty during a redraw get dropped or
/// reordered — the failure that produced `"ontinue"` in a composer. 150 ms
/// between keys is what that rail settled on, and a `--keys` payload types into
/// the same TUIs under the same conditions, so it takes the same pacing rather
/// than inventing a second number.
///
/// **Why the send is a closure.** The type is deliberately ignorant of tmux:
/// the actual `sendKey` call stays inside `RPCRouter+TerminalHandlers.swift`,
/// the file the actuation audit already covers, so a paced sequence cannot
/// become a new unrecorded actuation site (`.swiftlint.yml`'s
/// `actuation_primitive_allowlist`). It also makes the pacing a tier-1 test
/// with no tmux and no daemon.
struct PacedKeySender: Sendable {
    /// The pause between consecutive keys. Same value, same reason, as
    /// `LimitResumeActuator.interKeyPause`.
    static let interKeyPause: Duration = .milliseconds(150)

    /// Upper bound on one payload's key count. A `--keys` value is a
    /// whitespace-split string, so a quoting mistake ("$(seq 1 10000)") turns
    /// one call into a runaway that types for minutes into a live session.
    /// Bounded refusal is cheap; an unbounded one is not undoable.
    static let maxKeys = 32

    private let clock: any Clock<Duration>

    /// - Parameter clock: injected so tests run on virtual time
    ///   (`Tests/CLAUDE.md`, "Clock and date seams"). Existential, last, and
    ///   defaulted, per the repo rule.
    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// Split a `--keys` value into tmux key names.
    ///
    /// Returns `nil` when the value names no coherent key sequence: no tokens
    /// at all (empty or all-whitespace), or more than `maxKeys` of them. Empty
    /// tokens cannot survive the split — runs of whitespace collapse — so
    /// `"Escape   Enter"` is two keys, not four.
    static func tokenize(_ keys: String) -> [String]? {
        let tokens = keys
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty, tokens.count <= maxKeys else { return nil }
        return tokens
    }

    /// Send each key in order, pausing between them but not after the last —
    /// a trailing pause would delay the caller's response for nothing.
    ///
    /// The first `send` that throws stops the sequence and propagates, so a
    /// partially delivered sequence surfaces as a transport failure rather than
    /// as a success that typed half of what was asked for.
    func send(
        _ keys: [String],
        through send: @Sendable (String) async throws -> Void
    ) async throws {
        for (index, key) in keys.enumerated() {
            if index > 0 {
                try await clock.sleep(for: Self.interKeyPause)
            }
            try await send(key)
        }
    }
}
