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
/// The first three tests run every state, the corpus's and the review's, through one crossing and
/// compare everything `handoverCompare` reads: the screen and its scrollback, the cursor, the
/// modes, the mouse modes in effect, the region, the pen and the kitty flags. A state may differ
/// only where the two engines hold different screens for the same bytes, and only in the
/// categories its entry names. Each list is exact: a new difference fails, a difference outside a
/// listed state's categories fails, and so does a listed state that stops differing, which means
/// the list is stale. The lists are the proof of concept's misses on its generated states; CI
/// confirms them against the pinned SwiftTerm fork.
///
/// On an alternate screen each of the three also leaves it, the way the state entered it, and
/// compares again: the primary screen behind it, with its scrollback, and what the leave puts
/// back. There the two engines may also differ in `oneValueForBothScreens`, so the handback's
/// receiver is held as well to SwiftTerm fed the program's own bytes, in every category. The tests
/// after them hold the handback's reorderings, its scrollback cap and a detach inside a sequence.
///
/// Every body runs on a thread the tests own, one at a time: see `onHandoverThread`.
@Suite(.serialized, .fastPassBounded)
struct HandoverCorpusTests {
    static let clustering = HandoverMiss(
        reason: "with grapheme clustering on, libghostty joins क्ष and กำ into one wide cell each, where SwiftTerm keeps their parts in separate cells",
        categories: ["text", "wide"])

    static let heartAtTheEdge = HandoverMiss(
        reason: "libghostty widens a heart with VS16 to two columns, so in the last column it wraps to the next row; SwiftTerm keeps it one column wide in the last column",
        categories: ["text", "wide"])

    static let freshMisses: [String: HandoverMiss] = [
        "combining-marks": clustering,
        "vs16-at-edge": heartAtTheEdge,
    ]

    static let handbackMisses: [String: HandoverMiss] = [
        "combining-marks": clustering,
        "overline": HandoverMiss(
            reason: "SwiftTerm has no overline, so the overlined cells arrive without it", categories: ["attrs"]),
        "vs16-at-edge": heartAtTheEdge,
    ]

    /// What the two engines may differ in once a program has left the alternate screen, whatever
    /// crossed. Every alternate-screen state shares it, so it is not held to differing.
    static let oneValueForBothScreens = HandoverMiss(
        reason: "libghostty keeps one scrolling region, autowrap, reverse wrap and DECLRMM for both screens and leaves the cursor's visibility alone on a switch; SwiftTerm keeps a region per screen, puts back the modes its `?1049h` saved, and shows the cursor on every switch",
        categories: ["region", "mode.DECAWM", "mode.reverseWrap", "mode.DECLRMM", "cursorVisible", "mode.DECTCEM"])

    // MARK: - Every state through each crossing

    /// The daemon's SwiftTerm preamble, read by a fresh libghostty viewer, against the same
    /// preamble read by a fresh SwiftTerm one.
    @Test(arguments: HandoverFixtures.names)
    func swiftTermWriterIntoFreshGhosttyMatches(_ name: String) async throws {
        try await onHandoverThread {
            let state = HandoverFixtures.state(named: name)
            let preamble = HandoverFixtures.preamble(named: name)
            let swiftTerm = HandoverSwiftTerm(cols: state.cols, rows: state.rows)
            swiftTerm.feed(preamble)
            let ghostty = try Self.freshGhostty(state)
            ghostty.feed(preamble[...])

            let tally = handoverCompare(swiftTerm.handoverSnap(), ghostty.handoverSnap())
                .excluding(handoverInertCategories)
            let crossing = "SwiftTerm preamble into a fresh libghostty"
            Self.expectOutcome(name, tally: tally, misses: Self.freshMisses, crossing: crossing)

            guard let leave = Self.leave(state, on: ghostty) else { return }
            swiftTerm.feed(leave)
            ghostty.feed(leave[...])
            let left = handoverCompare(swiftTerm.handoverSnap(), ghostty.handoverSnap())
                .excluding(Self.allowedAfterLeaving(name, misses: Self.freshMisses))
            #expect(left.isEmpty, "\(name), \(crossing), then \(Self.describe(leave)): \(left.summary)")
        }
    }

    /// The same preamble, read by a libghostty viewer that had an earlier life and was reset, must
    /// leave it exactly as a fresh one: every category, scrollback included. No state may differ.
    @Test(arguments: HandoverFixtures.names)
    func swiftTermWriterIntoReusedGhosttyAfterResetMatches(_ name: String) async throws {
        try await onHandoverThread {
            let state = HandoverFixtures.state(named: name)
            let preamble = HandoverFixtures.preamble(named: name)
            let fresh = try Self.freshGhostty(state)
            fresh.feed(preamble[...])
            let expected = fresh.handoverSnap()
            // On an alternate screen, the same again once the program has left it.
            let leave = Self.leave(state, on: fresh)
            var expectedLeft: HandoverSnap?
            if let leave {
                fresh.feed(leave[...])
                expectedLeft = fresh.handoverSnap()
            }
            fresh.close()

            for life in HandoverCorpus.priorLives {
                let reused = try Self.freshGhostty(state)
                reused.feed(life.bytes[...])
                reused.reset()
                reused.feed(preamble[...])
                let tally = handoverCompare(expected, reused.handoverSnap())
                #expect(tally.isEmpty, "\(name), after a \(life.name) life and a reset: \(tally.summary)")
                if let leave, let expectedLeft {
                    reused.feed(leave[...])
                    let left = handoverCompare(expectedLeft, reused.handoverSnap())
                    #expect(
                        left.isEmpty,
                        "\(name), after a \(life.name) life and a reset, then \(Self.describe(leave)): \(left.summary)")
                }
            }
        }
    }

    /// A libghostty viewer's handback, read by a fresh SwiftTerm emulator, against the viewer. The
    /// viewer's scrollback is cut to the newest rows the handback carries.
    ///
    /// Once the program leaves an alternate screen, the receiver is compared with the viewer and
    /// with SwiftTerm fed the program's own bytes. The viewer cannot say what `?1049l` puts back
    /// of autowrap, reverse wrap and DECLRMM, because libghostty keeps one of each for both
    /// screens; SwiftTerm fed the program's bytes can. So a handback that sets one of them before
    /// the switch, where the receiver's `?1049h` saves it as the primary's, differs from the
    /// second.
    @Test(arguments: HandoverFixtures.names)
    func ghosttyHandbackIntoSwiftTermMatches(_ name: String) async throws {
        try await onHandoverThread {
            let state = HandoverFixtures.state(named: name)
            let source = try state.ghostty()
            let receiver = try Self.handedBack(source, state: state)

            let expected = source.handoverSnap().keepingNewestHistory(handoverScrollback)
            let tally = handoverCompare(expected, receiver.handoverSnap()).excluding(handoverInertCategories)
            let crossing = "libghostty handback into SwiftTerm"
            Self.expectOutcome(name, tally: tally, misses: Self.handbackMisses, crossing: crossing)

            guard let leave = Self.leave(state, on: source) else { return }
            let direct = state.swiftTerm()
            source.feed(leave[...])
            receiver.feed(leave)
            direct.feed(leave)
            let received = receiver.handoverSnap()
            let allowed = Self.allowedAfterLeaving(name, misses: Self.handbackMisses)
            let fromViewer = handoverCompare(source.handoverSnap().keepingNewestHistory(handoverScrollback), received)
                .excluding(allowed)
            #expect(
                fromViewer.isEmpty,
                "\(name), \(crossing), then \(Self.describe(leave)): the receiver differs from the viewer: \(fromViewer.summary)")
            let fromDirect = handoverCompare(direct.handoverSnap().keepingNewestHistory(handoverScrollback), received)
                .excluding(allowed.subtracting(Self.oneValueForBothScreens.categories))
            #expect(
                fromDirect.isEmpty,
                "\(name), \(crossing), then \(Self.describe(leave)): the receiver differs from SwiftTerm fed the program's bytes: \(fromDirect.summary)")
        }
    }

    @Test func handoverMissesNameStatesAndCategories() {
        let names = Set(HandoverFixtures.names)
        for (name, miss) in Array(Self.freshMisses) + Array(Self.handbackMisses) {
            #expect(names.contains(name), "\(name) is listed as a miss but is not a state")
            #expect(!miss.categories.isEmpty, "\(name) is listed as a miss with no category it may differ in")
        }
    }

    // MARK: - A program that leaves while a viewer is attached

    struct ProgramLeave: Sendable, CustomTestStringConvertible {
        let state: String
        /// The reset the program leaves with, the one that matches how the state entered.
        let leave: String

        var testDescription: String { "\(state), then \(leave.debugDescription)" }
    }

    static let programLeaves: [ProgramLeave] = [
        ProgramLeave(state: "alt-legacy-47", leave: "\u{1b}[?47l"),
        ProgramLeave(state: "alt-47-cursor-moved", leave: "\u{1b}[?47l"),
        ProgramLeave(state: "alt-1047", leave: "\u{1b}[?1047l"),
        ProgramLeave(state: "alt-1047-cursor-moved", leave: "\u{1b}[?1047l"),
        ProgramLeave(state: "alt-saved-cursor", leave: "\u{1b}[?1049l"),
    ]

    /// A viewer attaches on an alternate screen, the program leaves it, and the viewer detaches.
    /// The daemon's preamble enters with `?1049h`, and libghostty sets or resets only the bit of
    /// the mode it is given, so after `?47l` or `?1047l` the `?1049` bit stays set on the primary
    /// screen. A handback that took the switch from the mode table would switch the receiver to its
    /// alternate screen and write the primary there. Fed the handback, the receiver must match
    /// SwiftTerm fed the program's own bytes and its leave, in every category.
    @Test(arguments: HandoverCorpusTests.programLeaves)
    func handbackAfterTheProgramLeftTheAlternateScreenMatches(_ program: ProgramLeave) async throws {
        try await onHandoverThread {
            let state = HandoverFixtures.state(named: program.state)
            let leave = Array(program.leave.utf8)
            let viewer = try Self.freshGhostty(state)
            viewer.feed(HandoverFixtures.preamble(named: program.state)[...])
            #expect(viewer.withLocked { $0.isAlternateScreen }, "\(program.state) must attach on the alternate screen")
            viewer.feed(leave[...])
            #expect(viewer.withLocked { !$0.isAlternateScreen }, "\(program.testDescription) must leave the alternate screen")

            let receiver = try Self.handedBack(viewer, state: state)
            #expect(receiver.locked { !$0.isCurrentBufferAlternate }, "\(program.testDescription): the receiver is on its alternate screen")
            let direct = state.swiftTerm()
            direct.feed(leave)
            let tally = handoverCompare(direct.handoverSnap(), receiver.handoverSnap()).excluding(handoverInertCategories)
            #expect(
                tally.isEmpty,
                "\(program.testDescription), with a viewer attached, then handed back: the receiver differs from SwiftTerm fed the program's bytes: \(tally.summary)")
        }
    }

    // MARK: - The handback's reorderings

    /// SwiftTerm shows the cursor on every switch to the alternate screen, so a hidden cursor is
    /// hidden after the switch.
    @Test(arguments: ["hidden-then-alt", "alt-tui-full"])
    func handbackKeepsCursorHiddenOnAlternateScreen(_ name: String) async throws {
        try await onHandoverThread {
            let state = HandoverFixtures.state(named: name)
            let source = try state.ghostty()
            #expect(
                source.withLocked { !$0.isCursorVisible && $0.isAlternateScreen },
                "\(name) must leave a hidden cursor on the alternate screen")

            let receiver = try Self.handedBack(source, state: state)
            #expect(receiver.locked { $0.isCurrentBufferAlternate })
            #expect(receiver.mode(25) == false, "\(name): the receiver shows a cursor the viewer hid")
        }
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
        MouseCase(state: "mouse-crossterm", mode: 1003, swiftTerm: .anyEvent),
        MouseCase(state: "mouse-1000", mode: 1000, swiftTerm: .vt200),
        MouseCase(state: "mouse-1002-sgr", mode: 1002, swiftTerm: .buttonEventTracking),
        MouseCase(state: "mouse-1003-sgr", mode: 1003, swiftTerm: .anyEvent),
        MouseCase(state: "mouse-x10", mode: 9, swiftTerm: .x10),
        MouseCase(state: "primary-fresh", mode: 0, swiftTerm: .off),
    ]

    /// After `?1003h ?1000h` libghostty tracks clicks only, but keeps both modes set in its table.
    /// The handback writes only the mode in effect, so the receiver does not track every motion.
    @Test(arguments: HandoverCorpusTests.mouseCases)
    func handbackWritesOnlyTheEffectiveMouseMode(_ mouse: MouseCase) async throws {
        try await onHandoverThread {
            let state = HandoverFixtures.state(named: mouse.state)
            let source = try state.ghostty()
            let text = try Self.handbackText(source)
            let written = handoverMouseTrackingModes.sorted().filter { text.contains("\u{1b}[?\($0)h") }
            #expect(written == (mouse.mode == 0 ? [] : [mouse.mode]), "\(mouse.state) wrote mouse modes \(written)")

            let receiver = HandoverSwiftTerm(cols: state.cols, rows: state.rows)
            receiver.feed(Array(text.utf8))
            #expect(receiver.locked { $0.mouseMode } == mouse.swiftTerm)
        }
    }

    struct EncodingCase: Sendable, CustomTestStringConvertible {
        let state: String
        /// The one encoding the handback may set, or 0 for X10's.
        let encoding: Int

        var testDescription: String { state }
    }

    static let encodingCases: [EncodingCase] = [
        EncodingCase(state: "mouse-crossterm", encoding: 1006),
        EncodingCase(state: "mouse-urxvt", encoding: 1015),
        EncodingCase(state: "mouse-utf8", encoding: 1005),
        EncodingCase(state: "mouse-sgr-pixels", encoding: 1016),
        EncodingCase(state: "mouse-1002-sgr", encoding: 1006),
        EncodingCase(state: "mouse-1000", encoding: 0),
    ]

    /// libghostty reports in the encoding set last and keeps the others set in its table, and
    /// SwiftTerm uses the last one written. crossterm sets `?1015h` and then `?1006h`, so in the
    /// formatter's number order the receiver would report in urxvt's encoding, which cannot name
    /// a column past 223 to every reader. The handback writes only the encoding in effect.
    @Test(arguments: HandoverCorpusTests.encodingCases)
    func handbackWritesOnlyTheEffectiveMouseEncoding(_ mouse: EncodingCase) async throws {
        try await onHandoverThread {
            let state = HandoverFixtures.state(named: mouse.state)
            let source = try state.ghostty()
            #expect(source.withLocked { $0.mouseEncodingInEffect } == mouse.encoding)
            let text = try Self.handbackText(source)
            let written = handoverMouseEncodingModes.sorted().filter { text.contains("\u{1b}[?\($0)h") }
            #expect(written == (mouse.encoding == 0 ? [] : [mouse.encoding]), "\(mouse.state) wrote encodings \(written)")

            let receiver = HandoverSwiftTerm(cols: state.cols, rows: state.rows)
            receiver.feed(Array(text.utf8))
            #expect(receiver.handoverSnap(history: false).mouseEncoding == mouse.encoding)
        }
    }

    /// The review's case end to end: after crossterm's `?1015h ?1006h`, a click in column 251 that
    /// the receiver reports is an SGR report.
    @Test func handbackReceiverReportsAClickInSGRAfterCrosstermsModes() async throws {
        try await onHandoverThread {
            let state = HandoverFixtures.state(named: "mouse-crossterm")
            let receiver = try Self.handedBack(try state.ghostty(), state: state)
            let report = receiver.locked { terminal in
                receiver.collector.bytes.removeAll()
                terminal.sendEvent(buttonFlags: 0, x: 250, y: 5)
                return receiver.collector.bytes
            }
            #expect(String(bytes: report, encoding: .utf8) == "\u{1b}[<0;251;6M")
        }
    }

    /// SwiftTerm refuses reverse wrap while autowrap is off, so `?45h` must land while autowrap is
    /// still on. The handback writes `?7l` last.
    @Test func handbackTurnsReverseWrapOnBeforeAutowrapOff() async throws {
        try await onHandoverThread {
            let state = HandoverFixtures.state(named: "reverse-wrap-no-autowrap")
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
    }

    /// The formatter writes a soft-wrapped line as one run, which lays out only while autowrap is
    /// on. Written in the formatter's order, `?7l` came before the rows, and the receiver wrote
    /// the rest of each wrapped line over its last column. It now comes after every row.
    @Test func handbackLaysOutWrappedLinesBeforeTurningAutowrapOff() async throws {
        try await onHandoverThread {
            let state = HandoverFixtures.state(named: "wrapped-history-then-nowrap")
            let source = try state.ghostty()
            #expect(source.withLocked { !$0.mode(7) && $0.historyRowCount > 0 })
            let text = try Self.handbackText(source)
            let wrapOff = text.range(of: "\u{1b}[?7l")
            let lastRow = text.range(of: "v", options: .backwards)
            #expect(wrapOff != nil && lastRow != nil, "the handback must write autowrap off and the wrapped row")
            if let wrapOff, let lastRow {
                #expect(lastRow.lowerBound < wrapOff.lowerBound, "?7l must follow the rows")
            }

            let receiver = HandoverSwiftTerm(cols: state.cols, rows: state.rows)
            receiver.feed(Array(text.utf8))
            #expect(receiver.mode(7) == false)
            let tally = handoverCompare(source.handoverSnap(), receiver.handoverSnap()).excluding(handoverInertCategories)
            #expect(tally.isEmpty, "the wrapped rows arrive changed: \(tally.summary)")
        }
    }

    /// SwiftTerm's `?1049h` saves autowrap, reverse wrap and DECLRMM with the cursor, and its
    /// `?1049l` puts them back. libghostty keeps one of each for both screens and saves none, so
    /// the handback writes the alternate screen's values after the switch and the receiver saves
    /// the defaults for the primary. Written before the switch, autowrap off would be saved as the
    /// primary's, and a program that turns it back on as it leaves would leave it off.
    @Test func handbackLeavesAutowrapOnWhenTheProgramTurnsItBackOnAndLeaves() async throws {
        try await onHandoverThread {
            let state = HandoverFixtures.state(named: "alt-tui-nowrap")
            let source = try state.ghostty()
            #expect(source.withLocked { $0.isAlternateScreen && !$0.mode(7) })
            let receiver = try Self.handedBack(source, state: state)
            #expect(receiver.mode(7) == false, "the alternate screen's autowrap must arrive off")

            let leave = Array("\u{1b}[?7h\u{1b}[?1049l".utf8)
            source.feed(leave[...])
            receiver.feed(leave)
            #expect(source.withLocked { $0.mode(7) })
            #expect(receiver.mode(7) == true, "autowrap is off after the program turned it on and left")
            let tally = handoverCompare(source.handoverSnap(history: false), receiver.handoverSnap(history: false), history: false)
                .filtered(to: handoverScreenCategories)
            #expect(tally.isEmpty, "the primary screen differs after the program left: \(tally.summary)")
        }
    }

    /// Two alternate screens whose origin mode differs from the primary's saved one: set only on
    /// the alternate screen, and set only on the primary before the switch.
    static let originStates: [HandoverState] = [
        HandoverFixtures.state(named: "region-origin-alt"),
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
    func handbackRestoresThePrimaryOriginModeOnLeavingTheAlternateScreen(_ state: HandoverState) async throws {
        try await onHandoverThread {
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
    }

    // MARK: - The scrollback cap

    struct CapCase: Sendable, CustomTestStringConvertible {
        let name: String
        /// What follows the 5,000 lines: nothing, or a switch to the alternate screen.
        let tail: String
        /// What leaves the alternate screen before the scrollback is compared, or nothing.
        let leave: String

        var testDescription: String { name }
    }

    static let capCases: [CapCase] = [
        CapCase(name: "on the primary screen", tail: "", leave: ""),
        CapCase(name: "on the alternate screen", tail: "\u{1b}[?1049h\u{1b}[2;3Hin alt", leave: "\u{1b}[?1049l"),
    ]

    /// 5,000 lines with a cap of 1,000 replay to 1,000 lines of scrollback, the newest ones. On the
    /// alternate screen the primary's scrollback comes from the clone, and it is compared once
    /// both have left the alternate screen.
    @Test(arguments: HandoverCorpusTests.capCases)
    func handbackRespectsScrollbackCap(_ capCase: CapCase) async throws {
        try await onHandoverThread {
            let cols = 80, rows = 24, cap = 1_000, kept = 10_000
            let source = try GhosttyTerminal(
                cols: cols, rows: rows, scrollbackLines: kept, callbacks: GhosttyTerminalCallbacks())
            source.feed(Array(((0..<5_000).map { "line \($0)\r\n" }.joined() + capCase.tail).utf8)[...])

            let handback = try GhosttySnapshotWriter.snapshot(of: source, maxScrollbackLines: cap)
            let receiver = HandoverSwiftTerm(cols: cols, rows: rows, scrollback: kept)
            receiver.feed([UInt8](handback))
            #expect(receiver.locked { $0.isCurrentBufferAlternate } == !capCase.leave.isEmpty)
            let leave = Array(capCase.leave.utf8)
            source.feed(leave[...])
            receiver.feed(leave)

            let sourceHistory = source.withLocked { $0.scrollbackRows }
            #expect(sourceHistory > cap, "the source must hold more scrollback than the cap, not \(sourceHistory) rows")
            let replayed = receiver.locked { TerminalScreenProjection.project($0, maxLines: kept + rows) }
            #expect(replayed.viewportStart <= cap, "the receiver holds \(replayed.viewportStart) rows of scrollback")

            // The newest scrollback and the screen arrive intact.
            let expected = source.withLocked { GhosttyScreenProjection.project($0, maxLines: cap + rows) }
            let actual = receiver.locked { TerminalScreenProjection.project($0, maxLines: cap + rows) }
            #expect(actual.viewportStart == expected.viewportStart)
            #expect(actual.lines == expected.lines, "\(handoverFirstDifference(expected.lines, actual.lines))")
            #expect(actual.cursorRow == expected.cursorRow && actual.cursorColumn == expected.cursorColumn)
        }
    }

    // MARK: - A detach inside a sequence

    struct UnfinishedTail: Sendable, CustomTestStringConvertible {
        let name: String
        /// What the viewer's terminal read before it detached.
        let head: [UInt8]
        /// The rest of the sequence and what follows it, which arrive after the handback.
        let rest: [UInt8]
        /// What the rest writes at the cursor, and the colour of its first cell.
        let written: String
        let foreground: HandoverColor

        var testDescription: String { name }
    }

    static let unfinishedTails: [UnfinishedTail] = [
        UnfinishedTail(
            name: "half an SGR colour", head: Array("\u{1b}[38;5".utf8), rest: Array(";196mX\u{1b}[0m".utf8),
            written: "X", foreground: .palette(196)),
        UnfinishedTail(
            name: "half a UTF-8 character", head: [0xe2, 0x94], rest: [0x80] + Array("X".utf8),
            written: "─X", foreground: .standard),
        UnfinishedTail(
            name: "half a window title", head: Array("\u{1b}]2;half a ti".utf8), rest: Array("tle\u{07}X".utf8),
            written: "X", foreground: .standard),
    ]

    /// A viewer can detach while its terminal is inside a sequence. The handback ends with the
    /// sequence's unfinished bytes, so the receiver's parser is left inside it and the live bytes
    /// that follow finish it. Fed the handback and then the rest, the receiver must match a
    /// SwiftTerm emulator that read the whole stream: the screen in view, the primary screen under
    /// an alternate one, and the cells the finished sequence wrote.
    @Test(arguments: ["sgr-colors", "alt-tui-full"], HandoverCorpusTests.unfinishedTails)
    func handbackFinishesTheSequenceTheTerminalStoppedInside(_ name: String, _ tail: UnfinishedTail) async throws {
        try await onHandoverThread {
            let state = HandoverFixtures.state(named: name)
            let source = try state.ghostty()
            source.feed(tail.head[...])
            #expect(source.withLocked { !$0.isAtGround }, "\(name) must be left inside \(tail.name)")

            let receiver = try Self.handedBack(source, state: state)
            receiver.feed(tail.rest)
            let reference = HandoverSwiftTerm(cols: state.cols, rows: state.rows)
            reference.feed(state.bytes + tail.head + tail.rest)

            for terminal in [reference, receiver] {
                let (text, foreground) = Self.writtenBeforeCursor(terminal, count: tail.written.unicodeScalars.count)
                #expect(text == tail.written, "\(name), \(tail.name): the rest wrote \(text.debugDescription)")
                #expect(foreground == tail.foreground, "\(name), \(tail.name): its first cell is \(foreground)")
            }
            Self.expectSameScreen(reference, receiver, "\(name), stopped inside \(tail.name)")
            if reference.locked({ $0.isCurrentBufferAlternate }) {
                let leave = Array("\u{1b}[?1049l".utf8)
                reference.feed(leave)
                receiver.feed(leave)
                Self.expectSameScreen(reference, receiver, "\(name), stopped inside \(tail.name), on the primary screen")
            }
        }
    }

    struct OverlongSequence: Sendable, CustomTestStringConvertible {
        let name: String
        /// More of one sequence than libghostty keeps.
        let head: [UInt8]
        /// The end of the sequence, which arrives after the handback.
        let rest: [UInt8]

        var testDescription: String { name }
    }

    static let overlongSequences: [OverlongSequence] = {
        let base64 = String(repeating: "QUJD", count: 17_500)
        return [
            OverlongSequence(
                name: "a window title", head: Array(("\u{1b}]2;" + String(repeating: "t", count: 70_000)).utf8),
                rest: Array("t\u{07}".utf8)),
            OverlongSequence(
                name: "an OSC 52 copy", head: Array(("\u{1b}]52;c;" + base64).utf8), rest: Array("QUJD\u{07}".utf8)),
            OverlongSequence(
                name: "a sixel image",
                head: Array(("\u{1b}Pq\"1;1;10;10#0;2;100;0;0#0" + String(repeating: "~", count: 70_000)).utf8),
                rest: Array("~-\u{1b}\\".utf8)),
            OverlongSequence(
                name: "a kitty graphics image", head: Array(("\u{1b}_Ga=t,f=100,i=1;" + base64).utf8),
                rest: Array("QUJD\u{1b}\\".utf8)),
        ]
    }()

    /// A sequence longer than the 64 KiB libghostty keeps of one cannot be handed on, and a title,
    /// an OSC 52 copy, a sixel image or a kitty graphics image can be that long. The handback then
    /// rebuilds the screen in view and ends with an opener that takes in the rest of the sequence,
    /// so the rest prints nothing and what follows it prints as it does on the viewer. On the
    /// alternate screen that screen comes alone, because a terminal inside such a sequence cannot
    /// be cloned for its primary. Until the rest arrives the receiver is read without its modes:
    /// a DECRQM query would end the opener with its ESC.
    @Test(arguments: ["sgr-colors", "alt-tui-full"], HandoverCorpusTests.overlongSequences)
    func handbackDropsTheRestOfASequenceThatOutgrewItsBound(_ name: String, _ sequence: OverlongSequence) async throws {
        try await onHandoverThread {
            let state = HandoverFixtures.state(named: name)
            let source = try state.ghostty()
            source.feed(sequence.head[...])
            #expect(
                source.withLocked { !$0.isAtGround && $0.pendingContinuationBytes() == nil },
                "\(name) must be left inside \(sequence.name), past what libghostty keeps of it")
            let receiver = try Self.handedBack(source, state: state)

            func expectScreensMatch(_ moment: String, probingModes: Bool) {
                let received = receiver.handoverSnap(history: false, probingModes: probingModes)
                let tally = handoverCompare(source.handoverSnap(history: false), received, history: false)
                    .filtered(to: handoverScreenCategories)
                #expect(tally.isEmpty, "\(name), inside \(sequence.name), \(moment): the screens differ: \(tally.summary)")
            }
            expectScreensMatch("at the handback", probingModes: false)
            let rest = sequence.rest + Array("X".utf8)
            source.feed(rest[...])
            receiver.feed(rest)
            expectScreensMatch("once the rest arrived", probingModes: true)
            let (text, _) = Self.writtenBeforeCursor(receiver, count: 1)
            #expect(text == "X", "\(name), \(sequence.name): what follows the sequence wrote \(text.debugDescription)")
        }
    }

    // MARK: - Helpers

    /// The reset that leaves the alternate screen the way the state's own bytes last entered it,
    /// as the program would send it. nil when `terminal` is on the primary screen. It is read from
    /// the bytes, not from a terminal's mode table: libghostty keeps a bit for each switch mode, and
    /// a terminal that read the daemon's preamble has `?1049` set whichever mode the program used.
    private static func leave(_ state: HandoverState, on terminal: GhosttyTerminal) -> [UInt8]? {
        guard terminal.withLocked({ $0.isAlternateScreen }) else { return nil }
        let entries = [47, 1047, 1049].compactMap { mode in
            lastIndex(of: Array("\u{1b}[?\(mode)h".utf8), in: state.bytes).map { (mode: mode, at: $0) }
        }
        let entered = entries.max { $0.at < $1.at }?.mode ?? 1049
        return Array("\u{1b}[?\(entered)l".utf8)
    }

    private static func lastIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        return (0...(haystack.count - needle.count)).last { haystack[$0..<($0 + needle.count)].elementsEqual(needle) }
    }

    private static func describe(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self).debugDescription }

    /// What a state may differ in once the program has left the alternate screen: its own miss, the
    /// inert margins, and what libghostty keeps once for both screens.
    private static func allowedAfterLeaving(_ name: String, misses: [String: HandoverMiss]) -> Set<String> {
        handoverInertCategories.union(oneValueForBothScreens.categories).union(misses[name]?.categories ?? [])
    }

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

    /// The text of the `count` cells before the cursor on its row, and the first one's colour.
    private static func writtenBeforeCursor(_ terminal: HandoverSwiftTerm, count: Int) -> (String, HandoverColor) {
        let snap = terminal.handoverSnap(history: false)
        let end = snap.pending ? snap.cursorX + 1 : snap.cursorX
        let cells = snap.grid[snap.cursorY][max(0, end - count)..<end]
        return (cells.map(\.text).joined(), cells.first?.foreground ?? .standard)
    }

    private static func expectSameScreen(_ expected: HandoverSwiftTerm, _ actual: HandoverSwiftTerm, _ what: String) {
        let tally = handoverCompare(expected.handoverSnap(history: false), actual.handoverSnap(history: false), history: false)
            .filtered(to: handoverScreenCategories)
        #expect(tally.isEmpty, "\(what): the receiver differs from SwiftTerm fed the whole stream: \(tally.summary)")
    }

    private static func expectOutcome(_ name: String, tally: HandoverTally, misses: [String: HandoverMiss], crossing: String) {
        if let miss = misses[name] {
            #expect(
                !tally.isEmpty,
                "\(name) is a known miss for the \(crossing) (\(miss.reason)) but now matches: remove it from the list")
            let unexplained = tally.excluding(miss.categories)
            #expect(
                unexplained.isEmpty,
                "\(name): the \(crossing) differs beyond its known miss (\(miss.reason)): \(unexplained.summary)")
        } else {
            #expect(tally.isEmpty, "\(name): the \(crossing) differs: \(tally.summary)")
        }
    }
}

extension HandoverState: CustomTestStringConvertible {
    var testDescription: String { name }
}
