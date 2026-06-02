import Foundation
import Testing
@testable import TBDApp

@Suite("WorktreePager")
@MainActor
struct WorktreePagerTests {
    @Test func mountedWorktreeIDsAlwaysIncludeActiveWorktreeFirst() {
        let mainID = UUID()
        let activeID = UUID()

        #expect(WorktreePager.mountedWorktreeIDs(recentIDs: [mainID], activeID: activeID) == [
            activeID,
            mainID,
        ])
    }

    @Test func mountedWorktreeIDsDeduplicateActiveWorktree() {
        let mainID = UUID()
        let activeID = UUID()

        #expect(WorktreePager.mountedWorktreeIDs(recentIDs: [mainID, activeID], activeID: activeID) == [
            activeID,
            mainID,
        ])
    }
}
