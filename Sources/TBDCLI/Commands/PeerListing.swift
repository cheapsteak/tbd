import Foundation
import TBDShared

// Pure composition for `tbd peer list`: everything here takes facts already
// gathered — the registry directory as it was read, the worktree and terminal
// rows the daemon answered with — and returns the exact rows a human or a
// program sees. Nothing here touches the filesystem or a socket, so the
// interesting cases (a session that joins nothing, a daemon that is not
// running, a recycled-pid ghost) are asserted on the composed output rather
// than on an internal boolean.
//
// Design: docs/specs/2026-08-29-remote-peer-messaging-design.md
// § "Reclamation and detection" → "`tbd peer list`".

/// When a change to `remote_peer_messaging_enabled` actually takes hold.
///
/// One sentence in one place, because two commands say it: `tbd peer list`
/// names it when a provider that declares `messages` has no bridge, and
/// `tbd peer messaging` names it right after writing the flag. Two phrasings of
/// the same fact drift apart, and the one that drifts is the one a user reads
/// while wondering why nothing happened.
///
/// It is written for either direction on purpose. The gate is consulted where a
/// provider's poll loops are armed, so turning it on builds no bridge for a
/// provider already running, and turning it off leaves a running bridge up.
let peerMessagingRestartCaveat = """
    The gate is read when a provider's streams are armed, so a change made since \
    then takes effect at the next daemon restart.
    """

/// nil for nil, and nil for empty. An empty string in somebody else's record is
/// an absent value wearing a present one, and every read below wants the same
/// answer for both.
func nonEmptyPeerField(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

// MARK: - The registry as this command reads it

/// One row of Claude Code's peer registry, as `tbd peer list` reads it.
///
/// **Every field is optional, and that is the contract rather than laziness.**
/// The census in `docs/research/2026-08-29-cross-machine-messaging/findings.md`
/// (84 live records) found only twelve keys on every record: `status` and
/// `version` are on 83, `tmux` on 80, `pidDomain` on 63, `nameSource` on 24. A
/// reader that made any of those required would silently drop real sessions —
/// four of the 84 carry no `tmux` at all, and a shadow peer carries none by
/// construction. Absence is normal here, so it is modelled as absence rather
/// than as a decoding failure.
///
/// Unknown keys are ignored: this is a **reader** of somebody else's format and
/// must not break when that format grows a field.
///
/// The `pid` key is deliberately not read. Claude Code's own loader parses the
/// pid out of the record's **filename** and rejects a filename that does not
/// round-trip as an integer, so the filename is the authority.
///
/// This deliberately duplicates the daemon's `LocalPeerRegistryRecord` rather
/// than sharing it. `TBDCLI` links `TBDShared` and nothing else — it reaches
/// the daemon over a socket, never by linking it — and the daemon's reader
/// carries roster-admission concerns (announced names, handle minting) that
/// have no meaning here. Both are readers of the same third-party format, and
/// that format is documented in `findings.md`; a change to it has to reach both.
struct PeerRegistryRecord: Decodable, Equatable, Sendable {
    let sessionID: String?
    let cwd: String?
    let messagingSocketPath: String?
    let name: String?
    let status: String?
    /// `"<session>:<window>.<pane>"`, e.g. `main:@3541.%3541`. The first
    /// component is the tmux *session* name, not the server socket: every TBD
    /// repo server has a session called `main`, and so does a user's own
    /// default server. The pane alone is therefore not a machine-wide unique
    /// key, which is why the pane join below is paired with a `cwd` match.
    let tmux: String?
    let procStart: String?
    let version: String?
    let peerProtocol: Int?

    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case cwd
        case messagingSocketPath
        case name
        case status
        case tmux
        case procStart
        case version
        case peerProtocol
    }

    /// The pane component of `tmux`, normalised to include its `%`.
    ///
    /// Nil when the record carries no tmux coordinates — a plain-terminal
    /// `claude`, a `cloud` row, a shadow peer — and nil again when the value is
    /// not shaped like a pane id. A field that has changed shape must read as
    /// "no pane", never as a pane nothing can match: the first leaves a row
    /// unjoined and visible, the second is a join that quietly stops working.
    var tmuxPaneID: String? {
        guard let tmux, let pane = tmux.split(separator: ".").last, !pane.isEmpty else {
            return nil
        }
        let normalized = PeerJoinKeys.normalizedPaneID(String(pane))
        let digits = normalized.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return normalized
    }
}

/// One record, under the pid its filename names.
struct PeerRegistryEntry: Equatable, Sendable {
    let pid: pid_t
    let record: PeerRegistryRecord
}

/// What one read of the registry directory saw — **including what it could not
/// see**, which is the half a diagnostic command exists to report.
struct PeerRegistryScan: Equatable, Sendable {
    var entries: [PeerRegistryEntry] = []
    /// Filenames that parsed as `<pid>.json` but whose bytes would not read or
    /// decode. Skipped one at a time: a single torn or hand-edited file must
    /// not take the listing down with it.
    var malformedFilenames: [String] = []
    /// True when the directory could not be listed at all. Not an error: on a
    /// machine where no session has ever registered, it does not exist.
    var directoryUnreadable = false
}

/// The pure join keys, shared by the reader and the classifier.
///
/// A caseless enum rather than statics on a type, so nothing has to reason
/// about isolation to use them. These deliberately mirror the daemon's
/// `RosterJoinKeys`: the two subsystems join the same registry against the same
/// TBD rows, and a listing that joined differently from the roster would
/// describe a fleet the roster does not act on.
enum PeerJoinKeys {
    /// The pid a record filename names, or nil when the file is not a record.
    ///
    /// The round-trip is Claude Code's own rule — its loader parses the pid
    /// from the filename and rejects one that does not round-trip as an integer
    /// — and it is what keeps the third per-peer artifact
    /// (`<pid>.<sha256(messagingSocketPath)>.key`, one per live peer) and
    /// `ShadowPeerRecordStore`'s `.<name>.<uuid>.tmp` write-temps out of the
    /// listing without needing a list of things to exclude.
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
    /// stat the filesystem once per record to answer a question both sides of
    /// the comparison already agree on.
    static func normalizedPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized.count > 1, standardized.hasSuffix("/") else { return standardized }
        return String(standardized.dropLast())
    }
}

// MARK: - What the daemon could tell us

/// TBD's own rows, as far as this invocation could read them.
///
/// `reachable` is a separate fact from the arrays being empty: a fleet with no
/// worktrees and a daemon that never answered look identical otherwise, and the
/// difference decides whether an unjoined row means "TBD did not spawn this
/// session" or "nothing could be joined at all".
struct PeerListFleet: Equatable, Sendable {
    var reachable: Bool
    var worktrees: [Worktree]
    var terminals: [Terminal]
    /// The resolved value of the `remote_peer_messaging_enabled` config gate,
    /// or nil when the config could not be read. Nil is not "off" — the whole
    /// point of that tri-state column is that nobody has to guess.
    var remotePeerMessagingEnabled: Bool?
    /// The daemon's answer to `peer.status`: the durable shadow-peer ledger,
    /// each provider's link state, and whether each provider declared the
    /// `messages` capability. Nil when the daemon did not answer that call —
    /// an older daemon, or one that refused it — which narrows the listing
    /// (shadows fall back to being unrecognisable) rather than failing it.
    var bridge: PeerBridgeStatus?
    /// Why the daemon did not answer, when it did not. Carried so the warning
    /// can name the cause: "the daemon is not running" and "the daemon refused
    /// this call" send an operator to different places.
    var unreachableReason: String?

    init(
        reachable: Bool,
        worktrees: [Worktree] = [],
        terminals: [Terminal] = [],
        remotePeerMessagingEnabled: Bool? = nil,
        bridge: PeerBridgeStatus? = nil,
        unreachableReason: String? = nil
    ) {
        self.reachable = reachable
        self.worktrees = worktrees
        self.terminals = terminals
        self.remotePeerMessagingEnabled = remotePeerMessagingEnabled
        self.bridge = bridge
        self.unreachableReason = unreachableReason
    }

    /// The fleet as it reads when the daemon did not answer.
    static func unreachable(reason: String) -> PeerListFleet {
        PeerListFleet(reachable: false, unreachableReason: reason)
    }
}

// MARK: - Rows

/// What a peer row turned out to be.
///
/// `unattributed` is not a fourth kind of peer — it is the honest answer when
/// the daemon did not answer, so nothing could be joined. Rendering such a row
/// as `external` would state a fact ("TBD did not spawn this") that nothing
/// checked.
enum PeerRowKind: String, Encodable, Sendable {
    /// A session TBD spawned, joined to the worktree and terminal behind it.
    case local
    /// A shadow peer standing in for a session on another machine.
    case shadow
    /// A peer on this machine TBD did not spawn: a plain-terminal `claude`, a
    /// session on a profile TBD does not manage, or any other user of this
    /// shared directory. Listed, because the command lists every peer TBD can
    /// see and these are peers every local session can address.
    case external
    /// The daemon did not answer, so this row was joined against nothing.
    case unattributed

    /// Listing order: what TBD spawned, then what it mirrors, then everything
    /// else. Rows a daemonless run could not attribute sort last, which is
    /// immaterial — in that run they are the whole listing.
    var sortRank: Int {
        switch self {
        case .local: return 0
        case .shadow: return 1
        case .external: return 2
        case .unattributed: return 3
        }
    }
}

/// One peer row.
///
/// **There is no `ref` field, and that is deliberate.** A `[ref]` is minted by
/// Claude Code per record and lives only in what `ListAgents` renders — the
/// census of 84 live records found no key carrying it, so no reader of the
/// registry can produce one. An always-nil column would read as "this peer has
/// no ref" rather than "refs are not on disk", so the listing says the latter
/// in a closing note and prints the session id, which *is* on disk, instead.
///
/// Every row here is a **live** peer: the pid is running and is the process the
/// record was written for. A record failing either half is not a peer — the
/// membership test is a record plus a socket that answers — so it is reported
/// under `orphans` instead of as a row that lies about being addressable.
struct PeerRow: Encodable, Equatable, Sendable {
    let name: String
    let kind: PeerRowKind
    let status: String
    let pid: pid_t
    let sessionID: String?
    let cwd: String?
    let socketPath: String?
    /// False when the record names a socket path that is not on disk. The row
    /// is still listed — the record is what every other session reads — but
    /// nothing is listening at the address it advertises.
    let socketPresent: Bool
    /// The agent version the record carries, when it carries one. Diagnostic:
    /// messaging itself needs CLI ≥ 2.1.224, and a session below it registers
    /// no record at all, so a surprising value here explains a surprising fleet.
    let version: String?
    /// The peer protocol the record declares. TBD shadows a session only when
    /// it matches the protocol local sessions speak.
    let peerProtocol: Int?

    /// The worktree row behind this peer: the lane a local session runs in, or
    /// the lane a shadow was sited into. Nil for an `external` row, and for
    /// every row of a run that could not reach the daemon.
    let worktreeID: UUID?
    let worktreeDisplayName: String?
    /// The terminal behind a local session. A shadow has none: it stands in for
    /// a session on another machine and deliberately carries no tmux
    /// coordinates, so there is no pane to name.
    let terminalID: UUID?
    let tmuxPane: String?

    // Shadow rows: the provider session behind the shadow, and the link state.
    let provider: String?
    /// The **remote** session this shadow stands for, as the daemon's live link
    /// reports it. Nil when no live link vouches for the row — a shadow left
    /// over from a link that has since dropped, awaiting the sweep. Never
    /// filled in from the ledger's own `recordSessionID`, which is the id of
    /// the record published on *this* machine and names a different thing.
    let providerSessionID: String?
    /// `"up"` / `"down"` from `peer.status`, or `"unknown"` when the daemon did
    /// not answer that call — an older daemon, or one that refused it. Never a
    /// guess: a shadow whose link state cannot be established says so, because
    /// the whole cost of a stale link is a peer that lies about being
    /// reachable.
    let linkState: String?

    /// The name a nameless record is listed under. Deliberately not a guess at
    /// what Claude Code would show: a record with no `name` is one this listing
    /// cannot name, and saying so is the whole value.
    static let unnamed = "(unnamed)"
    /// The status a record carrying none is listed with. Deliberately **not**
    /// one of Claude Code's own words (`idle` / `busy` / `waiting` / `shell`):
    /// a value outside that vocabulary reads as "nobody said", where an
    /// invented `idle` would read as a fact and would be wrong exactly when a
    /// session is busy.
    static let unknownStatus = "unknown"
    /// The one value `linkState` takes today. See the field's note.
    static let unknownLinkState = "unknown"
}

/// A durable artifact nobody can account for.
///
/// **Listing is not reclaiming.** This command names what it sees and removes
/// nothing; `ShadowPeerReconciler` is the named owner of the reclamation, and
/// it reclaims against TBD's own durable bookkeeping rather than by inference.
/// The distinction matters most for `unclaimedSocket`, where inference would
/// race a real session between `bind()` and `listen()` — a report costs
/// nothing, a sweep on the same evidence would delete a live peer's listener.
enum PeerOrphanKind: String, Encodable, Sendable {
    /// A record whose pid is not running. Claude Code's reaper collects these
    /// on the next `ListAgents` — measured — so one here is a snapshot, not
    /// necessarily a leak.
    case deadRecord
    /// A record under a live pid that started at a different time: the
    /// **recycled-pid ghost**, which Claude Code's reaper provably will *not*
    /// collect, because it checks pid liveness and nothing else (measured).
    /// This is the one that accumulates.
    case ghostRecord
    /// A record that would not read or decode.
    case malformedRecord
    /// A socket file no record names. Nothing unlinks a dead one: the census
    /// found 92 socket files against roughly 80 records, the same shape as the
    /// ~7,100 orphaned tmux sockets recorded in `CLAUDE.md`.
    case unclaimedSocket

    /// The words a human reads, padded to a common width so the orphan block
    /// scans as a column without being a table.
    var label: String {
        switch self {
        case .deadRecord: return "dead record     "
        case .ghostRecord: return "ghost record    "
        case .malformedRecord: return "malformed record"
        case .unclaimedSocket: return "unclaimed socket"
        }
    }
}

struct PeerOrphan: Encodable, Equatable, Sendable {
    let kind: PeerOrphanKind
    let path: String
    let detail: String
}

/// The whole answer: rows, orphans, and everything the listing could not
/// establish.
struct PeerListResult: Encodable, Equatable, Sendable {
    let registryPath: String
    let peers: [PeerRow]
    let orphans: [PeerOrphan]
    /// Sentences naming what this listing could not establish. Present in both
    /// output modes: a diagnostic that quietly narrows its own scope is the
    /// failure this command exists to prevent.
    let warnings: [String]
    /// The resolved `remote_peer_messaging_enabled` gate, or nil when the
    /// config could not be read.
    let remotePeerMessagingEnabled: Bool?
    /// What the last `ShadowPeerReconciler` pass found, or nil when the daemon
    /// has not swept in this lifetime (or did not answer). Reported because
    /// every unbounded leak in this repo's history went unnoticed for want of
    /// a count somebody could read.
    let lastSweep: PeerShadowSweep?
}

// MARK: - Composition

/// Compose the whole listing.
///
/// - Parameters:
///   - registryPath: the directory `scan` was read from, for the closing note.
///   - scan: the registry directory as it was read.
///   - fleet: TBD's own rows, and whether the daemon answered at all.
///   - socketFilesOnDisk: absolute paths of every socket file found in the
///     directories the records themselves name. Empty when none was scanned,
///     which yields no `unclaimedSocket` orphans rather than a false clean bill
///     — the directory is only ever derived from a record, never guessed.
///   - procStartForPID: liveness. Returns the kernel's start time for a live
///     pid and nil for a dead one, which is both halves of the recycled-pid
///     check in one call.
///   - socketExists: whether the path a record advertises is on disk.
func composePeerListing(
    registryPath: String,
    scan: PeerRegistryScan,
    fleet: PeerListFleet,
    socketFilesOnDisk: [String] = [],
    procStartForPID: (pid_t) -> String?,
    socketExists: (String) -> Bool
) -> PeerListResult {
    var peers: [PeerRow] = []
    var orphans: [PeerOrphan] = []

    for filename in scan.malformedFilenames.sorted() {
        orphans.append(PeerOrphan(
            kind: .malformedRecord,
            path: filename,
            detail: "the record did not read or decode"))
    }

    let index = PeerFleetIndex(fleet: fleet)

    for entry in scan.entries.sorted(by: { $0.pid < $1.pid }) {
        guard let liveProcStart = procStartForPID(entry.pid) else {
            orphans.append(PeerOrphan(
                kind: .deadRecord,
                path: "\(entry.pid).json",
                detail: "pid \(entry.pid) is not running"))
            continue
        }
        if let claimed = entry.record.procStart, claimed != liveProcStart {
            orphans.append(PeerOrphan(
                kind: .ghostRecord,
                path: "\(entry.pid).json",
                detail: """
                    pid \(entry.pid) is alive but started \(liveProcStart); \
                    the record claims \(claimed)
                    """))
            continue
        }
        peers.append(index.row(for: entry, socketExists: socketExists))
    }

    // Both sides go through the same lexical normalisation. A directory
    // listing and a record's own string can spell the same socket differently,
    // and a spelling difference read as an orphan would report a false leak on
    // every single run — which is how a leak detector gets ignored.
    var claimedSockets: Set<String> = []
    for entry in scan.entries {
        if let path = nonEmptyPeerField(entry.record.messagingSocketPath) {
            claimedSockets.insert(PeerJoinKeys.normalizedPath(path))
        }
    }
    for path in socketFilesOnDisk.sorted() {
        if claimedSockets.contains(PeerJoinKeys.normalizedPath(path)) { continue }
        orphans.append(PeerOrphan(
            kind: .unclaimedSocket,
            path: path,
            detail: "no record names this socket"))
    }

    peers.sort { left, right in
        if left.kind != right.kind { return left.kind.sortRank < right.kind.sortRank }
        if left.name != right.name { return left.name < right.name }
        return left.pid < right.pid
    }

    return PeerListResult(
        registryPath: registryPath,
        peers: peers,
        orphans: orphans,
        warnings: peerListingWarnings(scan: scan, fleet: fleet),
        remotePeerMessagingEnabled: fleet.remotePeerMessagingEnabled,
        lastSweep: fleet.bridge?.lastSweep)
}

/// The joins, over TBD's own rows.
private struct PeerFleetIndex {
    private let reachable: Bool
    /// Claude session id → the terminal TBD captured it for. The stronger of
    /// the two local joins, because TBD wrote both sides of it.
    private let terminalsBySessionID: [String: Terminal]
    /// Normalised worktree path → the worktree row. Paired with the pane join
    /// below, because a pane id is unique per tmux *server* and TBD runs one
    /// server per repository alongside whatever servers the user runs.
    private let worktreesByPath: [String: Worktree]
    private let worktreesByID: [UUID: Worktree]
    /// (worktree, normalised pane) → terminal.
    private let terminalsByWorktreeAndPane: [PaneKey: Terminal]
    /// Helper pid → the shadow-peer ledger row filed under it. **This is the
    /// whole of how a shadow is recognised**, and it is TBD's own durable
    /// bookkeeping rather than an inference: a shadow's record carries no field
    /// Claude Code does not define (an unknown key was measured to make a
    /// record invisible to every listing), so there is nothing inside one to
    /// look for, and a path tells you nothing either.
    ///
    /// **Live rows only.** A row the daemon no longer vouches for is awaiting
    /// reclamation, not a peer, and a pid it still names may since have been
    /// recycled onto an unrelated session — indexing one would label that
    /// session with a dead link's provider and site it into someone else's
    /// lane. A record at a not-live row's pid falls through to the local join.
    private let shadowRowsByPID: [pid_t: PeerShadowArtifactRow]
    /// The link state the daemon reported per provider, so a shadow row can
    /// name its link without the listing inferring one.
    private let linkStateByProvider: [String: String]
    /// `(provider, remote session id)` → the worktree row TBD adopted that
    /// session into. An identity join on the key TBD itself stored, never a
    /// join on a composed name.
    private let remoteWorktreesByProviderSession: [ProviderSessionKey: Worktree]

    private struct PaneKey: Hashable {
        let worktreeID: UUID
        let pane: String
    }

    private struct ProviderSessionKey: Hashable {
        let provider: String
        let sessionID: String
    }

    init(fleet: PeerListFleet) {
        self.reachable = fleet.reachable

        var bySessionID: [String: Terminal] = [:]
        var byWorktreeAndPane: [PaneKey: Terminal] = [:]
        for terminal in fleet.terminals {
            if let sessionID = nonEmptyPeerField(terminal.claudeSessionID),
               bySessionID[sessionID] == nil {
                bySessionID[sessionID] = terminal
            }
            let key = PaneKey(
                worktreeID: terminal.worktreeID,
                pane: PeerJoinKeys.normalizedPaneID(terminal.tmuxPaneID))
            if byWorktreeAndPane[key] == nil { byWorktreeAndPane[key] = terminal }
        }
        self.terminalsBySessionID = bySessionID
        self.terminalsByWorktreeAndPane = byWorktreeAndPane

        var byPath: [String: Worktree] = [:]
        var byID: [UUID: Worktree] = [:]
        var byProviderSession: [ProviderSessionKey: Worktree] = [:]
        for worktree in fleet.worktrees {
            let path = PeerJoinKeys.normalizedPath(worktree.localPath)
            if byPath[path] == nil { byPath[path] = worktree }
            byID[worktree.id] = worktree
            if let binding = worktree.providerBinding {
                let key = ProviderSessionKey(
                    provider: binding.provider, sessionID: binding.sessionID)
                if byProviderSession[key] == nil { byProviderSession[key] = worktree }
            }
        }
        self.worktreesByPath = byPath
        self.worktreesByID = byID
        self.remoteWorktreesByProviderSession = byProviderSession

        var shadowRows: [pid_t: PeerShadowArtifactRow] = [:]
        var linkStates: [String: String] = [:]
        for row in fleet.bridge?.shadows ?? [] where row.live {
            shadowRows[pid_t(row.pid)] = row
        }
        for provider in fleet.bridge?.providers ?? [] {
            if let state = provider.linkState { linkStates[provider.provider] = state }
        }
        self.shadowRowsByPID = shadowRows
        self.linkStateByProvider = linkStates
    }

    func row(for entry: PeerRegistryEntry, socketExists: (String) -> Bool) -> PeerRow {
        let record = entry.record
        let socketPath = nonEmptyPeerField(record.messagingSocketPath)

        var kind = PeerRowKind.unattributed
        var worktree: Worktree?
        var terminal: Terminal?
        var provider: String?
        var providerSessionID: String?
        var linkState: String?

        if reachable {
            // **The ledger is asked first**, and it is the only thing that can
            // answer. A shadow's record is indistinguishable from any other
            // session's by construction — TBD may put no marker inside one —
            // so recognition comes from TBD's own durable bookkeeping, keyed on
            // the pid the record's filename already names.
            //
            // Only rows a live link still publishes are in that index, so a pid
            // matched here is one the daemon vouches for right now. A record
            // sitting at a not-live row's pid falls through to the local join
            // below and lists as whatever it actually is.
            if let row = shadowRowsByPID[entry.pid] {
                kind = .shadow
                provider = row.provider
                providerSessionID = row.remoteSessionID
                linkState = linkStateByProvider[row.provider] ?? PeerRow.unknownLinkState
                if let sessionID = row.remoteSessionID {
                    worktree = remoteWorktreesByProviderSession[ProviderSessionKey(
                        provider: row.provider, sessionID: sessionID)]
                }
            } else if let joined = localTerminal(for: record) {
                kind = .local
                terminal = joined
                worktree = worktreesByID[joined.worktreeID]
            } else {
                kind = .external
            }
        }

        // Set for a shadow as well as for a local row: a shadow was sited into
        // a worktree TBD adopted, and naming it is how an operator gets from a
        // peer back to a lane.
        var worktreeID: UUID?
        var worktreeDisplayName: String?
        if let worktree {
            worktreeID = worktree.id
            worktreeDisplayName = worktree.displayName
        }

        var pane = terminal.map { PeerJoinKeys.normalizedPaneID($0.tmuxPaneID) }
        if pane == nil { pane = record.tmuxPaneID }

        var socketPresent = false
        if let socketPath { socketPresent = socketExists(socketPath) }

        return PeerRow(
            name: nonEmptyPeerField(record.name) ?? PeerRow.unnamed,
            kind: kind,
            status: nonEmptyPeerField(record.status) ?? PeerRow.unknownStatus,
            pid: entry.pid,
            sessionID: nonEmptyPeerField(record.sessionID),
            cwd: nonEmptyPeerField(record.cwd),
            socketPath: socketPath,
            socketPresent: socketPresent,
            version: nonEmptyPeerField(record.version),
            peerProtocol: record.peerProtocol,
            worktreeID: worktreeID,
            worktreeDisplayName: worktreeDisplayName,
            terminalID: terminal?.id,
            tmuxPane: pane,
            provider: provider,
            providerSessionID: providerSessionID,
            linkState: linkState)
    }

    /// The local join, in the same two steps and the same order the roster
    /// admits on: the session id TBD captured through its `SessionStart` hook,
    /// then the worktree directory paired with the terminal's pane.
    ///
    /// Both fail closed. A TBD session whose hook never fired and whose
    /// worktree row has moved on lists as `external`, which understates what
    /// TBD knows rather than inventing a terminal for it.
    private func localTerminal(for record: PeerRegistryRecord) -> Terminal? {
        if let sessionID = nonEmptyPeerField(record.sessionID),
           let terminal = terminalsBySessionID[sessionID] {
            return terminal
        }
        guard let cwd = nonEmptyPeerField(record.cwd), let pane = record.tmuxPaneID,
              let worktree = worktreesByPath[PeerJoinKeys.normalizedPath(cwd)]
        else { return nil }
        return terminalsByWorktreeAndPane[PaneKey(worktreeID: worktree.id, pane: pane)]
    }
}

/// Everything the listing could not establish, said out loud.
private func peerListingWarnings(
    scan: PeerRegistryScan, fleet: PeerListFleet
) -> [String] {
    var warnings: [String] = []
    if scan.directoryUnreadable {
        warnings.append("""
            the peer registry directory could not be read, so no peer is listed. \
            It does not exist until a session on this machine registers as a peer.
            """)
    }
    if !fleet.reachable {
        let cause = fleet.unreachableReason.map { " (\($0))" } ?? ""
        warnings.append("""
            the TBD daemon did not answer\(cause), so no row could be joined to a \
            worktree, terminal or remote session. Every row below is listed unattributed.
            """)
    }
    if fleet.reachable, fleet.bridge == nil {
        warnings.append("""
            the daemon did not answer peer.status, so no shadow peer could be recognised \
            and no link state could be reported. A shadow is recognised only from TBD's \
            own durable bookkeeping — its record carries no marker of TBD's — so without \
            that answer a live shadow lists as an ordinary external peer.
            """)
    }
    if fleet.remotePeerMessagingEnabled == false {
        warnings.append("""
            remote peer messaging is off (config remote_peer_messaging_enabled), so TBD \
            publishes no shadow peers — a fleet with remote sessions still lists none here.
            """)
    }
    // The stale-shim answer. An old shim never declares `messages`, so TBD
    // never invokes it and the feature simply does nothing — which is the
    // failure this contract's users have been bitten by before, and the reason
    // the silence is answered here rather than accepted.
    if let bridge = fleet.bridge, bridge.messagingEnabled {
        let silent = bridge.providers
            .filter { !$0.declaresMessages }
            .map(\.provider)
            .sorted()
        if !silent.isEmpty {
            warnings.append("""
                remote peer messaging is on, but \(silent.joined(separator: ", ")) \
                \(silent.count == 1 ? "does" : "do") not declare the `messages` \
                capability, so TBD opens no stream to \
                \(silent.count == 1 ? "it" : "them") and mirrors none of \
                \(silent.count == 1 ? "its" : "their") sessions. That shim predates \
                remote peer messaging; update it.
                """)
        }
        let gated = bridge.providers
            .filter { $0.declaresMessages && !$0.bridged }
            .map(\.provider)
            .sorted()
        if !gated.isEmpty {
            warnings.append("""
                \(gated.joined(separator: ", ")) \
                \(gated.count == 1 ? "declares" : "declare") the `messages` capability \
                and \(gated.count == 1 ? "has" : "have") no bridge running. \
                \(peerMessagingRestartCaveat)
                """)
        }
        for provider in bridge.providers where !provider.unmirroredHandles.isEmpty {
            warnings.append("""
                \(provider.provider) announced \(provider.unmirroredHandles.count) peer(s) \
                TBD could not site and therefore did not mirror: a `peer` line carrying no \
                session id, or one naming a session TBD adopted no worktree row for.
                """)
        }
        for provider in bridge.providers
        where !provider.inventorySurplus.isEmpty || !provider.inventoryMissing.isEmpty {
            warnings.append("""
                \(provider.provider)'s own peer inventory diverges from what TBD asked it \
                to publish: \(provider.inventorySurplus.count) it publishes that TBD did \
                not ask for, \(provider.inventoryMissing.count) TBD asked for that it does \
                not publish. TBD cannot sweep the far host; this difference is the only \
                view of its hygiene.
                """)
        }
    }
    return warnings
}

// MARK: - Rendering

/// The whole listing as a human reads it, composed as one string so the
/// interesting cases can be asserted on the text a person actually sees.
func renderPeerListing(_ result: PeerListResult) -> String {
    var lines: [String] = []

    for warning in result.warnings {
        lines.append("warning: \(warning)")
    }
    if !result.warnings.isEmpty { lines.append("") }

    if result.peers.isEmpty {
        lines.append("No peers found in \(abbreviatedPeerPath(result.registryPath)).")
    } else {
        lines.append(tableRow([("NAME", 34), ("KIND", 13), ("STATUS", 8), ("BEHIND", 0)]))
        lines.append(String(repeating: "-", count: 100))
        for peer in result.peers {
            lines.append(tableRow([
                (peer.name, 34),
                (peer.kind.rawValue, 13),
                (peer.status, 8),
                (peerBehindColumn(peer), 0),
            ]))
        }
    }

    if !result.orphans.isEmpty {
        lines.append("")
        lines.append("Orphans (\(result.orphans.count)) — listed, not reclaimed:")
        for orphan in result.orphans {
            lines.append(
                "  \(orphan.kind.label)  \(abbreviatedPeerPath(orphan.path)) — \(orphan.detail)")
        }
    }

    if let sweep = result.lastSweep {
        lines.append("")
        lines.append("""
            Last shadow-peer sweep: reclaimed \(sweep.reclaimedArtifacts) artifact(s) \
            (helpers \(sweep.helpersKilled), records \(sweep.recordsUnlinked), \
            sockets \(sweep.socketsUnlinked)); kept \(sweep.liveShadowsKept) live, \
            \(sweep.withinGrace) within grace, \(sweep.unvouchedFor) unvouched-for, \
            left \(sweep.foreignArtifactsLeftAlone) foreign artifact(s) alone, \
            deferred \(sweep.deferred).
            """)
    }

    lines.append("")
    lines.append("""
        Registry: \(abbreviatedPeerPath(result.registryPath)). A `[ref]` is minted by \
        Claude Code per record and is never written to disk — read one from `ListAgents` \
        inside a session.
        """)

    return lines.joined(separator: "\n")
}

/// The `BEHIND` column: what stands behind this peer.
///
/// One column rather than several, because the answer has a different shape for
/// each kind, and empty cells across three-quarters of a table read as missing
/// data rather than as inapplicable.
func peerBehindColumn(_ peer: PeerRow) -> String {
    var parts: [String] = []
    switch peer.kind {
    case .local:
        parts.append(peer.worktreeDisplayName ?? "(worktree unknown)")
        if let pane = peer.tmuxPane { parts.append(pane) }
        if let terminalID = peer.terminalID {
            parts.append("terminal \(shortPeerID(terminalID))")
        }
    case .shadow:
        parts.append("\(peer.provider ?? "remote") session \(peer.providerSessionID ?? "(unknown)")")
        parts.append("link \(peer.linkState ?? PeerRow.unknownLinkState)")
    case .external:
        parts.append("not spawned by TBD")
        if let cwd = peer.cwd { parts.append(abbreviatedPeerPath(cwd)) }
    case .unattributed:
        parts.append("not joined")
        if let cwd = peer.cwd { parts.append(abbreviatedPeerPath(cwd)) }
    }
    if !peer.socketPresent {
        parts.append("socket missing")
    }
    return parts.joined(separator: " · ")
}

/// The first eight characters of a UUID — enough to name a row in a listing
/// that also prints the full value under `--json`.
func shortPeerID(_ id: UUID) -> String {
    String(id.uuidString.prefix(8))
}

/// `~`-abbreviated, for reading. Never used as a join key: every join above is
/// on an unabbreviated, lexically normalised path.
func abbreviatedPeerPath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}
