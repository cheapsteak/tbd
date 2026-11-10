import Foundation
import Testing
@testable import TBDDaemonLib

/// git's stderr for a `git worktree add` that ran out of disk space, in the
/// shape a real capture had: a `Preparing worktree` line, progress meters
/// joined by `\r` (git prints them even into a pipe) with
/// `error: failed to open file` lines between them, an
/// `error: unable to write file` line, and git's verdict last. The real one
/// was about 282 KB; `files` sets the size.
enum DiskFullStderrFixture {
    static let verdict = "fatal: Could not reset index file to revision 'HEAD'."

    static func make(files: Int) -> String {
        var text = "Preparing worktree (new branch 'tbd/brave-otter')\n"
        for index in 1...files {
            // git pads the percentage to three columns.
            let digits = String(index * 100 / files)
            let percent = String(repeating: " ", count: 3 - digits.count) + digits
            text += "Updating files: \(percent)% (\(index)/\(files))\r"
            if index % 3 == 0 {
                text += "error: failed to open file 'src/file\(index).swift': No space left on device\n"
            }
        }
        text += "error: unable to write file 'src/last.swift'\n"
        text += "Updating files: 100% (\(files)/\(files)), done.\n"
        text += verdict + "\n"
        return text
    }
}

/// Tier 1. `GitStderr.summary` keeps git's verdict and drops its progress
/// meters, within a character budget.
@Suite("GitStderr summary")
struct GitStderrTests {

    @Test func progressMetersAreDropped() {
        let summary = GitStderr.summary(DiskFullStderrFixture.make(files: 30), maxCharacters: 10_000)

        #expect(!summary.contains("Updating files"))
        #expect(!summary.contains("\r"))
        #expect(summary.hasPrefix("Preparing worktree (new branch 'tbd/brave-otter')\n"))
        #expect(summary.contains("error: failed to open file 'src/file3.swift': No space left on device"))
        #expect(summary.hasSuffix("\n" + DiskFullStderrFixture.verdict))
    }

    @Test func shortInputIsUnchanged() {
        let stderr = "Preparing worktree (new branch 'x')\nfatal: a branch named 'x' already exists"
        #expect(GitStderr.summary(stderr, maxCharacters: 500) == stderr)
        #expect(GitStderr.summary(stderr + "\n", maxCharacters: 500) == stderr)
    }

    @Test func emptyInputIsEmpty() {
        #expect(GitStderr.summary("", maxCharacters: 500) == "")
        #expect(GitStderr.summary(" \n\r\n", maxCharacters: 500) == "")
    }

    /// git prints its verdict last, so a summary that must leave lines out
    /// leaves out the earliest ones, and says how many.
    @Test func longInputKeepsTheTailWithAnOmittedCount() {
        let errors = (1...50).map { "error: failed to open file 'f\($0).txt': No space left on device" }
        let lines = errors + [DiskFullStderrFixture.verdict]
        let summary = GitStderr.summary(lines.joined(separator: "\n"), maxCharacters: 300)

        #expect(summary.count <= 300)
        var shown = summary.components(separatedBy: "\n")
        let notice = shown.removeFirst()
        #expect(notice == "… (\(lines.count - shown.count) earlier lines omitted)")
        // Whole lines, and the last ones: what is shown is the input's tail.
        #expect(!shown.isEmpty)
        #expect(Array(lines.suffix(shown.count)) == shown)
    }

    @Test func theDiskFullFixtureKeepsTheCauseAndTheVerdict() {
        let summary = GitStderr.summary(DiskFullStderrFixture.make(files: 3000), maxCharacters: 500)

        #expect(summary.count <= 500)
        #expect(summary.hasPrefix("… ("))
        #expect(summary.contains("No space left on device"))
        #expect(summary.contains("error: unable to write file 'src/last.swift'"))
        #expect(summary.hasSuffix(DiskFullStderrFixture.verdict))
        #expect(!summary.contains("Updating files"))
    }

    @Test func everyBudgetIsRespected() {
        let stderr = DiskFullStderrFixture.make(files: 300)
        for budget in [0, 1, 10, 40, 80, 200, 500, 700] {
            let summary = GitStderr.summary(stderr, maxCharacters: budget)
            #expect(summary.count <= budget, "budget \(budget): \(summary.count) characters")
        }
    }

    /// A line is cut only when the last line alone does not fit, and then
    /// its end is kept, since that is where git's sentence ends.
    @Test func aLastLineLongerThanTheBudgetKeepsItsTail() {
        let long = "fatal: " + String(repeating: "x", count: 1000) + " the end"
        let summary = GitStderr.summary("error: first\n" + long, maxCharacters: 100)

        #expect(summary.count <= 100)
        #expect(summary.hasPrefix("… (1 earlier line omitted)\n…"))
        #expect(summary.hasSuffix("x the end"))
    }

    /// A stderr of meters alone keeps its last meter, which says how far git
    /// got, rather than coming back empty.
    @Test func metersAloneKeepTheLastMeter() {
        let stderr = "Updating files:  50% (1/2)\rUpdating files: 100% (2/2), done.\n"
        #expect(GitStderr.summary(stderr, maxCharacters: 500) == "Updating files: 100% (2/2), done.")
    }

    @Test func progressMetersAreRecognized() {
        let meters = [
            "Updating files:  45% (1294/2876)",
            "Updating files:   5% (1/20)",
            "Updating files: 100% (2876/2876), done.",
            "remote: Counting objects: 100% (5/5), done.",
            "Receiving objects:  45% (12/26), 1.20 MiB | 2.00 MiB/s",
            "remote: Enumerating objects: 5, done.",
            "Counting objects: 1234",
        ]
        for meter in meters {
            #expect(GitStderr.isProgressMeter(meter), "\(meter)")
        }
    }

    @Test func gitsOwnLinesAreNotMeters() {
        let lines = [
            DiskFullStderrFixture.verdict,
            "error: failed to open file 'a.txt': No space left on device",
            "error: unable to write file 'a.txt'",
            "Preparing worktree (new branch 'x')",
            "HEAD is now at 1234abc init",
            "error: 5",
            "hint: 3",
        ]
        for line in lines {
            #expect(!GitStderr.isProgressMeter(line), "\(line)")
        }
    }
}

/// Tier 1. `GitError.description` is what the daemon logs, and the unified log
/// cuts a message off at about 1 KB, so it carries the summary rather than the
/// raw stderr, which stays on `stderr` for classification.
@Suite("GitError description")
struct GitErrorDescriptionTests {
    private static let command =
        "git -c checkout.workers=0 worktree add --no-track /tmp/acme/worktrees/brave-otter -b tbd/brave-otter origin/main"

    @Test func theDescriptionCarriesTheSummary() {
        let stderr = DiskFullStderrFixture.make(files: 3000)
        let error = GitError(command: Self.command, exitCode: 128, stderr: stderr)

        let description = error.description
        #expect(description.hasPrefix("Git command failed (128): \(Self.command)\n"))
        #expect(description.hasSuffix(DiskFullStderrFixture.verdict))
        #expect(description.contains("No space left on device"))
        #expect(!description.contains("Updating files"))
        #expect(description.utf8.count < 1024, "\(description.utf8.count) bytes")
        // The raw text is untouched: failure classification reads it.
        #expect(error.stderr == stderr)
    }

    @Test func aShortStderrIsShownWhole() {
        let error = GitError(
            command: "git worktree add /tmp/acme/wt x", exitCode: 128,
            stderr: "fatal: 'x' is already used by worktree at '/tmp/acme/other'\n")
        #expect(error.description == """
            Git command failed (128): git worktree add /tmp/acme/wt x
            fatal: 'x' is already used by worktree at '/tmp/acme/other'
            """)
    }
}
