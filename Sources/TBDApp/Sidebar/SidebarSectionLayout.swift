import Foundation
import TBDShared

/// What one sidebar owner (a repository, a remote provider, or Scratch)
/// renders below its own header, decided once so the view and its tests read
/// the same answer.
///
/// With workflow groups off — the shipped default, see
/// `AppState.sidebarWorkflowGroupsDefault` — every row stays inline in the
/// place it has always had: active local and remote roots in their stored
/// order, then the owner's unadopted remote sessions, with no group header.
/// With groups on, remote and exited work moves under a "Remote" disclosure
/// and wholly parked local work under a "Hibernated" one
/// (`docs/specs/2026-09-16-workflow-sidebar-groups-design.md`).
struct SidebarSectionLayout {
    /// Top-level worktree rows rendered in the owner's own place, in order.
    let inlineRoots: [Worktree]
    /// Remote sessions rendered inline after `inlineRoots`.
    let inlineSessions: [RemoteSessionInfo]
    /// The Remote/Exited partition; nil when no Remote header renders.
    let remoteGroups: SidebarRemoteGroups?
    /// The parked shelf; nil when no Hibernated header renders.
    let hibernation: SidebarHibernationPartition?
    /// Whether this layout files rows under workflow groups.
    let grouped: Bool
    /// The ended sessions behind one collapsed "Ended" row after the inline
    /// sessions; nil unless the collapse-ended option is on, groups are off,
    /// and at least one session has ended. Those sessions are then absent
    /// from `inlineSessions`.
    let ended: SidebarEndedSessions?

    init(inlineRoots: [Worktree], inlineSessions: [RemoteSessionInfo],
         remoteGroups: SidebarRemoteGroups?, hibernation: SidebarHibernationPartition?,
         grouped: Bool, ended: SidebarEndedSessions? = nil) {
        self.inlineRoots = inlineRoots
        self.inlineSessions = inlineSessions
        self.remoteGroups = remoteGroups
        self.hibernation = hibernation
        self.grouped = grouped
        self.ended = ended
    }

    /// Splits ungrouped inline sessions when `collapseEnded` is on. With it
    /// off this is the identity, and `unread` is never read.
    private static func inline(
        _ sessions: [RemoteSessionInfo], collapseEnded: Bool,
        unread: () -> [RemoteSessionSelection: UnreadSummary]
    ) -> (sessions: [RemoteSessionInfo], ended: SidebarEndedSessions?) {
        guard collapseEnded else { return (sessions, nil) }
        let partition = SidebarEndedSessions(sessions: sessions, unread: unread())
        return (partition.live, partition.hasEnded ? partition : nil)
    }

    /// The subset handed to a drag reorder of `inlineRoots`. Ungrouped, the
    /// inline rows are the whole top level, so nil asks for a plain index
    /// move; grouped, they are a subset that `SidebarSubsetOrder` moves in
    /// place, even when no header happens to render.
    var reorderVisibleIDs: [UUID]? {
        grouped ? inlineRoots.map(\.id) : nil
    }

    /// A repository section. Inputs are autoclosures so each mode computes
    /// only what it renders; the ungrouped default never partitions.
    /// `collapseEnded` applies only while ungrouped; grouped output ignores it.
    static func repository(
        grouped: Bool,
        collapseEnded: Bool,
        unread: @autoclosure () -> [RemoteSessionSelection: UnreadSummary],
        topLevel: @autoclosure () -> [Worktree],
        matchedSessions: @autoclosure () -> [RemoteSessionInfo],
        remoteGroups: @autoclosure () -> SidebarRemoteGroups,
        hibernation: @autoclosure () -> SidebarHibernationPartition
    ) -> SidebarSectionLayout {
        guard grouped else {
            let split = inline(matchedSessions(), collapseEnded: collapseEnded, unread: unread)
            return SidebarSectionLayout(
                inlineRoots: topLevel(), inlineSessions: split.sessions,
                remoteGroups: nil, hibernation: nil, grouped: false, ended: split.ended)
        }
        let groups = remoteGroups(), partition = hibernation()
        return SidebarSectionLayout(
            inlineRoots: partition.workingRoots, inlineSessions: [],
            remoteGroups: groups.isEmpty ? nil : groups,
            hibernation: partition.hibernatedRoots.isEmpty ? nil : partition, grouped: true)
    }

    /// A remote provider's unmatched sessions.
    static func provider(
        grouped: Bool,
        collapseEnded: Bool,
        unread: @autoclosure () -> [RemoteSessionSelection: UnreadSummary],
        sessions: @autoclosure () -> [RemoteSessionInfo],
        remoteGroups: @autoclosure () -> SidebarRemoteGroups
    ) -> SidebarSectionLayout {
        guard grouped else {
            let split = inline(sessions(), collapseEnded: collapseEnded, unread: unread)
            return SidebarSectionLayout(
                inlineRoots: [], inlineSessions: split.sessions, remoteGroups: nil, hibernation: nil,
                grouped: false, ended: split.ended)
        }
        let groups = remoteGroups()
        return SidebarSectionLayout(
            inlineRoots: [], inlineSessions: [],
            remoteGroups: groups.isEmpty ? nil : groups, hibernation: nil, grouped: true)
    }

    /// The Scratch section's flat rows.
    static func scratch(
        grouped: Bool,
        rows: [Worktree],
        hibernation: @autoclosure () -> SidebarHibernationPartition
    ) -> SidebarSectionLayout {
        guard grouped else {
            return SidebarSectionLayout(
                inlineRoots: rows, inlineSessions: [], remoteGroups: nil, hibernation: nil, grouped: false)
        }
        let partition = hibernation()
        return SidebarSectionLayout(
            inlineRoots: partition.workingRoots, inlineSessions: [], remoteGroups: nil,
            hibernation: partition.hibernatedRoots.isEmpty ? nil : partition, grouped: true)
    }
}
