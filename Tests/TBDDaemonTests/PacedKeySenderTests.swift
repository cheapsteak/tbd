import Clocks
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib

/// Tier 1 — pure logic plus a `TestClock`. No tmux, no daemon, no filesystem.
///
/// `PacedKeySender` owns two things a `--keys` payload depends on: the
/// tokenizer that decides what a keys string even names, and the 150 ms pause
/// that keeps a redrawing TUI from dropping keys. Both are testable without a
/// pane because the send itself is a closure.
@Suite("Paced key sender", .clockDriven)
struct PacedKeySenderTests {

    /// Records the keys handed to the send closure, in order.
    private final class KeyRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _keys: [String] = []
        var keys: [String] {
            lock.lock(); defer { lock.unlock() }
            return _keys
        }
        func record(_ key: String) {
            lock.lock(); defer { lock.unlock() }
            _keys.append(key)
        }
    }

    // MARK: - Tokenizing

    @Test("a single key tokenizes to one name")
    func singleKey() {
        #expect(PacedKeySender.tokenize("Escape") == ["Escape"])
    }

    @Test("whitespace separates keys, and runs of it collapse")
    func whitespaceSeparates() {
        // Empty tokens cannot survive the split — that is how "reject empty
        // tokens" is satisfied without making a double space an error.
        #expect(PacedKeySender.tokenize("Escape   Enter") == ["Escape", "Enter"])
        #expect(PacedKeySender.tokenize("  C-c\tC-c\n") == ["C-c", "C-c"])
    }

    @Test("a keys value naming nothing is rejected")
    func emptyRejected() {
        #expect(PacedKeySender.tokenize("") == nil)
        #expect(PacedKeySender.tokenize("   \t \n ") == nil)
    }

    /// A `--keys` value is whitespace-split, so a quoting mistake turns one
    /// call into a runaway that types for minutes into a live session.
    ///
    /// **Asserted against literals, not against `maxKeys`.** Spelling the
    /// counts as `maxKeys` and `maxKeys + 1` makes every assertion here move
    /// with the constant, so raising the cap to 100000 leaves this test green —
    /// measured, not assumed. The bound is a contract, so its value is asserted
    /// too.
    @Test("the key count is capped at 32, inclusive at its edge")
    func countCapped() {
        #expect(PacedKeySender.maxKeys == 32)

        let atCap = Array(repeating: "Escape", count: 32).joined(separator: " ")
        #expect(PacedKeySender.tokenize(atCap)?.count == 32)

        let overCap = Array(repeating: "Escape", count: 33).joined(separator: " ")
        #expect(PacedKeySender.tokenize(overCap) == nil)
    }

    // MARK: - Pacing

    @Test("keys are sent in order, one pause apart, with no pause after the last")
    func pacedInOrder() async throws {
        let clock = TestClock()
        let recorder = KeyRecorder()
        let sender = PacedKeySender(clock: clock)

        async let sent: Void = sender.send(["Escape", "C-c", "Enter"]) { recorder.record($0) }

        // The first key goes out with no preceding pause.
        await clock.advanceWhenSuspended(by: PacedKeySender.interKeyPause)
        await clock.advanceWhenSuspended(by: PacedKeySender.interKeyPause)
        try await sent

        #expect(recorder.keys == ["Escape", "C-c", "Enter"])
    }

    /// The pause is real virtual time, not a yield: a send that has not been
    /// advanced past its pause has typed only the keys before it.
    @Test("an un-advanced pause holds the sequence at the key it reached")
    func pauseHoldsTheSequence() async throws {
        let clock = TestClock()
        let recorder = KeyRecorder()
        let sender = PacedKeySender(clock: clock)

        async let sent: Void = sender.send(["Escape", "Enter"]) { recorder.record($0) }
        await clock.waitForSuspension()
        #expect(recorder.keys == ["Escape"])

        await clock.advance(by: PacedKeySender.interKeyPause)
        try await sent
        #expect(recorder.keys == ["Escape", "Enter"])
    }

    /// A partially delivered sequence must surface as a failure, not as a
    /// success that typed half of what was asked for.
    @Test("a throwing send stops the sequence and propagates")
    func throwingSendStops() async throws {
        struct PaneGone: Error {}
        let clock = TestClock()
        let recorder = KeyRecorder()
        let sender = PacedKeySender(clock: clock)

        // The throw is on the FIRST key deliberately: a later one would arm a
        // pause this test would then have to advance, and the point here is
        // that the sequence stops, not how it is paced.
        await #expect(throws: PaneGone.self) {
            try await sender.send(["C-c", "Enter"]) { key in
                recorder.record(key)
                if key == "C-c" { throw PaneGone() }
            }
        }
        #expect(recorder.keys == ["C-c"])
    }

    @Test("a one-key sequence needs no pause at all")
    func singleKeyNeedsNoPause() async throws {
        let clock = TestClock()
        let recorder = KeyRecorder()
        try await PacedKeySender(clock: clock).send(["C-c"]) { recorder.record($0) }
        #expect(recorder.keys == ["C-c"])
    }
}
