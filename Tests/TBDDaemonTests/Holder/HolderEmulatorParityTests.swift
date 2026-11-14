import Foundation
@testable import TBDDaemonLib
import TerminalCorpus
import TestSupport
import Testing

/// The daemon's libghostty emulator must answer as its SwiftTerm emulator does, so nothing that
/// reads a session can tell which one the daemon runs. Every stream, the handover corpus's 111
/// states and the four recordings in `Fixtures/EmulatorParity`, is fed to a fresh emulator of each
/// kind, of the same size and scrollback, and three things are compared:
///
/// 1. **What the daemon reads**: `screen(maxLines:source:)` field by field, `renderScreen()` and
///    `styledCapture(maxScrollbackLines:)`. Renders are compared with the spaces at the end of a
///    row trimmed (`EmulatorParity.trimmedRender`). Both emulators share a clock the suite moves
///    by hand, so the screen's age says when each last stamped a byte.
/// 2. **What the emulator sends**: the replies it writes to the child, split into one per reply
///    and compared by kind (`EmulatorParity.replyKind`) with the order of the kinds both sent,
///    and the OSC 7501 reports it delivers, in order. A recording is also fed in 64- and
///    4,096-byte chunks, so sequences and characters split across reads as a pty splits them,
///    and all three comparisons are made again. A stream of the queries every program may send
///    must be answered identically, with no miss (`theQueriesTheDaemonAnswersMatch`).
/// 3. **What a viewer restores**: each emulator's attach snapshot is fed, muted, to a fresh
///    headless libghostty viewer, as the app's viewer ingests one, and the two viewers' screens
///    and scrollback, cursors and cursor shapes, modes, regions and pens are compared, with the
///    state the formatter alone can read: the open hyperlink, tab stops, character sets,
///    modifyOtherKeys and protection, and the cursor DECRC restores. A viewer left on an
///    alternate screen also leaves it, the way the stream entered it, and is compared again
///    under `viewer.leave.`.
///
/// A stream may differ only in the fields `misses` lists for it, each listed with its reason, and
/// the list is exact: a difference it does not list fails, and so does a listed field that stops
/// differing, which means the list is stale. A failure prints every field that differs, with the
/// first difference in each. The comparison 1 entries are the engine suites' misses for the same
/// states (`ProjectionParityTests`); the rest are derived from what each snapshot writer carries
/// and from what each engine answers, and CI confirms them.
///
/// Every body runs on a thread the tests own, one at a time: see `EmulatorParity.onOwnThread`.
@Suite(.serialized, .fastPassBounded)
struct HolderEmulatorParityTests {
    /// Fields a stream may differ in, and why.
    struct Miss: Sendable {
        let reason: String
        let fields: Set<String>
    }

    // MARK: - Reasons shared by several streams

    static let penNotRestored = Miss(
        reason: "SwiftTerm's snapshot does not restore the pen, so its viewer writes the next character in the default style; libghostty's restores it",
        fields: ["viewer.pen"])

    static let pendingWrapLost = Miss(
        reason: "SwiftTerm's snapshot places the cursor with CUP, which cannot express a pending wrap, so its viewer's next character overwrites the last column instead of wrapping; libghostty's snapshot keeps the pending wrap",
        fields: ["viewer.pendingWrap"])

    static let mouseEncodingLost = Miss(
        reason: "SwiftTerm's snapshot writes the SGR mouse encoding (1006) and no other, so the UTF-8 (1005), urxvt (1015) and SGR-pixel (1016) encodings arrive as X10's; libghostty's snapshot keeps them",
        fields: ["viewer.mouseEncoding"])

    static let charsetsLost = Miss(
        reason: "SwiftTerm's snapshot does not write the character sets, so a line-drawing set the program left in use arrives as ASCII; the cells it already drew are the same",
        fields: ["viewer.charsets"])

    static let noOverline = Miss(
        reason: "SwiftTerm has no overline, so the overlined cells reach its viewer without it; libghostty's snapshot keeps it. The daemon's two styled captures agree, because libghostty's leaves overline out",
        fields: ["viewer.styled"])

    static let focusReportedOnEnable = Miss(
        reason: "SwiftTerm reports focus-in (`CSI I`) as soon as a program turns on focus reporting (1004), as xterm does; libghostty reports nothing until the focus changes, and the daemon's terminal never has a focus change",
        fields: ["replies.focus"])

    static let wideCharacterWrapped = Miss(
        reason: "a wide character that does not fit in the last column wraps to the next row: SwiftTerm leaves an empty cell behind, which its snapshot writes as a space, where libghostty keeps a spacer its formatter does not print, so the soft-wrapped line joins differently",
        fields: ["viewer.styled"])

    // MARK: - The misses

    /// Keyed by stream: a corpus state's name, a workload cut's `<workload>@<offset>`, or a
    /// recording's name, which holds for every feed plan. A key `<recording>/<plan>`, the plan
    /// `whole` or a chunk size, adds fields for that one plan.
    static let misses: [String: [Miss]] = [
        // Comparison 1, with what follows from it in comparison 3.
        "scroll-up-down": [Miss(
            reason: "libghostty keeps the rows SU scrolls off the top as scrollback; SwiftTerm deletes them, so its snapshot carries none either",
            fields: ["screen.lines", "screen.viewportStart", "capture", "viewer.text", "viewer.styled"])],
        "vs16-at-edge": [Miss(
            reason: "libghostty widens a heart with VS16 to two columns and wraps it to the next row; SwiftTerm keeps it one column wide in the last column. A viewer of either snapshot holds the same text, because it widens the heart again, but SwiftTerm's snapshot puts the cursor where SwiftTerm had it",
            fields: ["screen.lines", "screen.cursor", "render", "capture", "viewer.cursor"])],
        "wide-overwrite-tail": [Miss(
            reason: "printing over the second half of a wide character: libghostty clears its first half, SwiftTerm keeps it, and SwiftTerm's snapshot writes it",
            fields: ["screen.lines", "render", "capture", "viewer.text", "viewer.styled"])],
        "hidden-then-alt": [Miss(
            reason: "SwiftTerm shows the cursor when a program switches to the alternate screen, so its emulator reports the cursor the program hid as visible and its snapshot shows it; libghostty leaves visibility alone on a switch",
            fields: ["screen.cursorVisible", "viewer.cursorVisible", "viewer.leave.cursorVisible"])],

        // Comparison 2.
        "full-reset": [Miss(
            reason: "a full reset (RIS) drops every program-status record, and libghostty reports that as `state=clear`; SwiftTerm reports nothing",
            fields: ["reports"])],
        "focus-reporting": [focusReportedOnEnable],
        "claude-stub": [
            Miss(
                reason: "SwiftTerm answers the kitty graphics query and reports a cell size for `CSI 16 t`; the daemon's libghostty has kitty graphics off and a cell size of zero",
                fields: ["replies.kittyGraphics", "replies.windowOps"]),
            focusReportedOnEnable,
        ],
        "vim": [
            Miss(
                reason: "SwiftTerm answers the OSC 10 and OSC 11 colour queries with its default colours; the daemon's libghostty has no colours set to answer with",
                fields: ["replies.OSC10", "replies.OSC11"]),
            focusReportedOnEnable,
        ],

        // Comparison 3: what SwiftTerm's snapshot does not carry.
        "pending-wrap": [pendingWrapLost],
        "pending-wrap-styled": [pendingWrapLost, penNotRestored],
        "no-autowrap": [pendingWrapLost],
        "open-pen": [penNotRestored],
        "mouse-utf8": [mouseEncodingLost],
        "mouse-urxvt": [mouseEncodingLost],
        "mouse-sgr-pixels": [mouseEncodingLost],
        "mouse-x10": [Miss(
            reason: "SwiftTerm's snapshot writes the 1000, 1002 and 1003 tracking modes and no other, so X10 tracking (9) arrives off",
            fields: ["viewer.mouseTracking"])],
        "sync-output-open": [Miss(
            reason: "SwiftTerm's snapshot does not write synchronized output (2026)",
            fields: ["viewer.mode.syncOutput"])],
        "reverse-video": [Miss(
            reason: "SwiftTerm's snapshot does not write reverse video (DECSCNM, 5)",
            fields: ["viewer.mode.reverseVideo"])],
        "linefeed-mode": [Miss(
            reason: "SwiftTerm's snapshot does not write line feed/new line mode (LNM, 20)",
            fields: ["viewer.mode.LNM"])],
        "kitty-keyboard-flags": [Miss(
            reason: "SwiftTerm's snapshot does not write the kitty keyboard flags",
            fields: ["viewer.kittyFlags"])],
        "modify-other-keys": [Miss(
            reason: "SwiftTerm's snapshot does not write modifyOtherKeys",
            fields: ["viewer.keyboard"])],
        "lr-margins": [Miss(
            reason: "SwiftTerm's snapshot turns DECLRMM on but writes no left and right margins (DECSLRM)",
            fields: ["viewer.region"])],
        "cursor-style": [Miss(
            reason: "DECSCUSR 5 asks for a blinking bar. libghostty keeps the blink as mode 12, which its snapshot writes; SwiftTerm's snapshot writes neither the cursor's shape nor mode 12, so its viewer's cursor does not blink. libghostty's viewer is the right one, and neither snapshot carries the bar",
            fields: ["viewer.mode.cursorBlink"])],
        "tabstops-custom": [Miss(
            reason: "SwiftTerm's snapshot does not write tab stops, so its viewer has one every eight columns",
            fields: ["viewer.tabstops"])],
        "charset-linedraw-open": [charsetsLost],
        "charset-so": [charsetsLost],
        "hyperlink": [Miss(
            reason: "SwiftTerm's snapshot writes no OSC 8 hyperlinks, so the linked cells arrive unlinked",
            fields: ["viewer.styled"])],
        "hyperlink-open": [Miss(
            reason: "SwiftTerm's snapshot writes no OSC 8 hyperlinks, so the linked cells arrive unlinked and the link the program left open is closed",
            fields: ["viewer.styled", "viewer.link"])],
        "overline": [noOverline],
        "wide-at-edge": [wideCharacterWrapped],
        "wide-in-scrollback": [wideCharacterWrapped],

        // Comparison 3: the one workload cut past the scrollback the snapshot carries.
        "unicode@1000003": [Miss(
            reason: "libghostty prunes its scrollback a whole page at a time until it holds no more than the 5,000 lines the daemon asks for, so once a stream outgrows them it keeps up to a page fewer, 168 rows here; SwiftTerm keeps exactly 5,000. The daemon's own reads take 1,000 lines and agree, but the snapshot, which carries up to 5,000, gives libghostty's viewer fewer",
            fields: ["viewer.text", "viewer.styled"])],

        // Comparison 3: the workload cuts that stop with a colour or an attribute set.
        "colors@166666": [penNotRestored], "colors@333339": [penNotRestored], "colors@500006": [penNotRestored],
        "colors@666682": [penNotRestored], "colors@833335": [penNotRestored], "colors@1000006": [penNotRestored],
        "cursor@166666": [penNotRestored], "cursor@333333": [penNotRestored], "cursor@500002": [penNotRestored],
        "cursor@666666": [penNotRestored], "cursor@833335": [penNotRestored], "cursor@1000003": [penNotRestored],
        "scroll@166666": [penNotRestored], "scroll@333333": [penNotRestored], "scroll@500000": [penNotRestored],
        "scroll@666666": [penNotRestored], "scroll@1000000": [penNotRestored],
        "tui@333335": [penNotRestored], "tui@666672": [penNotRestored], "tui@1000003": [penNotRestored],
    ]

    // MARK: - The streams

    static let scenarios: [String] = HandoverCorpus.scenarios.map { $0.name }
    static let workloads: [String] = HandoverCorpus.checkpoints.map { $0.workload }

    @Test(arguments: HolderEmulatorParityTests.scenarios)
    func scenarioMatches(_ name: String) async throws {
        try await EmulatorParity.onOwnThread {
            let state = HandoverCorpus.state(named: name)
            let pair = try EmulatorParity.Pair(cols: state.cols, rows: state.rows)
            pair.feed(state.bytes[...])
            Self.expectOutcome(name, plan: nil, differences: try pair.differences(stream: state.bytes[...]))
        }
    }

    /// A workload is fed once and read at each of its cuts, which leaves both emulators exactly
    /// as a fresh one fed the cut's bytes would be: the reads change nothing, and SwiftTerm's
    /// snapshot changes its terminal only on an alternate screen, which no workload enters.
    @Test(arguments: HolderEmulatorParityTests.workloads)
    func workloadMatchesAtEveryCut(_ workload: String) async throws {
        try await EmulatorParity.onOwnThread {
            guard let offsets = HandoverCorpus.checkpoints.first(where: { $0.workload == workload })?.offsets else {
                throw EmulatorParity.Failure(description: "the corpus has no workload named \(workload)")
            }
            let bytes = HandoverCorpus.workloadBytes(workload)
            let pair = try EmulatorParity.Pair(cols: HandoverCorpus.workloadCols, rows: HandoverCorpus.workloadRows)
            var fed = 0
            for offset in offsets {
                pair.feed(bytes[fed..<offset])
                fed = offset
                let name = "\(workload)@\(offset)"
                if try pair.swiftTerm.screen(maxLines: 0, source: .daemon).modes.alternateScreen {
                    Issue.record(EmulatorParity.Failure(
                        description: "\(name) is on the alternate screen, where reading SwiftTerm's snapshot changes its terminal; feed each cut to fresh emulators instead"))
                }
                Self.expectOutcome(name, plan: nil, differences: try pair.differences(stream: bytes[..<offset]))
            }
        }
    }

    @Test(arguments: EmulatorParity.Recordings.names, EmulatorParity.FeedPlan.all)
    func recordingMatches(_ name: String, plan: EmulatorParity.FeedPlan) async throws {
        try await EmulatorParity.onOwnThread {
            let entry = try EmulatorParity.Recordings.entry(named: name)
            let bytes = try EmulatorParity.Recordings.bytes(of: entry)
            let pair = try EmulatorParity.Pair(cols: entry.cols, rows: entry.rows)
            pair.feed(bytes[...], chunkSize: plan.chunkSize)
            Self.expectOutcome(name, plan: plan, differences: try pair.differences(stream: bytes[...]))
        }
    }

    /// The queries a program may send and the daemon answers for it, each of which the two
    /// emulators must answer byte for byte: DA1, DA2 and XTVERSION, the frozen device identity;
    /// DSR's operating status and the cursor position, away from the home cell; DECRQM for modes
    /// both emulators know, synchronized output both reset and set, since Claude Code wraps its
    /// frames in it only on a "set" answer; and the OSC 7501 probe, which turns on Claude Code's
    /// program-status reports. Here and not in the corpus, because no other suite reads replies.
    static let queryPieces: [String] = [
        "\u{1b}[c", "\u{1b}[>c", "\u{1b}[>q", "\u{1b}[5n", "\u{1b}[5;10H\u{1b}[6n",
        "\u{1b}[?1$p\u{1b}[?7$p\u{1b}[?25$p\u{1b}[?2004$p\u{1b}[?2026$p",
        "\u{1b}[?2026h\u{1b}[?2026$p\u{1b}[?2026l",
        "\u{1b}]7501;?\u{07}",
    ]
    static let queryText: String = queryPieces.joined()
    static let queries: [UInt8] = Array(queryText.utf8)

    /// How many replies of each kind `queries` asks for.
    static let queryReplies: [String: Int] = [
        "DA1": 1, "DA2": 1, "XTVERSION": 1, "DSR": 1, "CPR": 1, "DECRQM": 6, "7501probe": 1,
    ]

    /// No miss is listed for the queries, so every field, every kind of reply among them, must
    /// match; and each emulator must send each reply, so a kind neither sends cannot pass.
    @Test func theQueriesTheDaemonAnswersMatch() async throws {
        try await EmulatorParity.onOwnThread {
            let pair = try EmulatorParity.Pair(cols: 80, rows: 24)
            pair.feed(Self.queries[...])
            Self.expectOutcome("queries", plan: nil, differences: try pair.differences(stream: Self.queries[...]))
            for (emulator, sink) in [(pair.swiftTerm, pair.swiftTermSink), (pair.ghostty, pair.ghosttySink)] {
                let kinds: [String] = EmulatorParity.splitReplies(sink.replies).map { EmulatorParity.replyKind($0) }
                var counts: [String: Int] = [:]
                for kind in kinds { counts[kind, default: 0] += 1 }
                #expect(counts == Self.queryReplies, "the \(emulator.kind) emulator sent \(kinds)")
            }
        }
    }

    /// Both emulators stamp each feed, so the age they report counts from the last byte fed and
    /// not from their construction. The comparison catches one emulator that stops stamping; this
    /// catches both.
    @Test func theAgeCountsFromTheLastByteFed() throws {
        let pair = try EmulatorParity.Pair(cols: 80, rows: 24)
        pair.feed(Array("a line\r\n".utf8)[...])
        pair.clock.advance(by: .milliseconds(1_500))
        for emulator in [pair.swiftTerm, pair.ghostty] {
            let age = try emulator.screen(maxLines: 0, source: .daemon).ageMilliseconds
            #expect(age == 1_500, "the \(emulator.kind) emulator reports an age of \(age) ms")
        }
    }

    // MARK: - The list itself

    /// The suite covers the corpus: its scenarios and workload cuts are every state the
    /// handover suites run.
    @Test func theStreamsCoverTheHandoverCorpus() {
        let cuts = HandoverCorpus.checkpoints.flatMap { entry in entry.offsets.map { "\(entry.workload)@\($0)" } }
        let streams = HandoverCorpus.scenarios.map(\.name) + cuts
        #expect(streams.count == 111, "\(streams.count) corpus states")
        #expect(Set(streams) == Set(HandoverCorpus.names))
    }

    /// Every key names a stream, every entry a reason and fields, and every field is one the
    /// suite reads.
    @Test func everyMissNamesAStreamAndFieldsTheSuiteReads() {
        let recordingPlans = EmulatorParity.Recordings.names.flatMap { name in
            EmulatorParity.FeedPlan.all.map { $0.missKey(for: name) }
        }
        #expect(recordingPlans.contains("claude-stub/whole"), "\(recordingPlans)")
        #expect(recordingPlans.contains("claude-stub/64"), "\(recordingPlans)")
        let streams = Set(HandoverCorpus.names + EmulatorParity.Recordings.names + recordingPlans)
        for (stream, entries) in Self.misses {
            #expect(streams.contains(stream), "\(stream) is listed as a miss but is not a stream the suite feeds")
            #expect(!entries.isEmpty, "\(stream) is listed with no miss")
            for miss in entries {
                #expect(!miss.reason.isEmpty, "\(stream) has a miss with no reason")
                #expect(!miss.fields.isEmpty, "\(stream) has a miss with no field it may differ in")
                let unknown = miss.fields.subtracting(EmulatorParity.allFields)
                #expect(unknown.isEmpty, "\(stream) lists fields the suite does not read: \(unknown.sorted())")
            }
        }
    }

    /// The fields a reading holds are the ones `EmulatorParity.allFields` names, so a miss that
    /// names one can match: checked on a stream left on the alternate screen, which reads them all.
    @Test func aReadingHoldsEveryFieldTheListCanName() async throws {
        try await EmulatorParity.onOwnThread {
            let state = HandoverCorpus.state(named: "alt-simple")
            let pair = try EmulatorParity.Pair(cols: state.cols, rows: state.rows)
            pair.feed(state.bytes[...])
            for emulator in [(pair.swiftTerm, pair.swiftTermSink), (pair.ghostty, pair.ghosttySink)] {
                let reading = try pair.observe(emulator.0, sink: emulator.1, stream: state.bytes[...])
                #expect(Set(reading.keys) == EmulatorParity.allFields, "\(emulator.0.kind)")
            }
        }
    }

    /// The outcome check itself, on a fake entry: a stream that differs in every field its misses
    /// name passes, one that has stopped differing in one fails and names it, one that differs in
    /// a field no miss names fails and prints the difference, one that does both fails once with
    /// both, and a plan's own entry adds to the stream's.
    @Test func theOutcomeHoldsTheListExact() {
        let misses: [String: [Miss]] = [
            "fake": [Miss(reason: "a fake miss", fields: ["render", "capture"])],
            "fake/64": [Miss(reason: "a fake chunked miss", fields: ["replies.other"])],
            "fake/whole": [Miss(reason: "a fake whole-feed miss", fields: ["reports"])],
        ]
        let both: [String: String] = ["render": "fake difference", "capture": "fake difference"]
        let passing = Self.outcomeFailures("fake", keys: ["fake"], differences: both, misses: misses)
        #expect(passing.isEmpty, "\(passing)")

        let stale = Self.outcomeFailures("fake", keys: ["fake"], differences: ["render": "fake"], misses: misses)
        #expect(stale.count == 1, "\(stale)")
        #expect(stale.first?.contains("now match in [\"capture\"]") == true, "\(stale)")

        let extra = both.merging(["replies.other": "SwiftTerm \"a\", libghostty \"b\""]) { $1 }
        let unlisted = Self.outcomeFailures("fake", keys: ["fake"], differences: extra, misses: misses)
        #expect(unlisted.count == 1, "\(unlisted)")
        #expect(unlisted.first?.contains("replies.other: SwiftTerm \"a\", libghostty \"b\"") == true, "\(unlisted)")

        let chunked = Self.outcomeFailures("fake, chunked", keys: ["fake", "fake/64"], differences: extra, misses: misses)
        #expect(chunked.isEmpty, "\(chunked)")

        // An unlisted difference and a stale miss together are one message holding both.
        let bothWays = Self.outcomeFailures(
            "fake", keys: ["fake"], differences: ["render": "fake", "replies.other": "fake"], misses: misses)
        #expect(bothWays.count == 1, "\(bothWays)")
        #expect(bothWays.first?.contains("beyond its listed misses") == true, "\(bothWays)")
        #expect(bothWays.first?.contains("now match in [\"capture\"]") == true, "\(bothWays)")

        // The whole feed's own key adds to the bare name's, and only for that plan.
        let wholeKeys: [String] = ["fake", EmulatorParity.FeedPlan(chunkSize: nil).missKey(for: "fake")]
        let whole = both.merging(["reports": "fake difference"]) { $1 }
        let wholePassing = Self.outcomeFailures("fake, whole", keys: wholeKeys, differences: whole, misses: misses)
        #expect(wholePassing.isEmpty, "\(wholePassing)")
        let wholeOnly = Self.outcomeFailures("fake, chunked", keys: ["fake", "fake/64"], differences: whole, misses: misses)
        #expect(wholeOnly.count == 1, "\(wholeOnly)")
    }

    /// The reply order holds every reply of each kind whose own field agrees, run for run, so
    /// the same replies sent in another order differ; a kind whose replies already differ under
    /// their own field drops out of the order.
    @Test func theReplyOrderComparesEveryReplyOfTheKindsThatAgree() {
        typealias Reading = [String: EmulatorParity.Observed]
        func reading(_ order: [String], cpr: String) -> Reading {
            let decrqm: [String] = Array(repeating: "\u{1b}[?2026;2$y", count: 3)
            return [
                "replies.order": .text(order.joined(separator: "\n")),
                "replies.DECRQM": .text(decrqm.joined(separator: "\n")),
                "replies.CPR": .text(cpr),
            ]
        }
        let first: [String] = ["DECRQM", "DECRQM", "CPR", "DECRQM"]
        let second: [String] = ["DECRQM", "CPR", "DECRQM", "DECRQM"]
        var expected: Reading = reading(first, cpr: "\u{1b}[1;1R")
        var actual: Reading = reading(second, cpr: "\u{1b}[1;1R")
        EmulatorParity.narrowReplyOrder(&expected, &actual)
        let firstOrder: EmulatorParity.Observed = .text(first.joined(separator: "\n"))
        let secondOrder: EmulatorParity.Observed = .text(second.joined(separator: "\n"))
        #expect(expected["replies.order"] == firstOrder)
        #expect(actual["replies.order"] == secondOrder)
        #expect(expected["replies.order"] != actual["replies.order"])

        var differingCPR: Reading = reading(first, cpr: "\u{1b}[1;1R")
        var otherCPR: Reading = reading(second, cpr: "\u{1b}[2;1R")
        EmulatorParity.narrowReplyOrder(&differingCPR, &otherCPR)
        let decrqmOnly: EmulatorParity.Observed = .text("DECRQM\nDECRQM\nDECRQM")
        #expect(differingCPR["replies.order"] == decrqmOnly)
        #expect(otherCPR["replies.order"] == decrqmOnly)
    }

    /// A reply split and sorted by kind: sequences cut across writes are rejoined, each reply's
    /// kind is read from its form, and a byte that is not UTF-8 is written as `\xNN`.
    @Test func repliesAreSplitAndSortedByKind() {
        let pieces: [String] = [
            "\u{1b}[?65;1c", "\u{1b}[>65;20;1c", "\u{1b}P>|name\u{1b}\\", "\u{1b}[0n", "\u{1b}[5;10R",
            "\u{1b}[?2026;2$y", "\u{1b}]7501;?\u{07}", "\u{1b}]10;rgb:0/0/0\u{1b}\\", "\u{1b}]11;rgb:f/f/f\u{07}",
            "\u{1b}[6;16;10t", "\u{1b}_Gi=31;OK\u{1b}\\", "\u{1b}[I", "\u{1b}[?0u",
        ]
        let expected: [String] = [
            "DA1", "DA2", "XTVERSION", "DSR", "CPR", "DECRQM", "7501probe", "OSC10", "OSC11", "windowOps",
            "kittyGraphics", "focus", "other",
        ]
        let bytes: [UInt8] = Array(pieces.joined().utf8)
        let kinds: [String] = EmulatorParity.splitReplies(bytes).map { EmulatorParity.replyKind($0) }
        #expect(kinds == expected)
        #expect(EmulatorParity.escaped([0x61, 0xff, 0xe2, 0x9c, 0x93, 0xe2, 0x9c]) == "a\\xFF✓\\xE2\\x9C")
    }

    /// What the viewer readings treat as the same: an ASCII designation and none, and blank
    /// cells written as default spaces and stepped over with CUF, whatever pen the output has open
    /// around the CUF; and what they keep apart: any other designation, and blank cells that
    /// carry a style.
    @Test func theViewerReadingsJoinOnlyWhatPrintsAlike() {
        func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
        func canonical(_ text: String) -> [UInt8] { EmulatorParity.canonicalStyled(bytes(text)) }
        #expect(EmulatorParity.withoutASCIIDesignations(bytes("\u{1b}(B\u{1b})0\u{1b}+B\u{0e}")) == bytes("\u{1b})0\u{0e}"))
        #expect(canonical("\u{1b}[2Cin alt") == bytes("  in alt"))
        #expect(canonical("ZXc\u{1b}[5CY\u{1b}[C") == bytes("ZXc     Y "))
        // libghostty's viewer of the cursor workload against SwiftTerm's: a gap after a coloured
        // run, before another colour.
        let libghosttyGap: String = "\u{1b}[0m\u{1b}[38;5;4mxyz\u{1b}[3C\u{1b}[0m\u{1b}[38;5;7mxyz\u{1b}[0m"
        let swiftTermGap: String = "\u{1b}[0m\u{1b}[38;5;4mxyz\u{1b}[0m   \u{1b}[0m\u{1b}[38;5;7mxyz\u{1b}[0m"
        #expect(canonical(libghosttyGap) == canonical(swiftTermGap))
        // The same colour on both sides of the gap, which the formatter does not write again.
        #expect(canonical("\u{1b}[31mx\u{1b}[3Cy") == canonical("\u{1b}[0m\u{1b}[31mx\u{1b}[0m   \u{1b}[0m\u{1b}[31my"))
        #expect(canonical("\u{1b}[31mx\u{1b}[3Cy") == bytes("\u{1b}[0m\u{1b}[31mx\u{1b}[0m   \u{1b}[0m\u{1b}[31my"))
        // Blanks with a background are written cells, unlike the ones CUF steps over.
        #expect(canonical("\u{1b}[41m   \u{1b}[0mx") != canonical("\u{1b}[3Cx"))
        // A hyperlink is kept as it is, in place.
        #expect(canonical("\u{1b}]8;;https://example.com\u{1b}\\x") == bytes("\u{1b}]8;;https://example.com\u{1b}\\x"))
    }

    // MARK: - The outcome

    private static func expectOutcome(_ name: String, plan: EmulatorParity.FeedPlan?, differences: [String: String]) {
        let label = plan.map { "\(name), fed \($0.testDescription)" } ?? name
        let planKeys: [String] = plan.map { [$0.missKey(for: name)] } ?? []
        let keys: [String] = [name] + planKeys
        for failure in outcomeFailures(label, keys: keys, differences: differences, misses: misses) {
            Issue.record(EmulatorParity.Failure(description: failure))
        }
    }

    /// Why a stream's differences fail, as one message, so a run shows all of it at once: the
    /// fields no miss under `keys` names, with their differences, and then the fields one names
    /// that no longer differ, which leaves the list stale. Empty when the differences are what
    /// the list says. `keys` is the stream's own and, for a recording, its feed plan's, whose
    /// fields add to the stream's.
    static func outcomeFailures(
        _ label: String, keys: [String], differences: [String: String], misses: [String: [Miss]]
    ) -> [String] {
        let entries = keys.flatMap { misses[$0] ?? [] }
        let listed = entries.reduce(into: Set<String>()) { $0.formUnion($1.fields) }
        func summary(_ fields: [String]) -> String {
            fields.sorted().map { "\($0): \(differences[$0] ?? "")" }.joined(separator: " | ")
        }
        var parts: [String] = []
        let unexplained = differences.keys.filter { !listed.contains($0) }
        if !unexplained.isEmpty {
            let expected = differences.keys.filter { listed.contains($0) }.sorted()
            let also = expected.isEmpty ? "" : " (it also differs, as listed, in \(expected))"
            parts.append("the libghostty emulator differs from SwiftTerm's beyond its listed misses\(also): \(summary(unexplained))")
        }
        let matching = listed.subtracting(differences.keys)
        if !matching.isEmpty {
            let reasons = entries.filter { !$0.fields.isDisjoint(with: matching) }.map(\.reason)
            parts.append(
                "it is listed as differing but the emulators now match in \(matching.sorted()): remove them from its entry (\(reasons.joined(separator: "; ")))")
        }
        return parts.isEmpty ? [] : ["\(label): " + parts.joined(separator: "; and ")]
    }
}
