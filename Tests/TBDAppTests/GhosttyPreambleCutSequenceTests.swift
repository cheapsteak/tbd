import Foundation
import Testing
@testable import TBDApp
import TestSupport

/// What a preamble finds in a libghostty engine whose output stopped inside a sequence.
///
/// libghostty's reset gives the terminal a fresh screen and leaves its stream parser where it was,
/// so `GhosttyEngine.prepareForPreamble()` ends the open sequence with a CAN before it resets.
/// Without the CAN, the preamble's first ESC ends the cut sequence on the fresh screen. Every
/// preamble here starts with ESC, as each handback writer's reset prelude does.
///
/// Each absence has a positive control: the same bytes fed into an engine that skips
/// `prepareForPreamble`, or the same CAN fed live, produce the effect the absence rules out.
///
/// libghostty only: the CAN is libghostty's, and SwiftTerm's `prepareForPreamble()` does nothing.
@MainActor
@Suite("libghostty preamble after a cut sequence", .fastPassBounded)
struct GhosttyPreambleCutSequenceTests {
    private static let link = "https://acme.example/x"
    /// An OSC 8 that opens a link, cut before its terminator.
    private static var cutLink: String { "\u{1b}]8;;\(link)" }
    /// U+2500 without its third byte.
    private static let cutCharacter: [UInt8] = [0xE2, 0x94]
    /// A DECRQSS for the SGR, cut before its string terminator. libghostty answers a DECRQSS when
    /// its DCS ends, whatever ends it.
    private static let cutStatusRequest = "\u{1b}P$qm"

    @Test("A cut OSC 8 puts no hyperlink on the cells the preamble writes",
          .enabled(if: EngineTestSupport.canBuildGhostty, EngineTestSupport.noMetalDevice))
    func aCutLinkDoesNotReachThePreamble() throws {
        let used = EngineUnderTest(kind: .ghostty, label: "GhosttyPreambleCut.Link.Used")
        let control = EngineUnderTest(kind: .ghostty, label: "GhosttyPreambleCut.Link.Control")
        defer {
            used.tearDown()
            control.tearDown()
        }
        try Self.requireGhostty(used, control)
        let preamble = Data("\u{1b}[Hrestored".utf8)

        used.feed("$ cat links\r\n\(Self.cutLink)")
        try #require(!used.engine.isAtSequenceBoundary, "the cut OSC 8 left the parser between sequences")
        used.engine.prepareForPreamble()
        #expect(used.engine.isAtSequenceBoundary, "prepareForPreamble left the parser inside the cut OSC 8")
        used.engine.ingestSnapshot(preamble)

        control.feed(Self.cutLink)
        control.engine.ingestSnapshot(preamble)

        let unprepared = Self.read(row: 0, of: control.engine)
        #expect(unprepared.links.contains(Self.link),
                "without prepareForPreamble the preamble's ESC should open the cut link: \(unprepared)")
        let restored = Self.read(row: 0, of: used.engine)
        #expect(restored.text == "restored", "the preamble's row 0 reads \(restored)")
        #expect(restored.links.isEmpty, "the cells the preamble wrote carry the cut link: \(restored)")
    }

    @Test("A cut UTF-8 character leaves no replacement character on the preamble's screen",
          .enabled(if: EngineTestSupport.canBuildGhostty, EngineTestSupport.noMetalDevice))
    func aCutCharacterDoesNotReachThePreamble() throws {
        let used = EngineUnderTest(kind: .ghostty, label: "GhosttyPreambleCut.Character.Used")
        let control = EngineUnderTest(kind: .ghostty, label: "GhosttyPreambleCut.Character.Control")
        defer {
            used.tearDown()
            control.tearDown()
        }
        try Self.requireGhostty(used, control)
        // Writes on row 1 only, so row 0 shows whatever the preamble's first ESC left at home.
        let preamble = Data("\u{1b}[2;1Hrestored".utf8)

        used.feed("$ ls\r\n")
        used.engine.feed(Self.cutCharacter[...])
        try #require(!used.engine.isAtSequenceBoundary, "the cut character left the parser between characters")
        used.engine.prepareForPreamble()
        #expect(used.engine.isAtSequenceBoundary, "prepareForPreamble left the parser inside the cut character")
        used.engine.ingestSnapshot(preamble)

        control.engine.feed(Self.cutCharacter[...])
        control.engine.ingestSnapshot(preamble)

        let unprepared = Self.read(row: 0, of: control.engine)
        #expect(unprepared.text?.contains("\u{FFFD}") == true,
                "without prepareForPreamble the preamble's ESC should end the cut character as U+FFFD at home: \(unprepared)")
        let home = Self.read(row: 0, of: used.engine)
        #expect(home.text == "", "the preamble left row 0 blank, and it reads \(home)")
        let written = Self.read(row: 1, of: used.engine)
        #expect(written.text == "restored", "the preamble's row 1 reads \(written)")
    }

    /// The CAN ends a cut DCS, and libghostty answers a DECRQSS that ends. The reply must stay in
    /// the mute: it answers a request the program made before the preamble, to a terminal that
    /// is about to be replaced.
    @Test("The reply a CAN provokes from a cut DECRQSS never reaches send",
          .enabled(if: EngineTestSupport.canBuildGhostty, EngineTestSupport.noMetalDevice))
    func theCansReplyStaysMuted() async throws {
        let fixture = EngineUnderTest(kind: .ghostty, label: "GhosttyPreambleCut.StatusRequest")
        defer { fixture.tearDown() }
        try Self.requireGhostty(fixture)

        fixture.feed(Self.cutStatusRequest)
        try #require(!fixture.engine.isAtSequenceBoundary, "the cut DECRQSS left the parser between sequences")
        await EngineTestSupport.settle()
        fixture.recorder.reset()

        fixture.engine.prepareForPreamble()
        #expect(fixture.engine.isAtSequenceBoundary, "prepareForPreamble left the parser inside the cut DECRQSS")
        await EngineTestSupport.settle()
        #expect(fixture.recorder.sent.isEmpty, "prepareForPreamble sent a reply: \(fixture.recorder.summary)")

        // The same request, ended by a CAN fed live, is answered.
        fixture.feed(Self.cutStatusRequest + "\u{18}")
        await EngineTestSupport.waitUntil(
            "a live CAN ending a cut DECRQSS to send its reply",
            observed: { fixture.recorder.summary }
        ) { String(bytes: fixture.recorder.sent, encoding: .utf8)?.contains("$r") == true }
    }

    // MARK: - Helpers

    /// A kind in `availableKinds` that fell back would run these against SwiftTerm.
    private static func requireGhostty(_ fixtures: EngineUnderTest...) throws {
        for fixture in fixtures {
            try #require(fixture.engine.kind == .ghostty, "asked for libghostty, the factory built \(fixture.engine.kind)")
        }
    }

    /// Row `row`'s text and the hyperlinks on its first eight cells, the length of "restored",
    /// in one hold.
    private static func read(row: Int, of engine: any TerminalEngine) -> (text: String?, links: [String]) {
        engine.withScreen { screen in
            (text: screen.lineText(row: row),
             links: (0..<8).compactMap { screen.hyperlink(column: $0, row: row) })
        }
    }
}
