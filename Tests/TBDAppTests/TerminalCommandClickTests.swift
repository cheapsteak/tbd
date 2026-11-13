import Foundation
import Testing
@testable import TBDApp
import TBDGhosttyCore
import TBDGhosttyTerminal

/// TBD's own ⌘-click matcher, the one both engines run on the pressed row, and SwiftTerm's link
/// detection as the libghostty engine reaches it. Rows are built the way both engines hand them
/// over: one character per column, `"\0"` for a cell with no text.
struct TerminalCommandClickTests {
    private let worktree = "/work/tree"

    /// `text` padded with empty cells to `columns`.
    private func row(_ text: String, columns: Int = 60) -> String {
        text + String(repeating: "\0", count: max(0, columns - text.count))
    }

    /// The column of the first character of `needle` in `text`, plus `offset`.
    private func column(of needle: String, in text: String, offset: Int = 0) throws -> Int {
        let range = try #require(text.range(of: needle), "\(needle) is not in \(text)")
        return text.distance(from: text.startIndex, to: range.lowerBound) + offset
    }

    private func target(
        _ text: String, at column: Int, existing: Set<String> = [], remoteURL: String? = nil
    ) -> TerminalCommandClick.Target? {
        TerminalCommandClick.target(
            row: row(text), column: column, worktreePath: worktree, remoteURL: remoteURL,
            isReadableFile: { existing.contains($0) })
    }

    // MARK: - Paths

    @Test func anAbsolutePathOpensTheFileAndASentencesFullStopIsNotPartOfIt() throws {
        let text = "see /srv/acme/notes.txt."
        let found = target(text, at: try column(of: "notes", in: text), existing: ["/srv/acme/notes.txt"])
        #expect(found == .file("/srv/acme/notes.txt"))
    }

    @Test func aRelativePathResolvesAgainstTheWorktree() throws {
        let text = "edited Sources/App/main.swift and more"
        let found = target(text, at: try column(of: "App", in: text), existing: ["/work/tree/Sources/App/main.swift"])
        #expect(found == .file("/work/tree/Sources/App/main.swift"))
    }

    @Test func aTildePathExpandsToHome() throws {
        let text = "wrote ~/acme/notes.txt"
        let expanded = NSString(string: "~/acme/notes.txt").expandingTildeInPath
        let found = target(text, at: try column(of: "acme", in: text), existing: [expanded])
        #expect(found == .file(expanded))
    }

    /// A colon, a quote, a bracket and a space are not path characters, so a `:line:col` suffix
    /// and the punctuation around a path end it. A click on the line number names no file.
    @Test func aLineSuffixAndPunctuationEndThePath() throws {
        let text = #"failed at ("Sources/App/main.swift:42:7")"#
        let existing: Set<String> = ["/work/tree/Sources/App/main.swift"]
        let onPath = target(text, at: try column(of: "main", in: text), existing: existing)
        #expect(onPath == .file("/work/tree/Sources/App/main.swift"))
        let onLine = target(text, at: try column(of: "42", in: text), existing: existing)
        #expect(onLine == nil)
    }

    @Test func aPathToNothingOpensNothing() throws {
        let text = "see /srv/acme/missing.txt"
        let found = target(text, at: try column(of: "missing", in: text))
        #expect(found == nil)
    }

    @Test func aClickOnSpaceOrPastTheRowOpensNothing() throws {
        let text = "see /srv/acme/notes.txt"
        let existing: Set<String> = ["/srv/acme/notes.txt"]
        let onSpace = target(text, at: 3, existing: existing)
        #expect(onSpace == nil)
        let pastTheRow = target(text, at: 200, existing: existing)
        #expect(pastTheRow == nil)
    }

    /// A character of two scalars before the path. Counting scalars instead of characters would
    /// put the click and the token out of step and, with the path at the row's end, step past it.
    @Test func aCharacterOfSeveralScalarsKeepsTheColumns() throws {
        let text = "cafe\u{301} /srv/acme/notes.txt"
        let found = TerminalCommandClick.target(
            row: text, column: try column(of: "notes", in: text), worktreePath: worktree, remoteURL: nil,
            isReadableFile: { $0 == "/srv/acme/notes.txt" })
        #expect(found == .file("/srv/acme/notes.txt"))
    }

    // MARK: - Pull requests

    @Test func aPullRequestNumberAnywhereOnTheRowOpensItsPage() throws {
        let found = target("merged in PR #42 today", at: 0, remoteURL: "git@github.com:acme/widgets.git")
        let expected = try #require(URL(string: "https://github.com/acme/widgets/pull/42"))
        #expect(found == .url(expected))
    }

    /// SwiftTerm's row has `"\0"` where a cell holds nothing; the pattern reads it as a space.
    @Test func anEmptyCellBetweenPRAndItsNumberReadsAsASpace() throws {
        let link = TerminalCommandClick.pullRequestLink(in: row("PR\0#7"), remoteURL: "https://github.com/acme/widgets")
        #expect(link == "https://github.com/acme/widgets/pull/7")
    }

    @Test func aPullRequestNumberWithNoRemoteOpensNothing() {
        let found = target("merged in PR #42 today", at: 0)
        #expect(found == nil)
    }

    @Test func aFileWinsOverAPullRequestNumberOnTheSameRow() throws {
        let text = "PR #42 changed /srv/acme/notes.txt"
        let found = target(
            text, at: try column(of: "notes", in: text), existing: ["/srv/acme/notes.txt"],
            remoteURL: "git@github.com:acme/widgets.git")
        #expect(found == .file("/srv/acme/notes.txt"))
    }

    // MARK: - SwiftTerm's link detection, as the libghostty engine reaches it

    private func clicked(
        _ rows: [(String, Bool)], column: Int, row: Int, columns: Int
    ) -> GhosttyClickedText {
        GhosttyClickedText(
            rows: rows.map { text, wraps in
                GhosttyClickedText.Row(text: self.row(text, columns: columns), isWrapContinuation: wraps)
            },
            column: column, row: row, columns: columns)
    }

    @Test func aPrintedURLIsFound() throws {
        let text = "see https://example.com/acme now"
        let link = SwiftTermLinkDetector.link(in: clicked(
            [(text, false), ("", false)], column: try column(of: "example", in: text), row: 0, columns: 40))
        #expect(link == "https://example.com/acme")
    }

    @Test func plainWordsAreNotALink() {
        let link = SwiftTermLinkDetector.link(in: clicked(
            [("just some words", false)], column: 2, row: 0, columns: 40))
        #expect(link == nil)
    }

    /// The seam falls on an `é`, which SwiftTerm's rule for joining rows a program did not wrap
    /// refuses to join across, so the path is found whole only from the wrap itself: the
    /// continuation row alone holds no path.
    @Test func aSoftWrappedPathIsFoundWholeFromEitherRow() throws {
        let path = "/srv/acme/notes-caf\u{E9}-final.txt"
        let upper = String(path.prefix(20))
        let lower = String(path.dropFirst(20))
        let seamIsTheAccent = upper.last == "\u{E9}"
        try #require(seamIsTheAccent, "the seam is not on the é: \(upper)")
        let wrapped = [(upper, false), (lower, true), ("", false)]
        let fromBelow = SwiftTermLinkDetector.link(in: clicked(wrapped, column: 2, row: 1, columns: 20))
        #expect(fromBelow == path)
        let fromAbove = SwiftTermLinkDetector.link(in: clicked(wrapped, column: 3, row: 0, columns: 20))
        #expect(fromAbove == path)

        // Control: the same rows, not wrapped.
        let unwrapped = [(upper, false), (lower, false), ("", false)]
        let belowAlone = SwiftTermLinkDetector.link(in: clicked(unwrapped, column: 2, row: 1, columns: 20))
        #expect(belowAlone == nil)
    }

    /// The second half of a wide character holds no text, and is not written: the character fills
    /// it, so the URL after two wide characters starts where it did on the screen. Pressed on the
    /// URL's first column, which a shift to the right would leave on the space before it.
    @Test func wideCharactersKeepTheColumnsOfWhatFollows() throws {
        let text = "\u{65E5}\0\u{672C}\0 https://example.com/acme"
        let link = SwiftTermLinkDetector.link(in: clicked(
            [(text, false)], column: try column(of: "https", in: text), row: 0, columns: 40))
        #expect(link == "https://example.com/acme")
    }

    @Test func aPressOutsideTheRowsFindsNothing() {
        let rows = [("see https://example.com/acme now", false)]
        let belowTheRows = SwiftTermLinkDetector.link(in: clicked(rows, column: 8, row: 3, columns: 40))
        #expect(belowTheRows == nil)
        let pastTheColumns = SwiftTermLinkDetector.link(in: clicked(rows, column: 40, row: 0, columns: 40))
        #expect(pastTheColumns == nil)
    }

    // MARK: - The cells SwiftTerm's link covers, for the ⌘-hover underline

    @Test func aPrintedURLCoversItsOwnCells() throws {
        let text = "see https://example.com/acme now"
        let link = SwiftTermLinkDetector.textLink(in: clicked(
            [(text, false)], column: try column(of: "example", in: text), row: 0, columns: 40))
        #expect(link == GhosttyTextLink(text: "https://example.com/acme", spans: [.init(row: 0, columns: 4..<28)]))
    }

    @Test func plainWordsCoverNoCells() {
        let link = SwiftTermLinkDetector.textLink(in: clicked(
            [("just some words", false)], column: 2, row: 0, columns: 40))
        #expect(link == nil)
    }

    /// The URL runs past the end of the first row and on at the start of the second.
    @Test func aSoftWrappedURLCoversBothRowsFromEither() {
        let wrapped = [("see https://example.", false), ("com/acme/wrapped now", true), ("", false)]
        let expected = GhosttyTextLink(
            text: "https://example.com/acme/wrapped",
            spans: [.init(row: 0, columns: 4..<20), .init(row: 1, columns: 0..<16)])
        let fromBelow = SwiftTermLinkDetector.textLink(in: clicked(wrapped, column: 2, row: 1, columns: 20))
        #expect(fromBelow == expected)
        let fromAbove = SwiftTermLinkDetector.textLink(in: clicked(wrapped, column: 6, row: 0, columns: 20))
        #expect(fromAbove == expected)
    }

    /// A program that wraps its own lines ends the row with a newline and indents the next, which
    /// SwiftTerm joins when the first row's text reaches near its end. The indent is not the link's.
    @Test func aURLItsProgramWrappedCoversBothRowsFromEither() {
        let wrapped = [("see https://example.com/", false), ("  acme/wrapped now", false), ("", false)]
        let expected = GhosttyTextLink(
            text: "https://example.com/acme/wrapped",
            spans: [.init(row: 0, columns: 4..<24), .init(row: 1, columns: 2..<14)])
        let fromBelow = SwiftTermLinkDetector.textLink(in: clicked(wrapped, column: 5, row: 1, columns: 24))
        #expect(fromBelow == expected)
        let fromAbove = SwiftTermLinkDetector.textLink(in: clicked(wrapped, column: 10, row: 0, columns: 24))
        #expect(fromAbove == expected)
    }

    /// The same URL ends one row and starts the next, rows SwiftTerm does not join: the first row's
    /// text stops short of the end. Each is a link of its own.
    @Test func theSameURLOnTheNextRowIsAnotherLink() {
        let url = "https://example.com/acme"
        let rows = [("see \(url)", false), ("\(url) again", false), ("", false)]
        let upper = SwiftTermLinkDetector.textLink(in: clicked(rows, column: 10, row: 0, columns: 40))
        #expect(upper == GhosttyTextLink(text: url, spans: [.init(row: 0, columns: 4..<28)]))
        let lower = SwiftTermLinkDetector.textLink(in: clicked(rows, column: 10, row: 1, columns: 40))
        #expect(lower == GhosttyTextLink(text: url, spans: [.init(row: 1, columns: 0..<24)]))
    }

    /// Two wide characters before the URL take two columns each, so its cells are the screen's.
    @Test func wideCharactersLeaveTheLinksCellsWhereTheyAreOnScreen() throws {
        let text = "\u{65E5}\0\u{672C}\0 https://example.com/acme"
        let link = SwiftTermLinkDetector.textLink(in: clicked(
            [(text, false)], column: try column(of: "https", in: text), row: 0, columns: 40))
        #expect(link == GhosttyTextLink(text: "https://example.com/acme", spans: [.init(row: 0, columns: 5..<29)]))
    }

    /// The hover asks about every cell the pointer crosses. One screen is written once, whatever
    /// is asked about it, and a screen that changed is written again rather than answered from
    /// the old one.
    @Test func hoverLinksWritesEachScreenOnce() {
        let hover = SwiftTermLinkDetector.HoverLinks()
        let screen = [("see https://example.com/acme and /srv/acme/notes.txt", false)]
        let url = hover.textLink(in: clicked(screen, column: 10, row: 0, columns: 60))
        #expect(url == GhosttyTextLink(text: "https://example.com/acme", spans: [.init(row: 0, columns: 4..<28)]))
        let sameURL = hover.textLink(in: clicked(screen, column: 20, row: 0, columns: 60))
        #expect(sameURL == url)
        let path = hover.textLink(in: clicked(screen, column: 40, row: 0, columns: 60))
        #expect(path == GhosttyTextLink(text: "/srv/acme/notes.txt", spans: [.init(row: 0, columns: 33..<52)]))
        let between = hover.textLink(in: clicked(screen, column: 30, row: 0, columns: 60))
        #expect(between == nil)
        #expect(hover.screensWritten == 1)

        let changed = hover.textLink(in: clicked([("see nothing here", false)], column: 10, row: 0, columns: 60))
        #expect(changed == nil)
        #expect(hover.screensWritten == 2)
    }

    /// SwiftTerm scans the whole line for each cell it is asked about. On a line of 20,000
    /// characters, soft-wrapped over 200 rows, a URL crossing a row end in the middle takes a few
    /// questions, not one for each of its cells and those either side.
    @Test func aLinkOnALongLineTakesAFewLookups() throws {
        let url = "https://example.com/acme"
        let columns = 100
        // The URL starts 10,090 characters in, at column 90 of row 100, and runs on into row 101.
        let text = String(repeating: "word ", count: 2_018) + url + " " + String(repeating: "word ", count: 1_977)
        let characters = Array(text)
        try #require(characters.count == 20_000)
        let rows = (0..<200).map { index in
            GhosttyClickedText.Row(
                text: String(characters[(index * columns)..<((index + 1) * columns)]), isWrapContinuation: index > 0)
        }
        let screen = try #require(SwiftTermLinkDetector.Screen(rows: rows, columns: columns))

        let link = screen.textLink(column: 5, row: 101)

        #expect(link == GhosttyTextLink(
            text: url, spans: [.init(row: 100, columns: 90..<100), .init(row: 101, columns: 0..<14)]))
        #expect(screen.lookups <= 8, "\(screen.lookups) lookups")
    }

    /// A letter outside ASCII is one column wide unless it is a wide character. At the end of a
    /// link with nothing written after it, the empty cell after it is no part of the link, as
    /// SwiftTerm sees it, so the hover there finds nothing.
    @Test func aNarrowAccentedLetterEndsItsLinkAtItsOwnCell() {
        let url = "https://fr.wikipedia.org/wiki/Caf\u{E9}"
        let screen = [("see \(url)", false), ("next", false)]
        let hover = SwiftTermLinkDetector.HoverLinks()
        let link = hover.textLink(in: clicked(screen, column: 10, row: 0, columns: 60))
        #expect(link == GhosttyTextLink(text: url, spans: [.init(row: 0, columns: 4..<38)]))
        let pastTheAccent = hover.textLink(in: clicked(screen, column: 38, row: 0, columns: 60))
        #expect(pastTheAccent == nil)
    }

    /// SwiftTerm starts a soft-wrapped row at its first cell that is not blank, as it does a row
    /// an editor's hard wrap joins, and the line `located` reads keeps the blanks. The link is not
    /// in that line, so its cells are found by asking about each: more questions than the five
    /// `located` asks about a link no hard wrap crosses.
    @Test func aLinkNotInTheLinesTextIsFoundCellByCell() throws {
        let wrapped = [("see https://example.", false), ("  com/acme now", true)]
        let rows = clicked(wrapped, column: 0, row: 0, columns: 20).rows
        let screen = try #require(SwiftTermLinkDetector.Screen(rows: rows, columns: 20))

        let link = screen.textLink(column: 4, row: 1)

        #expect(link == GhosttyTextLink(
            text: "https://example.com/acme", spans: [.init(row: 0, columns: 4..<20), .init(row: 1, columns: 2..<10)]))
        #expect(screen.lookups > 5, "\(screen.lookups) lookups: the cells were not asked about one by one")
    }
}
