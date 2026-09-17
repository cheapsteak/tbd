import Foundation
import TBDShared

/// View-only identity. A disclosure never becomes a selectable worktree.
struct SidebarGroupID: Hashable {
    enum Owner: Hashable {
        case repository(UUID)
        case parent(UUID)
        case provider(String)
        case scratch
    }
    enum Kind: Hashable { case remote, exited, hibernated }
    let owner: Owner
    let kind: Kind
}

/// One snapshot's partition. Roots keep their complete subtrees and stored order.
struct SidebarRemoteGroups {
    struct Snapshot {
        let children: [UUID: [Worktree]]
        let rowsByID: [UUID: Worktree]
        let rowIDsBySession: [UUID: Set<UUID>]
        let mirror: [UUID: RemoteSessionInfo]
        let freshProviders: Set<String>
        let sessionsByRepo: [UUID: [RemoteSessionInfo]]
        let sessionsByProvider: [String: [RemoteSessionInfo]]

        init(worktrees: [Worktree], sessions: [RemoteSessionInfo], providers: [RemoteProviderStatus]) {
            children = Dictionary(grouping: worktrees.filter {
                $0.parentWorktreeID != nil && ($0.status == .active || $0.status == .creating)
            }, by: { $0.parentWorktreeID! }).mapValues { $0.sorted { $0.sortOrder < $1.sortOrder } }
            rowsByID = Dictionary(worktrees.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var bindings: [UUID: Set<UUID>] = [:]
            for row in worktrees {
                guard !row.location.isLocal, let binding = row.providerBinding else { continue }
                let id = RemoteSessionIdentity.uuid(provider: binding.provider, sessionID: binding.sessionID)
                bindings[id, default: []].insert(row.id)
            }
            rowIDsBySession = bindings
            mirror = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            freshProviders = Set(providers.filter {
                $0.health == .ok && !$0.hasStaleSnapshot && !$0.freshnessUnreadable
            }.map { $0.config.name })
            sessionsByRepo = Dictionary(grouping: sessions.filter { $0.resolvedRepoID != nil }, by: { $0.resolvedRepoID! })
            sessionsByProvider = Dictionary(grouping: sessions, by: \.provider)
        }
    }

    enum State: CaseIterable, Hashable {
        case running, starting, exited, unknown, gone

        var label: String {
            switch self {
            case .running: "running"
            case .starting: "starting"
            case .exited: "exited"
            case .unknown: "unknown"
            case .gone: "no longer reported"
            }
        }
    }

    struct Summary {
        var counts: [State: Int] = [:]
        var attention: NotificationType?

        var text: String {
            State.allCases.compactMap { state in
                guard let count = counts[state], count > 0 else { return nil }
                return "\(count) \(state.label)"
            }.joined(separator: " · ")
        }

        var hasUncertainty: Bool { counts[.unknown, default: 0] > 0 || counts[.gone, default: 0] > 0 }
    }

    let localRoots: [Worktree]
    let remoteRoots: [Worktree]
    let exitedRoots: [Worktree]
    let sessions: [RemoteSessionInfo]
    let exitedSessions: [RemoteSessionInfo]
    let summary: Summary
    let exitedSummary: Summary
    let remoteWorktreeIDs: Set<UUID>
    let exitedWorktreeIDs: Set<UUID>
    let sessionIDs: Set<UUID>
    let exitedSessionIDs: Set<UUID>

    var isEmpty: Bool { remoteRoots.isEmpty && exitedRoots.isEmpty && sessions.isEmpty && exitedSessions.isEmpty }
    var hasExited: Bool { !exitedRoots.isEmpty || !exitedSessions.isEmpty }

    init(roots: [Worktree], remainder: [RemoteSessionInfo], allWorktrees: [Worktree],
         inventory: [RemoteSessionInfo], providers: [RemoteProviderStatus],
         unread: [RemoteSessionSelection: UnreadSummary] = [:]) {
        self.init(roots: roots, remainder: remainder,
                  snapshot: Snapshot(worktrees: allWorktrees, sessions: inventory, providers: providers), unread: unread)
    }

    init(roots: [Worktree], remainder: [RemoteSessionInfo], snapshot: Snapshot,
         unread: [RemoteSessionSelection: UnreadSummary], worktreeUnread: [UUID: UnreadSummary] = [:]) {
        let children = snapshot.children, mirror = snapshot.mirror, freshProviders = snapshot.freshProviders
        var local: [Worktree] = [], active: [Worktree] = [], exited: [Worktree] = []
        var activeSessions: [RemoteSessionInfo] = [], endedSessions: [RemoteSessionInfo] = []
        var allIDs: Set<UUID> = [], endedIDs: Set<UUID> = []
        var allSessionIDs: Set<UUID> = [], endedSessionIDs: Set<UUID> = []
        var placeholderIDs: Set<UUID> = []
        var total = Summary(), ended = Summary()

        func state(_ session: RemoteSessionInfo?) -> State {
            guard let session else { return .unknown }
            guard freshProviders.contains(session.provider) else { return .unknown }
            if session.gone { return .gone }
            switch session.payload.state {
            case .running: return .running
            case .starting: return .starting
            case .exited: return .exited
            case .unknown: return .unknown
            }
        }

        func add(_ id: UUID, session: RemoteSessionInfo?, to result: inout Summary) {
            result.counts[state(session), default: 0] += 1
            guard let session else { return }
            let key = RemoteSessionSelection(provider: session.provider, sessionID: session.payload.id)
            let steady: NotificationType? = freshProviders.contains(session.provider)
                && !session.gone && session.payload.agentState == .waitingInput ? .attentionNeeded : nil
            let candidates = [result.attention, unread[key]?.type, steady].compactMap { $0 }
                .filter { $0 != .responseComplete && $0 != .taskComplete }
            result.attention = candidates.max { $0.severity < $1.severity }
        }

        for root in roots {
            guard !root.location.isLocal else { local.append(root); continue }
            var stack: [(Worktree, Int)] = [(root, 0)]
            var visited: Set<UUID> = []
            var bindings: [UUID: RemoteSessionInfo?] = [:]
            var entirelyExited = true
            while let (row, depth) = stack.popLast() {
                guard depth <= 50, visited.insert(row.id).inserted else { entirelyExited = false; continue }
                // A landed local row retains its provider origin, but its
                // current work and liveness are local rather than that session's.
                if !row.location.isLocal, let binding = row.providerBinding {
                    if binding.sessionID.isEmpty {
                        // A creation placeholder has row identity, but no session
                        // identity yet. Never deduplicate separate pending creates.
                        if placeholderIDs.insert(row.id).inserted { total.counts[.unknown, default: 0] += 1 }
                        entirelyExited = false
                    } else {
                        let id = RemoteSessionIdentity.uuid(provider: binding.provider, sessionID: binding.sessionID)
                        bindings[id] = .some(mirror[id])
                        if row.status != .active || state(mirror[id]) != .exited { entirelyExited = false }
                    }
                } else {
                    entirelyExited = false
                }
                for child in children[row.id] ?? [] { stack.append((child, depth + 1)) }
            }
            allIDs.formUnion(visited)
            let rowAttention = visited.compactMap { worktreeUnread[$0]?.type }
                .filter { $0 != .responseComplete && $0 != .taskComplete }.max { $0.severity < $1.severity }
            total.attention = [total.attention, rowAttention].compactMap { $0 }.max { $0.severity < $1.severity }
            if entirelyExited {
                exited.append(root)
                endedIDs.formUnion(visited)
                ended.attention = [ended.attention, rowAttention].compactMap { $0 }.max { $0.severity < $1.severity }
            } else {
                active.append(root)
            }
            for (id, session) in bindings {
                if allSessionIDs.insert(id).inserted { add(id, session: session, to: &total) }
                if entirelyExited, endedSessionIDs.insert(id).inserted { add(id, session: session, to: &ended) }
            }
        }
        for session in remainder where !session.dismissed && !session.payload.isArchived {
            guard allSessionIDs.insert(session.id).inserted else { continue }
            add(session.id, session: session, to: &total)
            if state(session) == .exited {
                endedSessions.append(session)
                endedSessionIDs.insert(session.id)
                add(session.id, session: session, to: &ended)
            } else {
                activeSessions.append(session)
            }
        }
        localRoots = local; remoteRoots = active; exitedRoots = exited
        sessions = activeSessions; exitedSessions = endedSessions
        summary = total; exitedSummary = ended
        remoteWorktreeIDs = allIDs; exitedWorktreeIDs = endedIDs
        sessionIDs = allSessionIDs; exitedSessionIDs = endedSessionIDs
    }

    func revealGroups(owner: SidebarGroupID.Owner, worktreeIDs: Set<UUID>, remoteID: UUID?) -> Set<SidebarGroupID> {
        let selectsRemote = !remoteWorktreeIDs.isDisjoint(with: worktreeIDs)
            || remoteID.map(sessionIDs.contains) == true
        guard selectsRemote else { return [] }
        var result: Set<SidebarGroupID> = [.init(owner: owner, kind: .remote)]
        if !exitedWorktreeIDs.isDisjoint(with: worktreeIDs) || remoteID.map(exitedSessionIDs.contains) == true {
            result.insert(.init(owner: owner, kind: .exited))
        }
        return result
    }
}

enum SidebarSubsetOrder {
    /// Reorder the displayed subset in its original slots; reject stale identities.
    static func moved(all: [UUID], visible: [UUID], source: IndexSet, destination: Int) -> [UUID]? {
        let visibleSet = Set(visible)
        guard Set(all).count == all.count, visibleSet.count == visible.count,
              !visible.isEmpty, !source.isEmpty, destination >= 0, destination <= visible.count,
              source.allSatisfy({ $0 >= 0 && $0 < visible.count }),
              all.filter(visibleSet.contains) == visible else { return nil }
        let moved = source.map { visible[$0] }
        var reordered = visible.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertion = destination - source.filter { $0 < destination }.count
        reordered.insert(contentsOf: moved, at: insertion)
        var index = 0
        return all.map { id in
            guard visibleSet.contains(id) else { return id }
            defer { index += 1 }
            return reordered[index]
        }
    }
}
