import Foundation
import SwiftTerm
@testable import TBDGhosttyTerminal
import TBDTerminalSerialization
import TestSupport
import Testing

/// A screen must survive every handover between the two engines. A libghostty viewer is handed
/// the daemon's SwiftTerm preamble when it attaches, possibly after an earlier life, and on detach
/// it hands its own screen back for the daemon's SwiftTerm emulator to read.
///
/// The first three tests run every corpus state through one crossing and compare what a reader
/// sees: text, widths, colours, attributes, links, the cursor's cell and the active screen. A state
/// may differ only where the two engines hold different screens for the same bytes. Those states
/// are listed with the reason, and each list is exact: a new difference fails, and so does a
/// listed state that stops differing, which means the list is stale. The lists are the proof of
/// concept's misses on its generated states; CI confirms them against the pinned SwiftTerm fork.
/// The tests after them hold the handback's four reorderings and its scrollback cap.
@Suite(.fastPassBounded)
struct HandoverCorpusTests {
    static let freshMisses: [String: String] = [
        "combining-marks": "with grapheme clustering on, libghostty joins क्ष and กำ into one wide cell each, where SwiftTerm keeps their parts in separate cells",
        "vs16-at-edge": "libghostty widens a heart with VS16 to two columns, so in the last column it wraps to the next row; SwiftTerm keeps it one column wide in the last column",
    ]

    static let handbackMisses: [String: String] = [
        "combining-marks": "with grapheme clustering on, libghostty joins क्ष and กำ into one wide cell each, where SwiftTerm keeps their parts in separate cells",
        "overline": "SwiftTerm has no overline, so the overlined cells arrive without it",
        "vs16-at-edge": "libghostty widens a heart with VS16 to two columns, so in the last column it wraps to the next row; SwiftTerm keeps it one column wide in the last column",
    ]

    // MARK: - The corpus through each crossing

    /// The daemon's SwiftTerm preamble, read by a fresh libghostty viewer, against the same
    /// preamble read by a fresh SwiftTerm one.
    @Test(arguments: HandoverCorpus.names)
    func swiftTermWriterIntoFreshGhosttyMatches(_ name: String) throws {
        let state = HandoverCorpus.state(named: name)
        let preamble = state.swiftTerm().writerBytes()
        let swiftTerm = HandoverSwiftTerm(cols: state.cols, rows: state.rows)
        swiftTerm.feed(preamble)
        let ghostty = try Self.freshGhostty(state)
        ghostty.feed(preamble[...])

        let tally = handoverCompare(swiftTerm.handoverScreen(), ghostty.handoverSnap(history: false), history: false)
            .filtered(to: handoverScreenCategories)
        Self.expectOutcome(name, tally: tally, misses: Self.freshMisses, crossing: "SwiftTerm preamble into a fresh libghostty")
    }

    /// The same preamble, read by a libghostty viewer that had an earlier life and was reset, must
    /// leave it exactly as a fresh one: every category, scrollback included. No state may differ.
    @Test(arguments: HandoverCorpus.names)
    func swiftTermWriterIntoReusedGhosttyAfterResetMatches(_ name: String) throws {
        let state = HandoverCorpus.state(named: name)
        let preamble = state.swiftTerm().writerBytes()
        let fresh = try Self.freshGhostty(state)
        fresh.feed(preamble[...])
        let expected = fresh.handoverSnap()
        fresh.close()

        for life in HandoverCorpus.priorLives {
            let reused = try Self.freshGhostty(state)
            reused.feed(life.bytes[...])
            reused.reset()
            reused.feed(preamble[...])
            let tally = handoverCompare(expected, reused.handoverSnap())
            #expect(tally.isEmpty, "\(name), after a \(life.name) life and a reset: \(tally.summary)")
        }
    }

    /// A libghostty viewer's handback, read by a fresh SwiftTerm emulator, against the viewer.
    @Test(arguments: HandoverCorpus.names)
    func ghosttyHandbackIntoSwiftTermMatches(_ name: String) throws {
        let state = HandoverCorpus.state(named: name)
        let source = try state.ghostty()
        let receiver = try Self.handedBack(source, state: state)

        let tally = handoverCompare(source.handoverSnap(history: false), receiver.handoverScreen(), history: false)
            .filtered(to: handoverScreenCategories)
        Self.expectOutcome(name, tally: tally, misses: Self.handbackMisses, crossing: "libghostty handback into SwiftTerm")
    }

    @Test func handoverMissesNameCorpusStates() {
        let names = Set(HandoverCorpus.names)
        for name in Self.freshMisses.keys.sorted() + Self.handbackMisses.keys.sorted() {
            #expect(names.contains(name), "\(name) is listed as a miss but is not a corpus state")
        }
    }

    // MARK: - The handback's reorderings

    /// SwiftTerm shows the cursor on every switch to the alternate screen, so a hidden cursor is
    /// hidden after the switch.
    @Test(arguments: ["hidden-then-alt", "alt-tui-full"])
    func handbackKeepsCursorHiddenOnAlternateScreen(_ name: String) throws {
        let state = HandoverCorpus.state(named: name)
        let source = try state.ghostty()
        #expect(source.withLocked { !$0.isCursorVisible && $0.isAlternateScreen }, "\(name) must leave a hidden cursor on the alternate screen")

        let receiver = try Self.handedBack(source, state: state)
        #expect(receiver.locked { $0.isCurrentBufferAlternate })
        #expect(receiver.mode(25) == false, "\(name): the receiver shows a cursor the viewer hid")
    }

    struct MouseCase: Sendable, CustomTestStringConvertible {
        let state: String
        /// The one tracking mode the handback may set, or 0 for none.
        let mode: Int
        let swiftTerm: SwiftTerm.Terminal.MouseMode

        var testDescription: String { state }
    }

    static let mouseCases: [MouseCase] = [
        MouseCase(state: "mouse-downgrade", mode: 1000, swiftTerm: .vt200),
        MouseCase(state: "mouse-1000", mode: 1000, swiftTerm: .vt200),
        MouseCase(state: "mouse-1002-sgr", mode: 1002, swiftTerm: .buttonEventTracking),
        MouseCase(state: "mouse-1003-sgr", mode: 1003, swiftTerm: .anyEvent),
        MouseCase(state: "mouse-x10", mode: 9, swiftTerm: .x10),
        MouseCase(state: "primary-fresh", mode: 0, swiftTerm: .off),
    ]

    /// After `?1003h ?1000h` libghostty tracks clicks only, but keeps both modes set in its table.
    /// The handback writes only the mode in effect, so the receiver does not track every motion.
    @Test(arguments: HandoverCorpusTests.mouseCases)
    func handbackWritesOnlyTheEffectiveMouseMode(_ mouse: MouseCase) throws {
        let state = HandoverCorpus.state(named: mouse.state)
        let source = try state.ghostty()
        let text = try Self.handbackText(source)
        let written = [9, 1000, 1002, 1003].filter { text.contains("\u{1b}[?\($0)h") }
        #expect(written == (mouse.mode == 0 ? [] : [mouse.mode]), "\(mouse.state) wrote mouse modes \(written)")

        let receiver = HandoverSwiftTerm(cols: state.cols, rows: state.rows)
        receiver.feed(Array(text.utf8))
        #expect(receiver.locked { $0.mouseMode } == mouse.swiftTerm)
    }

    /// SwiftTerm refuses reverse wrap while autowrap is off, so `?45h` goes ahead of `?7l`.
    @Test func handbackTurnsReverseWrapOnBeforeAutowrapOff() throws {
        let state = HandoverCorpus.state(named: "reverse-wrap-no-autowrap")
        let source = try state.ghostty()
        #expect(source.withLocked { $0.mode(45) && !$0.mode(7) })
        let text = try Self.handbackText(source)
        let reverseOn = text.range(of: "\u{1b}[?45h")
        let wrapOff = text.range(of: "\u{1b}[?7l")
        #expect(reverseOn != nil && wrapOff != nil, "the handback must write both modes")
        if let reverseOn, let wrapOff {
            #expect(reverseOn.lowerBound < wrapOff.lowerBound, "?45h must precede ?7l")
        }

        let receiver = HandoverSwiftTerm(cols: state.cols, rows: state.rows)
        receiver.feed(Array(text.utf8))
        #expect(receiver.mode(45) == true)
        #expect(receiver.mode(7) == false)
    }

    /// Two alternate screens whose origin mode differs from the primary's saved one: set only on
    /// the alternate screen, and set only on the primary before the switch.
    static let originStates: [HandoverState] = [
        HandoverCorpus.state(named: "region-origin-alt"),
        HandoverState(
            name: "primary-origin-then-alt",
            bytes: Array("\u{1b}[5;20r\u{1b}[?6h\u{1b}[2;2H\u{1b}[?1049h\u{1b}[?6lx".utf8),
            cols: HandoverCorpus.scenarioCols, rows: HandoverCorpus.scenarioRows),
    ]

    /// Origin mode belongs to the screen that set it. libghostty saves it with the cursor on
    /// `?1049h` and restores it on `?1049l`, and so does SwiftTerm, so the handback must leave the
    /// receiver's saved primary cursor with the primary's origin mode and its alternate screen with
    /// the live one. Written in the formatter's order, the alternate screen's `?6h` would come
    /// before the switch and be saved with the primary's cursor.
    @Test(arguments: HandoverCorpusTests.originStates)
    func handbackRestoresThePrimaryOriginModeOnLeavingTheAlternateScreen(_ state: HandoverState) throws {
        let source = try state.ghostty()
        #expect(source.withLocked { $0.isAlternateScreen })
        let receiver = try Self.handedBack(source, state: state)
        #expect(receiver.locked { $0.isCurrentBufferAlternate })

        let leave = Array("\u{1b}[?1049l".utf8)
        for leaving in [false, true] {
            if leaving {
                source.feed(leave[...])
                receiver.feed(leave)
            }
            let screen = leaving ? "after leaving the alternate screen" : "on the alternate screen"
            let sourceOrigin = source.withLocked { $0.mode(6) }
            #expect(receiver.mode(6) == sourceOrigin, "\(state.name), \(screen): origin mode differs")
            let expected = source.withLocked { GhosttyScreenProjection.project($0, maxLines: 0) }
            let actual = receiver.locked { TerminalScreenProjection.project($0, maxLines: 0) }
            #expect(
                actual.cursorColumn == expected.cursorColumn && actual.cursorRow == expected.cursorRow,
                "\(state.name), \(screen): cursor \(actual.cursorColumn),\(actual.cursorRow) vs \(expected.cursorColumn),\(expected.cursorRow) (x,y)")
        }
    }

    // MARK: - The scrollback cap

    /// 5,000 lines with a cap of 1,000 replay to 1,000 lines of scrollback, the newest ones.
    @Test func handbackRespectsScrollbackCap() throws {
        let cols = 80, rows = 24, cap = 1_000, kept = 10_000
        let source = try GhosttyTerminal(cols: cols, rows: rows, scrollbackLines: kept, callbacks: GhosttyTerminalCallbacks())
        source.feed(Array((0..<5_000).map { "line \($0)\r\n" }.joined().utf8)[...])
        let sourceHistory = source.withLocked { $0.scrollbackRows }
        #expect(sourceHistory > cap, "the source must hold more scrollback than the cap, not \(sourceHistory) rows")

        let handback = try GhosttySnapshotWriter.snapshot(of: source, maxScrollbackLines: cap)
        let receiver = HandoverSwiftTerm(cols: cols, rows: rows, scrollback: kept)
        receiver.feed([UInt8](handback))
        let replayed = receiver.locked { TerminalScreenProjection.project($0, maxLines: kept + rows) }
        #expect(replayed.viewportStart <= cap, "the receiver holds \(replayed.viewportStart) rows of scrollback")

        // The newest scrollback and the screen arrive intact.
        let expected = source.withLocked { GhosttyScreenProjection.project($0, maxLines: cap + rows) }
        let actual = receiver.locked { TerminalScreenProjection.project($0, maxLines: cap + rows) }
        #expect(actual.viewportStart == expected.viewportStart)
        #expect(actual.lines == expected.lines, "\(handoverFirstDifference(expected.lines, actual.lines))")
        #expect(actual.cursorRow == expected.cursorRow && actual.cursorColumn == expected.cursorColumn)
    }

    // MARK: - Helpers

    /// A libghostty viewer of the state's size that has read nothing.
    private static func freshGhostty(_ state: HandoverState) throws -> GhosttyTerminal {
        try GhosttyTerminal(
            cols: state.cols, rows: state.rows, scrollbackLines: handoverScrollback, callbacks: GhosttyTerminalCallbacks())
    }

    /// A fresh SwiftTerm emulator that has read `source`'s handback.
    private static func handedBack(_ source: GhosttyTerminal, state: HandoverState) throws -> HandoverSwiftTerm {
        let handback = try GhosttySnapshotWriter.snapshot(of: source, maxScrollbackLines: handoverScrollback)
        let receiver = HandoverSwiftTerm(cols: state.cols, rows: state.rows)
        receiver.feed([UInt8](handback))
        return receiver
    }

    private static func handbackText(_ source: GhosttyTerminal) throws -> String {
        let handback = try GhosttySnapshotWriter.snapshot(of: source, maxScrollbackLines: handoverScrollback)
        return String(bytes: handback, encoding: .utf8) ?? ""
    }

    private static func expectOutcome(_ name: String, tally: HandoverTally, misses: [String: String], crossing: String) {
        if let reason = misses[name] {
            #expect(
                !tally.isEmpty,
                "\(name) is a known miss for the \(crossing) (\(reason)) but now matches: remove it from the list")
        } else {
            #expect(tally.isEmpty, "\(name): the \(crossing) differs on screen: \(tally.summary)")
        }
    }
}

extension HandoverState: CustomTestStringConvertible {
    var testDescription: String { name }
}
