import Foundation
import Testing
@testable import TBDShared

/// Where a composer attachment lives. Every helper takes an explicit environment
/// so this suite needs no `setenv` — the injection seam `Tests/CLAUDE.md`
/// prefers, and the reason the test fence works at all.
@Suite("attachment paths")
struct AttachmentPathTests {
    private let worktreeID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let attachmentID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    @Test func theBaseDirectorySitsUnderTheConfigDir() {
        let env = ["TBD_HOME": "/scratch/home"]
        #expect(TBDConstants.attachmentsDir(environment: env).path
            == "/scratch/home/attachments")
    }

    /// The load-bearing property: `TBD_HOME` is honored, so a test run and the
    /// live daemon never share a directory. A path composed from `$HOME` would
    /// ignore this and defeat the fence.
    @Test func itFollowsTBDHome() {
        let a = TBDConstants.attachmentsDir(environment: ["TBD_HOME": "/one"])
        let b = TBDConstants.attachmentsDir(environment: ["TBD_HOME": "/two"])
        #expect(a != b)
        #expect(a.path.hasPrefix("/one"))
    }

    @Test func aWorktreeGetsItsOwnDirectory() {
        let env = ["TBD_HOME": "/scratch/home"]
        #expect(TBDConstants.attachmentsDir(worktreeID: worktreeID, environment: env).path
            == "/scratch/home/attachments/\(worktreeID.uuidString)")
    }

    @Test func aFilePathIsTheWorktreeDirectoryPlusAUUIDPNG() {
        let env = ["TBD_HOME": "/scratch/home"]
        #expect(TBDConstants.attachmentPath(
            worktreeID: worktreeID, attachmentID: attachmentID, environment: env)
            == "/scratch/home/attachments/\(worktreeID.uuidString)/\(attachmentID.uuidString).png")
    }
}
