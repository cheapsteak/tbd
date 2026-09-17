import Foundation
import Testing
@testable import TBDApp
import TBDShared

@Suite("Remote group attention matches completion urgency")
struct SidebarRemoteAttentionTests {
    @Test(arguments: [NotificationType.responseComplete, .taskComplete, .attentionNeeded,
                      .focusRequest, .limitReached, .error], [false, true])
    func unreadCompletionDoesNotRaiseAnUrgentGroupIcon(type: NotificationType, adopted: Bool) {
        let row = SidebarGroupFixtures.row("worker", repoID: UUID(), remote: "worker")
        let session = SidebarGroupFixtures.session("worker", state: .exited)
        let unread = UnreadSummary(type: type, mostRecentAt: Date())
        let key = RemoteSessionSelection(provider: "acme", sessionID: "worker")
        let snapshot = SidebarRemoteGroups.Snapshot(
            worktrees: [row], sessions: [session], providers: [SidebarGroupFixtures.provider()])
        let groups = SidebarRemoteGroups(
            roots: adopted ? [row] : [], remainder: adopted ? [] : [session], snapshot: snapshot,
            unread: adopted ? [:] : [key: unread], worktreeUnread: adopted ? [row.id: unread] : [:])
        let expected: NotificationType? = type == .responseComplete || type == .taskComplete ? nil : type
        #expect(groups.summary.attention == expected)
        #expect(groups.exitedSummary.attention == expected)
        #expect(groups.summary.counts == [.exited: 1])
        #expect(groups.exitedSummary.counts == [.exited: 1])
    }

    @Test func completionDoesNotSuppressFreshWaitingInput() {
        let session = SidebarGroupFixtures.session("worker", agent: .waitingInput)
        let key = RemoteSessionSelection(provider: "acme", sessionID: "worker")
        let groups = SidebarGroupFixtures.groups(remainder: [session], unread: [
            key: UnreadSummary(type: .responseComplete, mostRecentAt: Date())
        ])
        #expect(groups.summary.attention == .attentionNeeded)
    }

    @Test(arguments: [NotificationType.attentionNeeded, .error])
    func urgentDescendantOutranksCompletionForBothSummaries(type: NotificationType) {
        let repo = UUID()
        let parent = SidebarGroupFixtures.row("parent", repoID: repo, remote: "parent")
        let child = SidebarGroupFixtures.row("child", repoID: repo, remote: "child", parent: parent.id)
        let sessions = [SidebarGroupFixtures.session("parent", state: .exited),
                        SidebarGroupFixtures.session("child", state: .exited)]
        let key = RemoteSessionSelection(provider: "acme", sessionID: "child")
        let snapshot = SidebarRemoteGroups.Snapshot(
            worktrees: [parent, child], sessions: sessions, providers: [SidebarGroupFixtures.provider()])
        let groups = SidebarRemoteGroups(
            roots: [parent], remainder: [], snapshot: snapshot,
            unread: [key: UnreadSummary(type: type, mostRecentAt: Date())],
            worktreeUnread: [parent.id: UnreadSummary(type: .responseComplete, mostRecentAt: Date())])
        #expect(groups.summary.attention == type)
        #expect(groups.exitedSummary.attention == type)
        #expect(groups.exitedSummary.counts == [.exited: 2])
    }
}
