import Foundation
@testable import TBDGhosttyCore
import TestSupport
import Testing

/// What the core gives an owner that keeps state beside the terminal: the daemon's holder
/// emulator. A feed that runs the owner's closure in the parse's own hold and mutes the parse
/// inside it, the viewport as lines, a count of the probe answers it swaps, and the prelude a
/// snapshot opens with. Design: `docs/specs/2026-11-13-swiftterm-retirement-design.md`, stream C.
@Suite(.fastPassBounded)
struct OwnerFeedTests {
    private static func makeTerminal(
        _ callbacks: GhosttyTerminalCallbacks = GhosttyTerminalCallbacks()
    ) throws -> GhosttyTerminal {
        try GhosttyTerminal(cols: 40, rows: 6, scrollbackLines: 100, callbacks: callbacks)
    }

    private static func bytes(_ text: String) -> ArraySlice<UInt8> { Array(text.utf8)[...] }

    // MARK: - The closure shares the parse's hold

    @Test func underLockRunsInsideTheHoldTheParseRunsIn() throws {
        let terminal = try Self.makeTerminal()
        #expect(!terminal.isLockHeldForTesting, "the lock is held with no call running")
        var heldDuringClosure: Bool?
        terminal.feed(Self.bytes("hello"), underLock: { heldDuringClosure = terminal.isLockHeldForTesting })
        #expect(heldDuringClosure == true, "the closure ran outside the terminal's lock")
        #expect(!terminal.isLockHeldForTesting, "the feed left its lock held")
        #expect(terminal.withLocked { $0.lineText(0) } == "hello")
    }

    @Test func underLockRunsOncePerFeedEvenForNoBytesAndNeverOnceClosed() throws {
        let terminal = try Self.makeTerminal()
        var runs = 0
        terminal.feed(Self.bytes("a"), underLock: { runs += 1 })
        terminal.feed(ArraySlice<UInt8>(), underLock: { runs += 1 })
        #expect(runs == 2, "the closure ran \(runs) times for two feeds")

        terminal.close()
        terminal.feed(Self.bytes("b"), underLock: { runs += 1 })
        #expect(runs == 2, "the closure ran on a closed terminal")
    }

    // MARK: - A mute for one parse

    @Test func aMutedFeedDropsWhatItsBytesProduceAndOnlyThose() throws {
        let recorder = CallbackRecorder()
        let terminal = try Self.makeTerminal(recorder.callbacks)

        // DA1, a bell and an OSC 7501 report, all in one muted parse.
        terminal.feed(
            Self.bytes("\u{1b}[c\u{07}\u{1b}]7501;state=working\u{1b}\\"), muted: true, underLock: {})
        #expect(recorder.total == 0, "a muted feed delivered \(recorder.writes) and \(recorder.statuses)")
        #expect(!terminal.isMuted, "the feed's mute outlived it")

        terminal.feed(text: "\u{1b}[c")
        #expect(recorder.writes.count == 1, "the next, unmuted feed did not answer DA1")
    }

    @Test func aMutedFeedSilencesTheProgramStatusProbe() throws {
        let recorder = CallbackRecorder()
        let terminal = try Self.makeTerminal(recorder.callbacks)

        terminal.feed(Self.bytes("\u{1b}]7501;?\u{07}"), muted: true, underLock: {})
        #expect(recorder.writes.isEmpty, "a muted feed answered the probe with \(recorder.writes)")

        // The control: unmuted, libghostty answers it.
        terminal.feed(text: "\u{1b}]7501;?\u{07}")
        let answered = recorder.writes.contains { $0.starts(with: ProgramStatusProbeAnswer.introducer) }
        #expect(answered, "the unmuted probe drew \(recorder.writes)")
    }

    @Test func aFeedPutsBackTheMuteItFound() throws {
        let terminal = try Self.makeTerminal()
        terminal.isMuted = true
        terminal.feed(Self.bytes("x"), muted: true, underLock: {})
        #expect(terminal.isMuted, "a muted feed lifted a mute set before it")
        terminal.feed(Self.bytes("y"), underLock: {})
        #expect(terminal.isMuted, "an unmuted feed lifted a mute set before it")
    }

    // MARK: - The viewport as lines

    @Test func viewportLinesAreTheRowsWithTrailingEmptyRowsDropped() throws {
        let terminal = try Self.makeTerminal()
        terminal.feed(text: "one\r\n\r\n  three\r\n")
        #expect(terminal.withLocked { $0.viewportLines() } == ["one", "", "  three"])

        terminal.close()
        #expect(terminal.withLocked { $0.viewportLines() }.isEmpty)
    }

    @Test func viewportLinesOfABlankScreenAreEmpty() throws {
        let terminal = try Self.makeTerminal()
        #expect(terminal.withLocked { $0.viewportLines() }.isEmpty)
    }

    // MARK: - Counting the probe answers swapped

    private static let answer = Array("\u{1b}]7501;?libghostty\u{07}".utf8)
    private static let replacement = Array("\u{1b}]7501;?TBD\u{07}".utf8)
    private static let da1 = Array("\u{1b}[?62;22c".utf8)

    @Test func theSwapCountsEveryAnswerItReplaces() {
        let swapped = ProgramStatusProbeAnswer.swappingLibghosttyAnswers(
            in: Self.answer + Self.da1 + Self.answer, with: Self.replacement)
        #expect(swapped.answers == 2)
        #expect(swapped.bytes == Self.replacement + Self.da1 + Self.replacement)
    }

    @Test func theSwapCountsAnswersItRemovesAndNothingElse() {
        let removed = ProgramStatusProbeAnswer.swappingLibghosttyAnswers(in: Self.answer + Self.da1, with: nil)
        #expect(removed.answers == 1)
        #expect(removed.bytes == Self.da1)

        let none = ProgramStatusProbeAnswer.swappingLibghosttyAnswers(in: Self.da1, with: Self.replacement)
        #expect(none.answers == 0)
        #expect(none.bytes == Self.da1)

        // An answer with no terminator is not one libghostty finished, so it is neither swapped
        // nor counted.
        let unfinished = Array(Self.answer.dropLast())
        let open = ProgramStatusProbeAnswer.swappingLibghosttyAnswers(in: unfinished, with: Self.replacement)
        #expect(open.answers == 0)
        #expect(open.bytes == unfinished)
    }

    @Test func theUncountedSwapIsTheCountedOnesBytes() {
        let input = Self.da1 + Self.answer + Self.da1
        #expect(
            ProgramStatusProbeAnswer.replacingLibghosttyAnswers(in: input, with: Self.replacement)
                == ProgramStatusProbeAnswer.swappingLibghosttyAnswers(in: input, with: Self.replacement).bytes)
    }

    // MARK: - The prelude every snapshot opens with

    /// The daemon hands an attaching viewer the prelude alone when a snapshot cannot be written,
    /// on the strength of its being how every snapshot opens.
    @Test func everySnapshotOpensWithTheResetPrelude() throws {
        let terminal = try Self.makeTerminal()
        terminal.feed(text: "\u{1b}[31mred\u{1b}[0m\r\nplain")
        let primary = try GhosttySnapshotWriter.snapshot(of: terminal, maxScrollbackLines: 100)
        #expect(primary.starts(with: GhosttySnapshotWriter.resetPrelude))

        terminal.feed(text: "\u{1b}[?1049halternate")
        let alternate = try GhosttySnapshotWriter.snapshot(of: terminal, maxScrollbackLines: 100)
        #expect(alternate.starts(with: GhosttySnapshotWriter.resetPrelude))
    }
}
