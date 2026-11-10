import Foundation
import Testing
@testable import TBDApp
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
    /// it, so the URL after two wide characters starts where it did on the screen.
    @Test func wideCharactersKeepTheColumnsOfWhatFollows() throws {
        let text = "\u{65E5}\0\u{672C}\0 https://example.com/acme"
        let link = SwiftTermLinkDetector.link(in: clicked(
            [(text, false)], column: try column(of: "example", in: text), row: 0, columns: 40))
        #expect(link == "https://example.com/acme")
    }

    @Test func aPressOutsideTheRowsFindsNothing() {
        let rows = [("see https://example.com/acme now", false)]
        let belowTheRows = SwiftTermLinkDetector.link(in: clicked(rows, column: 8, row: 3, columns: 40))
        #expect(belowTheRows == nil)
        let pastTheColumns = SwiftTermLinkDetector.link(in: clicked(rows, column: 40, row: 0, columns: 40))
        #expect(pastTheColumns == nil)
    }
}
