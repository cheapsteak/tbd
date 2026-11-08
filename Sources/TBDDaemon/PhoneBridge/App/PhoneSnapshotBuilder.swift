import Foundation
import TBDShared

/// Everything the phone's sessions list is built from, as the gather read it
/// from the database, the pending prompt store and `PhoneSessionActions`.
struct PhoneSnapshotInput: Sendable {
    /// Every repo, in `db.repos.list()` order.
    let repos: [Repo]
    /// The worktree rows that are not archived. Scratch rows may be among
    /// them; only rows with a repo are read from here.
    let worktrees: [Worktree]
    /// The scratch rows, those with no repo.
    let scratch: [Worktree]
    /// Each worktree's terminals, by worktree ID.
    let terminals: [UUID: [TBDShared.Terminal]]
    /// Each worktree's tab order, by worktree ID. A terminal tab's ID is its
    /// terminal's ID.
    let tabOrder: [UUID: [UUID]]
    /// The labels users gave tabs, by terminal ID.
    let tabLabels: [UUID: String]
    let profiles: [ModelProfile]
    /// Each local agent session's state, by terminal ID. A session missing
    /// here reads `unknown`.
    let states: [UUID: SessionState]
    /// Each terminal's oldest open prompt, by terminal ID.
    let openPrompts: [UUID: PendingPromptPayload]
    let remoteSessions: [RemoteSessionInfo]
    let providers: [RemoteProviderStatus]
}

/// The sessions list at one moment: the groups with their rows' places, and
/// the rows.
struct PhoneSnapshot: Equatable, Sendable {
    let layout: [PhoneGroupLayout]
    let rows: [PhoneRow]
    /// How many rows were left out: past `maxRows`, too large for a frame, or
    /// cut so the layout fits one.
    let omittedRows: Int
}

/// Builds the phone's sessions list in the laptop sidebar's order (spec
/// section 4.4, "Sessions list"). Pure: the gather reads everything first.
///
/// **The order** is the sidebar's ungrouped order with Show Hidden Repos off
/// and no repo filter, the two view settings the daemon cannot see:
/// 1. The scratch rows, in sibling order (`Worktree.precedesSibling`, the
///    order the sidebar sorts them in), as one `scratch` group, when any
///    exist.
/// 2. Each repo that is not hidden, in `repos` order, as a `repo` group: its
///    main, active and creating rows as `SidebarOrder.walk` lists them, then
///    the remote sessions matched to it, as the sidebar places them.
/// 3. Each provider in `providers` order with at least one session, as a
///    `provider` group of the sessions no shown repo claims.
///
/// Archived rows and dismissed sessions never appear.
///
/// **Rows.** A local worktree row has one session per agent tab, in tab
/// order; shell tabs are hidden. A remote lane's row has its one remote
/// session. A remote session no worktree row stands for is a `remoteSession`
/// row of its own.
///
/// **Size.** Every short text field is cut to `PhoneText.fieldLimit` bytes.
/// A row whose ID is longer than `rowIDByteLimit` bytes, or that alone would
/// encode to more than `rowByteLimit` bytes (a worktree with a hundred agent
/// tabs), is left out and counted in `omittedRows`, so no row needs more
/// than one frame. Past `maxRows`, rows are dropped from the end; and when
/// the layout would encode to more than `layoutByteLimit` bytes, rows are
/// dropped from the end until it fits, so the layout always fits one frame.
enum PhoneSnapshotBuilder {
    /// The most bytes one encoded row may take, leaving room in an event's
    /// `data` for its other fields.
    static let rowByteLimit = PhoneFrameBudget.eventDataBytes - 1_024
    /// The most bytes the encoded layout may take, for the same reason.
    static let layoutByteLimit = PhoneFrameBudget.eventDataBytes - 1_024
    /// The longest row ID kept, in UTF-8 bytes. A remote session's ID holds
    /// its provider's names, which TBD does not choose.
    static let rowIDByteLimit = 512
    /// The reason of a session TBD has no state for.
    static let noStateReason = "TBD has no state for this session."

    static func build(_ input: PhoneSnapshotInput, maxRows: Int = PhoneAppConstants.snapshotMaxRows) -> PhoneSnapshot {
        let encoder = PhoneAppCoding.makeEncoder()
        let (groups, entries) = orderedRows(input)

        var omitted = 0
        var seen = Set<String>()
        var kept: [Entry] = []
        for entry in entries {
            // A row listed twice keeps its first place.
            guard seen.insert(entry.row.id).inserted else { continue }
            guard entry.row.id.utf8.count <= rowIDByteLimit,
                  encodedSize(entry.row, encoder) <= rowByteLimit else {
                omitted += 1
                continue
            }
            kept.append(entry)
        }
        let rowLimit = max(0, maxRows)
        if kept.count > rowLimit {
            omitted += kept.count - rowLimit
            kept.removeLast(kept.count - rowLimit)
        }

        // The layout grows with every row kept, so the most rows whose layout
        // fits is found by halving.
        func fits(_ count: Int) -> Bool {
            encodedSize(layout(groups, kept.prefix(count)), encoder) <= layoutByteLimit
        }
        if !fits(kept.count) {
            var low = 0
            var high = kept.count
            while high - low > 1 {
                let mid = (low + high) / 2
                if fits(mid) {
                    low = mid
                } else {
                    high = mid
                }
            }
            omitted += kept.count - low
            kept.removeLast(kept.count - low)
        }

        var groupLayout = layout(groups, kept[...])
        if encodedSize(groupLayout, encoder) > layoutByteLimit {
            // Even the groups with no rows do not fit: so many repos that
            // their headers alone fill a frame. Drop groups from the end.
            var low = 0
            var high = groupLayout.count
            while high - low > 1 {
                let mid = (low + high) / 2
                if encodedSize(Array(groupLayout.prefix(mid)), encoder) <= layoutByteLimit {
                    low = mid
                } else {
                    high = mid
                }
            }
            groupLayout = Array(groupLayout.prefix(low))
        }
        return PhoneSnapshot(layout: groupLayout, rows: kept.map(\.row), omittedRows: omitted)
    }

    /// Whether the list places the remote session `provider`/`sessionID` in
    /// any row: the same walk `build` takes its rows from, so an action on a
    /// remote session and the list cannot disagree about which sessions the
    /// phone can see. A session missing from `input.remoteSessions`,
    /// dismissed, or matched only to a hidden repo is placed in none.
    ///
    /// The walk reads only the repos, the worktree and scratch rows, the
    /// remote sessions and the providers to place a remote session, so a
    /// caller may leave the other fields of `input` empty. A row `build`
    /// would leave out for its size still counts: the size limits keep the
    /// list within its frames and say nothing about what the phone may see.
    static func listsRemoteSession(provider: String, sessionID: String, in input: PhoneSnapshotInput) -> Bool {
        let ref = PhoneSessionRef.remote(provider: provider, sessionID: sessionID)
        return orderedRows(input).entries.contains { entry in
            entry.row.sessions.contains { $0.ref == ref }
        }
    }

    // MARK: - IDs

    static func worktreeRowID(_ worktree: Worktree) -> String {
        worktree.id.uuidString
    }

    static func remoteRowID(_ session: RemoteSessionInfo) -> String {
        "remote:\(session.provider)/\(session.payload.id)"
    }

    static func repoGroupID(_ repo: Repo) -> String {
        "repo:\(repo.id.uuidString)"
    }

    static func providerGroupID(_ name: String) -> String {
        "provider:\(name)"
    }

    // MARK: - Order

    private struct Group {
        let id: String
        let kind: String
        let name: String
        /// A repo's group stays when it has no rows, as its header does in
        /// the sidebar; the scratch and provider groups go.
        let keptWhenEmpty: Bool
    }

    private struct Entry {
        /// The index of its group.
        let group: Int
        let depth: Int
        let row: PhoneRow
    }

    /// What the rows are built from, indexed once.
    private struct Context {
        let input: PhoneSnapshotInput
        /// Each remote session that is not dismissed, by the location a
        /// remote lane's row names.
        let remoteByLocation: [WorktreeLocation: RemoteSessionInfo]
        /// Each provider's declared capabilities, by provider name.
        let declared: [String: Set<String>]
        /// Each profile's name, by profile ID.
        let profileNames: [UUID: String]

        init(_ input: PhoneSnapshotInput) {
            self.input = input
            var remote: [WorktreeLocation: RemoteSessionInfo] = [:]
            for session in input.remoteSessions where !session.dismissed {
                let location = WorktreeLocation.remote(provider: session.provider, sessionID: session.payload.id)
                if remote[location] == nil {
                    remote[location] = session
                }
            }
            remoteByLocation = remote
            declared = PhoneSessionStatus.declaredCapabilities(input.providers)
            var names: [UUID: String] = [:]
            for profile in input.profiles where names[profile.id] == nil {
                names[profile.id] = profile.name
            }
            profileNames = names
        }
    }

    private static func orderedRows(_ input: PhoneSnapshotInput) -> (groups: [Group], entries: [Entry]) {
        let context = Context(input)
        var groups: [Group] = []
        var entries: [Entry] = []

        // 1. Scratch.
        let scratch = input.scratch.filter { $0.status != .archived }.sorted(by: Worktree.precedesSibling)
        if !scratch.isEmpty {
            groups.append(Group(id: "scratch", kind: "scratch", name: "Scratch", keptWhenEmpty: false))
            for worktree in scratch {
                entries.append(Entry(group: groups.count - 1, depth: 0, row: worktreeRow(worktree, context)))
            }
        }

        // 2. Repos.
        let live = input.worktrees.filter { $0.status != .archived }
        let children = SidebarOrder.childrenIndex(live)
        var byRepo: [UUID: [Worktree]] = [:]
        for worktree in live {
            if let repoID = worktree.repoID {
                byRepo[repoID, default: []].append(worktree)
            }
        }
        for repo in input.repos where !repo.hidden {
            groups.append(Group(
                id: repoGroupID(repo), kind: "repo", name: PhoneText.capped(repo.displayName), keptWhenEmpty: true))
            let group = groups.count - 1
            let repoWorktrees = byRepo[repo.id] ?? []
            for step in SidebarOrder.walk(repoWorktrees: repoWorktrees, children: children, order: .parentsFirst) {
                entries.append(Entry(group: group, depth: step.depth, row: worktreeRow(step.worktree, context)))
            }
            let adopted = SidebarSessionPlacement.adoptedLocations(repoWorktrees)
            let matched = SidebarSessionPlacement.matchedRemoteSessionIndices(
                input.remoteSessions, repoID: repo.id, adopted: adopted)
            for index in matched {
                entries.append(Entry(group: group, depth: 0, row: remoteSessionRow(input.remoteSessions[index], context)))
            }
        }

        // 3. Providers.
        let known = SidebarSessionPlacement.knownRepoIDs(repos: input.repos, repoFilter: nil)
        for provider in input.providers {
            let name = provider.config.name
            let sessions = SidebarSessionPlacement.sessions(
                in: input.remoteSessions, forProvider: name, knownRepoIDs: known)
            guard !sessions.isEmpty else { continue }
            groups.append(Group(
                id: providerGroupID(name), kind: "provider", name: PhoneText.capped(name), keptWhenEmpty: false))
            for session in sessions {
                entries.append(Entry(group: groups.count - 1, depth: 0, row: remoteSessionRow(session, context)))
            }
        }
        return (groups, entries)
    }

    private static func layout(_ groups: [Group], _ kept: ArraySlice<Entry>) -> [PhoneGroupLayout] {
        var placements = Array(repeating: [PhoneRowPlacement](), count: groups.count)
        for entry in kept {
            placements[entry.group].append(PhoneRowPlacement(id: entry.row.id, depth: entry.depth))
        }
        var result: [PhoneGroupLayout] = []
        for (index, group) in groups.enumerated() where group.keptWhenEmpty || !placements[index].isEmpty {
            result.append(PhoneGroupLayout(id: group.id, kind: group.kind, name: group.name, rows: placements[index]))
        }
        return result
    }

    // MARK: - Rows

    private static func worktreeRow(_ worktree: Worktree, _ context: Context) -> PhoneRow {
        let sessions: [PhoneSession]
        if worktree.location.isLocal {
            sessions = localSessions(worktree, context)
        } else if let session = context.remoteByLocation[worktree.location] {
            sessions = [remoteSession(session, context)]
        } else {
            sessions = []
        }
        return PhoneRow(
            id: worktreeRowID(worktree), kind: "worktree", name: PhoneText.capped(worktree.displayName),
            remote: !worktree.location.isLocal,
            statusChangedAt: sessions.map(\.status.changedAt).max() ?? PhoneTime.ms(worktree.createdAt),
            sessions: sessions)
    }

    private static func remoteSessionRow(_ session: RemoteSessionInfo, _ context: Context) -> PhoneRow {
        let phoneSession = remoteSession(session, context)
        let title = session.payload.title.flatMap { $0.isEmpty ? nil : $0 } ?? session.payload.id
        return PhoneRow(
            id: remoteRowID(session), kind: "remoteSession", name: PhoneText.capped(title), remote: true,
            statusChangedAt: phoneSession.status.changedAt, sessions: [phoneSession])
    }

    // MARK: - Sessions

    /// The agent a terminal runs, or nil for a shell tab. A row written
    /// before kinds were recorded counts as Claude once it has a Claude
    /// session, as the daemon's session states count it.
    static func agent(of terminal: TBDShared.Terminal) -> PhoneAgent? {
        if terminal.kind == .shell { return nil }
        if terminal.isCodexTerminal { return .codex }
        if terminal.kind == .claude { return .claude }
        return terminal.claudeSessionID == nil ? nil : .claude
    }

    /// A local row's sessions, one per agent tab: tabs in the stored tab
    /// order first, then the rest by when they were made.
    private static func localSessions(_ worktree: Worktree, _ context: Context) -> [PhoneSession] {
        let input = context.input
        let terminals = input.terminals[worktree.id] ?? []
        guard !terminals.isEmpty else { return [] }
        let order = input.tabOrder[worktree.id] ?? []
        let position = [UUID: Int](order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let ordered = terminals.enumerated().sorted { lhs, rhs in
            switch (position[lhs.element.id], position[rhs.element.id]) {
            case let (left?, right?):
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                if lhs.element.createdAt != rhs.element.createdAt {
                    return lhs.element.createdAt < rhs.element.createdAt
                }
                return lhs.offset < rhs.offset
            }
        }.map { $0.element }
        let orderedIDs = ordered.map(\.id)

        var sessions: [PhoneSession] = []
        for (index, terminal) in ordered.enumerated() {
            guard let agent = agent(of: terminal) else { continue }
            let prompt = input.openPrompts[terminal.id]
            let userLabel = input.tabLabels[terminal.id].flatMap { $0.isEmpty ? nil : $0 }
            let tabName = userLabel ?? TerminalTabLabel.automatic(
                terminal: terminal, fallbackIndex: index, profiles: input.profiles,
                orderedTerminalIDs: orderedIDs, worktreeTerminals: terminals)
            sessions.append(PhoneSession(
                ref: .local(terminalID: terminal.id),
                agent: agent,
                tabName: PhoneText.capped(tabName),
                status: PhoneSessionStatus.local(state(of: terminal, input), openPrompt: prompt),
                profileName: terminal.profileID.flatMap { context.profileNames[$0] }.map { PhoneText.capped($0) },
                profileID: terminal.profileID,
                // No stored field holds a session's current model; reading
                // it from the transcript is too slow for this path.
                model: nil,
                capabilities: PhoneSessionStatus.localCapabilities(terminal: terminal, isRemoteWorktree: false),
                openPromptID: prompt?.id))
        }
        return sessions
    }

    /// The terminal's session state. One TBD has no state for reads
    /// `unknown`. An `unknown` state is stamped with the time it was read,
    /// which moves on every read, so its time is the terminal's last
    /// observed activity instead, or when the terminal was made; the phone
    /// sorts by it.
    private static func state(of terminal: TBDShared.Terminal, _ input: PhoneSnapshotInput) -> SessionState {
        let steadyTime = terminal.activityStateObservedAt ?? terminal.createdAt
        guard let state = input.states[terminal.id] else {
            return SessionState(value: .unknown(why: noStateReason), source: .unavailable, observedAt: steadyTime)
        }
        guard state.source == .unavailable else { return state }
        return SessionState(value: state.value, source: state.source, observedAt: steadyTime)
    }

    private static func remoteSession(_ session: RemoteSessionInfo, _ context: Context) -> PhoneSession {
        let status = PhoneSessionStatus.remote(session)
        return PhoneSession(
            ref: .remote(provider: session.provider, sessionID: session.payload.id),
            agent: .remote,
            tabName: PhoneText.capped(session.provider),
            status: status,
            profileName: nil,
            profileID: nil,
            model: nil,
            capabilities: PhoneSessionStatus.remoteCapabilities(declared: context.declared[session.provider] ?? []),
            // An exited session's prompt can no longer be answered.
            openPromptID: status.chip == .exited ? nil : session.payload.effectivePendingPrompt?.id)
    }

    // MARK: - Size

    /// Bytes `value` encodes to under the protocol's encoder; `Int.max` when
    /// it does not encode, so it never counts as fitting.
    private static func encodedSize(_ value: some Encodable, _ encoder: JSONEncoder) -> Int {
        (try? encoder.encode(value).count) ?? Int.max
    }
}
