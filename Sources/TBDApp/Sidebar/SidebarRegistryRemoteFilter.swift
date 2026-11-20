import Foundation
import TBDShared

/// What one repo section's registry filter hides, the count its header button
/// shows, whether that button exists, and the wording it uses
/// (`docs/specs/2026-11-19-sidebar-remote-session-filter-design.md`).
///
/// The one place the rule lives. The tree builder, the per-parent remote
/// groups, the header model, the menu item and the drop policy all consume
/// this value; none of them repeats the rule.
///
/// A **registry row** is a worktree row whose location is
/// `.remote(provider:sessionID:)` with a registry provider: any provider but
/// the compiled cloud one (`isRegistryProvider`). A **loose registry session**
/// is a registry-provider session in the repo's matched sessions that no
/// walked row stands for. The filter hides every registry row and loose
/// registry session, except that a row is kept while any row below it is kept
/// (so a kept local or cloud row is never cut off from the tree), and, while
/// the filter is on, a selected row or session is kept along with its
/// ancestors.
struct SidebarRegistryRemoteFilter: Equatable, Sendable {
    /// The worktree rows the section drops, after the selection exception.
    /// Empty while the filter is off.
    let hiddenWorktreeIDs: Set<UUID>
    /// The remote session IDs the section drops, after the selection
    /// exception: every loose registry session not selected, plus the session
    /// of every hidden row. Empty while the filter is off.
    let hiddenSessionIDs: Set<UUID>
    /// Hidden rows plus hidden loose sessions; a session and its row count
    /// once. 0 while the filter is off.
    let count: Int
    /// What the filter would hide with nothing selected, judged whether the
    /// filter is on or off. Decides whether the button exists, so selecting a
    /// hidden row never makes the button vanish under the pointer.
    let hideableCount: Int
    /// The registry providers among the hideable rows and sessions, sorted and
    /// distinct: one names itself in the wording, two or more fall back to the
    /// generic text.
    let providerNames: [String]
    /// The repo is in the saved set.
    let isOn: Bool

    /// The header button exists while the filter would hide anything.
    var showsButton: Bool { hideableCount > 0 }

    /// Nothing to hide, off.
    static let none = SidebarRegistryRemoteFilter(
        roots: [], children: [:], sessions: [], isOn: false, selectedWorktreeIDs: [], selectedSessionID: nil)

    /// - Parameters:
    ///   - roots: the section's top-level rows.
    ///   - children: active and creating rows by parent, in sibling order
    ///     (`SidebarOrder.childrenIndex`); it may name rows of other repos.
    ///   - sessions: the repo's matched remote sessions.
    ///   - isOn: the repo is in the saved set.
    ///   - selectedWorktreeIDs: the selected rows; read only while `isOn`.
    ///   - selectedSessionID: the selected session's identity
    ///     (`RemoteSessionIdentity.uuid`); read only while `isOn`. It keeps a
    ///     loose session, and also any row whose location names that session.
    init(roots: [Worktree], children: [UUID: [Worktree]], sessions: [RemoteSessionInfo], isOn: Bool,
         selectedWorktreeIDs: Set<UUID>, selectedSessionID: UUID?) {
        var walker = Walker(children: children, selectedWorktreeIDs: selectedWorktreeIDs,
                            selectedSessionID: selectedSessionID)
        for root in roots { _ = walker.visit(root, depth: 0) }

        var providers = walker.providers
        var looseHideable: Set<UUID> = [], looseHidden: Set<UUID> = [], boundHidden: Set<UUID> = []
        for session in sessions where Self.isRegistryProvider(session.provider)
            && !session.dismissed && !session.payload.isArchived {
            // A session a walked row stands for shares that row's fate and is
            // counted with it.
            if walker.boundSessions.contains(session.id) {
                if walker.hiddenRowSessions.contains(session.id) { boundHidden.insert(session.id) }
                continue
            }
            looseHideable.insert(session.id)
            providers.insert(session.provider)
            if session.id != selectedSessionID { looseHidden.insert(session.id) }
        }

        self.isOn = isOn
        hideableCount = walker.hideable.count + looseHideable.count
        providerNames = providers.sorted()
        if isOn {
            hiddenWorktreeIDs = walker.hidden
            hiddenSessionIDs = looseHidden.union(boundHidden)
            count = walker.hidden.count + looseHidden.count
        } else {
            hiddenWorktreeIDs = []
            hiddenSessionIDs = []
            count = 0
        }
    }

    /// Every provider but the compiled cloud one. Judged by name rather than
    /// by the loaded roster, which is empty until the app's first fetch and
    /// is cleared while remote backends are unavailable.
    static func isRegistryProvider(_ name: String) -> Bool {
        name != ClaudeCloudProvider.name
    }

    // MARK: Wording

    /// "Hide acme sessions"; with two or more providers, "Hide remote sessions
    /// except cloud".
    static func offTooltip(providerNames: [String]) -> String {
        if let name = soleProvider(providerNames) { return "Hide \(name) sessions" }
        return "Hide remote sessions except cloud"
    }

    /// "3 acme sessions hidden. Click to show them."; singular for 1
    /// ("1 acme session hidden. Click to show it."); with two or more
    /// providers, "remote" in place of the name.
    static func onTooltip(count: Int, providerNames: [String]) -> String {
        let noun = soleProvider(providerNames) ?? "remote"
        if count == 1 { return "1 \(noun) session hidden. Click to show it." }
        return "\(count) \(noun) sessions hidden. Click to show them."
    }

    /// "Hide acme Sessions"; with two or more providers, "Hide Remote Sessions
    /// Except Cloud".
    static func menuTitle(providerNames: [String]) -> String {
        if let name = soleProvider(providerNames) { return "Hide \(name) Sessions" }
        return "Hide Remote Sessions Except Cloud"
    }

    private static func soleProvider(_ names: [String]) -> String? {
        names.count == 1 ? names.first : nil
    }

    // MARK: Walk

    /// One post-order pass over a section's subtrees, answering for each row
    /// whether it is kept ignoring the selection and whether it is kept with
    /// it.
    private struct Walker {
        let children: [UUID: [Worktree]]
        let selectedWorktreeIDs: Set<UUID>
        let selectedSessionID: UUID?
        var visited: Set<UUID> = []
        /// Rows the filter would hide with nothing selected.
        var hideable: Set<UUID> = []
        /// Rows the filter hides with the selection kept.
        var hidden: Set<UUID> = []
        /// The session identity of every walked remote row.
        var boundSessions: Set<UUID> = []
        /// The session identities of the rows in `hidden`.
        var hiddenRowSessions: Set<UUID> = []
        /// The registry providers of the rows in `hideable`.
        var providers: Set<String> = []

        init(children: [UUID: [Worktree]], selectedWorktreeIDs: Set<UUID>, selectedSessionID: UUID?) {
            self.children = children
            self.selectedWorktreeIDs = selectedWorktreeIDs
            self.selectedSessionID = selectedSessionID
        }

        /// A revisit or a row past the depth cap answers "kept", so a corrupt
        /// parent chain never hides anything.
        mutating func visit(_ row: Worktree, depth: Int) -> (keptIgnoringSelection: Bool, keptWithSelection: Bool) {
            guard depth <= SidebarOrder.maxDepth, visited.insert(row.id).inserted else { return (true, true) }
            var childKept = false, childKeptWithSelection = false
            let kids = children[row.id] ?? []
            for child in kids {
                let answer = visit(child, depth: depth + 1)
                if answer.keptIgnoringSelection { childKept = true }
                if answer.keptWithSelection { childKeptWithSelection = true }
            }

            let identity = Self.sessionIdentity(of: row)
            if let identity { boundSessions.insert(identity) }
            let registryProvider = Self.registryProvider(of: row)
            let kept = registryProvider == nil || childKept
            var selected = selectedWorktreeIDs.contains(row.id)
            if let identity, identity == selectedSessionID { selected = true }
            let keptWithSelection = kept || selected || childKeptWithSelection

            if !kept {
                hideable.insert(row.id)
                if let registryProvider { providers.insert(registryProvider) }
            }
            if !keptWithSelection {
                hidden.insert(row.id)
                if let identity { hiddenRowSessions.insert(identity) }
            }
            return (kept, keptWithSelection)
        }

        /// The provider of a registry row, nil for every other row. A landed
        /// lane is `.local` whatever its origin, so it is never a registry row.
        static func registryProvider(of row: Worktree) -> String? {
            guard row.status != .main, case .remote(let provider, _) = row.location,
                  SidebarRegistryRemoteFilter.isRegistryProvider(provider) else { return nil }
            return provider
        }

        /// The identity of the session a remote row stands for; nil for a
        /// local row and for a creation placeholder, which has no session ID
        /// yet.
        static func sessionIdentity(of row: Worktree) -> UUID? {
            guard case .remote(let provider, let sessionID) = row.location, !sessionID.isEmpty else { return nil }
            return RemoteSessionIdentity.uuid(provider: provider, sessionID: sessionID)
        }
    }
}

/// The state a repo header's registry filter button draws; nil on the header
/// model means no button (`SidebarRegistryRemoteFilter.showsButton`).
struct SidebarRegistryFilterButton: Equatable, Sendable {
    var isOn: Bool
    /// What the filter hides now; drawn beside the symbol while on.
    var count: Int
    /// The registry providers' display names
    /// (`RemoteProviderIdentityPresentation.headline`), sorted and distinct.
    var providerNames: [String]

    var tooltip: String {
        isOn
            ? SidebarRegistryRemoteFilter.onTooltip(count: count, providerNames: providerNames)
            : SidebarRegistryRemoteFilter.offTooltip(providerNames: providerNames)
    }

    var menuTitle: String { SidebarRegistryRemoteFilter.menuTitle(providerNames: providerNames) }
}
