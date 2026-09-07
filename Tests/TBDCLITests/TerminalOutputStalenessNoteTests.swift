import Foundation
import TBDShared
import Testing

@testable import TBDCLI

/// What `tbd terminal output` tells a reader about a screen it did not read
/// live.
///
/// The contract makes every consumer of `TerminalScreen` declare what it does
/// with `.staleDaemon`; this consumer's declaration is *accept and surface*.
/// Before the typed screen, asking a session a viewer held simply failed, so a
/// reader could not mistake a frozen screen for a live one. Answering with the
/// frozen screen and saying nothing would remove that protection without
/// replacing it — a supervisor would read a three-hour-old composer as the
/// session's present state — which is why the note exists and why it carries
/// both facts a string cannot: which store answered, and how old its view is.
///
/// Asserted on the composed line rather than on a formatter in isolation: the
/// line is what a person and a supervising agent read, and a correct age
/// pasted into the wrong sentence is still the wrong answer.
@Suite("tbd terminal output staleness note")
struct TerminalOutputStalenessNoteTests {

    private static func screen(
        source: TerminalScreen.Source, ageMilliseconds: Int, contentObserved: Bool = true
    ) throws -> TerminalScreen {
        try TerminalScreen(
            lines: ["composer"],
            viewportStart: 0,
            cursor: TerminalScreen.Cursor(row: 0, column: 0, visible: true),
            size: TerminalScreen.Size(columns: 80, rows: 24),
            modes: TerminalScreen.ChildModes(
                bracketedPaste: false, applicationCursor: false, alternateScreen: false),
            modesObserved: true,
            contentObserved: contentObserved,
            source: source,
            ageMilliseconds: ageMilliseconds)
    }

    /// The live store needs no note, and adding one would put a line on stderr
    /// for every ordinary read — noise a reader would learn to ignore, which is
    /// how the notes that matter stop being read.
    @Test("a live daemon screen produces no note at all")
    func liveScreenIsSilent() throws {
        let live = try Self.screen(source: .daemon, ageMilliseconds: 12)
        #expect(TerminalOutput.stalenessNote(for: live) == nil)
    }

    /// The spec's own worked example: a screen frozen at an attach 41 minutes
    /// ago. Both facts are in the line, and the source is spelled the way the
    /// `--json` field spells it so a script can correlate the two.
    @Test("a stale daemon screen names the store, why it is frozen, and its age")
    func staleDaemonNoteCarriesSourceAndAge() throws {
        let stale = try Self.screen(source: .staleDaemon, ageMilliseconds: 41 * 60_000 + 3_000)
        let note = try #require(TerminalOutput.stalenessNote(for: stale))

        #expect(
            note == """
                note: screen is the daemon's emulator as it stood when a viewer attached \
                (source staleDaemon, age 41m 3s)
                """,
            "composed note was: \(note)")
        #expect(note.contains(TerminalScreen.Source.staleDaemon.rawValue))
    }

    /// A viewer's own answer is fresh, not frozen — but it still came from the
    /// other store, and a reader correlating it against an actuation row needs
    /// to be told which.
    @Test("a viewer screen is surfaced as the viewer's, not as the daemon's")
    func viewerNoteNamesTheViewer() throws {
        let viewer = try Self.screen(source: .viewer, ageMilliseconds: 250)
        let note = try #require(TerminalOutput.stalenessNote(for: viewer))

        #expect(
            note == """
                note: screen came from the viewer holding this session's pty \
                (source viewer, age 0s)
                """,
            "composed note was: \(note)")
        #expect(!note.contains("staleDaemon"))
    }

    /// The three bands of the age format, read off the composed line. Under a
    /// minute is seconds alone; an hour and above drops seconds entirely,
    /// because nobody deciding anything about a two-hour-old screen cares.
    @Test(
        "the age reads humanely in each band",
        arguments: [
            (0, "0s"),
            (999, "0s"),
            (1_000, "1s"),
            (59_000, "59s"),
            (60_000, "1m 0s"),
            (3_599_000, "59m 59s"),
            (3_600_000, "1h 0m"),
            (2_460_000, "41m 0s"),
            (9_000_000, "2h 30m"),
        ])
    func ageBands(milliseconds: Int, rendered: String) throws {
        let stale = try Self.screen(source: .staleDaemon, ageMilliseconds: milliseconds)
        let note = try #require(TerminalOutput.stalenessNote(for: stale))
        #expect(note.hasSuffix("(source staleDaemon, age \(rendered))"), "composed: \(note)")
    }

    /// The caveat the source cannot express. A daemon that restarts under a
    /// running session builds its emulator over a child already in flight, so
    /// the screen is live — nothing about it is stale — while every cell the
    /// child has not repainted since holds text the child never wrote. A reader
    /// shown that screen in silence reads a phantom composer line as the
    /// session's present state, which is exactly what was measured in the
    /// field.
    @Test("a live screen whose emulator never saw the child start still carries a note")
    func contentUnobservedScreenCarriesItsOwnNote() throws {
        let unobserved = try Self.screen(
            source: .daemon, ageMilliseconds: 12, contentObserved: false)
        let note = try #require(TerminalOutput.stalenessNote(for: unobserved))

        #expect(
            note == """
                note: screen comes from an emulator built over a child that was already \
                running, so cells the child has not repainted since the daemon restarted \
                may be stale or blank (contentObserved false)
                """,
            "composed note was: \(note)")
    }

    /// The other side of that check, and what makes the test above about the
    /// content provenance rather than about `daemon` screens getting noisy: an
    /// ordinary live read is still silent.
    @Test("a live screen whose emulator saw the child start is still silent")
    func observedLiveScreenStaysSilent() throws {
        let observed = try Self.screen(
            source: .daemon, ageMilliseconds: 12, contentObserved: true)
        #expect(TerminalOutput.stalenessNote(for: observed) == nil)
    }

    /// Both caveats on one screen — a viewer attached to a session the daemon
    /// had re-adopted — and both are told. The source note comes first: it is
    /// the one carrying an age, and it is the one a script's existing prefix
    /// match expects to find.
    @Test("a stale, content-unobserved screen carries both notes, source first")
    func staleAndUnobservedScreenCarriesBothNotes() throws {
        let both = try Self.screen(
            source: .staleDaemon, ageMilliseconds: 41 * 60_000 + 3_000, contentObserved: false)
        let note = try #require(TerminalOutput.stalenessNote(for: both))

        #expect(
            note == """
                note: screen is the daemon's emulator as it stood when a viewer attached \
                (source staleDaemon, age 41m 3s)
                note: screen comes from an emulator built over a child that was already \
                running, so cells the child has not repainted since the daemon restarted \
                may be stale or blank (contentObserved false)
                """,
            "composed note was: \(note)")
    }
}
