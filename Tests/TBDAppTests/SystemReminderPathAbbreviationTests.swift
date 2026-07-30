import Foundation
import Testing
@testable import TBDApp

/// Tier 1. The injected-row path field is the first place in the app fed an
/// *arbitrary* absolute path out of a transcript, so its `~` abbreviation has to
/// match whole path components — a substring replace of `NSHomeDirectory()`
/// presented sibling and nested directories as living inside the user's home.
@Suite("Injected row path abbreviation")
struct SystemReminderPathAbbreviationTests {
    private let home = NSHomeDirectory()
    private var homeLeaf: String { (home as NSString).lastPathComponent }
    private var homeParent: String { (home as NSString).deletingLastPathComponent }

    @Test("a genuine home-prefixed path abbreviates to ~/…")
    func abbreviatesHomePath() {
        #expect(SystemReminderRowBody.abbreviatedPath("\(home)/acme-prod/.github/CLAUDE.md")
            == "~/acme-prod/.github/CLAUDE.md")
    }

    @Test("a sibling directory sharing the home name's prefix is left alone")
    func leavesSiblingDirectoryAlone() {
        // e.g. home `/Users/me` must not turn `/Users/melog-archive/…` into `~log-archive/…`
        let sibling = "\(homeParent)/\(homeLeaf)log-archive/CLAUDE.md"
        #expect(SystemReminderRowBody.abbreviatedPath(sibling) == sibling)
    }

    @Test("home appearing mid-path on another volume is not spliced")
    func leavesNestedHomePathAlone() {
        let onVolume = "/Volumes/T7\(home)/notes.md"
        #expect(SystemReminderRowBody.abbreviatedPath(onVolume) == onVolume)
    }

    @Test("an unrelated absolute path is unchanged")
    func leavesUnrelatedPathAlone() {
        #expect(SystemReminderRowBody.abbreviatedPath("/srv/acme-prod/deploy.swift")
            == "/srv/acme-prod/deploy.swift")
    }
}
