import Foundation
import Testing
import TBDShared

@testable import TBDCLI

/// Tier 1. What `tbd worktree create` tells its caller, which for an agent is
/// the whole of what it learns about the creation.
///
/// Two failures of that once cost an agent a disk-full creation: `--no-wait`
/// printed "Created worktree" for a creation that had not run git yet and then
/// failed, and a waited creation that failed said only where the daemon had
/// logged why.
@Suite("worktree create: output")
struct WorktreeCreateOutputTests {

    private static let worktree = Worktree(
        repoID: UUID(),
        name: "brave-otter",
        displayName: "brave-otter",
        branch: "tbd/brave-otter",
        path: "/tmp/acme/worktrees/brave-otter",
        status: .creating,
        tmuxServer: "tbd-test")

    // MARK: - The rolled-back message

    /// With the daemon's reason, the message is the reason: git's verdict and
    /// the hint, not a pointer at a log.
    @Test func aRecordedReasonIsTheMessage() {
        let reason = "git worktree add failed — the disk is full; free space and try again\n"
            + "Details: … (2 earlier lines omitted)\n"
            + "error: failed to open file 'b.txt': No space left on device\n"
            + "fatal: Could not reset index file to revision 'HEAD'."

        let message = WorktreeCreate.rolledBackMessage(reason: reason)

        #expect(message == "Worktree creation failed and was rolled back:\n\n\(reason)")
        #expect(!message.contains("/usr/bin/log show"))
    }

    /// No reason (an older daemon, or none on record): the message names where
    /// the daemon logged it, with `log` spelled as an absolute path.
    @Test func noReasonNamesTheDaemonLog() {
        let message = WorktreeCreate.rolledBackMessage(reason: nil)

        #expect(message.hasPrefix("Worktree creation failed and was rolled back. The daemon logged why:"))
        #expect(message.contains("/usr/bin/log show --predicate 'subsystem == \"com.tbd.daemon\"'"))
    }

    /// A blank reason says nothing, so it is treated as none.
    @Test func aBlankReasonIsTreatedAsNone() {
        #expect(WorktreeCreate.rolledBackMessage(reason: " \n")
            == WorktreeCreate.rolledBackMessage(reason: nil))
    }

    // MARK: - Text output

    @Test func aWaitedCreateSaysItWasCreated() {
        let lines = WorktreeCreate.textOutput(Self.worktree, waited: true)

        #expect(lines.first == "Created worktree: brave-otter")
        #expect(lines.contains("  Branch: tbd/brave-otter"))
        #expect(lines.contains("  Path:   /tmp/acme/worktrees/brave-otter"))
        let mentionsNoWait = lines.contains { $0.contains("--no-wait") }
        #expect(!mentionsNoWait)
    }

    /// `--no-wait` returns before git runs, so it claims no success and says
    /// that a failure will not be reported here.
    @Test func noWaitClaimsNoSuccess() throws {
        let lines = WorktreeCreate.textOutput(Self.worktree, waited: false)

        #expect(lines.first == "Creating worktree: brave-otter")
        let claimsCreated = lines.contains { $0.hasPrefix("Created") }
        #expect(!claimsCreated)
        let notice = try #require(lines.last)
        #expect(notice.contains("returned before git ran"))
        #expect(notice.contains("a failure will not be reported here"))
        #expect(notice.contains("tbd worktree list"))
    }
}
