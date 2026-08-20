import Foundation
import Testing

@testable import TBDApp

/// The prompt has to read as a sentence. "storybook, dev running" is a list
/// pasted into prose; "storybook and dev" is English, and the difference is
/// whether the person reads the warning or dismisses it.
@Test func serverListReadsAsASentence() {
    #expect(makePending(servers: []).serverList == "")
    #expect(makePending(servers: ["dev"]).serverList == "dev")
    #expect(makePending(servers: ["storybook", "dev"]).serverList == "storybook and dev")
    #expect(
        makePending(servers: ["a", "b", "c"]).serverList == "a, b, and c")
    #expect(
        makePending(servers: ["a", "b", "c", "d"]).serverList == "a, b, c, and d")
}

/// Identity is the worktree, so SwiftUI replaces rather than stacks a prompt if
/// a second archive attempt arrives for the same worktree.
@Test func identityIsTheWorktree() {
    let id = UUID()
    #expect(makePending(id: id, servers: ["a"]).id == id)
}

/// `force` round-trips so a confirmation re-issues the SAME archive. It means
/// "skip the archive hook" — a confirmation that silently flipped it would run,
/// or skip, a repo's hook against the user's intent.
@Test func forceRoundTripsThroughTheConfirmation() {
    #expect(makePending(servers: ["dev"], force: true).force == true)
    #expect(makePending(servers: ["dev"], force: false).force == false)
}

private func makePending(
    id: UUID = UUID(), name: String = "worktree", servers: [String], force: Bool = false
) -> PendingArchive {
    PendingArchive(worktreeID: id, worktreeName: name, servers: servers, force: force)
}
