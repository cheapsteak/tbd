import Foundation
import Testing
@testable import TBDApp

@Suite("Sidebar dev server dot")
struct WorktreeRowServerDotTests {
    @Test func theDotFollowsTheRunningSet() {
        let a = UUID(), b = UUID()
        #expect(WorktreeRowPresentation.showsServerDot(worktreeID: a, running: [a]))
        #expect(!WorktreeRowPresentation.showsServerDot(worktreeID: b, running: [a]))
        #expect(!WorktreeRowPresentation.showsServerDot(worktreeID: a, running: []))
    }
}
