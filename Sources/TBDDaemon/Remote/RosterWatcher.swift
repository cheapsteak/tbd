import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "peerRoster")

// MARK: - What TBD knows about the sessions it spawned

/// One local Claude session **TBD itself spawned**, as TBD's own durable
/// bookkeeping describes it.
///
/// This is the half of the admission test that does not come from the registry.
/// It has to be: a shadow peer's record carries no field Claude Code does not
/// define (measured — one unknown key makes a record invisible to every
/// listing), and the same is true in reverse. TBD cannot mark the records of
/// the sessions it spawns, so "TBD spawned this" is never readable from a
/// record alone; it is a **join** between a record and this.
public struct TBDSpawnedSession: Sendable, Equatable {
    /// The worktree the session runs in.
    public let worktreeID: UUID
    /// The repository that worktree belongs to. This is the scoping key: a
    /// local session is announced to a link only when the remote session behind
    /// that link resolves to the same repository.
    public let repoID: UUID
    /// The terminal row TBD spawned the session into.
    public let terminalID: UUID
    /// The worktree's display name — the human-visible name in the sidebar,
    /// which is also the `--name` TBD spawned the session with.
    public let displayName: String
    /// The worktree directory on this machine. Joined against the record's
    /// `cwd`.
    public let worktreePath: String
    /// The tmux pane the session runs in, TBD's own documented join key —
    /// `%3541`. Joined against the pane component of the record's `tmux`.
    public let tmuxPaneID: String
    /// The Claude session id TBD captured for this terminal through the
    /// `SessionStart` hook, when one was captured. Joined against the record's
    /// `sessionId`, and the stronger of the two joins when present.
    public let claudeSessionID: String?

    public init(
        worktreeID: UUID,
        repoID: UUID,
        terminalID: UUID,
        displayName: String,
        worktreePath: String,
        tmuxPaneID: String,
        claudeSessionID: String?
    ) {
        self.worktreeID = worktreeID
        self.repoID = repoID
        self.terminalID = terminalID
        self.displayName = displayName
        self.worktreePath = worktreePath
        self.tmuxPaneID = tmuxPaneID
        self.claudeSessionID = claudeSessionID
    }
}

/// TBD's own bookkeeping about the local sessions it spawned, read fresh on
/// every roster scan.
///
/// A protocol rather than a direct store dependency because the roster's
/// admission rule is the interesting thing to test, and testing it against a
/// database would test GRDB instead.
public protocol LocalSessionDirectory: Sendable {
    /// Every live TBD-spawned Claude session, right now. Never throws: a
    /// bookkeeping read that fails yields an empty roster, which announces
    /// nothing, which is the safe direction for a trust boundary.
    func spawnedSessions() async -> [TBDSpawnedSession]
}

/// The production `LocalSessionDirectory`: TBD's own terminal and worktree
/// rows.
///
/// Only Claude terminals in **local, non-archived** worktrees that belong to a
/// repository. A scratch worktree has no `repoID`, so it has no repository to
/// scope an announcement by and is never announced — same rule the design
/// applies on the far side, where a remote session that resolves to no
/// registered repository is never bridged.
public struct DatabaseLocalSessionDirectory: LocalSessionDirectory {
    private let worktrees: WorktreeStore
    private let terminals: TerminalStore

    public init(worktrees: WorktreeStore, terminals: TerminalStore) {
        self.worktrees = worktrees
        self.terminals = terminals
    }

    public func spawnedSessions() async -> [TBDSpawnedSession] {
        do {
            let allWorktrees = try await worktrees.list()
            let allTerminals = try await terminals.list()
            let byID = Dictionary(
                allWorktrees.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return allTerminals.compactMap { terminal -> TBDSpawnedSession? in
                guard terminal.kind == .claude else { return nil }
                guard let worktree = byID[terminal.worktreeID] else { return nil }
                guard worktree.location.isLocal else { return nil }
                guard worktree.status == .active || worktree.status == .main else { return nil }
                guard let repoID = worktree.repoID else { return nil }
                return TBDSpawnedSession(
                    worktreeID: worktree.id,
                    repoID: repoID,
                    terminalID: terminal.id,
                    displayName: worktree.displayName,
                    worktreePath: worktree.localPath,
                    tmuxPaneID: terminal.tmuxPaneID,
                    claudeSessionID: terminal.claudeSessionID)
            }
        } catch {
            logger.error(
                "roster: could not read TBD's own session bookkeeping: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}

// MARK: - Reading Claude Code's registry

/// One row of Claude Code's peer registry, as read from disk.
///
/// **Every field is optional, and that is the contract rather than laziness.**
/// The census in `docs/research/2026-08-29-cross-machine-messaging/findings.md`
/// (84 live records) found only twelve keys on every record; `status` and
/// `version` are on 83, `tmux` on 80, `pidDomain` on 63, `nameSource` on 24. A
/// reader that made any of those required would silently drop real sessions —
/// four of the 84 carry no `tmux` at all. Absence is normal here, so it is
/// modelled as absence rather than as a decoding failure.
///
/// Unknown keys are ignored, which is the mirror of the rule on the write side:
/// this type is a **reader** of somebody else's format and must not break when
/// that format grows a field.
///
/// The `pid` key is deliberately not read. Claude Code's own loader parses the
/// pid out of the record's **filename** and rejects a filename that does not
/// round-trip as an integer, so the filename is the authority; a `pid` field
/// disagreeing with it describes a record Claude Code would file under the
/// filename's pid anyway.
public struct LocalPeerRegistryRecord: Sendable, Equatable, Decodable {
    public let sessionID: String?
    public let cwd: String?
    public let messagingSocketPath: String?
    public let peerProtocol: Int?
    public let name: String?
    public let status: String?
    /// `"<session>:<window>.<pane>"`, e.g. `main:@3541.%3541`. Note that the
    /// first component is the tmux *session* name, not the server socket: every
    /// TBD repo server has a session called `main`, and so does a user's own
    /// default server. The pane alone is therefore not a machine-wide unique
    /// key, which is why the pane join below is paired with a `cwd` match.
    public let tmux: String?
    public let procStart: String?
    public let version: String?
    public let kind: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case cwd
        case messagingSocketPath
        case peerProtocol
        case name
        case status
        case tmux
        case procStart
        case version
        case kind
    }

    /// The pane component of `tmux`, normalised to include its `%`.
    ///
    /// Nil when the record carries no tmux coordinates — a plain-terminal
    /// `claude`, a `cloud` row, or one of the four records in the census that
    /// simply had none — and nil again when the value is not shaped like a pane
    /// id. A field that has changed shape must read as "no pane", never as a
    /// pane nothing can match: the first is a session that stays local, the
    /// second is a join that quietly stops working.
    public var tmuxPaneID: String? {
        guard let tmux, let pane = tmux.split(separator: ".").last, !pane.isEmpty else {
            return nil
        }
        let normalized = RosterJoinKeys.normalizedPaneID(String(pane))
        let digits = normalized.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return normalized
    }

    /// The status to announce for a record that carries none.
    ///
    /// The wire's `status` is required and is written verbatim into a record on
    /// the far side, so something has to be sent. This word is deliberately
    /// **not** one of Claude Code's own (`idle` / `busy` / `waiting` / `shell`):
    /// a value outside that vocabulary reads as "nobody said", where an
    /// invented `idle` would read as a fact and would be wrong exactly when a
    /// session is busy.
    public static let unknownStatus = "unknown"
}

// MARK: - The roster

/// One local session the roster admits, with everything an announcement needs.
///
/// **No handle.** A handle names one session *on one link* and means nothing
/// outside it, so it is not a property of the session — it is minted per link
/// by that link's `LocalPeerHandleRegistry` at the moment of announcement. A
/// roster-wide handle would be a second, disagreeing table beside the one that
/// resolves inbound frames, and every message addressed to a local session
/// would resolve to nothing.
public struct RosterEntry: Sendable, Equatable {
    /// `<origin>:<display name> %<pane>`. The pane discriminator is *always*
    /// present, never added on collision: several Claude terminals in one
    /// worktree all carry the worktree display name, and a name that changes
    /// when some other session appears is worse than one that occasionally
    /// needs a ref.
    public let name: String
    /// Verbatim from the registry row, or `unknownStatus` when the row carried
    /// none.
    public let status: String
    /// The peer protocol this session speaks, sourced from its own registry row
    /// rather than asserted.
    public let peerProtocol: Int
    /// The repository this session's worktree belongs to — the scoping key.
    public let repoID: UUID
    public let worktreeID: UUID
    public let terminalID: UUID
    /// The pid the record is filed under.
    public let pid: pid_t
    /// The socket this session listens on.
    ///
    /// **Internal, and it stays internal.** This is the value a handle exists
    /// to keep off the wire: a wire that carried paths would let the far side
    /// name any socket in `/tmp/cc-socks`, including a personal non-TBD session
    /// or one on a profile logged into a different Anthropic account. It goes
    /// to a `LocalPeerHandleRegistry`, which keeps it, and nowhere else.
    let socketPath: String

    /// The `peer` line this entry announces on a link that minted `handle` for
    /// it. Complete and idempotent — never a partial diff — which is what makes
    /// re-announcing a changed session the same operation as announcing a new
    /// one.
    public func peerLine(handle: String) -> PeerBridgePeer {
        PeerBridgePeer(
            handle: handle, name: name, status: status, peerProtocol: peerProtocol)
    }
}

// MARK: - Handles

/// Mints the handles one link uses for local sessions, and keeps the
/// handle-to-socket table privately.
///
/// The roster does not own this. Inbound frames are delivered by looking a
/// handle up in the table that minted it, so the minting and the resolving have
/// to be the same table or every inbound frame resolves to nothing —
/// `ShadowPeerManager` owns both for a real link, and this protocol is the
/// shape it already has (`registerLocalPeer(socketPath:name:)` /
/// `withdrawLocalPeer(socketPath:)`).
///
/// **`handle(forLocalPeerAt:name:)` must be idempotent on the socket path.** A
/// `peer` line is a complete statement re-sent whenever anything about a
/// session changes, and a handle that churned on a status change would strand
/// every peer that had already been told about it.
public protocol LocalPeerHandleRegistry: Sendable {
    func handle(forLocalPeerAt socketPath: String, name: String) async -> String
    /// Forget one local session, returning the handle it held (nil when it was
    /// never registered).
    func withdrawLocalPeer(at socketPath: String) async -> String?
}

/// The default registry: the roster mints and remembers its own handles.
///
/// Used when a link has no `ShadowPeerManager` behind it — in tests, and in any
/// wiring where the roster is the only party that needs to resolve a handle.
/// Deliberately not a fallback the production path can reach by accident: a
/// registration names its registry.
public actor MemoizingLocalPeerHandleRegistry: LocalPeerHandleRegistry {
    private var handlesBySocket: [String: String] = [:]
    private var socketsByHandle: [String: String] = [:]
    private let mint: @Sendable () -> String

    public init(mint: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.mint = mint
    }

    public func handle(forLocalPeerAt socketPath: String, name: String) async -> String {
        if let existing = handlesBySocket[socketPath] { return existing }
        let handle = mint()
        handlesBySocket[socketPath] = handle
        socketsByHandle[handle] = socketPath
        return handle
    }

    public func withdrawLocalPeer(at socketPath: String) async -> String? {
        guard let handle = handlesBySocket.removeValue(forKey: socketPath) else { return nil }
        socketsByHandle[handle] = nil
        return handle
    }

    /// The socket behind a handle, or nil when the handle names nothing this
    /// registry minted. A handle outside the table resolves to nothing, which
    /// is the property that makes the table a boundary rather than a lookup.
    public func socketPath(forHandle handle: String) -> String? {
        socketsByHandle[handle]
    }
}

/// One peer link the roster announces on.
///
/// `repoID` is non-optional on purpose: it is the *remote* session's repository,
/// and a remote session that resolves to no registered repository has no
/// worktree row under the existing contract and is therefore never bridged. A
/// link that cannot name a repository cannot be registered, which is the
/// scoping rule expressed in the type rather than in a comment.
public struct RosterLinkRegistration: Sendable {
    public let id: UUID
    public let repoID: UUID
    /// The protocol this link negotiated in its `hello` exchange. A local
    /// session speaking a different one is not announced on this link: the far
    /// side would publish a shadow it could not talk to.
    public let peerProtocol: Int
    /// Who mints this link's handles for local sessions — `ShadowPeerManager`
    /// in production, since it is also what resolves them on the way back in.
    public let handles: any LocalPeerHandleRegistry
    /// Where a frame goes. The link owns the stream; the roster only writes
    /// `peer` and `peer-gone` lines into it.
    public let send: @Sendable (PeerBridgeFrame) async -> Void

    public init(
        id: UUID,
        repoID: UUID,
        peerProtocol: Int,
        handles: any LocalPeerHandleRegistry = MemoizingLocalPeerHandleRegistry(),
        send: @escaping @Sendable (PeerBridgeFrame) async -> Void
    ) {
        self.id = id
        self.repoID = repoID
        self.peerProtocol = peerProtocol
        self.handles = handles
        self.send = send
    }
}

/// Why a link is being dropped, which decides whether the far side is told.
///
/// The two cases are not a preference. A link the roster stops announcing on
/// while its **stream stays open** is a scope change on this side, and silence
/// there leaves the far host holding shadows for sessions it may no longer
/// reach — a remote lane in one project able to message local sessions in
/// another, which is exactly what the design's Trust section forbids. Silence
/// is correct only when the stream itself is over, because the contract then
/// obliges the far side to unlink everything it published for it.
public enum RosterLinkRemoval: Sendable, Equatable {
    /// The stream is over — the bridge is stopping, or the connection ended.
    /// No `peer-gone` is written and no handle is withdrawn: nothing can be
    /// delivered into a closed stream, and the far side unlinks every shadow it
    /// published for it.
    case streamEnded
    /// The stream is alive and keeps carrying traffic; this registration's
    /// repository simply left the provider's scope. Every session announced
    /// under it is withdrawn from the handle registry and announced gone.
    case stillOpen
}

/// What one scan of the registry saw.
///
/// **A partial roster is a correct roster of what TBD can see, and is reported
/// rather than treated as an error.** TBD makes the registry whole across
/// profiles by symlinking each profile's `sessions` into the host directory,
/// and that unification is best-effort: a profile whose seeding failed keeps a
/// private registry, so its sessions are simply absent here — invisibly, since
/// nothing in this directory records that another one exists. The counts below
/// are what makes the visible half of that answerable.
public struct RosterScanReport: Sendable, Equatable {
    /// Files in the directory whose name parsed as `<pid>.json`.
    public var recordsSeen = 0
    /// Records admitted to the roster.
    public var admitted = 0
    /// Records that would not decode, or whose bytes could not be read. Skipped
    /// one at a time: a single torn or hand-edited file must not take the
    /// roster down with it.
    public var skippedMalformed = 0
    /// Records that decoded but were missing something the roster cannot
    /// proceed without — a socket path, a peer protocol, or the process start
    /// time admission checks the pid against.
    public var skippedIncomplete = 0
    /// Records for sessions TBD did not spawn: a plain-terminal `claude`, a
    /// session on a profile TBD does not manage, or any other user of this
    /// shared directory. Never announced.
    public var skippedNotTBDSpawned = 0
    /// Records whose pid is dead, or alive with a different start time than the
    /// record claims — the recycled-pid ghost Claude Code's reaper provably
    /// will not collect, because it checks pid liveness and nothing else.
    public var skippedNotLive = 0
    /// True when the registry directory could not be listed at all. Not an
    /// error: on a machine where no session has ever run, it does not exist.
    public var directoryUnreadable = false

    public init() {}

    /// Whether this scan saw anything worth saying out loud.
    public var isDegraded: Bool {
        directoryUnreadable || skippedMalformed > 0 || skippedIncomplete > 0
    }
}

// MARK: - The watcher

/// Watches the host peer registry and produces the roster TBD announces
/// outward — the owner of this design's outbound half
/// (`docs/specs/2026-08-29-remote-peer-messaging-design.md`, "The local
/// roster").
///
/// ## Where the directory comes from
///
/// The registry directory is **always injected**. There is deliberately no
/// initializer that resolves one, and no static helper that builds a path out
/// of `$HOME`: production wiring passes
/// `ShadowPeerRecordStore(environment:).sessionsDirectory`, which is the single
/// resolution point for `TBD_CLAUDE_HOST_HOME` and delegates to
/// `TBDConstants.claudeHostHome(environment:)`. The consequence is the property
/// that matters for a type whose whole job is reading `~/.claude`: it is not
/// possible to construct a `RosterWatcher` that reads the developer's real
/// registry without naming that directory at the call site.
///
/// ## Polling, not watching
///
/// The registry is polled on an injected clock. Four reasons, in order of
/// weight:
///
/// 1. **A directory watcher cannot see a status change.** A `status` change is
///    a rewrite of an existing record's *contents*; a `DispatchSource` vnode
///    watch on the directory fires on entries appearing and vanishing. If
///    Claude Code rewrites a record in place — and nothing here can promise it
///    rewrites by rename — a watcher misses one of the three events the design
///    requires this subsystem to emit.
/// 2. **Half the roster's inputs are not files at all.** Admission and naming
///    join every record against TBD's own worktree and terminal rows, which
///    change with no filesystem event in this directory: renaming a worktree
///    changes the announced name of every session in it. The roster has to be
///    recomputed on a cadence regardless, so a watcher would optimise one of
///    two inputs and still leave the tick in place.
/// 3. **There is no daemon-side file watcher to reuse.** The one `FileWatcher`
///    in the tree is in `TBDApp`, which the daemon does not link; it is
///    single-*file*, holds an fd per watched path, and re-opens itself after
///    every atomic save. Per-record watching would mean dozens of fds
///    continuously re-armed by other people's renames. `SupervisionStore`
///    rejected a watcher for a daemon-side file store on the same grounds and
///    `BranchTrackingCache` records that no daemon-side watcher exists.
/// 4. **A scan is cheap.** One `readdir` and one small-JSON decode per entry,
///    over a directory that held 84 records on a heavily-used machine. There
///    is deliberately no mtime cache in front of the decode: it would buy a
///    fraction of a millisecond and cost a second copy of the roster's state
///    to keep correct.
///
/// The default interval is two seconds. It is not the design's stated honesty
/// knob — that is the link's 10s/30s ping and silence limit — but it bounds the
/// same failure from the other side: an announced peer that has exited is a
/// session lying about being reachable, and roster staleness should stay an
/// order of magnitude under the link's own liveness bound.
public actor RosterWatcher {
    private struct LinkState {
        let registration: RosterLinkRegistration
        /// What this link was last told, by the handle its own registry minted.
        /// The roster diffs against this rather than against the previous scan,
        /// so a link registered mid-flight is announced the whole roster and a
        /// link that has seen everything is sent nothing.
        var announced: [String: PeerBridgePeer] = [:]
        /// The socket behind each announced handle, so a session that goes away
        /// can be withdrawn from the registry that minted its handle. The
        /// roster keeps this only long enough to hand it back.
        var socketsByHandle: [String: String] = [:]
    }

    private let sessionsDirectory: URL
    private let sessions: any LocalSessionDirectory
    private let origin: String
    private let interval: Duration
    private let procStartForPID: @Sendable (pid_t) -> String?
    private let clock: any Clock<Duration>

    private var links: [UUID: LinkState] = [:]
    /// Every session the last scan admitted, by socket path — the roster
    /// itself, before any link scopes it.
    private var entries: [String: RosterEntry] = [:]
    private var lastReport = RosterScanReport()
    /// The pass every new `refresh()` queues behind. See `refresh()`.
    private var refreshChain: Task<RosterScanReport, Never>?
    /// Tickets, so the caller nobody queued behind can tell that it is the last
    /// one and release the chain. A `Task` has no identity to compare.
    private var nextRefreshTicket = 0
    private var lastQueuedRefresh = -1

    /// - Parameters:
    ///   - sessionsDirectory: the host registry — `~/.claude/sessions` in
    ///     production, resolved by the caller through
    ///     `ShadowPeerRecordStore(environment:)`.
    ///   - sessions: TBD's own bookkeeping about the sessions it spawned.
    ///   - origin: the origin label TBD declares in `hello`, and the namespace
    ///     every announced name is prefixed with.
    ///   - procStartForPID: liveness. Returns the kernel's start time for a
    ///     live pid and nil for a dead one, which is both halves of the
    ///     recycled-pid check in one call.
    public init(
        sessionsDirectory: URL,
        sessions: any LocalSessionDirectory,
        origin: String,
        interval: Duration = .seconds(2),
        procStartForPID: @escaping @Sendable (pid_t) -> String? = {
            ProcessStartTime.procStart(pid: $0)
        },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.sessions = sessions
        self.origin = origin
        self.interval = interval
        self.procStartForPID = procStartForPID
        self.clock = clock
    }

    // MARK: Links

    /// Register a link and announce the whole roster on it.
    ///
    /// Announcing from scratch is the design's resync rule, not a convenience:
    /// the far side unlinks every shadow when a stream ends, so a fresh `hello`
    /// re-announces the roster the way `events` resyncs with a snapshot rather
    /// than a cursor. A session that exited while the link was down therefore
    /// needs no catch-up.
    public func addLink(_ registration: RosterLinkRegistration) async {
        links[registration.id] = LinkState(registration: registration)
        await refresh()
    }

    /// Drop a link, telling the far side or not according to why.
    ///
    /// The default is silence, and it is only correct for the reason
    /// `.streamEnded` names. See `RosterLinkRemoval`.
    public func removeLink(id: UUID, because removal: RosterLinkRemoval = .streamEnded) async {
        guard let state = links.removeValue(forKey: id) else { return }
        guard case .stillOpen = removal else { return }

        // Withdraw first, announce second — the order `announce` uses, and for
        // the same reason. Withdrawing is what closes the hole: a handle that
        // is no longer in the table that minted it resolves to nothing, so an
        // inbound frame still addressed to it is dropped rather than delivered
        // to a session this link may no longer reach. The `peer-gone` that
        // follows is what stops the far side addressing it at all.
        //
        // Withdrawing every socket this link announced is safe because a
        // session belongs to exactly one repository and a bridge registers one
        // link per repository, so no other registration sharing this handle
        // registry can be announcing the same socket. A second *provider*
        // announcing the same session holds its own registry and is untouched.
        for socketPath in Set(state.socketsByHandle.values).sorted() {
            _ = await state.registration.handles.withdrawLocalPeer(at: socketPath)
        }
        let gone = state.announced.keys.sorted()
        for handle in gone {
            await state.registration.send(.peerGone(handle: handle))
        }
        logger.info("""
            roster: link \(id.uuidString, privacy: .public) for repo \
            \(state.registration.repoID.uuidString, privacy: .public) left this provider's \
            scope; withdrew \(gone.count, privacy: .public) announced session(s)
            """)
    }

    /// Forget everything a link has been told, so the next scan announces the
    /// whole roster on it again from scratch.
    ///
    /// **The roster's half of a reconnect.** `ShadowPeerManager` empties both
    /// halves of its handle table on `linkStateChanged(to: .down)` — a handle
    /// names one session for the life of one connection and means nothing
    /// outside it — and the roster's memory of what that link was told has to
    /// go with it. Left behind, it describes handles the registry no longer
    /// holds: the next scan mints a fresh handle for the same session and
    /// announces it, while the withdraw loop still sees the stale one and would
    /// (before the invariant in `announce`) tear the fresh binding straight
    /// back out.
    ///
    /// Nothing is withdrawn from the handle registry here and no `peer-gone` is
    /// written. The registry that minted those handles has already dropped
    /// them, and the far side unlinks every shadow it published the moment the
    /// stream ends — there is nobody left to tell.
    public func resetAnnouncements(linkID: UUID) {
        guard var state = links[linkID], !state.announced.isEmpty || !state.socketsByHandle.isEmpty
        else { return }
        state.announced.removeAll()
        state.socketsByHandle.removeAll()
        links[linkID] = state
        logger.debug(
            "roster: forgot what link \(linkID.uuidString, privacy: .public) was told; the next scan re-announces from scratch")
    }

    // MARK: Reads

    /// Every session the roster currently admits, for `tbd peer list`. Not
    /// what any one link was told — that is scoped, and two links are told
    /// different subsets under different handles.
    public func currentEntries() -> [RosterEntry] {
        entries.values.sorted { $0.name < $1.name }
    }

    /// What the last scan saw — including what it could not see.
    public func lastScanReport() -> RosterScanReport {
        lastReport
    }

    // MARK: The tick

    /// Scan, diff, announce. Runs until cancelled.
    public func run() async {
        while !Task.isCancelled {
            await refresh()
            do {
                try await clock.sleep(for: interval)
            } catch {
                return  // cancelled
            }
        }
    }

    /// One scan of the registry, and the announcements it implies.
    ///
    /// **Serialized, and it has to be.** This is public, it is called from the
    /// tick *and* from `addLink`, and it suspends twice over state it then
    /// overwrites — at `sessions.spawnedSessions()` and at every handle mint
    /// inside `announce`. An actor is re-entrant at each of those, so two
    /// unserialized passes interleave: the older one resumes holding a snapshot
    /// taken before the newer one ran, overwrites `entries` with it, and
    /// re-announces sessions the newer pass had just withdrawn. It self-corrects
    /// on the following tick, which is precisely what makes it hard to see —
    /// what it leaves behind is a wire and a `tbd peer list` that flap.
    ///
    /// Each call queues behind the pass already running rather than joining it:
    /// a caller that has just registered a link, or just changed the roster's
    /// inputs, needs a scan that *began* after its call, and a coalesced pass
    /// that started earlier cannot promise that.
    @discardableResult
    public func refresh() async -> RosterScanReport {
        let previous = refreshChain
        let ticket = nextRefreshTicket
        nextRefreshTicket &+= 1
        let pass = Task { [self] in
            // Suspends off the actor, so the pass ahead can finish.
            _ = await previous?.value
            return await self.scanAndAnnounce()
        }
        refreshChain = pass
        lastQueuedRefresh = ticket
        let report = await pass.value
        // Only the caller nobody queued behind clears the chain; anyone who
        // arrived while this pass ran is still waiting on it.
        if lastQueuedRefresh == ticket { refreshChain = nil }
        return report
    }

    /// The scan itself. Private, so the serialization above is the only way in.
    private func scanAndAnnounce() async -> RosterScanReport {
        var report = RosterScanReport()
        let records = loadRecords(report: &report)
        let spawned = await sessions.spawnedSessions()

        var current: [String: RosterEntry] = [:]
        for (pid, record) in records {
            guard let entry = admit(pid: pid, record: record, spawned: spawned, report: &report)
            else { continue }
            current[entry.socketPath] = entry
            report.admitted += 1
        }
        entries = current

        await announce(current)

        lastReport = report
        if report.isDegraded {
            logger.info(
                """
                roster: \(report.admitted, privacy: .public) announced of \
                \(report.recordsSeen, privacy: .public) records \
                (malformed \(report.skippedMalformed, privacy: .public), \
                incomplete \(report.skippedIncomplete, privacy: .public), \
                not TBD \(report.skippedNotTBDSpawned, privacy: .public), \
                not live \(report.skippedNotLive, privacy: .public), \
                directory unreadable \(report.directoryUnreadable, privacy: .public)) — \
                a partial roster is a correct roster of what TBD can see
                """)
        } else {
            logger.debug(
                "roster: \(report.admitted, privacy: .public) announced of \(report.recordsSeen, privacy: .public) records")
        }
        return report
    }

    // MARK: Announcement

    /// Diff the roster against what each link was last told, scoped twice: by
    /// repository, and by the protocol the link negotiated.
    ///
    /// Handles come from the link's own registry, one `await` per admitted
    /// session, and they are resolved *before* the link's announcement state is
    /// touched. An actor suspends at an `await` and can be re-entered there, so
    /// the link row is re-read after those suspensions and every mutation of it
    /// happens in one uninterrupted stretch; the frames themselves go out
    /// afterwards.
    private func announce(_ current: [String: RosterEntry]) async {
        for linkID in Array(links.keys) {
            guard let registration = links[linkID]?.registration else { continue }
            let scoped = current.values.filter { entry in
                entry.repoID == registration.repoID
                    && entry.peerProtocol == registration.peerProtocol
            }

            // The handle is this link's name for the session, minted by the
            // same table that will resolve it when a frame comes back.
            var lines: [String: PeerBridgePeer] = [:]
            var socketsByHandle: [String: String] = [:]
            for entry in scoped.sorted(by: { $0.name < $1.name }) {
                let handle = await registration.handles.handle(
                    forLocalPeerAt: entry.socketPath, name: entry.name)
                lines[handle] = entry.peerLine(handle: handle)
                socketsByHandle[handle] = entry.socketPath
            }

            guard var state = links[linkID] else {
                // **The link was retired while this pass was minting for it.**
                // `removeLink` runs at any of the suspensions above — an actor
                // is re-entrant at every `await` — and it withdraws the sockets
                // the link's *previous* state remembered. A session admitted
                // for the first time in this pass is in neither set: the link
                // had never been told about it, and the loop above has just
                // minted a handle for it. Left here it would sit in the table
                // that minted it with nothing that will ever withdraw it.
                //
                // Not a trust hole — handles are random rather than derived
                // from the socket, so a handle that reached no wire is one the
                // far side cannot address — but the table is the daemon's for
                // its whole life, so it is a per-retirement leak that only
                // grows.
                //
                // Withdrawing here is safe by `removeLink`'s own argument: a
                // session belongs to exactly one repository and a bridge
                // registers one link per repository, so no other registration
                // sharing this handle registry can be announcing these
                // sockets. `refresh()` serializes passes, so no *other* pass
                // can have bound them either.
                for socketPath in Set(socketsByHandle.values).sorted() {
                    _ = await registration.handles.withdrawLocalPeer(at: socketPath)
                }
                continue
            }
            // Withdrawals and announcements are accumulated apart because they
            // go on the wire in that order, whatever order they are computed
            // in. See the send loop below.
            var goneFrames: [PeerBridgeFrame] = []
            var peerFrames: [PeerBridgeFrame] = []
            var withdrawn: [String] = []
            // Every socket this pass just resolved a handle for. **Nothing in
            // here may be withdrawn, whatever `state` remembers.**
            //
            // The withdraw loop below walks handles, and a handle is not a
            // session: the registry can hand a *different* handle back for the
            // same socket, and does exactly that whenever its table was
            // emptied under the roster — which is what `ShadowPeerManager`
            // does on every link-down. The stale handle then has no line this
            // pass, so it is announced gone and its socket queued for
            // withdrawal — the same socket a handle minted moments earlier in
            // this very pass is bound to. Withdrawing it deletes the fresh
            // binding, so the next tick mints another, announces it, and
            // deletes it again: a self-sustaining churn that leaves the far
            // side holding a handle the registry cannot resolve, which drops
            // every frame in both directions while the link reports `up`.
            //
            // `resetAnnouncements(linkID:)` removes the specific trigger. This
            // is the invariant, and it holds however the divergence arose.
            let boundSockets = Set(socketsByHandle.values)

            for (handle, line) in lines.sorted(by: { $0.value.name < $1.value.name })
            where state.announced[handle] != line {
                state.announced[handle] = line
                peerFrames.append(.peer(line))
            }
            for handle in state.announced.keys.sorted() where lines[handle] == nil {
                state.announced[handle] = nil
                goneFrames.append(.peerGone(handle: handle))
                if let socketPath = state.socketsByHandle[handle],
                   !boundSockets.contains(socketPath) {
                    withdrawn.append(socketPath)
                }
                state.socketsByHandle[handle] = nil
            }
            state.socketsByHandle.merge(socketsByHandle) { _, new in new }
            links[linkID] = state

            for socketPath in withdrawn {
                _ = await registration.handles.withdrawLocalPeer(at: socketPath)
            }
            // **Withdrawals go out before announcements, never the other way.**
            // A re-mint announces one session under a new handle while the old
            // handle for that same session is being announced gone, and the
            // name on both lines is the same name. A far side that saw the
            // `peer` first would be holding two peers under one name for as
            // long as the pair took to arrive — which
            // `docs/remote-provider-contract.md` forbids it to do ("never
            // publish two peers under one name"), a collision there being a
            // misdelivery rather than a display glitch. Withdrawal first makes
            // the overlap unrepresentable on the wire instead of merely
            // short-lived.
            for frame in goneFrames + peerFrames {
                // The link can be retired mid-send, and `removeLink` writes
                // `peer-gone` for everything this pass just recorded as
                // announced. Anything written after that would leave the far
                // side holding a handle that has already been withdrawn from
                // the table which resolves it — a ghost until the stream ends.
                guard links[linkID] != nil else { break }
                await registration.send(frame)
            }
        }
    }

    // MARK: Admission

    /// Admit one record, or account for why not.
    ///
    /// **Only TBD-spawned sessions, and the test is a join** — never a marker
    /// inside the record, which is impossible (an unknown key makes a record
    /// invisible), and never a guess from a path. Two joins, both exact
    /// equality against facts TBD itself wrote:
    ///
    /// - the record's `sessionId` against the Claude session id TBD captured
    ///   for a terminal through its `SessionStart` hook, or
    /// - the record's `cwd` against a worktree directory **and** the pane
    ///   component of its `tmux` against that worktree's terminal pane.
    ///
    /// Either is sufficient; the session-id join is preferred when both are
    /// available. The pane join is paired with `cwd` rather than used alone
    /// because a pane id is unique per tmux *server*, and TBD runs one server
    /// per repository alongside whatever servers the user runs themselves.
    ///
    /// Both joins fail closed. A TBD session whose hook never fired and whose
    /// worktree row has moved on is not announced — it stays local, which is
    /// the harmless direction.
    ///
    /// **So does the liveness check, and it requires the record's own
    /// `procStart`.** A record that carries no start time is not admitted at
    /// all, rather than admitted on pid liveness alone: the pid being alive is
    /// exactly what a recycled-pid ghost also looks like, and with no claim to
    /// compare against there is nothing left that could tell the two apart.
    /// Admitting one would announce a real unix socket path outward on the
    /// strength of a number the kernel hands out again after every exit. The
    /// census in `docs/research/2026-08-29-cross-machine-messaging/findings.md`
    /// found `procStart` on 84 of 84 records, so refusing without it costs
    /// nothing a real registry produces.
    ///
    /// `ShadowPeerReconciler.occupancy(of:alive:currentStart:)` reads the same
    /// missing field the same way — as unverifiable identity — and stops for
    /// the same reason, though the action it declines is the opposite one:
    /// there, unverified identity means *do not reclaim*, because deleting a
    /// live peer's artifacts is irreversible; here it means *do not announce*,
    /// because publishing a local socket exposes it. When identity cannot be
    /// established, neither side takes the step it could not take back.
    private func admit(
        pid: pid_t,
        record: LocalPeerRegistryRecord,
        spawned: [TBDSpawnedSession],
        report: inout RosterScanReport
    ) -> RosterEntry? {
        guard let socketPath = record.messagingSocketPath, !socketPath.isEmpty,
              let peerProtocol = record.peerProtocol,
              let claimedProcStart = record.procStart
        else {
            report.skippedIncomplete += 1
            return nil
        }

        guard let session = match(record: record, against: spawned) else {
            report.skippedNotTBDSpawned += 1
            return nil
        }

        // Liveness, and the recycled-pid ghost in the same check: a dead pid
        // has no start time, and a live pid whose start time is not the one the
        // record claims is a different process wearing a dead session's row.
        // One comparison decides both, because a record with no claim never
        // reaches here — it was counted incomplete above.
        guard procStartForPID(pid) == claimedProcStart else {
            report.skippedNotLive += 1
            return nil
        }

        return RosterEntry(
            name: announcedName(for: session),
            status: record.status ?? LocalPeerRegistryRecord.unknownStatus,
            peerProtocol: peerProtocol,
            repoID: session.repoID,
            worktreeID: session.worktreeID,
            terminalID: session.terminalID,
            pid: pid,
            socketPath: socketPath)
    }

    private func match(
        record: LocalPeerRegistryRecord, against spawned: [TBDSpawnedSession]
    ) -> TBDSpawnedSession? {
        if let sessionID = record.sessionID, !sessionID.isEmpty,
           let bySession = spawned.first(where: { $0.claudeSessionID == sessionID }) {
            return bySession
        }
        guard let cwd = record.cwd, let pane = record.tmuxPaneID else { return nil }
        let normalizedCWD = RosterJoinKeys.normalizedPath(cwd)
        return spawned.first { session in
            RosterJoinKeys.normalizedPath(session.worktreePath) == normalizedCWD
                && RosterJoinKeys.normalizedPaneID(session.tmuxPaneID) == pane
        }
    }

    /// `<origin>:<display name> %<pane>`.
    ///
    /// The pane discriminator is always present, never added on collision:
    /// collisions are the norm rather than the exception here, since several
    /// Claude terminals in one worktree all carry the worktree display name,
    /// and a name that changes when some other session appears is worse than
    /// one that occasionally needs a ref. The pane is TBD's own documented join
    /// key, so a remote agent naming one names something `tbd terminal list`
    /// can resolve.
    private func announcedName(for session: TBDSpawnedSession) -> String {
        "\(origin):\(session.displayName) \(RosterJoinKeys.normalizedPaneID(session.tmuxPaneID))"
    }

    // MARK: Registry I/O

    /// Read every record in the directory. Never throws: an unreadable
    /// directory is an empty roster, and one unreadable record is one skipped
    /// record.
    private func loadRecords(report: inout RosterScanReport) -> [(pid_t, LocalPeerRegistryRecord)] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: sessionsDirectory, includingPropertiesForKeys: nil)
        } catch {
            report.directoryUnreadable = true
            return []
        }

        let decoder = JSONDecoder()
        var loaded: [(pid_t, LocalPeerRegistryRecord)] = []
        for url in contents {
            guard let pid = RosterJoinKeys.pid(fromRecordFilename: url.lastPathComponent) else {
                continue
            }
            report.recordsSeen += 1
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(LocalPeerRegistryRecord.self, from: data)
            else {
                report.skippedMalformed += 1
                continue
            }
            loaded.append((pid, record))
        }
        return loaded
    }
}

// MARK: - Join keys

/// The pure functions the roster joins on.
///
/// A caseless enum rather than statics on the actor, so that nothing — a test,
/// a decoder, a future caller — has to reason about the isolation of a static
/// member of an actor to use them.
enum RosterJoinKeys {
    /// The pid a record filename names, or nil when the file is not a record.
    ///
    /// The round-trip is Claude Code's own rule — its loader parses the pid
    /// from the filename and rejects one that does not round-trip as an integer
    /// — and it is what keeps the third per-peer artifact
    /// (`<pid>.<sha256(messagingSocketPath)>.key`, one per live peer) and
    /// `ShadowPeerRecordStore`'s `.<name>.<uuid>.tmp` write-temps out of the
    /// roster without needing a list of things to exclude.
    static func pid(fromRecordFilename filename: String) -> pid_t? {
        guard filename.hasSuffix(".json") else { return nil }
        let stem = String(filename.dropLast(".json".count))
        guard let value = pid_t(stem), String(value) == stem, value > 0 else { return nil }
        return value
    }

    /// A pane id with its `%`, whichever way it was written.
    static func normalizedPaneID(_ pane: String) -> String {
        pane.hasPrefix("%") ? pane : "%\(pane)"
    }

    /// Lexical path normalisation only — no symlink resolution, which would
    /// stat the filesystem once per record per tick to answer a question both
    /// sides of the comparison already agree on.
    static func normalizedPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized.count > 1, standardized.hasSuffix("/") else { return standardized }
        return String(standardized.dropLast())
    }
}
