import Foundation
import Testing
@testable import TBDApp

@Suite("Sidebar dev server dot")
struct WorktreeRowServerDotTests {
    @Test func theDotFollowsTheRunningSet() {
        let a = UUID(), b = UUID()
        #expect(WorktreeRowView.showsServerDot(worktreeID: a, running: [a]))
        #expect(!WorktreeRowView.showsServerDot(worktreeID: b, running: [a]))
        #expect(!WorktreeRowView.showsServerDot(worktreeID: a, running: []))
    }
}
