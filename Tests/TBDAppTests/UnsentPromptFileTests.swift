import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// `UnsentPromptFile` — where a first message that never reached its worktree
/// is written. Tier 2: a real temp directory, a fixed date and time zone, so
/// nothing depends on the wall clock or the process-global `TBD_HOME`.
@Suite("UnsentPromptFile")
struct UnsentPromptFileTests: ~Copyable {
    private let fm = FileManager.default
    /// 2026-03-04 05:06:07 UTC.
    private let date = Date(timeIntervalSince1970: 1_772_600_767)
    private let utc = TimeZone(identifier: "UTC")!
    let root: URL

    init() {
        root = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbdunsent"), isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private var directory: URL { root.appendingPathComponent("unsent-prompts", isDirectory: true) }

    @Test func timestampIsYearMonthDayDashHourMinuteSecond() {
        #expect(UnsentPromptFile.timestamp(date, timeZone: utc) == "20260304-050607")
    }

    @Test func aGeneratedSlugPassesThroughUnchanged() {
        #expect(UnsentPromptFile.sanitizedName("brave-otter_2.v1") == "brave-otter_2.v1")
    }

    @Test func unsafeCharactersCollapseToSingleDashes() {
        #expect(UnsentPromptFile.sanitizedName("fix: the / login  bug?") == "fix-the-login-bug")
        #expect(UnsentPromptFile.sanitizedName("café ünïcode") == "caf-n-code")
    }

    @Test func leadingDotsAndDashesCannotMakeADotfileOrTraversal() {
        #expect(UnsentPromptFile.sanitizedName("../../etc") == "etc")
        #expect(UnsentPromptFile.sanitizedName(".hidden") == "hidden")
    }

    @Test func anEmptyResultFallsBackToWorktree() {
        #expect(UnsentPromptFile.sanitizedName("") == "worktree")
        #expect(UnsentPromptFile.sanitizedName("🙂🙂") == "worktree")
    }

    @Test func aLongNameIsCapped() {
        let name = String(repeating: "a", count: 500)
        #expect(UnsentPromptFile.sanitizedName(name).count == UnsentPromptFile.maxNameLength)
    }

    @Test func writeCreatesTheDirectoryAndTheNamedFile() throws {
        let path = try UnsentPromptFile.write(
            text: "first message", worktreeName: "brave otter",
            directory: directory, date: date, timeZone: utc)

        #expect(path == directory.appendingPathComponent("20260304-050607-brave-otter.md").path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "first message\n")
    }

    @Test func aSecondWriteWithTheSameNameDoesNotClobberTheFirst() throws {
        let first = try UnsentPromptFile.write(
            text: "one", worktreeName: "otter", directory: directory, date: date, timeZone: utc)
        let second = try UnsentPromptFile.write(
            text: "two", worktreeName: "otter", directory: directory, date: date, timeZone: utc)
        let third = try UnsentPromptFile.write(
            text: "three", worktreeName: "otter", directory: directory, date: date, timeZone: utc)

        #expect(first.hasSuffix("/20260304-050607-otter.md"))
        #expect(second.hasSuffix("/20260304-050607-otter-2.md"))
        #expect(third.hasSuffix("/20260304-050607-otter-3.md"))
        #expect(try String(contentsOfFile: first, encoding: .utf8) == "one\n")
        #expect(try String(contentsOfFile: second, encoding: .utf8) == "two\n")
    }

    @Test func anUnwritableDirectoryThrows() throws {
        // A regular file where the directory should be: creating it fails.
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        fm.createFile(atPath: directory.path, contents: Data())
        #expect(throws: (any Error).self) {
            try UnsentPromptFile.write(
                text: "x", worktreeName: "otter", directory: directory, date: date, timeZone: utc)
        }
    }
}
