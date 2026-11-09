import Foundation
import Testing
@testable import TBDDaemonLib

/// Tier 1. The message a failed `git worktree add` produces, and the reason a
/// failed creation reports to the app and the CLI.
///
/// A disk-full `git worktree add` once reported only "git worktree add
/// failed" over the first 500 characters of its stderr, which were progress
/// meters, so nobody could tell the disk was full. These pin that the cause
/// and git's verdict both reach the message.
@Suite("worktree create: failure message")
struct WorktreeCreateFailureMessageTests {
    private static let command =
        "git -c checkout.workers=0 worktree add --no-track /tmp/acme/worktrees/brave-otter -b tbd/brave-otter origin/main"

    private static func gitError(_ stderr: String) -> GitError {
        GitError(command: command, exitCode: 128, stderr: stderr)
    }

    @Test func aFullDiskIsNamedAndGitsLastLinesAreKept() {
        let message = WorktreeLifecycle.worktreeAddFailedMessage(
            Self.gitError(DiskFullStderrFixture.make(files: 3000)))

        #expect(message.hasPrefix(
            "git worktree add failed — the disk is full; free space and try again\nDetails: … ("))
        #expect(message.contains("No space left on device"))
        #expect(message.hasSuffix(DiskFullStderrFixture.verdict))
        #expect(!message.contains("Updating files"))
        let details = message.components(separatedBy: "\nDetails: ").last ?? ""
        #expect(details.count <= WorktreeLifecycle.messageDetailBudget)
    }

    /// The hint is matched on git's raw stderr, case-insensitively, so it
    /// holds even when the summary left the matching line out.
    @Test func theDiskFullHintReadsTheRawStderr() {
        let stderr = "error: unable to create file a.txt: NO SPACE LEFT ON DEVICE\n"
            + String(repeating: "error: unable to write file 'b.txt'\n", count: 40)
            + DiskFullStderrFixture.verdict
        let message = WorktreeLifecycle.worktreeAddFailedMessage(Self.gitError(stderr))

        #expect(message.contains("the disk is full"))
        #expect(!message.contains("NO SPACE LEFT ON DEVICE"), "the summary was expected to omit the first line")
    }

    @Test func aStaleConfigLockStillGetsItsHint() {
        let message = WorktreeLifecycle.worktreeAddFailedMessage(Self.gitError(
            "error: could not lock config file .git/config: File exists\nfatal: unable to write upstream branch configuration"))

        #expect(message.contains("a stale .git/config.lock in the repo can be deleted"))
        #expect(!message.contains("the disk is full"))
    }

    @Test func anOrdinaryFailureGetsNoHint() {
        let message = WorktreeLifecycle.worktreeAddFailedMessage(
            Self.gitError("fatal: ambiguous object name: 'origin/main'\n"))

        #expect(message == "git worktree add failed\nDetails: fatal: ambiguous object name: 'origin/main'")
    }

    /// A non-git error is cut at the start, as before; only git's stderr is
    /// read from the end.
    @Test func aLongNonGitErrorIsCutToTheBudget() {
        struct Long: LocalizedError {
            var errorDescription: String? { String(repeating: "y", count: 2000) }
        }
        let details = WorktreeLifecycle.formatErrorForMessage(Long())

        #expect(details.hasPrefix("\nDetails: yyy"))
        #expect(details.hasSuffix("…"))
        #expect(details.count == "\nDetails: ".count + WorktreeLifecycle.messageDetailBudget + 1)
    }

    @Test func noDetailMeansNoDetailsLine() {
        #expect(WorktreeLifecycle.formatErrorForMessage(Self.gitError("")) == "")
    }

    // MARK: - The reason a failure reports

    /// A `createFailed` reports its own sentence: the app and the CLI say
    /// "Couldn't create worktree" / "Worktree creation failed" themselves.
    @Test func aCreateFailedReportsItsSentence() {
        let reason = WorktreeLifecycle.worktreeAddFailedMessage(
            Self.gitError(DiskFullStderrFixture.make(files: 30)))

        #expect(WorktreeLifecycle.creationFailureReason(
            WorktreeLifecycleError.createFailed(reason)) == reason)
    }

    @Test func aGitErrorReportsItsSummarizedDescription() {
        let error = Self.gitError(DiskFullStderrFixture.make(files: 3000))
        let reason = WorktreeLifecycle.creationFailureReason(error)

        #expect(reason == error.description)
        #expect(reason.hasSuffix(DiskFullStderrFixture.verdict))
    }

    @Test func aFoundationErrorReportsItsLocalizedDescription() {
        let error = CocoaError(.fileWriteOutOfSpace)
        #expect(WorktreeLifecycle.creationFailureReason(error)
            == (error as NSError).localizedDescription)
    }

    /// A Swift error with no localized description would render as the
    /// NSError bridge string, which names neither the case nor its payload.
    @Test func anUnlocalizedSwiftErrorReportsItsOwnDescription() {
        struct Unlocalized: Error, CustomStringConvertible {
            var description: String { "the acme probe failed" }
        }
        #expect(WorktreeLifecycle.creationFailureReason(Unlocalized()) == "the acme probe failed")
    }
}
