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

    /// The subset handed to a drag reorder of `inlineRoots`. Nil means the
    /// inline rows are the whole top level, so a plain index move applies.
    var reorderVisibleIDs: [UUID]? {
        remoteGroups == nil && hibernation == nil ? nil : inlineRoots.map(\.id)
    }

    /// A repository section. Inputs are autoclosures so each mode computes
    /// only what it renders; the ungrouped default never partitions.
    static func repository(
        grouped: Bool,
        topLevel: @autoclosure () -> [Worktree],
        matchedSessions: @autoclosure () -> [RemoteSessionInfo],
        remoteGroups: @autoclosure () -> SidebarRemoteGroups,
        hibernation: @autoclosure () -> SidebarHibernationPartition
    ) -> SidebarSectionLayout {
        guard grouped else {
            return SidebarSectionLayout(
                inlineRoots: topLevel(), inlineSessions: matchedSessions(),
                remoteGroups: nil, hibernation: nil)
        }
        let groups = remoteGroups(), partition = hibernation()
        return SidebarSectionLayout(
            inlineRoots: partition.workingRoots, inlineSessions: [],
            remoteGroups: groups.isEmpty ? nil : groups,
            hibernation: partition.hibernatedRoots.isEmpty ? nil : partition)
    }

    /// A remote provider's unmatched sessions.
    static func provider(
        grouped: Bool,
        sessions: @autoclosure () -> [RemoteSessionInfo],
        remoteGroups: @autoclosure () -> SidebarRemoteGroups
    ) -> SidebarSectionLayout {
        guard grouped else {
            return SidebarSectionLayout(
                inlineRoots: [], inlineSessions: sessions(), remoteGroups: nil, hibernation: nil)
        }
        let groups = remoteGroups()
        return SidebarSectionLayout(
            inlineRoots: [], inlineSessions: [],
            remoteGroups: groups.isEmpty ? nil : groups, hibernation: nil)
    }

    /// The Scratch section's flat rows.
    static func scratch(
        grouped: Bool,
        rows: [Worktree],
        hibernation: @autoclosure () -> SidebarHibernationPartition
    ) -> SidebarSectionLayout {
        guard grouped else {
            return SidebarSectionLayout(
                inlineRoots: rows, inlineSessions: [], remoteGroups: nil, hibernation: nil)
        }
        let partition = hibernation()
        return SidebarSectionLayout(
            inlineRoots: partition.workingRoots, inlineSessions: [], remoteGroups: nil,
            hibernation: partition.hibernatedRoots.isEmpty ? nil : partition)
    }
}
